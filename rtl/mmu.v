// A shared Sv32 MMU design instantiated twice by cpu_core.v: once as the
// data MMU (translating load/store/AMO addresses in EX) and once as the
// instruction MMU (translating fetch addresses in IF), each with its own
// TLB and its own dedicated read-only walker port into `dmem` (page
// tables for *both* code and data mappings live in ordinary `dmem` RAM -
// see ARCHITECTURE.md's note on why that's safe despite this core's
// Harvard imem/dmem split). An 8-entry fully-associative TLB sits in
// front of a 2-level page-table walker. Deliberately simplified vs. the
// real spec:
//
//  - Only load/store/AMO addresses and instruction fetches are ever
//    translated when `satp.MODE=1` *and* the effective privilege for
//    that access isn't M - see cpu_core.v's `effective_priv_for_data`/
//    `current_priv` gating (mirrors real S/U-mode + MPRV semantics now
//    that this core actually has S/U privilege levels).
//  - No hardware A/D update: a PTE whose Accessed bit (or Dirty bit, for
//    a store) isn't already set faults rather than being auto-set.
//  - Physical addresses beyond 32 bits are silently truncated - this
//    core's whole memory system is 32-bit addressed, so satp/PTE PPN
//    fields wider than that never point anywhere real anyway.
//  - TLB permission bits are cached at install time and trusted on every
//    hit (never re-walked) - per spec, software must SFENCE.VMA after
//    changing a PTE that's could be cached, so this is correct as long as
//    that contract is honored. The U bit is cached alongside them, so the
//    user/supervisor check below applies identically on a hit and on a walk.
//
// The walker reads PTEs through its own read-only port (`ptw_addr`/
// `ptw_rdata`) so it never contends with the MEM stage's own load/store
// access (or, for the instruction-MMU instance, with the data MMU's own
// walker).
module mmu (
    input  wire        clk,
    input  wire        rst,

    input  wire        req,        // an access in IF/EX needs translation this cycle
    input  wire [31:0] va,
    input  wire        is_store,
    input  wire        is_fetch,   // instruction fetch: check X instead of R/W permission
    input  wire        is_user,    // effective privilege of this access is U (not S)
    input  wire        sum,        // mstatus.SUM: let S-mode read/write user pages
    input  wire        mxr,        // mstatus.MXR: let a load read an execute-only page
    input  wire        sfence,     // SFENCE.VMA: flush the whole TLB
    input  wire [21:0] satp_ppn,

    output wire         resolved,  // answer valid this cycle (hit, or a walk just concluded)
    output wire         fault,     // valid when resolved: 1 = page fault
    output wire [31:0]  pa,        // valid when resolved && !fault
    output wire         busy,      // mid-walk (drives the pipeline stall)

    output wire [31:0]  ptw_addr,
    input  wire [31:0]  ptw_rdata
);
    localparam S_IDLE = 2'd0, S_L1 = 2'd1, S_L2 = 2'd2;
    reg [1:0]  state;
    reg [31:0] va_r;
    reg        store_r;
    reg        fetch_r;
    // Latched with the request, like store_r/fetch_r, rather than read live
    // during the walk. A walk takes several cycles, and the pipeline behind
    // it keeps moving; sampling the privilege or the SUM/MXR bits at the end
    // would let an unrelated later instruction's state decide whether this
    // access is permitted.
    reg        user_r;
    reg        sum_r, mxr_r;
    reg [31:0] pte1_r;

    // ---- TLB ----
    reg        tlb_valid [0:7];
    reg [19:0] tlb_vpn   [0:7]; // va[31:12]; superpage entries compare only [19:10] (vpn1)
    reg        tlb_super [0:7];
    reg [21:0] tlb_ppn   [0:7]; // the leaf PTE's raw PPN field
    reg        tlb_r [0:7], tlb_w [0:7], tlb_x [0:7], tlb_a [0:7], tlb_d [0:7];
    reg        tlb_u [0:7];
    reg [2:0]  repl_ptr;

    integer i;
    reg       tlb_hit;
    reg [2:0] tlb_hit_idx;
    always @(*) begin
        tlb_hit     = 1'b0;
        tlb_hit_idx = 3'd0;
        for (i = 0; i < 8; i = i + 1) begin
            if (!tlb_hit && tlb_valid[i] &&
                (tlb_super[i] ? (tlb_vpn[i][19:10] == va[31:22]) : (tlb_vpn[i] == va[31:12]))) begin
                tlb_hit     = 1'b1;
                tlb_hit_idx = i[2:0];
            end
        end
    end

    // Sv32 permission check, shared by the TLB-hit path and both walk levels.
    //
    // The user/supervisor rule is the part that was missing entirely before:
    // without it a U-mode access could reach a supervisor page and an S-mode
    // access could reach a user page, which is the whole isolation boundary
    // the U bit exists to draw. riscv-tests found the thread (rv32mi-p-illegal
    // probes for SUM/MXR); the missing U check was underneath it.
    //
    //  - U-mode may only touch pages with U=1.
    //  - S-mode may only touch pages with U=1 if SUM is set, and *never* may
    //    fetch instructions from one regardless of SUM - the spec carves
    //    execution out explicitly, so that SUM cannot be used to make user
    //    code executable at supervisor privilege.
    //  - MXR widens a load (not a fetch) to accept an execute-only page.
    function perm_ok;
        input pu, pr, pw, px, pa, pd;   // the PTE's permission bits
        input fetch, store, user, sum_b, mxr_b;
        begin
            if (!pa)                                   perm_ok = 1'b0; // no hardware A/D update
            else if (user && !pu)                      perm_ok = 1'b0;
            else if (!user && pu && (fetch || !sum_b)) perm_ok = 1'b0;
            else if (fetch)                            perm_ok = px;
            else if (store)                            perm_ok = pw && pd;
            else                                       perm_ok = pr || (mxr_b && px);
        end
    endfunction

    wire perm_ok_hit = perm_ok(tlb_u[tlb_hit_idx], tlb_r[tlb_hit_idx],
                               tlb_w[tlb_hit_idx], tlb_x[tlb_hit_idx],
                               tlb_a[tlb_hit_idx], tlb_d[tlb_hit_idx],
                               is_fetch, is_store, is_user, sum, mxr);
    wire [33:0] pa_hit_normal_wide = {tlb_ppn[tlb_hit_idx], va[11:0]};
    wire [33:0] pa_hit_super_wide  = {tlb_ppn[tlb_hit_idx][21:10], va[21:0]};
    wire [31:0] pa_hit_normal = pa_hit_normal_wide[31:0];
    wire [31:0] pa_hit_super  = pa_hit_super_wide[31:0];
    wire [31:0] pa_hit        = tlb_super[tlb_hit_idx] ? pa_hit_super : pa_hit_normal;

    // ---- walker ----
    wire [9:0]  vpn1 = va_r[31:22];
    wire [9:0]  vpn0 = va_r[21:12];
    wire [33:0] l1_table_pa = {satp_ppn, 12'b0};
    wire [33:0] l1_sum      = l1_table_pa + {22'b0, vpn1, 2'b00};
    wire [31:0] l1_addr     = l1_sum[31:0];

    wire v1 = pte1_r[0], r1 = pte1_r[1], w1 = pte1_r[2], x1 = pte1_r[3];
    wire u1 = pte1_r[4], a1 = pte1_r[6], d1 = pte1_r[7];
    wire leaf1       = v1 && (r1 || (x1 && !w1));
    wire reserved1   = v1 && !r1 && w1;
    wire misaligned1 = leaf1 && (pte1_r[19:10] != 10'b0); // superpage needs PPN[0]=0

    wire [33:0] l2_table_pa = {pte1_r[31:10], 12'b0};
    wire [33:0] l2_sum      = l2_table_pa + {22'b0, vpn0, 2'b00};
    wire [31:0] l2_addr     = l2_sum[31:0];

    assign ptw_addr = (state == S_L1) ? l1_addr : l2_addr;
    wire [31:0] pte2 = ptw_rdata; // only meaningful while in S_L2 and pte1 was a pointer

    wire v2 = pte2[0], r2 = pte2[1], w2 = pte2[2], x2 = pte2[3];
    wire u2 = pte2[4], a2 = pte2[6], d2 = pte2[7];
    wire leaf2     = v2 && (r2 || (x2 && !w2));
    wire reserved2 = v2 && !r2 && w2;

    wire l1_conclusive = !v1 || reserved1 || leaf1; // fault-or-leaf at level 1: no level-2 read needed

    wire fault_from_l1 = !v1 || reserved1 || misaligned1 ||
                          !perm_ok(u1, r1, w1, x1, a1, d1,
                                   fetch_r, store_r, user_r, sum_r, mxr_r);
    wire fault_from_l2 = !v2 || reserved2 || !leaf2 ||
                          !perm_ok(u2, r2, w2, x2, a2, d2,
                                   fetch_r, store_r, user_r, sum_r, mxr_r);

    wire        walk_fault = l1_conclusive ? fault_from_l1 : fault_from_l2;
    wire [33:0] walk_pa_super_wide  = {pte1_r[31:20], vpn0, va_r[11:0]};
    wire [33:0] walk_pa_normal_wide = {pte2[31:10], va_r[11:0]};
    wire [31:0] walk_pa    = l1_conclusive ? walk_pa_super_wide[31:0]
                                            : walk_pa_normal_wide[31:0];

    assign busy     = (state != S_IDLE);
    assign resolved = (state == S_IDLE) ? (req && tlb_hit) : (state == S_L2);
    assign fault    = (state == S_IDLE) ? !perm_ok_hit : walk_fault;
    assign pa       = (state == S_IDLE) ? pa_hit : walk_pa;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state    <= S_IDLE;
            repl_ptr <= 3'd0;
            for (i = 0; i < 8; i = i + 1) tlb_valid[i] <= 1'b0;
        end else if (sfence) begin
            for (i = 0; i < 8; i = i + 1) tlb_valid[i] <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (req && !tlb_hit) begin
                        va_r    <= va;
                        store_r <= is_store;
                        fetch_r <= is_fetch;
                        user_r  <= is_user;
                        sum_r   <= sum;
                        mxr_r   <= mxr;
                        state   <= S_L1;
                    end
                end
                S_L1: begin
                    pte1_r <= ptw_rdata; // l1_addr has been on ptw_addr this whole cycle
                    state  <= S_L2;
                end
                S_L2: begin
                    if (!walk_fault) begin
                        tlb_valid[repl_ptr] <= 1'b1;
                        tlb_vpn[repl_ptr]   <= va_r[31:12];
                        tlb_super[repl_ptr] <= l1_conclusive;
                        tlb_ppn[repl_ptr]   <= l1_conclusive ? pte1_r[31:10] : pte2[31:10];
                        tlb_r[repl_ptr]     <= l1_conclusive ? r1 : r2;
                        tlb_w[repl_ptr]     <= l1_conclusive ? w1 : w2;
                        tlb_x[repl_ptr]     <= l1_conclusive ? x1 : x2;
                        tlb_a[repl_ptr]     <= l1_conclusive ? a1 : a2;
                        tlb_d[repl_ptr]     <= l1_conclusive ? d1 : d2;
                        tlb_u[repl_ptr]     <= l1_conclusive ? u1 : u2;
                        repl_ptr <= repl_ptr + 3'd1;
                    end
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
