// Formal properties for rtl/pmp.v.
//
// rtl/pmp.v is pure combinational logic with no state, so every property
// here is really a claim about every possible input combination at a single
// instant - the bound (DEPTH cycles) buys nothing extra for this module the
// way it does for the PLIC or BTB, but running it anyway costs nothing and
// keeps this file the same shape as every other formal target.
//
// Three properties, each picked because it is exactly the kind of thing a
// plausible implementation bug gets backwards, not because it is easy to
// state:
//   1. The fully-unconfigured default: with every entry OFF, M-mode is
//      allowed and S/U-mode is denied. This is the rule that makes turning
//      PMP enforcement *on* a hazard the moment any entry is real (see
//      rtl/pmp.v's header) - getting the direction of this default backwards
//      would either lock out every S/U-mode access with zero configuration,
//      or silently grant M-mode nothing.
//   2. An entry covering the whole address space, unlocked, full RWX: every
//      access from every privilege is allowed, regardless of what any other
//      entry says - proves priority (entry 0 is consulted first) and
//      totality (NAPOT's maximal encoding really does cover all 2^32 bytes,
//      the exact case rtl/pmp.v's 33-bit base/top exists for) together.
//   3. The same region, but locked with all-zero permissions: every access
//      from every privilege, M included, is denied - proves the lock bit
//      really does withdraw M-mode's usual bypass, not just S/U's default.
module fv_pmp (
    input wire [127:0] pmpcfg,
    input wire [511:0] pmpaddr,
    input wire [31:0]  addr,
    input wire [1:0]   size,
    input wire         is_write,
    input wire         is_fetch,
    input wire [1:0]   priv
);
    localparam [1:0] PRIV_M = 2'b11;

    wire fault;
    pmp DUT (
        .pmpcfg(pmpcfg), .pmpaddr(pmpaddr),
        .addr(addr), .size(size), .is_write(is_write), .is_fetch(is_fetch),
        .priv(priv), .fault(fault)
    );

    // 1. Fully unconfigured: no entry has ever been given a mode other than
    // OFF (A field == 00 in every one of the 16 pmpNcfg bytes).
    wire nothing_configured =
        (pmpcfg[4:3]==2'b00) && (pmpcfg[12:11]==2'b00) && (pmpcfg[20:19]==2'b00) &&
        (pmpcfg[28:27]==2'b00) && (pmpcfg[36:35]==2'b00) && (pmpcfg[44:43]==2'b00) &&
        (pmpcfg[52:51]==2'b00) && (pmpcfg[60:59]==2'b00) && (pmpcfg[68:67]==2'b00) &&
        (pmpcfg[76:75]==2'b00) && (pmpcfg[84:83]==2'b00) && (pmpcfg[92:91]==2'b00) &&
        (pmpcfg[100:99]==2'b00) && (pmpcfg[108:107]==2'b00) && (pmpcfg[116:115]==2'b00) &&
        (pmpcfg[124:123]==2'b00);

    always @(*) begin
        if (nothing_configured)
            assert (fault == (priv != PRIV_M));
    end

    // 2/3 share a fixture: entry 0 is NAPOT, A=11, covering the whole space
    // (pmpaddr0 = all-ones - the real "open everything" encoding), every
    // other entry left fully unconstrained (proving entry 0 alone decides
    // the outcome). L/X/W/R come from the properties below.
    wire entry0_is_max_napot =
        (pmpcfg[4:3] == 2'b11) && (pmpaddr[31:0] == 32'hFFFF_FFFF);

    // Properties 2 and 3 need the same precondition the real caller already
    // guarantees (rtl/pmp.v's header, and cpu_core.v's mem_misaligned,
    // checked before PMP ever runs): the access is naturally aligned to its
    // own size. Without this, z3 finds e.g. addr=0xFFFFFFFF with a 4-byte
    // size - a real counterexample against the *property*, not the module:
    // that access's nominal top (0x100000003) spills past the 32-bit space
    // the maximal NAPOT region actually covers (exactly up to 0x100000000,
    // see rtl/pmp.v's header on why that boundary needs the extra address
    // bit at all), so it is correctly judged not fully contained - a
    // real caller can never produce it. Found by running this, not assumed.
    wire aligned = (size == 2'd0) ||
                   (size == 2'd1 && !addr[0]) ||
                   (size == 2'd2 && addr[1:0] == 2'b00);

    // 2. Unlocked, full permissions: always allowed, whoever else is
    // configured and whatever they say.
    always @(*) begin
        if (aligned && entry0_is_max_napot && !pmpcfg[7] &&
            pmpcfg[2] && pmpcfg[1] && pmpcfg[0]) // X=W=R=1, L=0
            assert (!fault);
    end

    // 3. Locked, zero permissions: always denied, M-mode included.
    always @(*) begin
        if (aligned && entry0_is_max_napot && pmpcfg[7] &&
            !pmpcfg[2] && !pmpcfg[1] && !pmpcfg[0]) // X=W=R=0, L=1
            assert (fault);
    end
endmodule
