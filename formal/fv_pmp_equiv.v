// rtl/pmp.v against formal/pmp_ref.v, the byte-granular algorithm it was
// restructured from: for every pmpcfg/pmpaddr/access/privilege combination -
// including accesses that are not naturally aligned, which cpu_core.v never
// presents but rtl/pmp.v's straddle path exists to deny safely - the two
// must agree on `fault`.
module fv_pmp_equiv (
    input wire [127:0] pmpcfg,
    input wire [511:0] pmpaddr,
    input wire [31:0]  addr,
    input wire [1:0]   size,
    input wire         is_write,
    input wire         is_fetch,
    input wire [1:0]   priv
);
    wire f_new, f_ref;
    pmp     NEW (.pmpcfg(pmpcfg), .pmpaddr(pmpaddr), .addr(addr), .size(size),
                 .is_write(is_write), .is_fetch(is_fetch), .priv(priv), .fault(f_new));
    pmp_ref REF (.pmpcfg(pmpcfg), .pmpaddr(pmpaddr), .addr(addr), .size(size),
                 .is_write(is_write), .is_fetch(is_fetch), .priv(priv), .fault(f_ref));

    always @(*) assert (f_new == f_ref);
endmodule
