// Physical Memory Protection: address matching + permission resolution
// against the 16 pmpcfg/pmpaddr entries csr_file.v stores. Pure combinational
// logic, no state. (Written standalone and instantiated later - cpu_core.v and
// core_ooo.v now enforce through it; what follows is the original account.) See
// docs/roadmap/beyond-the-phases.md's PMP entry for why wiring enforcement into an actual
// access path is a separate, more hazardous round (it changes the *default*
// rule for every S/U-mode memory access the moment any entry is real) and is
// deliberately not part of this one. This module exists now, verified in
// isolation (sim/tb_pmp.v, formal/fv_pmp.v), so that round can wire a
// finished, trusted piece rather than build and verify the matching algorithm
// under the same time pressure as the pipeline integration.
//
// Priority: entry 0 is checked first; the lowest-numbered entry whose range
// overlaps the access at all is *the* match, whether or not it grants
// permission - lower-priority entries are never consulted once one overlaps,
// matching the spec's "first match wins" rule.
//
// Straddling access: per spec, an access that overlaps a region without
// being fully contained in it still counts as *matched* (stopping the
// search) but is denied regardless of the region's R/W/X bits - permission
// is only granted to an access fully inside the matching region. This is
// kept general (checked for every mode, TOR included) even though it is
// unreachable in this design today: pmpaddr always stores address>>2 - true
// for TOR's bounds exactly as much as NA4/NAPOT's, not just the
// power-of-two modes - so every region boundary is inherently 4-byte
// granular, and this core's accesses are at most 4 bytes and (once
// mem_misaligned in cpu_core.v has run) always naturally aligned to their
// own size. A boundary that can only ever land on a multiple of 4 can never
// be straddled by an access that is itself at most 4 bytes and aligned to
// its own size - checked by construction in sim/tb_pmp.v's test 5, not
// assumed. sim/tb_pmp.v also feeds this module one deliberately-misaligned
// access directly (bypassing the guarantee cpu_core.v would otherwise
// provide) specifically to confirm the straddle path still denies safely
// if it is ever reached - defense in depth for a real caller that should
// never exercise it, not dead code.
//
// M-mode is exempt from every entry whose lock bit (L) is clear: an
// unlocked match grants M-mode access unconditionally, independent of the
// entry's own R/W/X. Once L is set, the entry's R/W/X apply to M-mode too,
// which is the whole point of locking - it is the only way for M-mode
// firmware to protect a region from *itself* as well as from S/U.
//
// Default when no entry matches at all: M-mode is allowed (nothing has
// restricted it), S/U-mode is denied. That default flips the moment any
// PMP hardware exists, spec-mandated - real firmware (OpenSBI's generic
// PMP init) is expected to configure an open region during boot for exactly
// this reason. See docs/roadmap/beyond-the-phases.md for why that firmware-side dependency is
// what keeps this module unwired for now.
module pmp (
    input  wire [127:0] pmpcfg,   // 16 x 8-bit pmpNcfg: pmpcfg[8*i +: 8] = pmp[i]cfg
    input  wire [511:0] pmpaddr,  // 16 x 32-bit pmpaddrN: pmpaddr[32*i +: 32] = pmpaddrN
    input  wire [31:0]  addr,     // physical address of the access (naturally aligned)
    input  wire [1:0]   size,     // 0=byte, 1=halfword, 2=word
    input  wire         is_write, // store, or an AMO other than LR - see cpu_core.v's
                                   // identical is_lr carve-out for the data MMU, mirrored
                                   // here so PMP and paging agree on what an AMO needs
    input  wire         is_fetch, // instruction fetch: check X instead of R/W
    input  wire [1:0]   priv,     // effective privilege of this access
    output wire         fault     // 1 = PMP denies the access
);
    localparam [1:0] PRIV_M = 2'b11;

    // Everything below compares in word space (address >> 2), not byte
    // space. Every region bound is a multiple of 4 - pmpaddr holds address>>2
    // for TOR as much as for NA4/NAPOT - so for any byte address a and bound
    // b (b a multiple of 4), `a < b` is `a[31:2] < b>>2` and `a >= b` is
    // `a[31:2] >= b>>2`; the exclusive end of the access, addr+size, is
    // tested through its *last byte* (addr+size-1): `addr+size > b` is
    // `last>>2 >= b>>2` and `addr+size <= b` is `last>>2 < b>>2`. That
    // replaces a pair of 33-bit byte comparators per entry (and a 33-bit
    // access-end adder feeding all sixteen) with 31-bit word comparators
    // against two values computed once, here. It is exact for every input,
    // not only for aligned accesses: formal/fv_pmp_equiv.v proves `fault`
    // equal to formal/pmp_ref.v's byte-granular original for all of them,
    // the deliberately misaligned straddle case included.
    wire [29:0] lo_w = addr[31:2];
    // Last byte of the access: addr + 0, 1 or 3. One bit wider than the
    // address because addr = 0xFFFFFFFF with a word access ends past 2^32.
    wire [32:0] last_byte = {1'b0, addr} + ((size == 2'd0) ? 33'd0 :
                                            (size == 2'd1) ? 33'd1 : 33'd3);
    wire [30:0] last_w = last_byte[32:2];

    wire [15:0] entry_hit_vec, entry_permit_vec, entry_l_vec;

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : PMP_ENTRY
            wire [7:0]  cfg    = pmpcfg[8*gi +: 8];
            wire        l_bit  = cfg[7];
            wire [1:0]  a_mode = cfg[4:3];
            wire        x_bit  = cfg[2];
            wire        w_bit  = cfg[1];
            wire        r_bit  = cfg[0];
            wire [31:0] a_this = pmpaddr[32*gi +: 32];
            wire [31:0] a_prev = (gi == 0) ? 32'b0 : pmpaddr[32*(gi-1) +: 32];

            // Region bounds in word space, exclusive top, 31 bits: the byte
            // form was 33 bits (bound = word<<2), so pmpaddr[31] has always
            // fallen off the top of a shift and pmpaddr[30] has landed in
            // the 33rd bit - and the NA4 top wraps at 2^33 bytes, which is
            // 2^31 words. The 31-bit words here keep exactly that, unchanged.
            reg [30:0] base_w, top_w;

            // NAPOT: the count of trailing one-bits in a_this sets both the
            // region size (2^(t+3) bytes) and how many low bits of the base
            // are "don't care". `mask = a_this ^ (a_this + 1)` sets exactly
            // those t+1 bits (the t ones plus the terminating zero) - the
            // standard trick, not this project's invention, but re-derived
            // and checked here rather than trusted on the strength of
            // pattern-matching it from elsewhere. Worked example: a_this
            // ending ...0111 (t=3 trailing ones) -> +1 ends ...1000 -> XOR
            // ends ...1111 (4 = t+1 bits set), region size 2^(3+3)=64 bytes.
            wire [29:0] napot_mask = a_this[29:0] ^ (a_this[29:0] + 30'd1);
            wire [29:0] napot_base_hi = a_this[29:0] & ~napot_mask;
            // Region size in words, up to 2^30 exactly (the "whole 32-bit
            // space" maximal encoding - all of a_this[29:0] set), which is
            // why this needs 31 bits and not 30: the canonical "open
            // everything" encoding real firmware uses ends exactly on 2^32
            // bytes. Written out as its own wire, rather than folded into
            // `top_w`, for the reason the byte-space version did: Verilator's
            // width inference on the folded form was genuinely ambiguous
            // (WIDTHEXPAND, caught by `make sim_opensbi`'s Verilator build and
            // not by Icarus - "no warnings" from one simulator is not the
            // same claim as "no warnings").
            wire [30:0] napot_size_w = {1'b0, napot_mask} + 31'd1;

            always @(*) begin
                case (a_mode)
                    2'b01: begin // TOR: [pmpaddr[i-1], pmpaddr[i])
                        base_w = a_prev[30:0];
                        top_w  = a_this[30:0];
                    end
                    2'b10: begin // NA4: exactly 4 bytes at pmpaddr[i]<<2
                        base_w = a_this[30:0];
                        top_w  = base_w + 31'd1;
                    end
                    2'b11: begin // NAPOT
                        base_w = {1'b0, napot_base_hi};
                        top_w  = base_w + napot_size_w;
                    end
                    default: begin // OFF
                        base_w = 31'b0;
                        top_w  = 31'b0;
                    end
                endcase
            end

            wire active   = (a_mode != 2'b00);
            wire overlaps = active && (last_w >= base_w) && ({1'b0, lo_w} < top_w);
            wire contains = ({1'b0, lo_w} >= base_w) && (last_w < top_w);
            wire grant    = is_fetch ? x_bit : (is_write ? w_bit : r_bit);

            assign entry_hit_vec[gi]    = overlaps;
            assign entry_permit_vec[gi] = overlaps && contains && grant;
            assign entry_l_vec[gi]      = l_bit;
        end
    endgenerate

    // Priority encode: iterate high index to low, unconditionally
    // overwriting on every hit - the last (lowest-index) write wins, which
    // is exactly "lowest-numbered matching entry, checked first".
    integer k;
    reg matched, permitted, entry_locked;
    always @(*) begin
        matched      = 1'b0;
        permitted    = 1'b0;
        entry_locked = 1'b0;
        for (k = 15; k >= 0; k = k - 1) begin
            if (entry_hit_vec[k]) begin
                matched      = 1'b1;
                permitted    = entry_permit_vec[k];
                entry_locked = entry_l_vec[k];
            end
        end
    end

    wire m_unlocked_bypass = (priv == PRIV_M) && !entry_locked;
    wire allow_matched     = m_unlocked_bypass || permitted;
    wire allow_unmatched   = (priv == PRIV_M);

    assign fault = matched ? !allow_matched : !allow_unmatched;
endmodule
