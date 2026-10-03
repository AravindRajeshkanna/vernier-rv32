// The byte-granular reference for rtl/pmp.v: the matching algorithm exactly as
// it stood before rtl/pmp.v was restructured to compare in word space (one
// shared last-byte adder instead of a 33-bit byte comparator pair in every
// entry). It is the specification, not a design - nothing instantiates it
// outside formal/fv_pmp_equiv.v, which proves rtl/pmp.v's `fault` equals this
// module's for every input, so the restructuring cannot have changed what the
// PMP decides. rtl/pmp.v's own header explains the semantics (priority,
// straddle, M-mode exemption, default); they are not repeated here.
module pmp_ref (
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

    // Access byte range, as an exclusive [lo, hi) pair. One bit wider than
    // the address so a full 4 GiB region (base 0, top exactly 2^32) does
    // not silently wrap to 0 - the canonical "open everything" NAPOT
    // encoding real firmware uses lands exactly on that boundary.
    reg [32:0] acc_lo, acc_hi;
    always @(*) begin
        acc_lo = {1'b0, addr};
        case (size)
            2'd0:    acc_hi = acc_lo + 33'd1;
            2'd1:    acc_hi = acc_lo + 33'd2;
            default: acc_hi = acc_lo + 33'd4;
        endcase
    end

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

            // Region bounds in byte-address space, exclusive top, one bit
            // wider than addr for the same reason acc_hi is - see above.
            reg [32:0] base, top;

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
            // Region size in bytes, as an explicit 33-bit value before any
            // arithmetic touches it - up to 2^32 exactly (the "whole 32-bit
            // space" maximal encoding), which is why this needs the extra
            // bit rather than fitting in 32. Written out this way, rather
            // than folded into the `top` expression below, because folding
            // it left Verilator's width inference genuinely ambiguous about
            // which sub-expression was supposed to carry 33 bits
            // (WIDTHEXPAND, caught by `make sim_opensbi`'s Verilator build,
            // not by Icarus - iverilog accepted the folded form without
            // complaint, another reminder that "no warnings" from one
            // simulator is not the same claim as "no warnings").
            wire [32:0] napot_size = ({3'b000, napot_mask} + 33'd1) << 2;

            always @(*) begin
                case (a_mode)
                    2'b01: begin // TOR: [pmpaddr[i-1], pmpaddr[i])
                        base = {1'b0, a_prev} << 2;
                        top  = {1'b0, a_this} << 2;
                    end
                    2'b10: begin // NA4: exactly 4 bytes at pmpaddr[i]<<2
                        base = {1'b0, a_this} << 2;
                        top  = base + 33'd4;
                    end
                    2'b11: begin // NAPOT
                        base = {1'b0, napot_base_hi, 2'b00};
                        top  = base + napot_size;
                    end
                    default: begin // OFF
                        base = 33'b0;
                        top  = 33'b0;
                    end
                endcase
            end

            wire active   = (a_mode != 2'b00);
            wire overlaps = active && (acc_hi > base) && (acc_lo < top);
            wire contains = (acc_lo >= base) && (acc_hi <= top);
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
