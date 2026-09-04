// ---------------------------------------------------------------------------
// A 5-stage pipelined RV32IMA CPU core (base integer ISA + Zicsr + the M
// multiply/divide extension + the A atomic extension), with full M/S/U
// privilege modes and trap delegation, timer/software/external interrupts
// (the external source now a real prioritized/claimable PLIC), a data AND
// instruction Sv32 MMU (independent TLBs/walkers), and a BTB + 2-bit
// saturating-counter dynamic branch predictor. Harvard architecture:
// separate instruction and data memory ports.
//
// Stages: IF -> ID -> EX -> MEM -> WB, separated by pipeline registers
// if_id / id_ex / ex_mem / mem_wb. A pipeline register with its `valid`
// bit clear is a bubble: every consumer of its control fields (reg_we,
// mem_we, is_branch, ..., csr_we) gates on `valid` before trusting them,
// so a bubble can never write regfile/dmem/CSRs or trigger a redirect.
//
// Hazards:
//  - Data hazards are resolved by forwarding EX/MEM and MEM/WB results
//    back into the EX stage's operands (see the `fwd1_*`/`fwd2_*` block).
//  - A load-use hazard (a load/AMO/LR immediately followed by a dependent
//    instruction) can't be fixed by forwarding alone, since the value
//    isn't ready until MEM - it costs a 1-cycle stall instead
//    (`load_use_stall` freezes PC/IF-ID and inserts a bubble into ID/EX).
//  - A busy DIV/DIVU/REM/REMU or a translating load/store/AMO is a
//    different shape of stall (`ex_busy_stall`): the *same* instruction
//    stays in EX for multiple cycles (ID/EX holds its own contents
//    unchanged, rather than becoming a bubble) while EX/MEM is fed
//    bubbles, until the divider or the data MMU walker finishes.
//  - IF itself can now also stall or fault, independently of the above:
//    a translating instruction fetch that misses the ITLB freezes PC and
//    bubbles IF/ID (`if_stall`) until the instruction-MMU walker
//    resolves - this is a genuinely different, orthogonal condition from
//    `id_ex`'s own hold/bubble logic (`id_ex_stall`), which reacts only
//    to whatever `if_id_valid` says and needs no awareness of `if_stall`
//    at all. Folding the two together would let `if_id` be held *and*
//    consumed in the same cycle, silently double-executing an
//    instruction - see the `if_id` register block below for the exact
//    3-way split that avoids this.
//  - Control hazards are now resolved by a BTB: a correctly-predicted
//    branch/JAL/JALR costs nothing, and only a genuine `mispredict`
//    (including the new "predicted taken but actually not taken, recover
//    to PC+4" case) redirects, at the same 2-cycle flush cost a taken
//    branch always paid before. Trap entry and MRET/SRET always redirect.
//
// Trap priority in EX (highest first): a pending, enabled interrupt >
// a synchronous exception (illegal instruction/ECALL/EBREAK/instruction-
// page-fault from ID, or a data-MMU page fault discovered once a walk
// concludes) > a branch/JAL/JALR misprediction > MRET/SRET. An interrupt
// preempts whatever instruction is currently in EX entirely - unlike a
// synchronous exception (which naturally has no side effects of its own),
// an interrupted instruction is otherwise perfectly valid, so its
// reg/mem/CSR/MRET/SRET writes must be actively suppressed
// (`!interrupt_taken` gating) and mepc/sepc points at it so it's simply
// re-fetched after the trap returns. Interrupts are only sampled when EX
// isn't already in the middle of a busy divide/walk (`!ex_busy_stall`) -
// a multi-cycle op always runs to completion first.
//
// A trap lands in S-mode instead of M-mode only if the hart wasn't
// already in M (traps never move to a *less* privileged mode than where
// they occurred) and the specific cause is delegated via medeleg/mideleg
// - see csr_file.v for the actual delegation logic, exposed here as
// `csr_trap_to_s`.
//
// This is an educational core, not a performance-tuned design. See
// docs/architecture.md for the full design writeup and README.md for what
// would actually be required to run Linux.
// ---------------------------------------------------------------------------
module cpu_core #(
    parameter RESET_PC = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        rst,

    // instruction memory port (physical address, post-translation if active)
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    // High while an ITLB walk for the fetch we want has not yet resolved -
    // i.e. `imem_addr` is `itlb_pa_hold`, not a translation of the current
    // PC. A bus adapter uses this to keep that held address from ever
    // hitting the cache or issuing a request while it's stale; see the
    // `itlb_pa_hold` comment below and rtl/soc/cpu_wb.v.
    output wire         itlb_wait_stall,

    // data memory port (physical address, post-translation if active)
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire         dmem_we,
    output wire         dmem_re,   // asserted exactly on a real load - lets
                                    // a peripheral with a read side effect
                                    // (the PLIC's claim register) tell a
                                    // genuine load apart from "this address
                                    // just happens to be on the bus"
    output wire [1:0]   dmem_size,
    input  wire [31:0] dmem_rdata,
    // `dmem_rdata` this cycle is the answer to the read that was asked for,
    // rather than whatever the port happens to be showing. The MEM stage's
    // AMO read/write phases key off this: the read value is captured the
    // cycle this is high, and the write is issued the cycle after. A
    // zero-latency memory answers immediately and ties this high
    // (rtl/top.v); a bus adapter drives it from the read acknowledgement
    // (rtl/soc/cpu_wb.v).
    input  wire         dmem_rvalid,
    output wire         dmem_is_amo, // this MEM access is an AMO/LR/SC - a bus
                                      // adapter needs to know, since an AMO is a
                                      // read-modify-write that takes two bus
                                      // phases (see rtl/soc/cpu_wb.v)

    // Bus wait states. Both default to "never wait" for a zero-latency
    // memory system (rtl/top.v ties them low, so that path is bit-identical
    // to before these existed); a real interconnect (rtl/soc/) drives them
    // to hold the pipeline until a bus transaction is acknowledged.
    //  - `ibus_wait`: this cycle's instruction fetch has no valid data yet.
    //    Folds into `if_stall`, so PC freezes and IF/ID bubbles - exactly
    //    the shape an ITLB-miss stall already had.
    //  - `dbus_wait`: the MEM-stage access is still in flight. This is a
    //    *new* stall shape: it freezes the whole pipeline including EX,
    //    holds EX/MEM (the request must stay asserted on the bus) and holds
    //    MEM/WB, and suppresses every EX-stage architectural side effect,
    //    since the instruction in EX is being re-presented next cycle and
    //    must not commit twice. Holding (rather than bubbling) MEM/WB also
    //    keeps the MEM/WB forwarding path alive across the stall - bubbling
    //    it would silently drop a forwarded operand for whatever is sitting
    //    in EX, the same class of bug the `store_data_latched` snapshot
    //    exists to prevent.
    input  wire         ibus_wait,
    input  wire         dbus_wait,

    // Data-MMU page-table-walker's read port. Request/grant rather than a
    // plain address, because main memory is a synchronous block RAM and the
    // two walkers share one physical read port - see mmu.v for the contract.
    output wire        ptw_req,
    output wire [31:0] ptw_addr,
    input  wire        ptw_gnt,
    input  wire [31:0] ptw_rdata,

    // instruction-MMU page-table-walker's own port
    // (independent TLB and walker from the data MMU - see mmu.v)
    output wire        iptw_req,
    output wire [31:0] iptw_addr,
    input  wire        iptw_gnt,
    input  wire [31:0] iptw_rdata,

    // interrupt sources
    input  wire         mtip,     // CLINT timer compare
    input  wire         msip_in,  // CLINT software interrupt
    input  wire         meip,     // PLIC context 0 (M-mode): a claimable source
    // PLIC context 1 (S-mode). ORed with mip.SEIP's software-writable half
    // inside csr_file.v, per the spec - see that file's header.
    input  wire         seip,
    input  wire [63:0]  mtime_in, // CLINT mtime, for the `time` CSR

    output wire         fence_i, // FENCE.I retired: any instruction buffer/cache must drop its contents
    output wire         trap,  // pulses for one cycle when a trap/interrupt redirect is taken (EX)

    // ---- hart control (rtl/debug/dm.v), simulation-only this round ----
    //
    // No debug ROM, no Program Buffer, no `dret` - halt is "freeze pipeline
    // admission in place" and resume is "un-freeze". See docs/roadmap.md's
    // "Phase 6" and rtl/debug/README.md for why the full RISC-V debug-spec
    // model (which needs a debug mode, dcsr, dpc, dret and a debug ROM the
    // core vectors into) is deliberately not what this is: that touches the
    // fetch redirect on a core two of six FPGA placement seeds already fail
    // to close 25 MHz on. This implementation touches `pc_freeze` and the
    // regfile's write mux only - nothing on the redirect-target side.
    //
    // Single-step (`dcsr.step`, near dbg_halt_admit_block below) is the
    // same idea applied once: resuming with it set re-blocks admission the
    // instant `dbg_step_admit_now` fires (one cycle after resume, once the
    // stepped instruction is actually admitted), not when it retires -
    // which is what makes it exactly one instruction rather than a race
    // against however many land before `instret_retire` is next observed.
    input  wire         dbg_haltreq,     // level: dm.v wants the hart halted
    input  wire         dbg_resumereq,   // one-cycle pulse: dm.v wants it running again
    output wire         dbg_halted,      // level: genuinely frozen, safe to touch GPRs/dcsr/dpc

    // Debug register access (GPRs via regno 0x1000-0x101f, dcsr at 0x7b0,
    // dpc at 0x7b1 - the same regno space RISC-V debug-spec Abstract
    // Commands use for GPRs, reused here for dcsr/dpc too rather than
    // building a second mechanism). dm.v is responsible for only asserting
    // `dbg_reg_valid` while `dbg_halted` is high; this module does not
    // re-check that, so a `dbg_reg_valid` pulse while running would corrupt
    // regfile state - see rtl/debug/dm.v's own comment on this contract.
    input  wire         dbg_reg_valid,   // one-cycle strobe: perform this access now
    input  wire         dbg_reg_we,      // 1 = write, 0 = read
    input  wire [15:0]  dbg_reg_num,
    input  wire [31:0]  dbg_reg_wdata,
    output wire [31:0]  dbg_reg_rdata,   // combinational, valid the same cycle as dbg_reg_valid
    output wire         dbg_reg_err      // regno not recognized (not a GPR/dcsr/dpc)
);

    // ---- forward declarations ----
    //
    // Verilog requires a net to be declared before it is referenced, and
    // these are all referenced above the point where the logic that drives
    // them reads most naturally - pipeline registers used by the hazard and
    // forwarding logic in the stage before them, CSR outputs consumed by
    // decode, branch resolution feeding the fetch redirect.
    //
    // iverilog 12 accepted the forward references; iverilog 14 rejects them
    // with 94 elaboration errors, and it is right to. Declaring them here
    // and assigning them where they belong keeps the layout of the file and
    // makes it build on both.
    reg        id_ex_valid;
    reg [31:0] id_ex_pc;
    reg [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
    reg        id_ex_is_load, id_ex_is_store, id_ex_mem_we;
    reg        id_ex_is_amo;
    wire actual_taken;
    wire btb_train_en;
    reg branch_taken;
    wire [31:0] actual_target;
    wire fetch_misaligned;
    wire mmu_resolved, mmu_fault, mmu_busy;
    wire sfence_en;
    wire ex_commit;
    wire ex_busy_stall;
    wire [31:0] csr_mcounteren, csr_scounteren;
    wire [1:0]  current_priv;
    wire        satp_mode;
    wire [21:0] satp_ppn;
    wire        csr_mstatus_mprv;
    wire [1:0]  csr_mstatus_mpp;
    wire        csr_mstatus_sum, csr_mstatus_mxr;
    wire        csr_mstatus_tvm, csr_mstatus_tw, csr_mstatus_tsr;
    wire [127:0] csr_pmpcfg;
    wire [511:0] csr_pmpaddr;
    wire interrupt_taken;
    reg        ex_mem_valid;
    reg [4:0]  ex_mem_rd;
    reg        ex_mem_reg_we;
    reg [31:0] ex_mem_wb_data;
    reg        reservation_valid;
    reg [31:0] reservation_addr;
    reg        dbg_halted_r, dbg_halt_pending;
    reg        dbg_stepping_r, dbg_step_admitted_r;
    reg [31:0] dpc_r;
    reg [2:0]  dcsr_cause_r;
    reg [1:0]  dcsr_prv_r;
    reg        dcsr_step_r;

    localparam OPC_LOAD    = 7'b0000011;
    localparam OPC_MISCMEM = 7'b0001111;
    localparam OPC_OPIMM   = 7'b0010011;
    localparam OPC_AUIPC   = 7'b0010111;
    localparam OPC_STORE   = 7'b0100011;
    localparam OPC_AMO     = 7'b0101111;
    localparam OPC_OP      = 7'b0110011;
    localparam OPC_LUI     = 7'b0110111;
    localparam OPC_BRANCH  = 7'b1100011;
    localparam OPC_JALR    = 7'b1100111;
    localparam OPC_JAL     = 7'b1101111;
    localparam OPC_SYSTEM  = 7'b1110011;

    localparam [1:0] PRIV_U = 2'b00, PRIV_S = 2'b01, PRIV_M = 2'b11;

    localparam [2:0] WB_ALU    = 3'd0;
    localparam [2:0] WB_LUI    = 3'd1;
    localparam [2:0] WB_AUIPC  = 3'd2;
    localparam [2:0] WB_PC4    = 3'd3;
    localparam [2:0] WB_CSR    = 3'd4;
    localparam [2:0] WB_MULDIV = 3'd5;

    // =======================================================================
    // IF stage
    // =======================================================================
    reg [31:0] pc;

    // ---- instruction-fetch translation (separate ITLB + walker) ----
    wire ifetch_mmu_active = satp_mode && (current_priv != PRIV_M); // MPRV never affects fetch
    wire itlb_req = ifetch_mmu_active;
    wire itlb_resolved, itlb_fault, itlb_busy;
    wire [31:0] itlb_pa;
    wire [31:0] itlb_pa_va;

    mmu IMMU (
        .clk(clk), .rst(rst),
        .req(itlb_req), .va(pc), .is_store(1'b0), .is_fetch(1'b1),
        // Fetch privilege is always the hart's real current_priv: MPRV
        // relocates data accesses only, never instruction fetch. SUM/MXR are
        // tied off because neither applies to execution - SUM is carved out
        // for fetch by the spec, and MXR only widens loads.
        .is_user(current_priv == PRIV_U), .sum(1'b0), .mxr(1'b0),
        .sfence(sfence_en), .satp_ppn(satp_ppn),
        .resolved(itlb_resolved), .fault(itlb_fault), .pa(itlb_pa),
        .pa_va(itlb_pa_va), .busy(itlb_busy),
        .ptw_req(iptw_req), .ptw_addr(iptw_addr),
        .ptw_gnt(iptw_gnt), .ptw_rdata(iptw_rdata)
    );

    // A walk that resolves for a PC the fetch has since moved away from must
    // not answer the *current* fetch.
    //
    // The ITLB is handed the live `pc`, and a walk latches it and answers,
    // several cycles later, for the address it latched. Nothing stops `pc`
    // changing in between: `redirect_valid` deliberately overrides the PC
    // freeze, so a branch resolving in EX moves the PC while a fetch-side
    // walk is in flight. The walk then completes and hands back the
    // *mispredicted* path's physical address, cpu_wb.v fetches from it - a
    // real instruction, at a real address, so nothing downstream objects -
    // and the IF/ID register pairs that instruction with the corrected PC.
    //
    // The result is one instruction executed in place of another, silently.
    // It cost a Linux boot: a `ret` whose BTB target was stale redirected
    // correctly to `li a5,1`, the ITLB walk in flight answered for the
    // mispredicted target instead, and the core executed `li a4,3` from
    // there under the right PC. `a5` kept a stale value, the `bne` two
    // instructions later took a branch it must not take, and
    // unflatten_device_tree() reported a malformed device tree that was
    // perfectly well formed.
    //
    // Rejecting the answer costs a re-walk. It cannot livelock: the walk
    // still installs its TLB entry, and the next request is for the settled
    // PC. Nothing here caught it before because it needs an ITLB miss and a
    // mispredict in flight at the same moment - and every bare-metal program
    // in this repository is small enough that the ITLB stops missing after
    // the first pass.
    // The *whole* address, not just the page number. A physical address is
    // {ppn, va[11:0]}, so the offset comes from the virtual address too - and
    // a walk that started one instruction earlier in the same page produces a
    // perfectly valid translation of the wrong word. Comparing [31:12] caught
    // 32 of the 35 wrong decodes in a Linux boot and left three, all of them
    // a redirect within a single page.
    wire itlb_answer_stale = itlb_pa_va != pc;
    wire itlb_ok           = itlb_resolved && !itlb_answer_stale;

    assign itlb_wait_stall = itlb_req && !itlb_ok;
    wire itlb_fault_now  = itlb_req && itlb_ok && itlb_fault;

    // ---- what to fetch while the ITLB is still walking ----
    //
    // `itlb_pa` is only meaningful once the walk resolves. Before that mmu.v
    // derives it from `pte1_r`, a register holding a PTE that has not been
    // read yet - so it is not merely the wrong address, it is **X**, and
    // cpu_wb.v indexes its instruction cache with whatever is on this wire
    // every cycle.
    //
    // The consequences are worse than a wasted fetch. `ic_valid[ic_idx]` with
    // an X index makes `fetch_hit` X, which makes `iwb_cyc` X, which puts an X
    // on the shared bus - and wb_ram.v's `ack_r <= a_en && !ack_r` latches it
    // permanently, because `!x` is `x`. One unresolved fetch address wedges
    // main memory for the rest of the simulation, and the machine hangs with
    // no trap and no output.
    //
    // Nothing caught this before, because nothing ran with instruction fetch
    // translated: riscv-tests' rv32si suite is the `-p` (physical) variant and
    // never turns fetch translation on. software/soc/mmutest.c is the test
    // that does, and this is what it found.
    //
    // Holding the last address that *was* valid fixes more than the X. That
    // address was fetched moments ago, so it is in the instruction cache, so
    // `fetch_hit` is true and the fetch master issues no bus cycle at all -
    // which is what we want anyway: the walker (rtl/soc/wb_ptw.v) is now a bus
    // master competing for the same interconnect, and a fetch of an address
    // the core cannot yet compute has no business ahead of it.
    //
    // **That side effect was load-bearing, and until now nothing enforced
    // it.** Four attempts to change the fetch path (fpga/README.md) all left
    // the *kernel* boot untouched - within 1,301 cycles of 127,920,017 to
    // `Freeing unused`, one part in a hundred thousand - and all made **user
    // mode** at least 150x slower, turning a 5-million-cycle phase into one
    // that had not finished at 900 million. Not a hang, and not the
    // instruction cache: the traps concentrate in `uart_write`, which is the
    // interrupt-driven tty path rather than the polled console one, so the
    // phase that breaks is the phase that needs a UART interrupt delivered
    // through the PLIC.
    //
    // (Two earlier versions of this comment were wrong in turn: first that
    // the stall logic below could not tolerate `ibus_wait` during a walk -
    // inferred from a gate reporting a timeout - and then that the cost was
    // paid in the instruction cache, which a mid-boot measurement refuted.)
    //
    // All four attempts predate the mip.SEIP RMW fix in rtl/csr_file.v
    // (docs/practices.md §45): an RMW landing while the PLIC's line was
    // momentarily high could latch it into the software half permanently,
    // and any change that reshuffles the boot's cycle-level interleaving -
    // which every one of these variants does, by construction - could arm
    // it. A UART interrupt permanently failing to arrive again is exactly
    // what that latch-up looks like from the trap trace.
    //
    // `itlb_wait_stall` (this module's own output, of the same name) is now
    // wired into rtl/soc/cpu_wb.v to *enforce* - rather than accidentally
    // rely on - "the fetch neither hits nor requests while a walk is in
    // flight". That is the simplest of the four historical variants,
    // re-run on top of the CSR fix to test the latch-up hypothesis
    // directly rather than argue it. fpga/README.md has the measured
    // result.
    reg [31:0] itlb_pa_hold;
    wire [31:0] fetch_phys_addr =
        itlb_req ? (itlb_ok ? itlb_pa : itlb_pa_hold) : pc;

    always @(posedge clk or posedge rst) begin
        if (rst)
            itlb_pa_hold <= RESET_PC;
        else if (!itlb_req || itlb_resolved)
            itlb_pa_hold <= fetch_phys_addr;
    end

    assign imem_addr = fetch_phys_addr;

    // ---- branch target buffer: consulted every fetch, trained at EX ----
    wire btb_pred_taken;
    wire [31:0] btb_pred_target;

    btb BTB (
        .clk(clk), .rst(rst),
        .predict_pc(pc),
        .predicted_taken(btb_pred_taken), .predicted_target(btb_pred_target),
        .train_en(btb_train_en), .train_pc(id_ex_pc),
        .train_taken(actual_taken), .train_target(actual_target)
    );

    // =======================================================================
    // IF/ID pipeline register
    // =======================================================================
    reg        if_id_valid;
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;
    reg        if_id_ifetch_fault;
    reg        if_id_pred_taken;
    reg [31:0] if_id_pred_target;

    // =======================================================================
    // ID stage: decode
    // =======================================================================
    wire [6:0]  d_opcode = if_id_instr[6:0];
    wire [4:0]  d_rd     = if_id_instr[11:7];
    wire [2:0]  d_funct3 = if_id_instr[14:12];
    wire [4:0]  d_rs1    = if_id_instr[19:15];
    wire [4:0]  d_rs2    = if_id_instr[24:20];
    wire [6:0]  d_funct7 = if_id_instr[31:25];
    wire [4:0]  d_funct5 = if_id_instr[31:27];
    wire [11:0] d_csr_addr = if_id_instr[31:20];
    wire [11:0] d_funct12  = if_id_instr[31:20];

    wire [31:0] d_imm_i = {{20{if_id_instr[31]}}, if_id_instr[31:20]};
    wire [31:0] d_imm_s = {{20{if_id_instr[31]}}, if_id_instr[31:25], if_id_instr[11:7]};
    wire [31:0] d_imm_b = {{19{if_id_instr[31]}}, if_id_instr[31], if_id_instr[7], if_id_instr[30:25], if_id_instr[11:8], 1'b0};
    wire [31:0] d_imm_u = {if_id_instr[31:12], 12'b0};
    wire [31:0] d_imm_j = {{11{if_id_instr[31]}}, if_id_instr[31], if_id_instr[19:12], if_id_instr[20], if_id_instr[30:21], 1'b0};
    wire [31:0] d_zimm  = {27'b0, d_rs1};

    wire is_op      = (d_opcode == OPC_OP);
    wire is_opimm   = (d_opcode == OPC_OPIMM);
    wire is_load    = (d_opcode == OPC_LOAD);
    wire is_store   = (d_opcode == OPC_STORE);
    wire is_amo     = (d_opcode == OPC_AMO) && (d_funct3 == 3'b010); // RV32A: word-only
    wire is_branch  = (d_opcode == OPC_BRANCH);
    wire is_jal     = (d_opcode == OPC_JAL);
    wire is_jalr    = (d_opcode == OPC_JALR);
    wire is_lui     = (d_opcode == OPC_LUI);
    wire is_auipc   = (d_opcode == OPC_AUIPC);
    wire is_system  = (d_opcode == OPC_SYSTEM);
    wire is_miscmem = (d_opcode == OPC_MISCMEM); // FENCE / FENCE.I
    // FENCE.I (funct3=001) is not a no-op here even though plain FENCE is.
    // rtl/soc/cpu_wb.v keeps a one-entry fetch buffer, so a store that
    // modifies an instruction at an address already sitting in that buffer
    // would otherwise be invisible to the next fetch of it - exactly the
    // hazard FENCE.I exists to close, and exactly what a bootloader copying
    // a program into RAM and jumping to it does.
    wire is_fence_i = is_miscmem && (d_funct3 == 3'b001);

    wire is_lr = is_amo && (d_funct5 == 5'b00010);
    wire is_sc = is_amo && (d_funct5 == 5'b00011);
    wire amo_funct5_ok = (d_funct5 == 5'b00010) || (d_funct5 == 5'b00011) || (d_funct5 == 5'b00001) ||
                          (d_funct5 == 5'b00000) || (d_funct5 == 5'b00100) || (d_funct5 == 5'b01100) ||
                          (d_funct5 == 5'b01000) || (d_funct5 == 5'b10000) || (d_funct5 == 5'b10100) ||
                          (d_funct5 == 5'b11000) || (d_funct5 == 5'b11100);
    wire amo_illegal = is_amo && !amo_funct5_ok;

    wire is_muldiv  = is_op && (d_funct7 == 7'b0000001); // RV32M: MUL/DIV family

    wire is_csr    = is_system && (d_funct3 != 3'b000);
    wire is_priv   = is_system && (d_funct3 == 3'b000);
    wire is_ecall  = is_priv && (d_funct12 == 12'h000);
    wire is_ebreak = is_priv && (d_funct12 == 12'h001);
    wire is_mret   = is_priv && (d_funct12 == 12'h302);
    wire is_sret   = is_priv && (d_funct12 == 12'h102);
    wire is_sfence_vma = is_priv && (d_funct7 == 7'b0001001); // has real rs1/rs2, not a fixed funct12
    // WFI retires as a plain no-op. The spec explicitly permits that ("a
    // legal implementation is to simply implement WFI as a NOP"), and it is
    // the honest choice for this core: there is no clock gating or power
    // state to enter, so a stall loop would burn exactly the same energy
    // while making the pipeline harder to reason about. What matters
    // architecturally is that WFI does not trap - software (including
    // OpenSBI's idle path and any Linux cpuidle driver) executes it
    // unconditionally and expects to keep running.
    wire is_wfi        = is_priv && (d_funct12 == 12'h105);

    // mstatus.TVM/TW/TSR let M-mode trap the supervisor operations it wants
    // to intercept. Each turns an otherwise-legal instruction into an
    // illegal-instruction trap when executed at S (never at M - firmware
    // must not be able to trap itself).
    wire mret_priv_ok    = (current_priv == PRIV_M);
    wire sret_priv_ok    = (current_priv == PRIV_M) ||
                           ((current_priv == PRIV_S) && !csr_mstatus_tsr);
    wire sfence_priv_ok  = (current_priv == PRIV_M) ||
                           ((current_priv == PRIV_S) && !csr_mstatus_tvm);
    // U-mode WFI is illegal here (this core never enables it), and S-mode
    // WFI is illegal while TW is set. Trapping immediately rather than after
    // a bounded wait is allowed: the spec's limit is an upper bound.
    wire wfi_priv_ok     = (current_priv == PRIV_M) ||
                           ((current_priv == PRIV_S) && !csr_mstatus_tw);

    wire csr_imm_form   = is_csr && d_funct3[2];                 // CSRRWI/SI/CI
    wire csr_set_clear  = (d_funct3[1:0] == 2'b10) || (d_funct3[1:0] == 2'b11); // CSRRS(I)/CSRRC(I)
    wire csr_will_write = !csr_set_clear || (d_rs1 != 5'd0);      // CSRRW(I) always writes

    function csr_addr_ok;
        input [11:0] a;
        begin
            case (a)
                12'h100, 12'h104, 12'h105, 12'h106, 12'h140, 12'h141, 12'h142,
                12'h143, 12'h144, 12'h180,
                12'h300, 12'h301, 12'h302, 12'h303, 12'h304, 12'h305, 12'h306,
                // mstatush. RV32-only, and required: it holds MBE and SBE,
                // the big-endian controls. This core is little-endian only,
                // so both are read-only zero - which the spec allows, they
                // are WARL - but the CSR has to *exist*, because RV32
                // firmware clears them unconditionally in its assembly
                // startup, before it has installed a handler that could
                // survive an illegal-instruction trap.
                //
                // OpenSBI does exactly that, at fw_base.S, and this core
                // trapped it. mtvec at that point still points at
                // `_start_hang`, so the machine stopped in a `wfi` loop with
                // no console and no message - eight million cycles of silence
                // that took a PC readout from the Verilator harness to
                // explain.
                12'h310,
                12'h320,
                12'h340, 12'h341, 12'h342, 12'h343, 12'h344,
                // PMP: pmpcfg0-3, pmpaddr0-15 - csr_file.v stores and serves
                // these (WARL/lock semantics only, nothing enforces them
                // yet). Address bits [9:8]=11 puts them at the generic
                // M-only privilege check below, same as every other M-mode
                // CSR here - no special-casing needed.
                12'h3A0, 12'h3A1, 12'h3A2, 12'h3A3,
                12'h3B0, 12'h3B1, 12'h3B2, 12'h3B3, 12'h3B4, 12'h3B5, 12'h3B6, 12'h3B7,
                12'h3B8, 12'h3B9, 12'h3BA, 12'h3BB, 12'h3BC, 12'h3BD, 12'h3BE, 12'h3BF,
                12'hB00, 12'hB02, 12'hB80, 12'hB82,
                12'hC00, 12'hC01, 12'hC02, 12'hC80, 12'hC81, 12'hC82,
                // Machine identity. All read-only zero, which the spec allows
                // ("may return 0 ... to indicate the field is not
                // implemented"). They exist because firmware reads them
                // unconditionally during boot - not returning *something* is
                // an illegal-instruction trap in the middle of startup.
                12'hF11, 12'hF12, 12'hF13,
                12'hF14: csr_addr_ok = 1'b1;
                default: csr_addr_ok = 1'b0;
            endcase
        end
    endfunction

    function csr_addr_ro;
        input [11:0] a;
        begin
            case (a)
                // The user-level counter views are read-only; the machine-level
                // originals (0xB00/0xB02/...) are writable.
                //
                // `misa` (0x301) is deliberately *not* here. It is WARL, not
                // read-only: software legitimately writes it to try to turn an
                // extension off, and the architected response to an
                // unsupported request is to ignore the write - not to trap.
                // csr_file.v has no write case for it, so the write lands in
                // the ignore-by-default branch, which is exactly WARL. Making
                // it trap instead breaks any feature-probing code that writes
                // a bit and reads it back.
                12'hF11, 12'hF12, 12'hF13, 12'hF14,
                12'hC00, 12'hC01, 12'hC02, 12'hC80, 12'hC81, 12'hC82: csr_addr_ro = 1'b1;
                default: csr_addr_ro = 1'b0;
            endcase
        end
    endfunction

    // CSR minimum privilege is spec-encoded directly in address bits
    // [9:8] (00=U, 01=S, 11=M) - this generalizes across every CSR here
    // with no per-address special-casing needed.
    wire csr_funct3_ok    = !is_csr || (d_funct3 != 3'b100); // 100 is reserved under SYSTEM/funct3!=0

    // The user-level counters (cycle/time/instret and their `h` halves) sit at
    // 0xC0x/0xC8x, whose addr[9:8] is 00 - i.e. U-readable as far as the
    // generic privilege check is concerned. The spec instead gates them
    // per-counter through mcounteren/scounteren: a read below M needs the
    // matching mcounteren bit, and a read from U additionally needs the
    // scounteren bit. Without this an S-mode OS can't actually deny U-mode
    // the cycle counter, which is a real (if mild) isolation property.
    wire       is_ucounter = is_csr && (d_csr_addr[11:5] == 7'b1100_000); // 0xC00-0xC1F / 0xC80-0xC9F
    wire [4:0] counter_idx = d_csr_addr[4:0];
    wire counter_denied = is_ucounter &&
        (((current_priv != PRIV_M) && !csr_mcounteren[counter_idx]) ||
         ((current_priv == PRIV_U) && !csr_scounteren[counter_idx]));

    // satp is also gated by TVM: with it set, a supervisor reading or writing
    // satp traps so M-mode firmware can virtualize translation.
    wire satp_denied = is_csr && (d_csr_addr == 12'h180) &&
                       (current_priv == PRIV_S) && csr_mstatus_tvm;

    wire csr_priv_illegal = is_csr && ((current_priv < d_csr_addr[9:8]) ||
                                       counter_denied || satp_denied);
    wire csr_illegal      = is_csr && (!csr_funct3_ok || !csr_addr_ok(d_csr_addr) ||
                                       (csr_will_write && csr_addr_ro(d_csr_addr)) || csr_priv_illegal);
    wire priv_illegal     = is_priv && !(is_ecall || is_ebreak ||
                                         (is_mret && mret_priv_ok) ||
                                         (is_sret && sret_priv_ok) ||
                                         (is_wfi && wfi_priv_ok) ||
                                         (is_sfence_vma && sfence_priv_ok));

    wire valid_opcode = is_op || is_opimm || is_load || is_store || is_branch ||
                         is_jal || is_jalr || is_lui || is_auipc || is_system ||
                         is_miscmem || is_amo;

    reg alu_op_illegal;
    always @(*) begin
        alu_op_illegal = 1'b0;
        if (is_op && !is_muldiv) begin
            case (d_funct3)
                3'b000, 3'b101: if (d_funct7 != 7'b0000000 && d_funct7 != 7'b0100000) alu_op_illegal = 1'b1;
                default:        if (d_funct7 != 7'b0000000) alu_op_illegal = 1'b1;
            endcase
        end else if (is_opimm) begin
            case (d_funct3)
                3'b001:  if (d_funct7 != 7'b0000000) alu_op_illegal = 1'b1;                             // SLLI
                3'b101:  if (d_funct7 != 7'b0000000 && d_funct7 != 7'b0100000) alu_op_illegal = 1'b1;    // SRLI/SRAI
                default: ; // ADDI/SLTI/SLTIU/XORI/ORI/ANDI - funct7 field is just immediate bits
            endcase
        end
    end

    wire branch_funct3_ok = !is_branch || (d_funct3 != 3'b010 && d_funct3 != 3'b011);
    wire load_funct3_ok   = !is_load  || (d_funct3 != 3'b011 && d_funct3 != 3'b110 && d_funct3 != 3'b111);
    wire store_funct3_ok  = !is_store || (d_funct3 == 3'b000 || d_funct3 == 3'b001 || d_funct3 == 3'b010);

    wire illegal = !valid_opcode || alu_op_illegal || !branch_funct3_ok ||
                   !load_funct3_ok || !store_funct3_ok || csr_illegal || priv_illegal || amo_illegal;

    // An instruction-fetch page fault is discovered even earlier than any
    // of the above (in IF, not ID) - it must unconditionally override
    // whatever `illegal`/ECALL/EBREAK the garbage `if_id_instr` bits of a
    // faulting fetch would otherwise combinationally decode to, and
    // suppress every side effect the same way `illegal` already does.
    wire d_fetch_fault    = if_id_ifetch_fault;
    wire is_trap_event    = illegal || is_ecall || is_ebreak || d_fetch_fault;
    wire suppress_effects = illegal || d_fetch_fault;

    wire [31:0] ecall_cause = (current_priv == PRIV_M) ? 32'd11 :
                              (current_priv == PRIV_S) ? 32'd9  : 32'd8;
    wire [31:0] d_trap_cause = d_fetch_fault ? 32'd12 :
                                illegal      ? 32'd2  :
                                is_ecall     ? ecall_cause :
                                is_ebreak    ? 32'd3  : 32'd0;
    wire [31:0] d_trap_val   = d_fetch_fault ? if_id_pc :
                                illegal      ? if_id_instr : 32'd0;

    wire use_funct7b5 = is_op || (is_opimm && d_funct3 == 3'b101);
    wire [3:0] d_alu_ctrl = {(use_funct7b5 & d_funct7[5]), d_funct3};

    reg [31:0] d_imm;
    always @(*) begin
        case (d_opcode)
            OPC_STORE:  d_imm = d_imm_s;
            OPC_BRANCH: d_imm = d_imm_b;
            OPC_LUI, OPC_AUIPC: d_imm = d_imm_u;
            OPC_JAL:    d_imm = d_imm_j;
            OPC_AMO:    d_imm = 32'b0; // AMO has no immediate offset - address is rs1 alone
            default:    d_imm = d_imm_i; // LOAD, OPIMM, JALR, (CSR ignores this)
        endcase
    end

    reg [2:0] d_wb_sel;
    always @(*) begin
        case (d_opcode)
            OPC_LUI:            d_wb_sel = WB_LUI;
            OPC_AUIPC:          d_wb_sel = WB_AUIPC;
            OPC_JAL, OPC_JALR:  d_wb_sel = WB_PC4;
            default:            d_wb_sel = is_csr ? WB_CSR : (is_muldiv ? WB_MULDIV : WB_ALU);
        endcase
    end

    wire d_reg_we_raw = is_op || is_opimm || is_lui || is_auipc || is_jal || is_jalr ||
                          is_load || is_csr || is_amo;
    wire d_reg_we     = d_reg_we_raw && !suppress_effects;
    wire d_mem_we     = is_store && !suppress_effects; // AMO/SC's write-enable is resolved in MEM, not here
    wire d_csr_we     = is_csr && csr_will_write && !suppress_effects;

    // which register fields does *this* instruction actually read? (needed
    // so the hazard unit doesn't false-trigger on e.g. CSRRWI's zimm field,
    // which reuses the rs1 bit position for something that isn't a register)
    wire uses_rs1 = is_op || is_opimm || is_load || is_store || is_branch || is_jalr || is_amo ||
                    (is_csr && !csr_imm_form);
    wire uses_rs2 = is_op || is_store || is_branch || is_amo;

    // regfile: ID reads (combinational), WB writes (synchronous) - same
    // instance, same trick the single-cycle core used.
    wire [31:0] d_rs1_data, d_rs2_data;
    wire [31:0] mem_wb_wb_data;
    wire        mem_wb_reg_we;
    wire [4:0]  mem_wb_rd;

    // ---- hart control: dcsr/dpc, and the debug register-access mux ----
    //
    // dcsr/dpc deliberately do NOT live in csr_file.v and are NOT reachable
    // by an ordinary CSRRW: there is no debug-mode instruction stream under
    // this halt-in-place model that would ever execute one, so the
    // simplest way to keep M/S/U-mode software from touching Debug Mode
    // state is to never put it on that path at all. (A real debug ROM,
    // added later, would need to - and would then also need an explicit
    // "illegal outside Debug Mode" gate separate from the ordinary
    // privilege check: dcsr=0x7b0's bits [9:8] read as 2'b11, identical to
    // PRIV_M, so the existing `current_priv < d_csr_addr[9:8]` check alone
    // would wrongly treat it as an ordinary M-mode CSR.)
    //
    // Every hardwired-0 dcsr field below is a real spec field with no
    // meaning under this model, not an oversight - see the comment on each.
    wire [31:0] dcsr_r = {4'd4,              // [31:28] xdebugver = 4 (0.13/1.0 shape)
                          12'b0,              // [27:16] reserved
                          1'b0,               // [15] ebreakm - no-op: no ebreak-in-debug-config exists
                          1'b0,               // [14] ebreaks - same
                          1'b0,               // [13] ebreaku - same
                          1'b0,               // [12] reserved
                          1'b0,               // [11] stepie - no-op: no debug-mode instruction
                                              //   stream to have an interrupt-enable policy for
                          1'b0,               // [10] stopcount - no-op: counters aren't paused here
                          1'b0,               // [9]  stoptime - same
                          dcsr_cause_r,       // [8:6]
                          1'b0,               // [5] reserved
                          1'b0,               // [4] mprven - no-op: no debug-mode memory access path
                          1'b0,               // [3] nmip - no NMI source in this core
                          dcsr_step_r,        // [2] step - real now; see the resume logic below
                          dcsr_prv_r};        // [1:0]

    // 0x1000-0x101f, RISC-V debug spec's Abstract-Command GPR regno range:
    // regno = 0x1000 + architectural register number. 0x1000 = 11'h080 << 5,
    // not 11'h001 - checked against sim/tb_cpu_halt.v, not assumed (an
    // earlier version of this line had exactly that off-by-a-lot bug and a
    // debug write to x5 silently landed nowhere).
    wire        is_gpr_regno  = (dbg_reg_num[15:5] == 11'h080);
    wire [4:0]  dbg_gpr_idx   = dbg_reg_num[4:0];
    wire        is_dcsr_regno = (dbg_reg_num == 16'h07B0);
    wire        is_dpc_regno  = (dbg_reg_num == 16'h07B1);
    wire        dbg_reg_ok    = is_gpr_regno || is_dcsr_regno || is_dpc_regno;
    assign      dbg_reg_err   = dbg_reg_valid && !dbg_reg_ok;
    wire        dbg_gpr_write = dbg_reg_valid && dbg_reg_ok && dbg_reg_we && is_gpr_regno;
    wire [31:0] dbg_gpr_rdata;

    // dcsr/dpc writes land in the halt/resume always block below (near
    // dbg_halted_r), not a new always block of their own - dpc_r already
    // has one driver there (the halt-entry capture) and Verilog does not
    // allow a second procedural block to also drive it. Only dcsr.step is
    // writable; every other dcsr field stays the hardwired no-op the
    // comment above already explains.
    wire        dbg_dcsr_write = dbg_reg_valid && dbg_reg_we && is_dcsr_regno;
    wire        dbg_dpc_write  = dbg_reg_valid && dbg_reg_we && is_dpc_regno;

    assign dbg_reg_rdata = is_gpr_regno  ? dbg_gpr_rdata :
                           is_dcsr_regno ? dcsr_r :
                           is_dpc_regno  ? dpc_r  : 32'b0;

    // Safe as a plain priority mux, never a real two-driver race:
    // dbg_gpr_write can only be true while dbg_reg_valid is asserted, which
    // per dm.v's own contract only happens while dbg_halted is high - and
    // mem_wb_reg_we is guaranteed 0 whenever the hart is genuinely halted,
    // by construction of dbg_pipeline_quiescent above (nothing is retiring).
    // Deliberately does not touch mem_wb_reg_we/mem_wb_rd/mem_wb_wb_data
    // themselves (or the trace_rd_* taps sim/tracer.v and cosim read) - a
    // debug write must never look like a retiring instruction, and keeping
    // the mux here, at the RF instantiation boundary, gets that for free.
    wire        rf_we    = dbg_gpr_write ? 1'b1         : mem_wb_reg_we;
    wire [4:0]  rf_rd    = dbg_gpr_write ? dbg_gpr_idx   : mem_wb_rd;
    wire [31:0] rf_wdata = dbg_gpr_write ? dbg_reg_wdata : mem_wb_wb_data;

    regfile RF (
        .clk(clk), .we(rf_we),
        .rs1(d_rs1), .rs2(d_rs2), .rd(rf_rd),
        .wdata(rf_wdata),
        .rdata1(d_rs1_data), .rdata2(d_rs2_data),
        .dbg_rs(dbg_gpr_idx), .dbg_rdata(dbg_gpr_rdata)
    );

    // =======================================================================
    // Hazard detection
    // =======================================================================
    // Loads AND AMO/LR (their rd value, like a load's, only exists once
    // MEM computes it) share the same load-use hazard shape.
    wire id_ex_is_load_like = id_ex_is_load || id_ex_is_amo;
    wire load_use_stall = if_id_valid && id_ex_valid && id_ex_is_load_like && (id_ex_rd != 5'd0) &&
                           ((uses_rs1 && (id_ex_rd == d_rs1)) || (uses_rs2 && (id_ex_rd == d_rs2)));

    wire id_ex_stall = load_use_stall || ex_busy_stall;
    // The IF-stage ITLB-miss stall is independent of id_ex_stall: it's
    // about whether IF has something new to offer id_ex, not about
    // whether id_ex is free to accept if_id's *current* content. Folding
    // the two together would double-latch an instruction - see the
    // if_id register block below.
    wire if_stall    = itlb_wait_stall || ibus_wait;
    // `dbg_halt_pending` covers a debugger that only pulses `dbg_haltreq`
    // for one DMI write rather than holding it until `dmstatus.allhalted` -
    // the spec says to hold it, but nothing here should silently drop a
    // request that doesn't. `dbg_halted_r` keeps admission blocked for the
    // whole time the hart reports halted, not just the cycle it got there.
    // `dbg_stepping_r && dbg_step_admitted_r` is single-step's own block:
    // resuming with `dcsr.step` set clears `dbg_halted_r` (see the always
    // block below) without setting this term yet, so admission opens for
    // exactly the cycles it takes `admitting_now` below to fire once - the
    // moment it does, `dbg_step_admitted_r` latches and re-blocks admission
    // before a second instruction can ever be admitted, which is what
    // makes single-step exactly one instruction rather than "however many
    // fit before the host notices."
    wire dbg_halt_admit_block = dbg_haltreq || dbg_halt_pending || dbg_halted_r ||
                                 (dbg_stepping_r && dbg_step_admitted_r);
    wire pc_freeze   = id_ex_stall || if_stall || dbg_halt_admit_block;
    // True on a cycle that admits a new instruction into if_id while a
    // single-step is waiting for its one admission - the same condition
    // the if_id_valid register block's own final `else` branch uses, minus
    // `!redirect_valid`. That term is provably moot here: this wire is only
    // ever consulted (below) while `dbg_stepping_r && !dbg_step_admitted_r`,
    // and until the first admission happens, if_id_valid has been 0 since
    // before resume (nothing halted admits), so id_ex_valid is 0 too - and
    // `redirect_valid` requires id_ex_valid, so it cannot be set on any
    // cycle this wire's value actually changes the outcome. Leaving it out
    // sidesteps forward-referencing `redirect_valid` (declared later, in
    // the EX stage) purely for a term that cannot matter here.
    wire dbg_step_admit_now = !id_ex_stall && !if_stall && !dbg_halt_admit_block;

    // =======================================================================
    // ID/EX pipeline register
    // =======================================================================
    reg [31:0] id_ex_rs1_data, id_ex_rs2_data;
    reg [31:0] id_ex_imm;
    reg [3:0]  id_ex_alu_ctrl;
    reg        id_ex_is_op;
    reg [2:0]  id_ex_wb_sel;
    reg        id_ex_reg_we;
    reg [1:0]  id_ex_mem_size;
    reg [2:0]  id_ex_funct3;
    reg        id_ex_is_branch, id_ex_is_jal, id_ex_is_jalr;
    reg        id_ex_is_csr, id_ex_csr_we, id_ex_csr_imm_form;
    reg [11:0] id_ex_csr_addr;
    reg [31:0] id_ex_zimm;
    reg        id_ex_is_trap_event, id_ex_is_mret, id_ex_is_sret;
    reg [31:0] id_ex_trap_cause, id_ex_trap_val;
    reg        id_ex_is_muldiv, id_ex_is_sfence_vma, id_ex_is_fence_i;
    reg [4:0]  id_ex_funct5;
    reg        id_ex_pred_taken;
    reg [31:0] id_ex_pred_target;

    // ---- retire trace (simulation only) ----
    // A shadow copy of the PC and instruction word carried alongside the real
    // pipeline registers, so that what leaves MEM/WB can be reported as a
    // retired instruction. This is what sim/tracer.v prints and what the
    // Spike co-simulation in tests/cosim.py diffs against.
    //
    // These deliberately ride *inside* the existing pipeline-register always
    // blocks rather than in a parallel block of their own. A separate block
    // would have to restate every stall and flush condition, and would then
    // silently drift out of step the first time one of those conditions
    // changed - the same failure mode that produced the misaligned-address
    // bug (an operand recomputed from a control signal that had moved on).
    // Riding along means the trace cannot disagree with the pipeline.
    //
    // Nothing outside a testbench reads these, so synthesis strips them; see
    // fpga/README.md for the measured before/after.
    reg [31:0] id_ex_instr;
    reg [31:0] ex_mem_pc, ex_mem_instr;
    // Carries `instret_retire` down to the trace strobe, so a trapping
    // instruction is not reported as retired. Spike's --log-commits makes the
    // same distinction (it prints an exception line instead of a commit line),
    // and matching it is what lets the two traces be diffed at all.
    reg        ex_mem_retire;
    reg [31:0] trace_pc, trace_instr;
    reg        trace_valid;
    wire       trace_rd_we   = mem_wb_reg_we;
    wire [4:0] trace_rd      = mem_wb_rd;
    wire [31:0] trace_rd_data = mem_wb_wb_data;

    // =======================================================================
    // EX stage
    // =======================================================================

    // forwarding: EX/MEM (most recent) takes priority over MEM/WB
    wire fwd1_exmem = ex_mem_valid && ex_mem_reg_we && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs1);
    wire fwd1_memwb = mem_wb_reg_we && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1);
    wire fwd2_exmem = ex_mem_valid && ex_mem_reg_we && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs2);
    wire fwd2_memwb = mem_wb_reg_we && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2);

    wire [31:0] op1     = fwd1_exmem ? ex_mem_wb_data : (fwd1_memwb ? mem_wb_wb_data : id_ex_rs1_data);
    wire [31:0] op2_reg = fwd2_exmem ? ex_mem_wb_data : (fwd2_memwb ? mem_wb_wb_data : id_ex_rs2_data);

    function [31:0] alu_exec;
        input [31:0] a, b;
        input [3:0]  op;
        begin
            case (op)
                4'b0000: alu_exec = a + b;                                      // ADD/ADDI
                4'b1000: alu_exec = a - b;                                      // SUB
                4'b0001: alu_exec = a << b[4:0];                                // SLL/SLLI
                4'b0010: alu_exec = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;   // SLT/SLTI
                4'b0011: alu_exec = (a < b) ? 32'd1 : 32'd0;                    // SLTU/SLTIU
                4'b0100: alu_exec = a ^ b;                                      // XOR/XORI
                4'b0101: alu_exec = a >> b[4:0];                                // SRL/SRLI
                4'b1101: alu_exec = $signed(a) >>> b[4:0];                      // SRA/SRAI
                4'b0110: alu_exec = a | b;                                      // OR/ORI
                4'b0111: alu_exec = a & b;                                      // AND/ANDI
                default: alu_exec = 32'b0;
            endcase
        end
    endfunction

    wire [31:0] alu_b      = id_ex_is_op ? op2_reg : id_ex_imm;
    wire [31:0] alu_result = alu_exec(op1, alu_b, id_ex_alu_ctrl);

    // ---- M extension: multiply (combinational) ----
    wire signed [63:0] mul_ss = $signed({{32{op1[31]}}, op1}) * $signed({{32{op2_reg[31]}}, op2_reg});
    wire        [63:0] mul_uu = {32'b0, op1} * {32'b0, op2_reg};
    wire signed [63:0] mul_su = $signed({{32{op1[31]}}, op1}) * $signed({32'b0, op2_reg});

    reg [31:0] mul_result;
    always @(*) begin
        case (id_ex_funct3[1:0])
            2'b00: mul_result = mul_ss[31:0];   // MUL
            2'b01: mul_result = mul_ss[63:32];  // MULH
            2'b10: mul_result = mul_su[63:32];  // MULHSU
            2'b11: mul_result = mul_uu[63:32];  // MULHU
        endcase
    end

    // ---- M extension: divide (multi-cycle) ----
    wire is_muldiv_now = id_ex_valid && id_ex_is_muldiv;
    wire is_div_now    = is_muldiv_now && id_ex_funct3[2];
    wire div_busy, div_done;
    wire [31:0] div_quotient, div_remainder;
    wire div_start = is_div_now && !div_busy;

    muldiv_div DIVU (
        .clk(clk), .rst(rst),
        .start(div_start),
        .dividend(op1), .divisor(op2_reg), .is_signed(!id_ex_funct3[0]),
        .quotient(div_quotient), .remainder(div_remainder),
        .busy(div_busy), .done(div_done)
    );

    wire div_stall = is_div_now && !div_done;
    wire [31:0] div_result = id_ex_funct3[1] ? div_remainder : div_quotient;

    assign actual_taken = (id_ex_is_branch && branch_taken) || id_ex_is_jal || id_ex_is_jalr;
    wire is_control_flow = id_ex_is_branch || id_ex_is_jal || id_ex_is_jalr;
    // Not trained on a misaligned target: that branch traps rather than
    // transferring control, so caching its target would mispredict the next
    // time round for a jump that never actually goes there.
    assign btb_train_en = id_ex_valid && is_control_flow && ex_commit && !fetch_misaligned;

    always @(*) begin
        case (id_ex_funct3)
            3'b000:  branch_taken = (op1 == op2_reg);                       // BEQ
            3'b001:  branch_taken = (op1 != op2_reg);                       // BNE
            3'b100:  branch_taken = ($signed(op1) <  $signed(op2_reg));     // BLT
            3'b101:  branch_taken = ($signed(op1) >= $signed(op2_reg));     // BGE
            3'b110:  branch_taken = (op1 <  op2_reg);                       // BLTU
            3'b111:  branch_taken = (op1 >= op2_reg);                       // BGEU
            default: branch_taken = 1'b0;
        endcase
    end

    wire [31:0] mem_addr_ex   = op1 + id_ex_imm;               // load/store/AMO effective (virtual) address
    wire [31:0] jalr_target   = (op1 + id_ex_imm) & ~32'h1;
    wire [31:0] jal_target    = id_ex_pc + id_ex_imm;
    wire [31:0] branch_target = id_ex_pc + id_ex_imm;
    wire [31:0] auipc_result  = id_ex_pc + id_ex_imm;
    assign actual_target = id_ex_is_jal  ? jal_target  :
                                id_ex_is_jalr ? jalr_target : branch_target;

    // Misaligned instruction fetch (cause 0). Without the C extension
    // IALIGN is 32, so any taken control transfer to an address with bit 1
    // set is an exception - and it is reported against the *jumping*
    // instruction, before the bad fetch is ever issued. That ordering is the
    // whole point: the faulting PC in mepc is the branch, not the target, so
    // a handler can see what tried to jump where.
    //
    // Bit 0 needs no check: JALR clears it by definition, and JAL/branch
    // immediates have it hardwired to zero by the encoding.
    //
    // A not-taken branch to a misaligned target must *not* trap, which is why
    // `actual_taken` gates this rather than the target being computed for
    // every branch.
    assign fetch_misaligned = is_control_flow && actual_taken && actual_target[1];

    // ---- data MMU: translate load/store/AMO addresses ----
    // Real spec: satp/paging only applies at S/U privilege, or to an
    // M-mode access "acting as" a lower privilege via mstatus.MPRV/MPP
    // (which never affects instruction fetch). This replaces the old
    // "unconditional whenever satp.MODE=1" stand-in now that a real
    // privilege boundary exists.
    wire [1:0] effective_priv_for_data = (current_priv == PRIV_M && csr_mstatus_mprv) ? csr_mstatus_mpp : current_priv;
    wire is_mem_op_now   = id_ex_valid && (id_ex_is_load || id_ex_is_store || id_ex_is_amo);

    // ---- misaligned access detection ----
    // This core has no misaligned-access support: rtl/soc/cpu_wb.v's byte-lane
    // shifting assumes natural alignment, and rtl/dmem.v would do an unaligned
    // word read. Previously such an access was silently mis-executed. Trapping
    // is what the spec requires of an implementation that doesn't support them,
    // and it's what lets M-mode firmware emulate the access instead - OpenSBI
    // does exactly that, but only ever gets the chance if the hardware traps.
    //
    // Checked on the *virtual* address and before translation, per spec: a
    // misaligned address faults as misaligned whether or not it would also
    // have page-faulted, so there's no point starting a walk for one.
    reg misaligned_sized;
    always @(*) begin
        case (id_ex_mem_size)
            2'b01:   misaligned_sized = mem_addr_ex[0];       // halfword
            2'b10:   misaligned_sized = |mem_addr_ex[1:0];    // word
            default: misaligned_sized = 1'b0;                 // byte is always aligned
        endcase
    end
    // AMO/LR/SC are word-only regardless of the funct3 size field.
    //
    // `!mmu_busy` is load-bearing, not belt-and-braces. `mem_addr_ex` is
    // recomputed from *live forwarding* every cycle, and during a multi-cycle
    // MMU walk the rest of the pipeline keeps draining underneath the stalled
    // instruction, so its forwarded operands decay to stale values - the same
    // hazard `store_data_latched` exists to defeat, and the reason mmu.v
    // snapshots `va_r` on the walk's first cycle. Evaluating alignment against
    // the decayed address mid-walk invents misalignment faults for perfectly
    // aligned accesses. A misaligned access never starts a walk (it gates
    // `need_translate` off below), so a walk in progress always implies the
    // address was already judged aligned on cycle one - which makes
    // "not mid-walk" exactly the right window to decide this in.
    wire mem_misaligned = is_mem_op_now && !mmu_busy &&
                          (id_ex_is_amo ? (|mem_addr_ex[1:0]) : misaligned_sized);
    // Cause 4 = load address misaligned, 6 = store/AMO address misaligned.
    wire [31:0] misaligned_cause = (id_ex_is_store || id_ex_is_amo) ? 32'd6 : 32'd4;

    wire need_translate  = is_mem_op_now && !mem_misaligned &&
                           satp_mode && (effective_priv_for_data != PRIV_M);
    wire [31:0] mmu_pa;
    assign sfence_en = id_ex_valid && id_ex_is_sfence_vma && !interrupt_taken && ex_commit;
    wire fence_i_en = id_ex_valid && id_ex_is_fence_i && !interrupt_taken && ex_commit;
    assign fence_i = fence_i_en;

    // An AMO writes memory, so it needs W permission and reports a *store*
    // page fault when it lacks one - checking it as a load would let a
    // read-only page be modified. LR is the exception: it only reads, and
    // Spike models it that way too, which matters because the co-simulation
    // in tests/ compares fault causes against Spike's.
    wire id_ex_is_lr_ex      = id_ex_is_amo && (id_ex_funct5 == 5'b00010);
    wire mmu_access_is_write = id_ex_is_store || (id_ex_is_amo && !id_ex_is_lr_ex);

    mmu MMU (
        .clk(clk), .rst(rst),
        .req(need_translate), .va(mem_addr_ex), .is_store(mmu_access_is_write), .is_fetch(1'b0),
        .is_user(effective_priv_for_data == PRIV_U),
        .sum(csr_mstatus_sum), .mxr(csr_mstatus_mxr),
        .sfence(sfence_en), .satp_ppn(satp_ppn),
        .resolved(mmu_resolved), .fault(mmu_fault), .pa(mmu_pa),
        // The data address cannot move under a stall the way the PC can -
        // mmu.v snapshots it for exactly that reason - so the data side has
        // no use for this. Named rather than left off, so the port is
        // accounted for.
        .pa_va(),
        .busy(mmu_busy),
        .ptw_req(ptw_req), .ptw_addr(ptw_addr),
        .ptw_gnt(ptw_gnt), .ptw_rdata(ptw_rdata)
    );

    wire mmu_wait_stall = need_translate && !mmu_resolved;
    wire mmu_fault_now  = need_translate && mmu_resolved && mmu_fault;
    wire [31:0] mmu_cause = mmu_access_is_write ? 32'd15 : 32'd13; // store/AMO or load page fault
    wire [31:0] mem_phys_addr = need_translate ? mmu_pa : mem_addr_ex;

    // ---- PMP: data-path enforcement only ----
    // rtl/pmp.v is pure combinational, checked against `mem_phys_addr` once
    // it is genuinely meaningful - either no translation was needed (M-mode
    // or paging off, valid the same cycle as every other data-path signal)
    // or a walk just resolved *without* a page fault. A walk that itself
    // faulted leaves `mem_phys_addr` holding whatever `mmu.v` computed for
    // it regardless (see mmu.v's `pa` assignment - it is not gated by
    // `fault`), which is not a real, permitted physical address to be
    // checking PMP against; `mmu_fault_now` already traps that access for
    // an unrelated reason, so PMP has nothing useful to add there.
    //
    // Explicitly out of scope for this round, named here so the gap is
    // documented rather than silent: page-table-walker reads (a PTE fetch
    // goes through mmu.v's own dedicated ptw_req/ptw_addr port, never
    // through this one) and instruction fetch (the timing-critical path
    // Phase 3 spent so long on - see docs/roadmap.md's PMP entry for why
    // that is its own, separately-measured round).
    wire pmp_pa_valid = !need_translate || (mmu_resolved && !mmu_fault);
    wire pmp_fault_raw;
    pmp PMP (
        .pmpcfg(csr_pmpcfg), .pmpaddr(csr_pmpaddr),
        .addr(mem_phys_addr), .size(id_ex_mem_size),
        .is_write(mmu_access_is_write), .is_fetch(1'b0),
        .priv(effective_priv_for_data),
        .fault(pmp_fault_raw)
    );
    wire pmp_fault_now = is_mem_op_now && !mem_misaligned && pmp_pa_valid && pmp_fault_raw;
    // Cause 7 = store/AMO access fault, 5 = load access fault - distinct
    // from the page-fault causes (15/13) mmu_cause above uses.
    wire [31:0] pmp_cause = mmu_access_is_write ? 32'd7 : 32'd5;

    // A MEM-stage bus access that hasn't been acknowledged freezes EX too
    // (folded in here so PC/IF-ID/ID-EX hold and interrupts stop being
    // sampled, all of which this signal already does) - but EX/MEM must
    // *hold* rather than bubble for it, so its own register block special-
    // cases `dbus_stall` ahead of `ex_busy_stall`.
    // An AMO holding MEM for its second phase stalls exactly like an
    // unacknowledged bus access does, so it folds in here rather than
    // becoming a fourth stall shape: `dbus_stall` is what makes EX/MEM and
    // MEM/WB *hold* instead of bubble, and both of those are as necessary
    // between an AMO's two phases as they are across a bus wait. Driven in
    // the MEM stage, where the phase state lives.
    wire amo_stall;
    wire dbus_stall = dbus_wait || amo_stall;
    // Whether the instruction in EX may take architectural effect this
    // cycle. Under `dbus_stall` it may not: ID/EX is being held and will
    // re-present the same instruction next cycle, so letting it redirect,
    // write a CSR, take a trap, return from one, flush the TLB, or train
    // the predictor now would do all of that twice.
    assign ex_commit = !dbus_stall;

    assign ex_busy_stall = div_stall || mmu_wait_stall || dbus_stall;

    // op2_reg is live-forwarded and drifts once EX/MEM and MEM/WB drain
    // (a few cycles into a walk, well before it resolves, since the rest
    // of the pipeline keeps moving underneath a stalled instruction) -
    // the MMU already latches `va` for the address (see mmu.v's `va_r`),
    // but the store/AMO *operand* has to be snapshotted here the same
    // way, on the same first cycle, or a translated store/AMO would end
    // up using whatever stale value forwarding falls back to once
    // resolved.
    reg [31:0] store_data_latched;
    always @(posedge clk or posedge rst) begin
        if (rst) store_data_latched <= 32'b0;
        else if (need_translate && !mmu_busy) store_data_latched <= op2_reg;
    end

    // `mmu_busy` in the select, not just `need_translate`, and the difference
    // is a whole cycle of store data.
    //
    // The snapshot above is a *register*: it holds op2_reg as of the end of
    // the cycle it was captured in. That is exactly right when a walk follows,
    // because the walk keeps the instruction in EX for several more cycles and
    // the snapshot is the only surviving copy. It is exactly wrong on a TLB
    // hit, where the MMU resolves in the same cycle it is asked and the
    // instruction leaves EX immediately: selecting the register then hands the
    // store *the previous instruction's* operand, one cycle stale.
    //
    // Measured, before the fix, from software/soc/mmutest.c running in S-mode:
    // `sw a5,0(a3)` with a5 = 0xA585A585 wrote 0x00000000, and the `sw zero`
    // two instructions later wrote 0x00000001 - each store carrying its
    // predecessor's data. The first symptom was a trap the program had armed
    // being reported as unexpected, because the store that armed it had
    // written somebody else's value.
    //
    // Nothing caught it because nothing ever did a translated store that hit
    // in the TLB: riscv-tests' S-mode suite is the `-p` (physical) variant and
    // never turns translation on at all. Under a walk - the only path that had
    // ever run - the snapshot is correct, which is why the bug survived.
    //
    // On a hit, op2_reg has not had a chance to decay: decay needs the
    // pipeline to drain underneath a stalled instruction, and nothing stalled.
    wire [31:0] store_data_final =
        (need_translate && mmu_busy) ? store_data_latched : op2_reg;

    // CSR read/write (RMW in one cycle - see csr_file.v)
    wire [31:0] csr_rdata;
    wire [31:0] csr_rdata_rmw;
    wire [31:0] csr_mtvec, csr_stvec, csr_mepc, csr_sepc;
    wire        csr_trap_to_s;
    wire [31:0] csr_mie, csr_mip, csr_mideleg;
    wire        csr_mstatus_mie, csr_sstatus_sie;
    wire [31:0] csr_op_operand = id_ex_csr_imm_form ? id_ex_zimm : op1;
    reg  [31:0] csr_new_value;
    always @(*) begin
        case (id_ex_funct3[1:0])
            2'b01:   csr_new_value = csr_op_operand;                 // CSRRW/CSRRWI
            // RS/RC compute from `csr_rdata_rmw`, not `csr_rdata`: for mip,
            // the live half of SEIP must not write back into its software
            // half. rd still gets `csr_rdata`, the OR - see csr_file.v.
            2'b10:   csr_new_value = csr_rdata_rmw | csr_op_operand;  // CSRRS/CSRRSI
            2'b11:   csr_new_value = csr_rdata_rmw & ~csr_op_operand; // CSRRC/CSRRCI
            default: csr_new_value = csr_rdata;
        endcase
    end

    // ---- interrupts ----
    // SSI/STI/SEI (bits 1/5/9) are separate causes from MSI/MTI/MEI
    // (bits 3/7/11), not delegated aliases of them - see csr_file.v.
    // M-targeted causes always win over S-targeted ones (M outranks S);
    // within a target, priority is EI > SI > TI. M-mode interrupts are
    // never maskable by mstatus.MIE while running below M; likewise
    // S-targeted ones are never maskable by sstatus.SIE while running
    // below S (only sampled between multi-cycle ops - a busy
    // divide/walk always runs to completion first).
    wire pend_mei = csr_mip[11] && csr_mie[11];
    wire pend_msi = csr_mip[3]  && csr_mie[3];
    wire pend_mti = csr_mip[7]  && csr_mie[7];
    wire pend_sei = csr_mip[9]  && csr_mie[9];
    wire pend_ssi = csr_mip[1]  && csr_mie[1];
    wire pend_sti = csr_mip[5]  && csr_mie[5];

    wire tgt_s_sei = (current_priv != PRIV_M) && csr_mideleg[9];
    wire tgt_s_ssi = (current_priv != PRIV_M) && csr_mideleg[1];
    wire tgt_s_sti = (current_priv != PRIV_M) && csr_mideleg[5];

    wire m_mei = pend_mei;
    wire m_msi = pend_msi;
    wire m_mti = pend_mti;
    wire m_sei = pend_sei && !tgt_s_sei;
    wire m_ssi = pend_ssi && !tgt_s_ssi;
    wire m_sti = pend_sti && !tgt_s_sti;
    wire any_m_candidate = m_mei || m_msi || m_mti || m_sei || m_ssi || m_sti;
    wire m_enabled = (current_priv != PRIV_M) || csr_mstatus_mie;

    wire s_sei = pend_sei && tgt_s_sei;
    wire s_ssi = pend_ssi && tgt_s_ssi;
    wire s_sti = pend_sti && tgt_s_sti;
    wire any_s_candidate = s_sei || s_ssi || s_sti;
    wire s_enabled = (current_priv == PRIV_U) || (current_priv == PRIV_S && csr_sstatus_sie);

    wire interrupt_pending_m = any_m_candidate && m_enabled;
    wire interrupt_pending_s = any_s_candidate && s_enabled;
    wire any_interrupt_pending = interrupt_pending_m || interrupt_pending_s; // M always wins if both

    wire [31:0] interrupt_cause =
        interrupt_pending_m ? (m_mei ? 32'h8000_000B : m_msi ? 32'h8000_0003 : m_mti ? 32'h8000_0007 :
                                m_sei ? 32'h8000_0009 : m_ssi ? 32'h8000_0001 : 32'h8000_0005) :
                               (s_sei ? 32'h8000_0009 : s_ssi ? 32'h8000_0001 : 32'h8000_0005);

    assign interrupt_taken = id_ex_valid && any_interrupt_pending && !ex_busy_stall;

    wire synchronous_trap = id_ex_is_trap_event || mmu_fault_now || pmp_fault_now ||
                            mem_misaligned || fetch_misaligned;
    wire take_trap = id_ex_valid && (interrupt_taken || synchronous_trap) && ex_commit;
    // Misalignment outranks a page fault, which outranks a PMP access
    // fault: misalignment is detected on the virtual address before
    // translation is even attempted (see above), and a page fault is
    // detected as part of translation, before PMP has a real physical
    // address to check at all - see `pmp_pa_valid` above.
    //
    // `fetch_misaligned` sits last because it is mutually exclusive with the
    // others by construction - a control transfer is not a memory access and
    // does not decode to an illegal instruction or ECALL - but ordering it
    // explicitly means a future decoder change cannot turn an overlap into a
    // silently wrong mcause.
    wire [31:0] cause_for_csr = interrupt_taken ? interrupt_cause :
                                 (id_ex_is_trap_event ? id_ex_trap_cause :
                                 (mem_misaligned  ? misaligned_cause :
                                 (mmu_fault_now   ? mmu_cause :
                                 (pmp_fault_now   ? pmp_cause :
                                 (fetch_misaligned ? 32'd0 : id_ex_trap_cause)))));
    wire [31:0] val_for_csr   = interrupt_taken ? 32'b0 :
                                 (id_ex_is_trap_event ? id_ex_trap_val :
                                 (mem_misaligned  ? mem_addr_ex :
                                 (mmu_fault_now   ? mem_addr_ex :
                                 (pmp_fault_now   ? mem_addr_ex :
                                 (fetch_misaligned ? actual_target : id_ex_trap_val)))));

    // MRET/SRET's own privilege-restore side effect must be suppressed
    // the same way reg/mem/CSR writes already are: an interrupt-preempted
    // MRET/SRET never architecturally completes, so it must not pop
    // mstatus/current_priv either (it'll simply be re-fetched after the
    // interrupt handler returns).
    // `minstret` counts *retired* instructions, and this core's retirement
    // point is the end of EX, not MEM: every exception it can raise - illegal
    // instruction, page fault, misaligned address, misaligned target - is
    // resolved by then, so nothing downstream can cancel an instruction that
    // gets this far.
    //
    // This used to count `ex_mem_valid` instead, which was wrong twice over:
    // it counted trapping instructions (which by definition do not retire),
    // and it put the increment a stage later than the CSR write that
    // riscv-tests' instret_overflow expects to observe. `!ex_busy_stall` is
    // what keeps a multi-cycle divide or page walk from counting itself once
    // per cycle it spends parked in EX.
    wire instret_retire = id_ex_valid && !ex_busy_stall && !take_trap;

    wire mret_en = id_ex_valid && id_ex_is_mret && !interrupt_taken && ex_commit;
    wire sret_en = id_ex_valid && id_ex_is_sret && !interrupt_taken && ex_commit;
    assign trap = take_trap;

    csr_file CSR (
        .clk(clk), .rst(rst),
        .addr(id_ex_csr_addr), .we(id_ex_valid && id_ex_csr_we && !interrupt_taken && ex_commit),
        .wdata(csr_new_value), .rdata(csr_rdata), .rdata_rmw(csr_rdata_rmw),
        .trap_en(take_trap), .trap_pc(id_ex_pc), .trap_cause(cause_for_csr), .trap_val(val_for_csr),
        .mtvec_out(csr_mtvec), .stvec_out(csr_stvec), .trap_to_s_out(csr_trap_to_s),
        .mret_en(mret_en), .mepc_out(csr_mepc),
        .sret_en(sret_en), .sepc_out(csr_sepc),
        .mtip(mtip), .msip_in(msip_in), .meip_in(meip), .seip_in(seip),
        .mie_out(csr_mie), .mip_out(csr_mip), .mideleg_out(csr_mideleg),
        .mstatus_mie_out(csr_mstatus_mie), .sstatus_sie_out(csr_sstatus_sie),
        .current_priv_out(current_priv),
        // Zero-extended: this core retires at most one instruction per
        // cycle. csr_file.v's port is 2 bits wide so that rtl/ooo/core_ooo.v
        // can report a dual-issue pair; nothing else about this core changes.
        .mtime_in(mtime_in), .instret_inc({1'b0, instret_retire}),
        .mcounteren_out(csr_mcounteren), .scounteren_out(csr_scounteren),
        .satp_mode_out(satp_mode), .satp_ppn_out(satp_ppn),
        .mstatus_mprv_out(csr_mstatus_mprv), .mstatus_mpp_out(csr_mstatus_mpp),
        .mstatus_sum_out(csr_mstatus_sum), .mstatus_mxr_out(csr_mstatus_mxr),
        .mstatus_tvm_out(csr_mstatus_tvm), .mstatus_tw_out(csr_mstatus_tw),
        .mstatus_tsr_out(csr_mstatus_tsr),
        .pmpcfg_out(csr_pmpcfg), .pmpaddr_out(csr_pmpaddr)
    );

    // Trap vector, honoring mtvec/stvec MODE.
    //
    // Direct (MODE=0): every trap enters at BASE.
    // Vectored (MODE=1): *interrupts* enter at BASE + 4*cause, so each
    //   interrupt source gets its own entry point and the handler skips the
    //   dispatch it would otherwise have to do by reading mcause. Synchronous
    //   exceptions still enter at BASE even in vectored mode - the spec is
    //   explicit about that, and getting it wrong would send a page fault to
    //   whatever handler shares its cause number with an interrupt.
    wire [31:0] tvec         = csr_trap_to_s ? csr_stvec : csr_mtvec;
    wire        tvec_vectored = tvec[0] && cause_for_csr[31];
    wire [31:0] tvec_offset  = {24'b0, cause_for_csr[5:0], 2'b00};
    wire [31:0] trap_redirect_target =
        {tvec[31:2], 2'b00} + (tvec_vectored ? tvec_offset : 32'b0);
    wire [31:0] mispredict_recovery_target = actual_taken ? actual_target : (id_ex_pc + 32'd4);
    wire mispredict = id_ex_valid && is_control_flow &&
                      ((id_ex_pred_taken != actual_taken) ||
                       (actual_taken && (id_ex_pred_target != actual_target)));

    wire redirect_valid = id_ex_valid && ex_commit &&
                          (interrupt_taken || synchronous_trap || mispredict ||
                           mret_en || sret_en || fence_i_en);
    reg [31:0] redirect_target;
    always @(*) begin
        if (interrupt_taken)        redirect_target = trap_redirect_target;
        else if (synchronous_trap)  redirect_target = trap_redirect_target;
        else if (mispredict)        redirect_target = mispredict_recovery_target;
        else if (mret_en)           redirect_target = csr_mepc;
        else if (sret_en)           redirect_target = csr_sepc;
        else if (fence_i_en)        redirect_target = id_ex_pc + 32'd4;
        else                        redirect_target = id_ex_pc + 32'd4; // unreachable given redirect_valid's gating
    end

    // Testbench-observability-only counter (hierarchical reference from
    // sim/tb_top.v) - there's no other externally-visible way to confirm
    // the predictor is actually avoiding flushes on a hot loop.
    reg [31:0] mispredict_count;
    always @(posedge clk or posedge rst) begin
        if (rst) mispredict_count <= 32'b0;
        else if (mispredict && ex_commit) mispredict_count <= mispredict_count + 32'd1;
    end

    reg [31:0] ex_result;
    always @(*) begin
        case (id_ex_wb_sel)
            WB_LUI:    ex_result = id_ex_imm;
            WB_AUIPC:  ex_result = auipc_result;
            WB_PC4:    ex_result = id_ex_pc + 32'd4;
            WB_CSR:    ex_result = csr_rdata;
            WB_MULDIV: ex_result = id_ex_funct3[2] ? div_result : mul_result;
            default:   ex_result = alu_result; // WB_ALU (OP/OPIMM); LOAD/AMO's real value doesn't use this
        endcase
    end

    // A page-faulting, PMP-denied, or interrupt-preempted load/store/AMO
    // must not commit its register or memory write - `mmu_fault_now`/
    // `pmp_fault_now` are discovered only once the walk resolves (or, for
    // PMP on an untranslated access, the same cycle - either way, after
    // id_ex_reg_we/id_ex_mem_we were already latched true for what was, at
    // decode time, a legitimately-decoded access.
    // `!fetch_misaligned` is what keeps JAL/JALR from writing its link
    // register on a misaligned target. riscv-tests checks exactly this
    // ("verify that return address was not written"), and it matters: a
    // handler that emulated the jump would otherwise see a return address
    // for a jump that never happened.
    wire commit_ok = !interrupt_taken && !mmu_fault_now && !pmp_fault_now &&
                     !mem_misaligned && !fetch_misaligned;

    // =======================================================================
    // EX/MEM pipeline register
    // =======================================================================
    reg        ex_mem_is_load, ex_mem_mem_we;
    reg [2:0]  ex_mem_funct3;
    reg [31:0] ex_mem_mem_addr, ex_mem_mem_wdata;
    reg [1:0]  ex_mem_mem_size;
    reg        ex_mem_is_amo;
    reg [4:0]  ex_mem_funct5;

    // =======================================================================
    // MEM stage
    // =======================================================================
    wire ex_mem_is_lr      = ex_mem_is_amo && (ex_mem_funct5 == 5'b00010);
    wire ex_mem_is_sc      = ex_mem_is_amo && (ex_mem_funct5 == 5'b00011);
    wire ex_mem_is_amo_rmw = ex_mem_is_amo && !ex_mem_is_lr && !ex_mem_is_sc;

    // ---- AMO read and write phases ----
    // An AMO is a read-modify-write. Doing it in one cycle - read the old
    // value combinationally, compute, write at that same edge - is
    // functionally an ordinary RMW rather than a combinational loop, and is
    // what this stage used to do. To *static timing* it is something worse:
    // one combinational chain running from the memory's read port, through
    // the AMO ALU, into the memory's write-data port. That chain was this
    // design's critical path on an ECP5 - a block RAM's 5.83 ns
    // clock-to-out followed by twelve hops of the signed and unsigned
    // comparators below, 35.4 ns end to end for 28.25 MHz. It is not a path
    // any tool can be told to ignore, either: the write is disabled during
    // the cycle the chain is live, but nothing in the netlist says so.
    //
    // So the read and the write get a register between them. `amo_rdata_q`
    // captures the old value; the ALU that consumes it runs in the
    // following cycle. Both ends of the ALU are now bounded by flops and
    // neither reaches memory combinationally.
    //
    // The phase state lives here, not in the bus adapter, because the core
    // is the only place that knows what an AMO is. rtl/soc/cpu_wb.v used to
    // run its own copy of this state machine to drive the bus write-enable;
    // it now just passes `dmem_we` through and reports `dmem_rvalid` back.
    //
    // Cycle cost: none on the SoC, which already spent a cycle between the
    // read acknowledgement and issuing the write - the register slots into
    // a gap that was there anyway. On rtl/top.v's zero-latency memory an
    // AMO now holds MEM for two cycles instead of one, because there was no
    // such gap to reuse.
    reg        amo_wr_phase;
    reg [31:0] amo_rdata_q;

    wire sc_match   = reservation_valid && (reservation_addr == ex_mem_mem_addr);
    wire sc_success = ex_mem_is_sc && sc_match;

    wire amo_active = ex_mem_valid && ex_mem_is_amo;
    // Whether this AMO writes at all. An LR never does; an SC does only
    // while its reservation holds. Neither depends on the value just read,
    // so this is known in the read phase - which is what lets both of them
    // finish there and skip the write phase entirely.
    wire amo_writes = ex_mem_is_amo_rmw || sc_success;
    wire amo_done   = amo_active && (amo_wr_phase ? !dbus_wait
                                                  : (dmem_rvalid && !amo_writes));
    assign amo_stall = amo_active && !amo_done;

    always @(posedge clk or posedge rst) begin
        if (rst)                          amo_wr_phase <= 1'b0;
        // Cleared on completion rather than on `!amo_active` alone, so that
        // an AMO immediately followed by another AMO starts in the read
        // phase instead of inheriting this one's write phase.
        else if (!amo_active || amo_done) amo_wr_phase <= 1'b0;
        else if (!amo_wr_phase && dmem_rvalid && amo_writes)
                                          amo_wr_phase <= 1'b1;
    end

    always @(posedge clk) begin
        if (amo_active && !amo_wr_phase && dmem_rvalid)
            amo_rdata_q <= dmem_rdata;
    end

    reg [31:0] amo_new_value;
    always @(*) begin
        case (ex_mem_funct5)
            5'b00000: amo_new_value = amo_rdata_q + ex_mem_mem_wdata;                                          // AMOADD
            5'b00001: amo_new_value = ex_mem_mem_wdata;                                                         // AMOSWAP
            5'b00100: amo_new_value = amo_rdata_q ^ ex_mem_mem_wdata;                                           // AMOXOR
            5'b01100: amo_new_value = amo_rdata_q & ex_mem_mem_wdata;                                           // AMOAND
            5'b01000: amo_new_value = amo_rdata_q | ex_mem_mem_wdata;                                           // AMOOR
            5'b10000: amo_new_value = ($signed(amo_rdata_q) < $signed(ex_mem_mem_wdata)) ? amo_rdata_q : ex_mem_mem_wdata; // AMOMIN
            5'b10100: amo_new_value = ($signed(amo_rdata_q) > $signed(ex_mem_mem_wdata)) ? amo_rdata_q : ex_mem_mem_wdata; // AMOMAX
            5'b11000: amo_new_value = (amo_rdata_q < ex_mem_mem_wdata) ? amo_rdata_q : ex_mem_mem_wdata;         // AMOMINU
            5'b11100: amo_new_value = (amo_rdata_q > ex_mem_mem_wdata) ? amo_rdata_q : ex_mem_mem_wdata;         // AMOMAXU
            default:  amo_new_value = amo_rdata_q;
        endcase
    end

    // The write phase is only ever entered when `amo_writes` was true, so it
    // already carries "this AMO writes" and there is nothing to re-test.
    wire        dmem_we_amo    = amo_active && amo_wr_phase;
    wire [31:0] dmem_wdata_amo = ex_mem_is_sc ? ex_mem_mem_wdata : amo_new_value;

    assign dmem_addr  = ex_mem_mem_addr;
    assign dmem_wdata = ex_mem_is_amo ? dmem_wdata_amo : ex_mem_mem_wdata;
    assign dmem_we    = (ex_mem_valid && ex_mem_mem_we) || dmem_we_amo;
    assign dmem_re    = ex_mem_valid && ex_mem_is_load;
    assign dmem_size  = ex_mem_mem_size;
    assign dmem_is_amo = ex_mem_valid && ex_mem_is_amo;

    // ---- LR/SC reservation - MEM stage only ----
    // Required, not stylistic: for back-to-back LR;SC, SC reaches EX the
    // same cycle LR is in MEM (LR's reservation update doesn't land until
    // the edge ending that cycle) - checking the reservation in EX would
    // read the stale pre-LR value and spuriously fail almost every time.
    // Checking here, one cycle later, sees it correctly. Any trap
    // invalidates the reservation (checked first, so it wins over a
    // same-cycle LR); any SC (success or failure) invalidates it too, as
    // does any successful write anywhere (coarser than address-matched,
    // spec-legal, simpler).
    wire       any_successful_write = (ex_mem_valid && ex_mem_mem_we) || dmem_we_amo;
    wire       any_sc_this_cycle    = ex_mem_valid && ex_mem_is_sc;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            reservation_valid <= 1'b0;
            reservation_addr  <= 32'b0;
        end else if (dbus_stall) begin
            // Hold until the access actually completes. This is load-bearing
            // for SC over a multi-cycle bus, not just tidiness: an SC both
            // *reads* the reservation (to decide success) and *clears* it.
            // With a zero-latency memory those happen in the same single
            // cycle and the order never mattered. With a bus, an SC occupies
            // MEM for several cycles, so clearing on the first of them would
            // pull `sc_match` out from under the write phase - the store
            // would still be issued but would report failure. Every other
            // update here is idempotent across a stall; this one is not.
        end else if (take_trap) begin
            reservation_valid <= 1'b0;
        end else if (ex_mem_valid && ex_mem_is_lr) begin
            reservation_valid <= 1'b1;
            reservation_addr  <= ex_mem_mem_addr;
        end else if (any_sc_this_cycle || any_successful_write) begin
            reservation_valid <= 1'b0;
        end
    end

    reg [31:0] mem_result;
    always @(*) begin
        if (ex_mem_is_load) begin
            case (ex_mem_funct3)
                3'b000:  mem_result = {{24{dmem_rdata[7]}},  dmem_rdata[7:0]};   // LB
                3'b001:  mem_result = {{16{dmem_rdata[15]}}, dmem_rdata[15:0]};  // LH
                3'b010:  mem_result = dmem_rdata;                                // LW
                3'b100:  mem_result = {24'b0, dmem_rdata[7:0]};                  // LBU
                3'b101:  mem_result = {16'b0, dmem_rdata[15:0]};                 // LHU
                default: mem_result = dmem_rdata;
            endcase
        end else if (ex_mem_is_lr) begin
            mem_result = dmem_rdata; // old value, word-only, no sign extension.
                                      // An LR finishes in the read phase, so
                                      // this is the read data itself
        end else if (ex_mem_is_amo_rmw) begin
            mem_result = amo_rdata_q; // ...whereas an RMW finishes in the write
                                       // phase, by which point the memory's read
                                       // port is no longer the place to look for
                                       // the old value. This is the copy taken
                                       // before the write was issued
        end else if (ex_mem_is_sc) begin
            mem_result = sc_success ? 32'd0 : 32'd1;
        end else begin
            mem_result = ex_mem_wb_data;
        end
    end

    // =======================================================================
    // MEM/WB pipeline register
    // =======================================================================
    reg [31:0] mem_wb_wb_data_r;
    reg        mem_wb_reg_we_r;
    reg [4:0]  mem_wb_rd_r;
    assign mem_wb_wb_data = mem_wb_wb_data_r;
    assign mem_wb_reg_we  = mem_wb_reg_we_r;
    assign mem_wb_rd      = mem_wb_rd_r;

    // =======================================================================
    // Sequential pipeline register updates
    // =======================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pc <= RESET_PC;
        end else if (redirect_valid) begin
            pc <= redirect_target;
        end else if (pc_freeze) begin
            // hold
        end else if (btb_pred_taken) begin
            pc <= btb_pred_target;
        end else begin
            pc <= pc + 32'd4;
        end
    end

    // ---- hart control: halted detection ----
    //
    // `dbg_pipeline_quiescent` checks if_id/id_ex/ex_mem, deliberately not
    // mem_wb: once those three are simultaneously empty, whatever lands in
    // mem_wb this cycle is the last write that will ever happen with the
    // pipeline frozen upstream of it - waiting one more cycle for mem_wb's
    // own valid bit to clear too would only add latency, not correctness.
    // Genuinely in-flight work (a divide, an MMU walk, an AMO's write
    // phase, a bus wait) is not disturbed: `dbg_halt_admit_block` only
    // blocks *admission* into if_id, so id_ex_stall's hold path (line
    // ~1421) still lets a busy EX finish exactly as it does for every
    // other stall - halting drains the pipeline instead of killing it.
    wire dbg_pipeline_quiescent = !if_id_valid && !id_ex_valid && !ex_mem_valid;

    // Single-step re-halts through this exact same quiescence check, not a
    // new one - `dbg_stepping_r && dbg_step_admitted_r` is only true once
    // the one admitted instruction is confirmed in flight (see
    // `dbg_step_admit_now` above), so `dbg_pipeline_quiescent` cannot
    // read true from stale pre-resume state: at the moment `dbg_halted_r`
    // clears, if_id/id_ex/ex_mem are all already 0 (that was the halt
    // condition), and `dbg_step_admitted_r` staying 0 until admission
    // genuinely happens is what stops this block from re-halting on that
    // same already-quiescent state before the stepped instruction ever
    // enters the pipeline.
    wire dbg_step_done = dbg_stepping_r && dbg_step_admitted_r;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dbg_halted_r         <= 1'b0;
            dbg_halt_pending     <= 1'b0;
            dbg_stepping_r       <= 1'b0;
            dbg_step_admitted_r  <= 1'b0;
            // Unlike dpc_r/dcsr_cause_r/dcsr_prv_r (purely informational,
            // never read before the first halt writes them), dcsr_step_r
            // gates admission on every resume - reset explicitly so a
            // resume before any debug write is ever issued cannot read an
            // undefined `step` and take the single-step path unasked.
            dcsr_step_r          <= 1'b0;
        end else if (dbg_halted_r) begin
            // Register writes over Abstract Command land here: dm.v only
            // ever pulses `dbg_reg_valid` while `dbg_halted` is high (its
            // own comment on this contract), so this is the only place
            // dpc_r/dcsr_step_r can change from a debug write - one more
            // condition on dpc_r's existing driver, not a second one.
            if (dbg_dpc_write)  dpc_r <= dbg_reg_wdata;
            if (dbg_dcsr_write) dcsr_step_r <= dbg_reg_wdata[2];
            if (dbg_resumereq) begin
                dbg_halted_r     <= 1'b0;
                dbg_halt_pending <= 1'b0;
                // dcsr.step is sticky per spec - resuming does not clear
                // it, a host wanting an ordinary resume again must write
                // it back to 0 first. Reads the pre-edge value of
                // dcsr_step_r on purpose: a real host cannot land a dcsr
                // write and a resume on the same DMI-driven cycle (dm.v
                // serializes DMI transactions - see its own header), so
                // this is simplest, not a race.
                dbg_stepping_r      <= dcsr_step_r;
                dbg_step_admitted_r <= 1'b0;
            end
        end else begin
            if (dbg_haltreq) dbg_halt_pending <= 1'b1;
            if (dbg_step_admit_now && dbg_stepping_r && !dbg_step_admitted_r)
                dbg_step_admitted_r <= 1'b1;
            if ((dbg_halt_pending || dbg_step_done) && dbg_pipeline_quiescent) begin
                dbg_halted_r     <= 1'b1;
                dbg_halt_pending <= 1'b0;
                dbg_stepping_r   <= 1'b0;
                dpc_r            <= pc;            // pc is frozen here: the resume address
                dcsr_cause_r     <= dbg_step_done ? 3'd4 : 3'd3;  // step : haltreq
                dcsr_prv_r       <= current_priv;
            end
        end
    end
    assign dbg_halted = dbg_halted_r;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            if_id_valid <= 1'b0;
        end else if (redirect_valid) begin
            if_id_valid <= 1'b0;
        end else if (id_ex_stall) begin
            // hold if_id unchanged (content not yet consumed by id_ex)
        end else if (if_stall || dbg_halt_admit_block) begin
            if_id_valid <= 1'b0; // content WAS consumed into id_ex; IF has nothing new this cycle
                                  // (dbg_halt_admit_block: or the hart is halting/halted, and
                                  // must stop admitting new instructions - id_ex_valid drains
                                  // one cycle behind this for free, on its own default path)
        end else begin
            if_id_valid        <= 1'b1;
            if_id_pc           <= pc;
            if_id_instr        <= imem_rdata;
            if_id_ifetch_fault <= itlb_fault_now;
            if_id_pred_taken   <= btb_pred_taken;
            if_id_pred_target  <= btb_pred_target;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            id_ex_valid <= 1'b0;
        end else if (redirect_valid) begin
            id_ex_valid <= 1'b0; // flush: squash instruction currently in ID
        end else if (ex_busy_stall) begin
            // hold id_ex unchanged: the same divide/translating instruction
            // stays "in EX" until the multi-cycle op finishes
        end else if (load_use_stall) begin
            id_ex_valid <= 1'b0; // bubble: load-use hazard
        end else begin
            id_ex_valid         <= if_id_valid;
            id_ex_pc            <= if_id_pc;
            id_ex_rs1_data      <= d_rs1_data;
            id_ex_rs2_data      <= d_rs2_data;
            id_ex_rs1           <= d_rs1;
            id_ex_rs2           <= d_rs2;
            id_ex_rd            <= d_rd;
            id_ex_imm           <= d_imm;
            id_ex_alu_ctrl      <= d_alu_ctrl;
            id_ex_is_op         <= is_op;
            id_ex_wb_sel        <= d_wb_sel;
            id_ex_reg_we        <= d_reg_we;
            id_ex_is_load       <= is_load;
            id_ex_is_store      <= is_store;
            id_ex_mem_we        <= d_mem_we;
            id_ex_mem_size      <= d_funct3[1:0];
            id_ex_funct3        <= d_funct3;
            id_ex_is_branch     <= is_branch;
            id_ex_is_jal        <= is_jal;
            id_ex_is_jalr       <= is_jalr;
            id_ex_is_csr        <= is_csr;
            id_ex_csr_we        <= d_csr_we;
            id_ex_csr_imm_form  <= csr_imm_form;
            id_ex_csr_addr      <= d_csr_addr;
            id_ex_zimm          <= d_zimm;
            id_ex_is_trap_event <= is_trap_event;
            id_ex_trap_cause    <= d_trap_cause;
            id_ex_trap_val      <= d_trap_val;
            id_ex_is_mret       <= is_mret;
            id_ex_is_sret       <= is_sret;
            id_ex_is_muldiv     <= is_muldiv;
            id_ex_is_sfence_vma <= is_sfence_vma;
            id_ex_is_fence_i    <= is_fence_i;
            id_ex_is_amo        <= is_amo;
            id_ex_funct5        <= d_funct5;
            id_ex_pred_taken    <= if_id_pred_taken;
            id_ex_pred_target   <= if_id_pred_target;
            id_ex_instr         <= if_id_instr;               // trace only
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ex_mem_valid <= 1'b0;
        end else if (dbus_stall) begin
            // Hold: this MEM access is still on the bus and its request
            // signals (driven straight off these registers) have to stay
            // asserted until the slave acknowledges. Checked ahead of
            // `ex_busy_stall`, which `dbus_stall` is a member of but whose
            // bubble behavior would drop the in-flight request.
        end else if (ex_busy_stall) begin
            ex_mem_valid  <= 1'b0; // multi-cycle op still running - nothing new for MEM this cycle
            ex_mem_retire <= 1'b0; // trace only, and it must bubble with ex_mem_valid:
                                    // leaving it set makes the divide or page walk
                                    // that caused this stall show up in the trace once
                                    // per stalled cycle. Found by the Spike
                                    // co-simulation, which is exactly the class of
                                    // thing an end-of-test pass/fail check cannot see.
        end else begin
            ex_mem_valid     <= id_ex_valid;
            ex_mem_rd        <= id_ex_rd;
            ex_mem_reg_we    <= id_ex_valid && id_ex_reg_we && commit_ok;
            ex_mem_wb_data   <= ex_result;
            // `commit_ok`-gated like `ex_mem_mem_we`/`ex_mem_is_amo` just
            // below - a load that faults (misaligned, page fault, or now a
            // PMP access fault) must not reach `dmem_re` next cycle, or
            // enforcement is architectural only: the register write-back
            // was already blocked by `ex_mem_reg_we`'s own `commit_ok`
            // gate, but the bus read (and any side effect a real device's
            // read has - a UART RX FIFO pop, for one) would still happen.
            // `mem_result`'s own use of `ex_mem_is_load` below is unaffected
            // by this either way, since nothing downstream of it can be
            // written back without `ex_mem_reg_we`.
            ex_mem_is_load   <= id_ex_valid && id_ex_is_load && commit_ok;
            ex_mem_funct3    <= id_ex_funct3;
            ex_mem_mem_we    <= id_ex_valid && id_ex_mem_we && commit_ok;
            ex_mem_mem_addr  <= mem_phys_addr;
            ex_mem_mem_wdata <= store_data_final;
            ex_mem_mem_size  <= id_ex_mem_size;
            ex_mem_is_amo    <= id_ex_valid && id_ex_is_amo && commit_ok;
            ex_mem_funct5    <= id_ex_funct5;
            ex_mem_pc        <= id_ex_pc;                     // trace only
            ex_mem_instr     <= id_ex_instr;                  // trace only
            ex_mem_retire    <= instret_retire;               // trace only
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mem_wb_reg_we_r <= 1'b0;
            trace_valid     <= 1'b0;
        end else if (dbus_stall) begin
            // Trace only: MEM/WB's contents are held below, so without this
            // an instruction stalled on the bus would be reported as retiring
            // once per stall cycle instead of once.
            trace_valid <= 1'b0;
            // Hold rather than bubble. The MEM access hasn't produced its
            // result yet, so there's nothing new to write back - but
            // clearing reg_we here would also tear down the MEM/WB
            // forwarding path mid-stall, and whatever is sitting in EX may
            // still be depending on it. Re-writing the same rd with the
            // same data for a few extra cycles is idempotent; losing a
            // forwarded operand is not.
        end else begin
            mem_wb_reg_we_r  <= ex_mem_valid && ex_mem_reg_we;
            mem_wb_rd_r      <= ex_mem_rd;
            mem_wb_wb_data_r <= mem_result;
            trace_valid      <= ex_mem_retire;                // trace only
            trace_pc         <= ex_mem_pc;                    // trace only
            trace_instr      <= ex_mem_instr;                 // trace only
        end
    end
endmodule
