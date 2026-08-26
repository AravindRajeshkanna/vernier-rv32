// core_ooo.v - the wide/out-of-order core. Phase 1 of docs/roadmap.md.
//
// ---- Why this is a second core rather than an edit to cpu_core.v ----
//
// rtl/cpu_core.v is the only design in this project that has run on silicon.
// It passes 79/82 architectural tests, matches Spike on 82/82 instruction
// traces, and closes timing at 30.77 MHz on an 85F. Evolving it in place would
// mean every intermediate commit risks the one proven artifact, with no
// working baseline left to diff a regression against.
//
// So this is a separate module with the identical port list. Both cores run
// the same suites: `make verify` for the in-order one, `make verify_ooo` for
// this one. A regression in either cannot hide behind the other, and the
// comparison between them is itself a measurement.
//
// ---- Where this file came from, and why that matters ----
//
// It starts as a byte-for-byte copy of cpu_core.v with the module renamed.
// That is deliberate rather than lazy. Roughly 140 lines of that file are
// load-bearing for M/S/U privilege, the Sv32 MMU and the A extension, and the
// verification layers found fifteen real bugs in getting them right - an MMU
// that never checked the PTE U bit, an AMO permission-checked as a load,
// medeleg refusing causes 0/4/6. Rewriting that from scratch alongside a
// microarchitecture change would mix two kinds of risk in one diff.
//
// The first commit therefore changes nothing but the name, and proves the
// second core passes everything the first does. Width is added after that,
// against a harness already known to work - docs/practices.md §2.
//
// ---- Staging ----
//
//   1a  parallel core, behaviourally identical, full suite green   done
//   1b  decoupled fetch buffer, dual issue for independent ALU ops <- here
//   1c  scoreboard: out-of-order completion, in-order retire
//   1d  renaming + reorder buffer + reservation stations + LSQ
//
// Each stage must leave `make verify_ooo` green, because a core that is
// half-converted and failing tells you nothing about which half is wrong.
//
// ---- What stage 1b added, and what it did not ----
//
// Two things, in two places worth reading together: the fetch buffer that
// replaces the single IF/ID register (search for `fb_`), and the second issue
// slot that the buffer makes possible (search for `s1_` and `id_ex1_`).
//
// The second slot executes exactly one class of instruction - single-cycle
// integer ALU ops - and the pair only forms when *both* halves are in that
// class. That is what keeps the change small enough to reason about: a pair
// in EX contains nothing that can branch, trap on an address, touch memory or
// take a second cycle, so there is no second redirect source, no second
// memory port and no way for the two halves to come apart mid-flight. An
// interrupt is the one event that can still kill a pair, and slot 1 shares
// slot 0's `commit_ok` so that it kills both.
//
// This is not a 2 IPC machine and cannot become one here. The fetch port is
// one 32-bit word per cycle all the way down to `wb_ram.v`, so sustained
// throughput is bounded at 1 IPC on straight-line code no matter how good the
// issue rule is. What dual issue buys on this design is the backlog: fetch
// runs ahead during a stall, and when the stall clears the buffer can hand
// the back end two instructions at once. The measured effect is in
// docs/roadmap.md, next to the cycle count it was measured against.
//
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
module core_ooo #(
    parameter RESET_PC = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        rst,

    // instruction memory port (physical address, post-translation if active)
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,

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
    output wire         trap   // pulses for one cycle when a trap/interrupt redirect is taken (EX)
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
    wire defer_now;
    wire [31:0] csr_mcounteren, csr_scounteren;
    wire [1:0]  current_priv;
    wire        satp_mode;
    wire [21:0] satp_ppn;
    wire        csr_mstatus_mprv;
    wire [1:0]  csr_mstatus_mpp;
    wire        csr_mstatus_sum, csr_mstatus_mxr;
    wire        csr_mstatus_tvm, csr_mstatus_tw, csr_mstatus_tsr;
    wire interrupt_taken;
    reg        ex_mem_valid;
    reg [4:0]  ex_mem_rd;
    reg        ex_mem_reg_we;
    reg [31:0] ex_mem_wb_data;
    reg        reservation_valid;
    reg [31:0] reservation_addr;

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

    wire itlb_wait_stall = itlb_req && !itlb_ok;
    wire itlb_fault_now  = itlb_req && itlb_ok && itlb_fault;
    // ---- what to fetch while the ITLB is still walking ----
    //
    // `itlb_pa` only means anything once the walk resolves; before that mmu.v
    // derives it from a PTE that has not been read yet, so it is X. cpu_wb.v
    // indexes its instruction cache with whatever is on this wire, an X index
    // makes `fetch_hit` X, and that X reaches the shared bus - where
    // wb_ram.v's `ack_r <= a_en && !ack_r` latches it permanently, because
    // `!x` is `x`. One unresolved fetch address wedges main memory for the
    // rest of the simulation.
    //
    // Holding the last address that *was* valid keeps the wire defined and,
    // because that address was fetched moments ago and is still in the
    // instruction cache, issues no bus cycle at all - which matters now that
    // the page-table walkers are a bus master competing for the same
    // interconnect. See rtl/cpu_core.v for the full account and
    // software/soc/mmutest.c for the test that found it.
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
    // IF/ID: a fetch buffer, not a single register
    // =======================================================================
    // `cpu_core.v` has one IF/ID register, so the front end and the back end
    // move as one unit: whenever ID/EX can't accept (a load-use stall, a
    // divide, a data-bus wait), PC freezes and the fetch port sits idle. Every
    // one of those cycles is a fetch this machine could have performed and
    // didn't, and when the stall clears the pipe restarts from empty.
    //
    // Here IF/ID is a FIFO instead. Fetch advances whenever the *buffer* has
    // room, which decouples it from whether ID/EX is ready, and decode drains
    // the head. Two things fall out:
    //
    //  - An `ibus_wait` is absorbed rather than bubbling the pipe, as long as
    //    the buffer is non-empty. That is the win that matters on the SoC,
    //    where instruction fetch and data share one Wishbone bus, so a load is
    //    *routinely* stalling the fetch behind it (docs/roadmap.md Phase 3).
    //  - Instructions accumulate during a stall, which is what gives the dual
    //    issue below something to be dual about. A one-entry IF/ID can never
    //    offer a second instruction, so no issue rule, however clever, can
    //    find a pair.
    //
    // Depth 4 is chosen against the stall it is meant to cover: the longest
    // routine stall here is a 33-cycle divide, which would fill any buffer,
    // and the common one is a handful of cycles of bus wait, which 4 covers.
    // Deeper costs flops and buys only the tail.
    //
    // Flushing: `redirect_valid` empties the buffer, exactly as it used to
    // clear `if_id_valid`. `sfence_en` empties it too, and that is new - see
    // the redirect logic for why SFENCE.VMA now redirects.
    localparam FB_DEPTH = 4;
    localparam FB_AW    = 2;   // clog2(FB_DEPTH)

    reg [31:0] fb_pc      [0:FB_DEPTH-1];
    reg [31:0] fb_instr   [0:FB_DEPTH-1];
    reg        fb_fault   [0:FB_DEPTH-1];
    reg        fb_ptaken  [0:FB_DEPTH-1];
    reg [31:0] fb_ptarget [0:FB_DEPTH-1];

    reg [FB_AW-1:0] fb_head, fb_tail;
    reg [FB_AW:0]   fb_count;   // one bit wider than an index: 0..FB_DEPTH

    wire fb_empty = (fb_count == 0);

    // The head entry, presented to ID under the names the decode logic below
    // already uses. Everything from here to the ID/EX register is unchanged
    // from the single-register version - decode is still exactly one
    // instruction wide, and slot 1 below reads the *second* entry separately.
    wire        if_id_valid        = !fb_empty;
    wire [31:0] if_id_pc           = fb_pc[fb_head];
    wire [31:0] if_id_instr        = fb_instr[fb_head];
    wire        if_id_ifetch_fault = fb_fault[fb_head];
    wire        if_id_pred_taken   = fb_ptaken[fb_head];
    wire [31:0] if_id_pred_target  = fb_ptarget[fb_head];

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
                // mstatush, and the same story as in rtl/cpu_core.v - which
                // is the point. That fix landed on the in-order core only,
                // and this line is the second half of it, eight months late,
                // because nothing ever asked this core for the CSR: OpenSBI
                // is the only thing that reads it and `make sim_opensbi`
                // builds CORE=inorder. The wide core hung in `_start_hang`
                // with no console the first time a kernel image was pointed
                // at it. docs/practices.md section 26.
                12'h310,
                12'h320,
                12'h340, 12'h341, 12'h342, 12'h343, 12'h344,
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

    // =======================================================================
    // Slot 1: the second decoder
    // =======================================================================
    // Deliberately not a copy of the decoder above. Slot 1 accepts exactly one
    // class of instruction - a single-cycle integer ALU op - and refusing
    // everything else is what keeps the second pipe down to an ALU, a result
    // register and a write port. Anything outside the class simply waits and
    // is decoded by slot 0 on a later cycle, at exactly the speed it has now.
    //
    // What slot 1 must never contain, and why each is excluded rather than
    // handled:
    //   loads/stores/AMO      a second memory port, and a second load-use
    //                         hazard shape
    //   branches/JAL/JALR     a second redirect source - and slot 1 is the
    //                         *younger* instruction, so its redirect would
    //                         have to lose to slot 0's, which is a priority
    //                         question with no cheap answer
    //   CSR/ECALL/xRET/fences architectural state that is only correct if it
    //                         is updated in program order
    //   MUL/DIV               multi-cycle; the pair has to move in lockstep
    //
    // The class that is left - OP (minus M), OP-IMM, LUI, AUIPC - has a
    // property worth exploiting: every member is `alu_exec(a, b, ctrl)` for
    // some choice of a and b. So slot 1 has no writeback-select mux at all.
    // LUI is 0 + imm and AUIPC is pc + imm, both with the ALU's ADD control.
    // One ALU, one shared function, and no second copy of the result
    // selection logic that could drift out of step with slot 0's.
    wire [FB_AW-1:0] fb_head1 = fb_head + {{(FB_AW-1){1'b0}}, 1'b1};

    wire        s1_present = (fb_count > 1);
    wire [31:0] s1_pc      = fb_pc[fb_head1];
    wire [31:0] s1_instr   = fb_instr[fb_head1];
    wire        s1_fault   = fb_fault[fb_head1];

    wire [6:0]  s1_opcode = s1_instr[6:0];
    wire [4:0]  s1_rd     = s1_instr[11:7];
    wire [2:0]  s1_funct3 = s1_instr[14:12];
    wire [4:0]  s1_rs1    = s1_instr[19:15];
    wire [4:0]  s1_rs2    = s1_instr[24:20];
    wire [6:0]  s1_funct7 = s1_instr[31:25];

    wire s1_is_op    = (s1_opcode == OPC_OP) && (s1_funct7 != 7'b0000001); // M excluded
    wire s1_is_opimm = (s1_opcode == OPC_OPIMM);
    wire s1_is_lui   = (s1_opcode == OPC_LUI);
    wire s1_is_auipc = (s1_opcode == OPC_AUIPC);
    wire s1_in_class = s1_is_op || s1_is_opimm || s1_is_lui || s1_is_auipc;

    // The same funct7 legality rules slot 0 applies, against slot 1's fields.
    // Duplicated rather than shared because slot 0's version reads slot 0's
    // instruction word. An instruction this calls illegal is simply not
    // paired; it takes the ordinary illegal-instruction trap when it reaches
    // slot 0 next cycle. That is the safe direction to be wrong in - a false
    // "illegal" here costs throughput and never correctness.
    reg s1_alu_illegal;
    always @(*) begin
        s1_alu_illegal = 1'b0;
        if (s1_is_op) begin
            case (s1_funct3)
                3'b000, 3'b101: if (s1_funct7 != 7'b0000000 && s1_funct7 != 7'b0100000) s1_alu_illegal = 1'b1;
                default:        if (s1_funct7 != 7'b0000000) s1_alu_illegal = 1'b1;
            endcase
        end else if (s1_is_opimm) begin
            case (s1_funct3)
                3'b001:  if (s1_funct7 != 7'b0000000) s1_alu_illegal = 1'b1;                          // SLLI
                3'b101:  if (s1_funct7 != 7'b0000000 && s1_funct7 != 7'b0100000) s1_alu_illegal = 1'b1; // SRLI/SRAI
                default: ; // funct7 is immediate bits for the rest
            endcase
        end
    end

    wire s1_uses_rs1 = s1_is_op || s1_is_opimm;
    wire s1_uses_rs2 = s1_is_op;

    wire s1_use_funct7b5 = s1_is_op || (s1_is_opimm && s1_funct3 == 3'b101);
    wire [3:0] s1_alu_ctrl = (s1_is_lui || s1_is_auipc) ? 4'b0000
                                                        : {(s1_use_funct7b5 & s1_funct7[5]), s1_funct3};

    wire [31:0] s1_imm = (s1_is_lui || s1_is_auipc) ? {s1_instr[31:12], 12'b0}
                                                    : {{20{s1_instr[31]}}, s1_instr[31:20]};

    // Operand-A source, resolved at decode: LUI adds its immediate to zero,
    // AUIPC to its own PC, everything else to rs1 (forwarded in EX).
    localparam [1:0] A_REG = 2'd0, A_PC = 2'd1, A_ZERO = 2'd2;
    wire [1:0] s1_a_sel   = s1_is_auipc ? A_PC : (s1_is_lui ? A_ZERO : A_REG);
    wire       s1_use_imm = !s1_is_op;

    // =======================================================================
    // Register file
    // =======================================================================
    wire [31:0] d_rs1_data, d_rs2_data;
    wire [31:0] mem_wb_wb_data;
    wire        mem_wb_reg_we;
    wire [4:0]  mem_wb_rd;
    wire [31:0] s1_rs1_data, s1_rs2_data;
    wire [31:0] mem_wb1_wb_data;
    wire        mem_wb1_reg_we;
    wire [4:0]  mem_wb1_rd;

    // rtl/ooo/regfile_wide.v (4R/2W) in place of rtl/regfile.v (2R/1W), which
    // is unchanged and still serves cpu_core.v. Port b is read
    // unconditionally with slot 1's register fields even when no pair issues:
    // reading a register file has no side effect, and gating the address
    // would only put a mux in front of it. Write port 1 is the younger half
    // of a pair - see regfile_wide.v's header for why that priority is the
    // property its formal proof is about.
    regfile_wide RF (
        .clk(clk),
        .rs1_a(d_rs1),  .rs2_a(d_rs2),
        .rs1_b(s1_rs1), .rs2_b(s1_rs2),
        .rdata1_a(d_rs1_data),  .rdata2_a(d_rs2_data),
        .rdata1_b(s1_rs1_data), .rdata2_b(s1_rs2_data),
        .we0(mem_wb_reg_we),  .rd0(mem_wb_rd),  .wdata0(mem_wb_wb_data),
        .we1(mem_wb1_reg_we), .rd1(mem_wb1_rd), .wdata1(mem_wb1_wb_data)
    );

    // ---- slot 1's pipeline registers -------------------------------------
    // Declared here because the forwarding function below reads them. Slot 1
    // has no MEM work to do, so EX/MEM and MEM/WB carry a result and a
    // destination and nothing else - but they exist, rather than slot 1
    // writing back early, because the pair must retire in the same cycle for
    // regfile_wide's write-port priority to mean what it says. A shorter
    // slot-1 pipe would let the younger instruction's write land *before* the
    // older one's, which is the WAW bug renaming exists to solve and which
    // this stage is far too simple to need.
    reg        ex_mem1_valid, ex_mem1_reg_we, ex_mem1_retire;
    reg [4:0]  ex_mem1_rd;
    reg [31:0] ex_mem1_wb_data;
    reg [31:0] ex_mem1_pc, ex_mem1_instr;   // trace only

    reg        mem_wb1_reg_we_r;
    reg [4:0]  mem_wb1_rd_r;
    reg [31:0] mem_wb1_wb_data_r;
    assign mem_wb1_reg_we  = mem_wb1_reg_we_r;
    assign mem_wb1_rd      = mem_wb1_rd_r;
    assign mem_wb1_wb_data = mem_wb1_wb_data_r;

    // =======================================================================
    // Hazard detection
    // =======================================================================
    // Loads AND AMO/LR (their rd value, like a load's, only exists once
    // MEM computes it) share the same load-use hazard shape.
    wire id_ex_is_load_like = id_ex_is_load || id_ex_is_amo;
    wire load_use_stall = if_id_valid && id_ex_valid && id_ex_is_load_like && (id_ex_rd != 5'd0) &&
                           ((uses_rs1 && (id_ex_rd == d_rs1)) || (uses_rs2 && (id_ex_rd == d_rs2)));

    wire id_ex_stall = load_use_stall || (ex_busy_stall && !defer_now);

    // ---- the issue rule --------------------------------------------------
    // Slot 0 must itself be in slot 1's class. That is a stronger condition
    // than it first looks, and it is what makes the pair safe rather than
    // merely fast: a slot 0 that cannot branch, cannot trap, cannot touch
    // memory and cannot take more than one cycle also cannot redirect or
    // stall out from under the younger instruction beside it. The one thing
    // that can still kill the pair from slot 0's side is an interrupt, and
    // `commit_ok` - which slot 1 shares verbatim - already covers that.
    wire s0_in_class = (is_op && !is_muldiv) || is_opimm || is_lui || is_auipc;
    wire s0_pairable = if_id_valid && !if_id_ifetch_fault && !illegal &&
                       s0_in_class && !if_id_pred_taken;

    // `!if_id_pred_taken` is what makes slot 1 slot 0's architectural
    // successor rather than merely the next thing that happened to be
    // fetched. Fetch follows the BTB, so if slot 0's fetch was predicted
    // taken then the next buffer entry is at the predicted *target* - correct
    // to execute only if the prediction holds, which is not something the
    // issue stage is in a position to know.
    wire s1_pairable = s1_present && !s1_fault && s1_in_class && !s1_alu_illegal;

    // No intra-pair forwarding: slot 1 may not read what slot 0 writes. The
    // alternative is an ALU-to-ALU path inside a single cycle, which is the
    // classic way a machine that is faster in cycles turns out slower in
    // nanoseconds. The pair is simply not formed and slot 1 issues next
    // cycle, forwarded from EX/MEM like any other dependent instruction.
    wire pair_raw = d_reg_we_raw && (d_rd != 5'd0) &&
                    ((s1_uses_rs1 && (s1_rs1 == d_rd)) ||
                     (s1_uses_rs2 && (s1_rs2 == d_rd)));

    // Slot 1 needs the same load-use check slot 0 gets. `load_use_stall`
    // above only looks at slot 0's source fields, and a pair that ignored
    // this would forward a load's *address* out of EX/MEM in place of its
    // data - precisely the bug the load-use stall exists to prevent, and one
    // that only appears when a load is followed by a pair whose younger half
    // is the dependent one.
    wire s1_load_use = id_ex_valid && id_ex_is_load_like && (id_ex_rd != 5'd0) &&
                       ((s1_uses_rs1 && (id_ex_rd == s1_rs1)) ||
                        (s1_uses_rs2 && (id_ex_rd == s1_rs2)));

    wire issue_pair = s0_pairable && s1_pairable && !pair_raw && !s1_load_use;
    // The IF-stage ITLB-miss stall is independent of id_ex_stall: it's
    // about whether IF has something new to offer id_ex, not about
    // whether id_ex is free to accept if_id's *current* content. Folding
    // the two together would double-latch an instruction - see the
    // if_id register block below.
    wire if_stall    = itlb_wait_stall || ibus_wait;
    // There is no `pc_freeze` any more. In cpu_core.v the PC froze on
    // `id_ex_stall || if_stall`; with the fetch buffer the back end being
    // stalled no longer stops the front end, and the only thing that holds
    // the PC is the fetch itself stalling or the buffer filling up. See the
    // `fb_push` term in the sequential section.

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

    // Slot 1's half of the retire trace. sim/tracer.v emits this line *after*
    // slot 0's when both are valid in the same cycle, which is what keeps the
    // trace in program order and therefore keeps it diffable against Spike.
    // A dual-issue machine that retired two instructions per cycle and told
    // the tracer about only one would pass co-simulation by not showing it
    // the second one, which is the shape of test failure docs/practices.md
    // section 1 is about.
    reg [31:0] trace1_pc, trace1_instr;
    reg        trace1_valid;
    wire        trace1_rd_we   = mem_wb1_reg_we;
    wire [4:0]  trace1_rd      = mem_wb1_rd;
    wire [31:0] trace1_rd_data = mem_wb1_wb_data;

    // =======================================================================
    // EX stage
    // =======================================================================

    // forwarding: EX/MEM (most recent) takes priority over MEM/WB
    // Four in-flight results to choose between now instead of two, so the
    // four-way priority is written once as a function rather than eight times
    // as wires. The order is age, youngest first: within a pair slot 1 is the
    // younger instruction, so EX/MEM slot 1 beats EX/MEM slot 0, and both
    // beat either half of MEM/WB. Get that order backwards and the machine
    // reads a stale value only when a pair happens to write the same
    // register as a later instruction reads - which is to say, rarely, and
    // never in a way an end-of-test pass/fail check would notice.
    //
    // With slot 1 idle this is exactly the two-source mux it replaces:
    // `ex_mem1_reg_we` and `mem_wb1_reg_we` are low, and the remaining two
    // arms are the original EX/MEM-then-MEM/WB priority.
    // The four candidate producers, each reduced to "this really writes a
    // register": EX/MEM and MEM/WB, for each of the two slots.
    wire        fwd_e0_we = ex_mem_valid && ex_mem_reg_we && (ex_mem_rd != 5'd0);
    wire        fwd_m0_we = mem_wb_reg_we && (mem_wb_rd != 5'd0);
    // Slot 1's two already have validity and the x0 case folded in where they
    // are latched, so they need no extra qualification here.

    // Every forwarding source is passed in as an argument rather than read
    // out of the enclosing scope, and that is not a style choice. A function
    // called from a continuous assignment is only guaranteed to re-evaluate
    // when its *arguments* change; signals it reads from the module around it
    // may not appear in the assignment's sensitivity list at all. Written the
    // other way this function computed a correct answer whenever a new
    // instruction entered EX - which is most of the time, and enough to pass
    // the zero-latency-memory testbench - and a stale one whenever EX held
    // its contents across a bus stall and a result landed underneath it. On
    // the SoC that showed up as the boot ROM reading a wrong magic number,
    // and in co-simulation as a CSR write that the very next trap could not
    // see. Arguments make the dependency explicit and the sensitivity total.
    function [31:0] fwd_pick;
        input [4:0]  a;
        input [31:0] regval;
        input        e1_we; input [4:0] e1_rd; input [31:0] e1_data;  // youngest
        input        e0_we; input [4:0] e0_rd; input [31:0] e0_data;
        input        m1_we; input [4:0] m1_rd; input [31:0] m1_data;
        input        m0_we; input [4:0] m0_rd; input [31:0] m0_data;  // oldest
        begin
            if (a == 5'd0)                    fwd_pick = 32'b0;
            else if (e1_we && (e1_rd == a))   fwd_pick = e1_data;
            else if (e0_we && (e0_rd == a))   fwd_pick = e0_data;
            else if (m1_we && (m1_rd == a))   fwd_pick = m1_data;
            else if (m0_we && (m0_rd == a))   fwd_pick = m0_data;
            else                              fwd_pick = regval;
        end
    endfunction

    wire [31:0] op1     = fwd_pick(id_ex_rs1, id_ex_rs1_data,
                                   ex_mem1_reg_we, ex_mem1_rd, ex_mem1_wb_data,
                                   fwd_e0_we,      ex_mem_rd,  ex_mem_wb_data,
                                   mem_wb1_reg_we, mem_wb1_rd, mem_wb1_wb_data,
                                   fwd_m0_we,      mem_wb_rd,  mem_wb_wb_data);
    wire [31:0] op2_reg = fwd_pick(id_ex_rs2, id_ex_rs2_data,
                                   ex_mem1_reg_we, ex_mem1_rd, ex_mem1_wb_data,
                                   fwd_e0_we,      ex_mem_rd,  ex_mem_wb_data,
                                   mem_wb1_reg_we, mem_wb1_rd, mem_wb1_wb_data,
                                   fwd_m0_we,      mem_wb_rd,  mem_wb_wb_data);

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

    // ---- slot 1's EX: the second ALU -------------------------------------
    // The same `alu_exec` function, so the two slots cannot disagree about
    // what SRA means. Everything slot 1 can execute reduces to one call: the
    // operand-A select turns LUI into 0 + imm and AUIPC into pc + imm, which
    // is why there is no result mux here to match slot 0's `ex_result`.
    reg        id_ex1_valid;
    reg [4:0]  id_ex1_rd, id_ex1_rs1, id_ex1_rs2;
    reg [31:0] id_ex1_rs1_data, id_ex1_rs2_data;
    reg [31:0] id_ex1_imm, id_ex1_pc;
    reg [3:0]  id_ex1_alu_ctrl;
    reg [1:0]  id_ex1_a_sel;
    reg        id_ex1_use_imm;
    reg [31:0] id_ex1_instr;   // trace only

    wire [31:0] s1_op1 = fwd_pick(id_ex1_rs1, id_ex1_rs1_data,
                                  ex_mem1_reg_we, ex_mem1_rd, ex_mem1_wb_data,
                                  fwd_e0_we,      ex_mem_rd,  ex_mem_wb_data,
                                  mem_wb1_reg_we, mem_wb1_rd, mem_wb1_wb_data,
                                  fwd_m0_we,      mem_wb_rd,  mem_wb_wb_data);
    wire [31:0] s1_op2 = fwd_pick(id_ex1_rs2, id_ex1_rs2_data,
                                  ex_mem1_reg_we, ex_mem1_rd, ex_mem1_wb_data,
                                  fwd_e0_we,      ex_mem_rd,  ex_mem_wb_data,
                                  mem_wb1_reg_we, mem_wb1_rd, mem_wb1_wb_data,
                                  fwd_m0_we,      mem_wb_rd,  mem_wb_wb_data);

    wire [31:0] s1_a = (id_ex1_a_sel == A_PC)   ? id_ex1_pc :
                       (id_ex1_a_sel == A_ZERO) ? 32'b0     : s1_op1;
    wire [31:0] s1_b = id_ex1_use_imm ? id_ex1_imm : s1_op2;
    wire [31:0] s1_result = alu_exec(s1_a, s1_b, id_ex1_alu_ctrl);

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

    // =======================================================================
    // EX/MEM pipeline register
    // =======================================================================
    // Declared up here, ahead of the store buffer below, because the buffer's
    // ownership and stall logic reads them and iverilog 14 rejects
    // declaration after use. The register itself is still written in the
    // sequential block at the end of the file with the rest of the pipeline.
    reg        ex_mem_is_load, ex_mem_mem_we;
    reg [2:0]  ex_mem_funct3;
    reg [31:0] ex_mem_mem_addr, ex_mem_mem_wdata;
    reg [1:0]  ex_mem_mem_size;
    reg        ex_mem_is_amo;
    reg [4:0]  ex_mem_funct5;

    // =======================================================================
    // Store buffer
    // =======================================================================
    // Stage 1c's measurement: the data bus costs 12.6% of runtime, in 80,738
    // waits averaging 1.36 cycles each. Every one of those cycles froze the
    // entire pipeline, because `dbus_stall` held ID/EX and the request signals
    // are driven straight off `ex_mem_*` - so the store had to stay in MEM
    // until Wishbone acknowledged, and nothing behind it could move.
    //
    // A store is the case where that is pure waste. It writes no register, so
    // nothing downstream is waiting on a result, and a store that has reached
    // MEM can no longer fault: misaligned is caught in EX, page faults come
    // out of the MMU before the access is issued, and the interconnect decodes
    // on addr[31:24] alone so an out-of-range store aliases rather than
    // traps. There is therefore nothing left to report and nothing to keep it
    // in the pipeline for - only a bus transaction that has to finish.
    //
    // So it hands the transaction to this buffer and leaves. The buffer drives
    // `dmem_*` in its place until the acknowledgement arrives. That needs no
    // reorder buffer and no scoreboard, which is why it is the first piece of
    // 1c rather than a slice of the last one.
    //
    // One entry, deliberately. `cpu_wb.v` issues one transaction at a time, so
    // a second buffered store would have nowhere to go; depth here would buy
    // nothing without a deeper bus.
    reg        sb_valid;
    reg [31:0] sb_addr, sb_wdata;
    reg [1:0]  sb_size;

    wire mem_op_in_mem   = ex_mem_valid && (ex_mem_is_load || ex_mem_mem_we || ex_mem_is_amo);
    // `ex_mem_mem_we` is a plain store only - an AMO's and an SC's write
    // enables are resolved in MEM, not carried in this bit - so this is
    // already the exact set that may be buffered. `!ex_mem_is_amo` is there
    // as a guard on that reasoning rather than because it currently excludes
    // anything.
    wire plain_store_now = ex_mem_valid && ex_mem_mem_we && !ex_mem_is_amo;

    // Who owns the memory port this cycle. The buffer wins: it is holding an
    // older transaction that Wishbone has already been told about.
    wire ex_mem_owns_port = !sb_valid && mem_op_in_mem;

    // The store hands over instead of stalling. Requires the port, and
    // requires that the access did not already complete this cycle - a
    // zero-wait-state slave acknowledges immediately and the buffer never
    // sees it.
    wire store_absorbed = plain_store_now && !sb_valid && dbus_wait;

    // A younger memory access cannot use the port while the buffer holds it,
    // and waits. This is the cost side of the trade: the gain is every
    // *non*-memory instruction that gets to execute during the wait, and the
    // loss is that back-to-back memory traffic is no better off than before.
    wire sb_port_busy = sb_valid && mem_op_in_mem;

    // `dbus_wait` refers to whatever request is actually on the port, so it
    // only stalls the pipeline when the port belongs to the instruction in
    // MEM. While the buffer owns it, a `dbus_wait` is the buffer's business
    // and the pipeline runs underneath it.
    wire dbus_wait_stall = ex_mem_owns_port && dbus_wait && !store_absorbed;

    wire dbus_stall = dbus_wait_stall || amo_stall || sb_port_busy;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sb_valid <= 1'b0;
            sb_addr  <= 32'b0;
            sb_wdata <= 32'b0;
            sb_size  <= 2'b0;
        end else if (sb_valid) begin
            if (!dbus_wait) sb_valid <= 1'b0;   // acknowledged
        end else if (store_absorbed) begin
            // Latched at the same edge `ex_mem_*` advances, so the muxed bus
            // output below is continuous across the handover - Wishbone sees
            // one unbroken request, not a request that flickers while the
            // core changes its mind about where it lives.
            sb_valid <= 1'b1;
            sb_addr  <= ex_mem_mem_addr;
            sb_wdata <= ex_mem_mem_wdata;
            sb_size  <= ex_mem_mem_size;
        end
    end

    // A fence may not take effect over a store that has not reached memory
    // yet. FENCE.I exists to publish writes to the instruction stream and
    // SFENCE.VMA to publish page-table writes; both are stores, and both may
    // still be sitting in the buffer. Draining costs a cycle or two on an
    // instruction that is rare and already expensive.
    //
    // This gates `ex_commit` as well as `ex_busy_stall`, and it has to gate
    // both or neither. Holding the instruction in EX without withholding its
    // commit is what the first version of this did, and SFENCE.VMA promptly
    // vanished: `sfence_en` keys off `ex_commit`, so the fence flushed the
    // TLB and redirected - and `redirect_valid` is checked ahead of
    // `ex_busy_stall` in the ID/EX block, so it squashed itself out of the
    // pipeline. Meanwhile `instret_retire` keys off `ex_busy_stall`, so the
    // instruction never retired. It executed and was never reported. Spike
    // co-simulation caught it as a missing trace line; nothing else would
    // have, because the TLB flush still happened and the program still ran.
    wire fence_drain_stall = id_ex_valid && sb_valid &&
                             (id_ex_is_fence_i || id_ex_is_sfence_vma);

    // Testbench-observability-only: how many stores actually took the buffered
    // path. Without it, a store buffer that never absorbs anything is
    // indistinguishable from one that works (docs/practices.md section 1).
    reg [31:0] store_buffered_count;
    always @(posedge clk or posedge rst) begin
        if (rst) store_buffered_count <= 32'b0;
        else if (store_absorbed) store_buffered_count <= store_buffered_count + 32'd1;
    end
    // Whether the instruction in EX may take architectural effect this
    // cycle. Under `dbus_stall` it may not: ID/EX is being held and will
    // re-present the same instruction next cycle, so letting it redirect,
    // write a CSR, take a trap, return from one, flush the TLB, or train
    // the predictor now would do all of that twice.
    assign ex_commit = !dbus_stall && !fence_drain_stall;

    assign ex_busy_stall = div_stall || mmu_wait_stall || dbus_stall || fence_drain_stall;

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
    // `mmu_busy` in the select, not just `need_translate`. The snapshot is a
    // register, so it holds op2_reg as of the *end* of the cycle it was taken
    // in - right when a walk follows and keeps the instruction in EX, wrong on
    // a TLB hit where the instruction leaves EX the same cycle and the
    // register still holds the previous instruction's operand. rtl/cpu_core.v
    // carries the measurement; the fix is identical because the bug is.
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

    wire synchronous_trap = id_ex_is_trap_event || mmu_fault_now ||
                            mem_misaligned || fetch_misaligned;
    wire take_trap = id_ex_valid && (interrupt_taken || synchronous_trap) && ex_commit;
    // Misalignment outranks a page fault: it is detected on the virtual
    // address before translation is even attempted (see above).
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
                                 (fetch_misaligned ? 32'd0 : id_ex_trap_cause))));
    wire [31:0] val_for_csr   = interrupt_taken ? 32'b0 :
                                 (id_ex_is_trap_event ? id_ex_trap_val :
                                 (mem_misaligned  ? mem_addr_ex :
                                 (mmu_fault_now   ? mem_addr_ex :
                                 (fetch_misaligned ? actual_target : id_ex_trap_val))));

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
    wire instret_retire  = id_ex_valid  && !ex_busy_stall && !take_trap;
    wire instret1_retire = id_ex1_valid && !ex_busy_stall && !take_trap;
    // `minstret` has to advance by two when a pair retires, so csr_file.v's
    // increment is a 2-bit count rather than a flag. Anything that stops slot
    // 0 retiring stops slot 1 too - slot 1 is the younger instruction and
    // never outlives its partner - so this is a sum of two terms that share
    // their gating rather than two independent conditions.
    wire [1:0] instret_inc_n = {1'b0, instret_retire} + {1'b0, instret1_retire} +
                               {1'b0, defer_now};

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
        .mtime_in(mtime_in), .instret_inc(instret_inc_n),
        .mcounteren_out(csr_mcounteren), .scounteren_out(csr_scounteren),
        .satp_mode_out(satp_mode), .satp_ppn_out(satp_ppn),
        .mstatus_mprv_out(csr_mstatus_mprv), .mstatus_mpp_out(csr_mstatus_mpp),
        .mstatus_sum_out(csr_mstatus_sum), .mstatus_mxr_out(csr_mstatus_mxr),
        .mstatus_tvm_out(csr_mstatus_tvm), .mstatus_tw_out(csr_mstatus_tw),
        .mstatus_tsr_out(csr_mstatus_tsr)
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

    // `sfence_en` joins this list, which it was not part of in cpu_core.v.
    // There, the only instruction ahead of an SFENCE.VMA was the single IF/ID
    // entry; here the fetch buffer holds up to four, all translated under the
    // mappings the fence is invalidating. Redirecting to PC+4 - the same
    // treatment FENCE.I gets, for the same reason - refetches them under the
    // new mappings. It costs a flush on an instruction that is rare and
    // already expensive, and it is what makes the buffer safe under Sv32.
    wire redirect_valid = id_ex_valid && ex_commit &&
                          (interrupt_taken || synchronous_trap || mispredict ||
                           mret_en || sret_en || fence_i_en || sfence_en);
    reg [31:0] redirect_target;
    always @(*) begin
        if (interrupt_taken)        redirect_target = trap_redirect_target;
        else if (synchronous_trap)  redirect_target = trap_redirect_target;
        else if (mispredict)        redirect_target = mispredict_recovery_target;
        else if (mret_en)           redirect_target = csr_mepc;
        else if (sret_en)           redirect_target = csr_sepc;
        else if (fence_i_en)        redirect_target = id_ex_pc + 32'd4;
        else if (sfence_en)         redirect_target = id_ex_pc + 32'd4;
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

    // Testbench-observability-only, same as `mispredict_count` above and read
    // the same way (a hierarchical reference from sim/tb_bench.v).
    //
    // It exists because without it "dual issue works" is unfalsifiable. An
    // issue rule that never fires also never breaks anything, and would sail
    // through 82/82 co-simulation by being indistinguishable from the
    // single-issue core it replaced - the most expensive kind of test that
    // cannot fail (docs/practices.md section 1). This counts the pairs, so
    // the claim can be checked against a number instead of an absence of
    // failures.
    reg [31:0] dual_issue_count;
    always @(posedge clk or posedge rst) begin
        if (rst) dual_issue_count <= 32'b0;
        else if (instret1_retire) dual_issue_count <= dual_issue_count + 32'd1;
    end

    // The denominator for the above, and the more interesting number of the
    // two: cycles on which the buffer actually held a second instruction to
    // consider while the back end was ready to take it. If this is close to
    // `dual_issue_count` then the issue rule is accepting nearly everything
    // it is offered and the buffer is what limits pairing; if it is far
    // larger, the rule is what limits it. Those call for opposite fixes, and
    // guessing which one is in play is how a microarchitecture gets tuned in
    // the wrong direction.
    reg [31:0] pair_window_count;
    always @(posedge clk or posedge rst) begin
        if (rst) pair_window_count <= 32'b0;
        else if (!redirect_valid && !id_ex_stall && if_id_valid && s1_present)
            pair_window_count <= pair_window_count + 32'd1;
    end

    // And *why* it did not pair, charged to one cause per window, innermost
    // first. This is the other half of the paragraph above: knowing that the
    // window is wide and the pair rate is low says the rule is the
    // constraint, but not which clause of it. Widening slot 1's class,
    // adding intra-pair forwarding and deepening the fetch buffer are three
    // different changes, and these four counters are what separates them.
    reg [31:0] pair_blk_slot0;   // slot 0 itself is out of class, or predicted taken
    reg [31:0] pair_blk_class;   // slot 1 is not an ALU op this design will pair
    reg [31:0] pair_blk_raw;     // slot 1 reads what slot 0 writes
    reg [31:0] pair_blk_loaduse; // slot 1 reads a load still in EX
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pair_blk_slot0   <= 32'b0;
            pair_blk_class   <= 32'b0;
            pair_blk_raw     <= 32'b0;
            pair_blk_loaduse <= 32'b0;
        end else if (!redirect_valid && !id_ex_stall && if_id_valid &&
                     s1_present && !issue_pair) begin
            if (!s0_pairable)      pair_blk_slot0   <= pair_blk_slot0   + 32'd1;
            else if (!s1_pairable) pair_blk_class   <= pair_blk_class   + 32'd1;
            else if (pair_raw)     pair_blk_raw     <= pair_blk_raw     + 32'd1;
            else                   pair_blk_loaduse <= pair_blk_loaduse + 32'd1;
        end
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

    // A page-faulting (or interrupt-preempted) load/store/AMO must not
    // commit its register or memory write - `mmu_fault_now` is
    // discovered only once the walk resolves, well after id_ex_reg_we/
    // id_ex_mem_we were already latched true for what was, at decode
    // time, a legitimately-decoded access.
    // `!fetch_misaligned` is what keeps JAL/JALR from writing its link
    // register on a misaligned target. riscv-tests checks exactly this
    // ("verify that return address was not written"), and it matters: a
    // handler that emulated the jump would otherwise see a return address
    // for a jump that never happened.
    wire commit_ok = !interrupt_taken && !mmu_fault_now && !mem_misaligned &&
                     !fetch_misaligned;

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

    // The buffer drives the port whenever it holds a transaction; otherwise
    // MEM does, exactly as before. Held values are copies of what `ex_mem_*`
    // presented the cycle before, so every bus signal is bit-identical across
    // the changeover and `cpu_wb.v` - which drives Wishbone combinationally
    // off these, with no request register of its own - sees no discontinuity.
    assign dmem_addr  = sb_valid ? sb_addr  : ex_mem_mem_addr;
    assign dmem_wdata = sb_valid ? sb_wdata : (ex_mem_is_amo ? dmem_wdata_amo : ex_mem_mem_wdata);
    assign dmem_we    = sb_valid ? 1'b1     : ((ex_mem_valid && ex_mem_mem_we) || dmem_we_amo);
    assign dmem_re    = sb_valid ? 1'b0     : (ex_mem_valid && ex_mem_is_load);
    assign dmem_size  = sb_valid ? sb_size  : ex_mem_mem_size;
    assign dmem_is_amo = sb_valid ? 1'b0    : (ex_mem_valid && ex_mem_is_amo);

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
    // Stall attribution (simulation-observable only)
    // =======================================================================
    // Where the cycles actually go, by cause, read the same way
    // `mispredict_count` is - a hierarchical reference from sim/tb_bench.v.
    //
    // This exists because stage 1b's measurement said the back end is not
    // what this machine is short of, and the obvious next question -
    // "then what is it waiting on?" - deserves an answer with numbers in it
    // rather than a plausible story. The categories are prioritised so they
    // sum to something meaningful: each cycle is charged to exactly one
    // cause, the innermost one that is actually blocking.
    reg [31:0] stall_div_count;      // multi-cycle divide
    reg [31:0] stall_mmu_count;      // data-MMU page-table walk
    reg [31:0] stall_dbus_count;     // data access waiting on the bus
    reg [31:0] stall_loaduse_count;  // load-use hazard bubble
    reg [31:0] stall_ifetch_count;   // fetch had nothing to offer
    // Events, not cycles: `stall_dbus_count / dbus_event_count` is the mean
    // length of a data-bus wait, which is what decides how deep the reorder
    // buffer has to be to cover one. Depth is the expensive dimension of a
    // ROB - every entry is a forwarding comparator on four read ports - so
    // it is worth knowing rather than rounding up to a power of two that
    // sounds safe.
    reg [31:0] dbus_event_count;
    reg        dbus_stall_q;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dbus_event_count <= 32'b0;
            dbus_stall_q     <= 1'b0;
        end else begin
            dbus_stall_q <= dbus_stall;
            if (dbus_stall && !dbus_stall_q) dbus_event_count <= dbus_event_count + 32'd1;
        end
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            stall_div_count     <= 32'b0;
            stall_mmu_count     <= 32'b0;
            stall_dbus_count    <= 32'b0;
            stall_loaduse_count <= 32'b0;
            stall_ifetch_count  <= 32'b0;
        end else begin
            if (div_stall)                              stall_div_count     <= stall_div_count + 32'd1;
            else if (mmu_wait_stall)                    stall_mmu_count     <= stall_mmu_count + 32'd1;
            else if (dbus_stall)                        stall_dbus_count    <= stall_dbus_count + 32'd1;
            else if (load_use_stall)                    stall_loaduse_count <= stall_loaduse_count + 32'd1;
            // Charged only when the back end was ready and the buffer had
            // nothing: an idle fetch behind a full buffer is not a stall.
            else if (fb_empty && if_stall)              stall_ifetch_count  <= stall_ifetch_count + 32'd1;
        end
    end

    // ---- what a load-completion buffer could recover, and what it costs ----
    // The remaining piece of stage 1c is a buffer that lets an independent
    // younger instruction complete while a load waits on the bus. These count
    // the opportunity: a data-bus stall caused by a load in MEM, with an
    // instruction in EX that is a simple ALU op and does not depend on that
    // load. Every one is a cycle the machine spends frozen and could spend
    // executing.
    //
    // On CoreMark that is 19,188 cycles of 65,083 load-wait cycles - a 4.0%
    // ceiling, and the first piece of this phase whose ceiling was worth
    // building for. It was built, and it is not here. See docs/roadmap.md:
    // slot 1's pipeline is the only completion slot this core has, dual issue
    // is already using it 19,872 times a run, and a deferral mechanism that
    // borrows it takes more from dual issue than it returns. A version that
    // pays off needs a completion slot of its own, which is a reorder buffer
    // entry, which is stage 1d.
    //
    // The counters stay because that argument is only as good as the number
    // under it, and because the next attempt should be measured against the
    // same one.
    wire ex_is_simple_alu = id_ex_valid && !id_ex_is_load && !id_ex_is_store &&
                            !id_ex_is_amo && !id_ex_is_branch && !id_ex_is_jal &&
                            !id_ex_is_jalr && !id_ex_is_csr && !id_ex_is_muldiv &&
                            !id_ex_is_trap_event && !id_ex_is_mret && !id_ex_is_sret &&
                            !id_ex_is_fence_i && !id_ex_is_sfence_vma;
    wire ex_indep_of_load = !(ex_mem_valid && ex_mem_is_load && (ex_mem_rd != 5'd0) &&
                              ((ex_mem_rd == id_ex_rs1) || (ex_mem_rd == id_ex_rs2)));
    wire defer_candidate  = dbus_stall && ex_mem_valid && ex_mem_is_load &&
                            ex_is_simple_alu && ex_indep_of_load;

    // Every instruction that will be in EX next cycle must be independent of
    // the outstanding load - and that is *both* halves of a dual-issue pair,
    // not just the one in slot 0.
    //
    // Deferring releases `id_ex_stall`, which is exactly the condition that
    // lets a pair be latched. Checking only slot 0 leaves slot 1 to arrive in
    // EX while the load is still in MEM and take the load's *address* off the
    // EX/MEM forwarding path. It needs a load followed by a pair whose younger
    // half depends on it, which no architectural test produces - riscv-tests
    // co-simulates 82/82 against Spike with this bug present - and which
    // CoreMark's list and state passes hit within a few thousand
    // instructions. The matrix pass, which has fewer pointer chases, still
    // produced a correct CRC.
    wire next_indep_of_load =
        !(ex_mem_valid && ex_mem_is_load && (ex_mem_rd != 5'd0) &&
          ((uses_rs1 && (ex_mem_rd == d_rs1)) ||
           (uses_rs2 && (ex_mem_rd == d_rs2)) ||
           (issue_pair && s1_uses_rs1 && (ex_mem_rd == s1_rs1)) ||
           (issue_pair && s1_uses_rs2 && (ex_mem_rd == s1_rs2))));

    assign defer_now = defer_candidate && next_indep_of_load &&
                       !ex_mem1_valid && !id_ex1_valid &&
                       !redirect_valid && !fence_drain_stall;

    reg [31:0] defer_taken_count;
    always @(posedge clk or posedge rst) begin
        if (rst) defer_taken_count <= 32'b0;
        else if (defer_now) defer_taken_count <= defer_taken_count + 32'd1;
    end

    // ---- why the other opportunities are missed ----
    // 4,205 of 19,118 candidates are taken. Stage 1d's job is the rest, and
    // the two blockers call for completely different work:
    //
    //   slot 1 busy       a pair is using the only completion slot this core
    //                     has. Fixing it means a slot of its own - a third
    //                     writeback path, a third register write port, and
    //                     regfile_wide going from 2W to 3W. That is a reorder
    //                     buffer entry in all but name.
    //   successor depends the instruction that would take EX's place reads
    //                     the outstanding load. No completion slot helps;
    //                     this needs out-of-order *issue*, which is
    //                     reservation stations.
    //
    // Whichever dominates is what 1d should build, and building the wrong one
    // is the mistake this phase has already made twice. The categories are
    // exclusive and ordered the way the condition evaluates, so they sum with
    // `defer_taken_count` to the candidate count minus the rare
    // redirect/fence cases.
    reg [31:0] defer_blk_dep;    // successor instruction depends on the load
    reg [31:0] defer_blk_slot1;  // slot 1's pipeline already in use
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            defer_blk_dep   <= 32'b0;
            defer_blk_slot1 <= 32'b0;
        end else if (defer_candidate) begin
            if (!next_indep_of_load)
                defer_blk_dep <= defer_blk_dep + 32'd1;
            else if (ex_mem1_valid || id_ex1_valid)
                defer_blk_slot1 <= defer_blk_slot1 + 32'd1;
        end
    end

    reg [31:0] defer_candidate_count;  // recoverable by a load-completion buffer
    reg [31:0] load_wait_count;        // data-bus stall cycles caused by a load
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            defer_candidate_count <= 32'b0;
            load_wait_count       <= 32'b0;
        end else begin
            if (dbus_stall && ex_mem_valid && ex_mem_is_load)
                load_wait_count <= load_wait_count + 32'd1;
            if (defer_candidate)
                defer_candidate_count <= defer_candidate_count + 32'd1;
        end
    end

    // ---- how much of the load-use stall out-of-order issue could reach ----
    //
    // `stall_loaduse_count` says the pipeline waited. It does not say whether
    // there was anything else it could have run instead, and that difference
    // is the entire case for stage 1d. So this walks the fetch buffer behind
    // the stalled instruction and asks whether any entry could have issued in
    // its place: none of its sources may be written by the load in EX, by the
    // instruction that is stuck, or by anything between that one and it.
    //
    // Two answers, because they cost very different amounts to build:
    //
    //   `alu`  the independent candidate is OP / OP-IMM / LUI / AUIPC.
    //          Reachable with reservation stations and renaming alone - no
    //          memory ordering, no speculative control.
    //   `any`  a candidate exists at all, loads, stores and branches
    //          included. That needs a load-store queue and checkpointed
    //          recovery on top, so it is the looser bound.
    //
    // Both are ceilings, deliberately. Neither checks that the candidate's
    // own operands have been produced yet, that a functional unit is free, or
    // that issuing it would not simply move the stall one instruction later.
    // The window is FB_DEPTH entries, which is what this front end holds.
    // Running the same counters at FB_DEPTH 8 and 16 moves the `alu` count
    // from 1,303 to 1,743 on CoreMark, so the shallow window is not what is
    // limiting the answer - see docs/roadmap.md.
    reg [31:0] loaduse_oo_alu;
    reg [31:0] loaduse_oo_any;
    reg [31:0] loaduse_oo_none;
    // How many entries there actually were to look at, summed over every
    // load-use stall, and how often the buffer was full. Without these the
    // three counts above are unreadable: "nothing independent was available"
    // means one thing when the window held three instructions and something
    // else entirely when it held none.
    reg [31:0] loaduse_window_sum;
    reg [31:0] loaduse_window_full;

    integer         lu_k;
    reg [FB_AW-1:0] lu_idx;
    reg [31:0]      lu_instr;
    reg [6:0]       lu_op;
    reg [4:0]       lu_rs1, lu_rs2, lu_rd;
    reg             lu_u1, lu_u2, lu_is_alu, lu_writes, lu_serial, lu_dep;
    reg             lu_found_alu, lu_found_any;
    // One bit per architectural register: "a write to this is already in
    // flight ahead of the candidate". Cheaper and more exact than a nested
    // scan over the entries in between.
    reg [31:0]      lu_blockers;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            loaduse_oo_alu  <= 32'b0;
            loaduse_oo_any  <= 32'b0;
            loaduse_oo_none <= 32'b0;
            loaduse_window_sum  <= 32'b0;
            loaduse_window_full <= 32'b0;
        end else if (load_use_stall) begin
            loaduse_window_sum <= loaduse_window_sum +
                                  {{(32-FB_AW-1){1'b0}}, (fb_count - {{FB_AW{1'b0}}, 1'b1})};
            if (fb_count == FB_DEPTH)
                loaduse_window_full <= loaduse_window_full + 32'd1;
            lu_blockers           = 32'b0;
            lu_blockers[id_ex_rd] = 1'b1;              // the load in EX
            lu_blockers[d_rd]     = 1'b1;              // the instruction that is stuck
            lu_blockers[0]        = 1'b0;              // x0 is never a dependence
            lu_found_alu          = 1'b0;
            lu_found_any          = 1'b0;

            for (lu_k = 1; lu_k < FB_DEPTH; lu_k = lu_k + 1) begin
                if (lu_k < fb_count) begin
                    lu_idx    = fb_head + lu_k[FB_AW-1:0];
                    lu_instr  = fb_instr[lu_idx];
                    lu_op     = lu_instr[6:0];
                    lu_rs1    = lu_instr[19:15];
                    lu_rs2    = lu_instr[24:20];
                    lu_rd     = lu_instr[11:7];

                    lu_is_alu = (lu_op == 7'b0110011) || (lu_op == 7'b0010011) ||
                                (lu_op == 7'b0110111) || (lu_op == 7'b0010111);
                    // SYSTEM and FENCE serialize; an out-of-order machine
                    // does not get to hoist past them either.
                    lu_serial = (lu_op == 7'b1110011) || (lu_op == 7'b0001111);
                    lu_u1     = lu_is_alu || (lu_op == 7'b0000011) ||   // load
                                (lu_op == 7'b0100011) || (lu_op == 7'b1100011) ||
                                (lu_op == 7'b1100111) || (lu_op == 7'b0101111);
                    lu_u2     = (lu_op == 7'b0110011) || (lu_op == 7'b0100011) ||
                                (lu_op == 7'b1100011) || (lu_op == 7'b0101111);
                    lu_writes = lu_is_alu || (lu_op == 7'b0000011) ||
                                (lu_op == 7'b1101111) || (lu_op == 7'b1100111) ||
                                (lu_op == 7'b0101111);

                    lu_dep = (lu_u1 && lu_blockers[lu_rs1]) ||
                             (lu_u2 && lu_blockers[lu_rs2]);

                    if (!lu_dep && !lu_serial) begin
                        lu_found_any = 1'b1;
                        if (lu_is_alu) lu_found_alu = 1'b1;
                    end
                    // Whether or not it could have issued, anything past it
                    // has to treat its destination as pending.
                    if (lu_writes && (lu_rd != 5'd0)) lu_blockers[lu_rd] = 1'b1;
                end
            end

            if (lu_found_alu)      loaduse_oo_alu  <= loaduse_oo_alu  + 32'd1;
            else if (lu_found_any) loaduse_oo_any  <= loaduse_oo_any  + 32'd1;
            else                   loaduse_oo_none <= loaduse_oo_none + 32'd1;
        end
    end

    // =======================================================================
    // Sequential pipeline register updates
    // =======================================================================
    // ---- fetch buffer control -------------------------------------------
    // Declared here rather than beside the buffer itself because they depend
    // on `redirect_valid`, `if_stall` and `id_ex_stall`, all of which are
    // defined further down. iverilog 14 rejects use-before-declaration.
    //
    // How many entries leave the head this cycle. `fb_pop_n` is 0, 1 or 2:
    // slot 0 alone, or a dual-issued pair. It is 0 when ID/EX can't accept
    // (`id_ex_stall`), which is the same condition that used to hold IF/ID.
    wire [1:0] fb_pop_n = (redirect_valid || id_ex_stall || fb_empty) ? 2'd0 :
                          issue_pair                                  ? 2'd2 : 2'd1;
    wire       fb_pop   = (fb_pop_n != 2'd0);
    // Zero-extended to the counter's width once, here, rather than at each
    // of the three places it is used. `fb_pop_n` is two bits because the
    // issue rule can retire at most a pair; `fb_count` is FB_AW+1 bits
    // because it counts 0..FB_DEPTH inclusive. Mixing those by hand is how
    // FB_DEPTH stopped being a parameter: `fb_pop_n[FB_AW-1:0]` is an
    // out-of-range part-select for any FB_AW above 2, which yields x rather
    // than an error, and the head pointer went x on the first pop. The core
    // executed nothing at FB_DEPTH=8 and every stall counter read zero.
    wire [FB_AW:0] fb_pop_ext = {{(FB_AW-1){1'b0}}, fb_pop_n};

    // Push whenever this cycle's fetch produced a real instruction and there
    // is somewhere to put it. `fb_pop_n` counts against fullness in the same
    // cycle: an entry leaving frees its slot for the one arriving.
    wire fb_push = !redirect_valid && !sfence_en && !if_stall &&
                   ((fb_count - fb_pop_ext) < FB_DEPTH);

    // The fetch buffer makes SFENCE.VMA's ordering visible, so it has to be
    // handled rather than left implicit: `sfence_en` invalidates the ITLB, and
    // any instruction already sitting in the buffer was translated by the
    // mappings being invalidated. With a one-entry IF/ID that was one
    // instruction; with a 4-deep buffer it is up to four, plus however far the
    // PC has run ahead. Both are wrong - the spec orders subsequent implicit
    // references after the fence - so SFENCE.VMA now redirects to PC+4 and
    // empties the buffer, which is precisely what FENCE.I already did.
    wire fb_flush = redirect_valid || sfence_en;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pc <= RESET_PC;
        end else if (redirect_valid) begin
            pc <= redirect_target;
        end else if (!fb_push) begin
            // hold: either the fetch itself is stalled (ITLB walk, bus wait)
            // or the buffer is full. Note what is *not* here any more -
            // `id_ex_stall`. The back end being busy no longer freezes the
            // front end, which is the whole point of the buffer.
        end else if (btb_pred_taken) begin
            pc <= btb_pred_target;
        end else begin
            pc <= pc + 32'd4;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fb_head  <= {FB_AW{1'b0}};
            fb_tail  <= {FB_AW{1'b0}};
            fb_count <= {(FB_AW+1){1'b0}};
        end else if (fb_flush) begin
            fb_head  <= {FB_AW{1'b0}};
            fb_tail  <= {FB_AW{1'b0}};
            fb_count <= {(FB_AW+1){1'b0}};
        end else begin
            if (fb_push) begin
                fb_pc[fb_tail]      <= pc;
                fb_instr[fb_tail]   <= imem_rdata;
                fb_fault[fb_tail]   <= itlb_fault_now;
                fb_ptaken[fb_tail]  <= btb_pred_taken;
                fb_ptarget[fb_tail] <= btb_pred_target;
                fb_tail             <= fb_tail + {{(FB_AW-1){1'b0}}, 1'b1};
            end
            fb_head  <= fb_head + fb_pop_ext[FB_AW-1:0];
            fb_count <= fb_count + {{FB_AW{1'b0}}, fb_push} - fb_pop_ext;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            id_ex_valid  <= 1'b0;
            id_ex1_valid <= 1'b0;
        end else if (redirect_valid) begin
            id_ex_valid  <= 1'b0; // flush: squash instruction currently in ID
            id_ex1_valid <= 1'b0; // ...and the younger half of any pair with it
        end else if (ex_busy_stall && !defer_now) begin
            // hold id_ex unchanged: the same divide/translating instruction
            // stays "in EX" until the multi-cycle op finishes
        end else if (load_use_stall) begin
            id_ex_valid  <= 1'b0; // bubble: load-use hazard
            id_ex1_valid <= 1'b0;
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

            // Slot 1 latches under exactly slot 0's conditions - same block,
            // same branches - because the pair has to move as one unit. Split
            // into a second always block it would be one edit away from the
            // two halves stalling differently, and a pair that came apart
            // mid-flight would write back out of order.
            id_ex1_valid        <= issue_pair;
            id_ex1_rd           <= s1_rd;
            id_ex1_rs1          <= s1_rs1;
            id_ex1_rs2          <= s1_rs2;
            id_ex1_rs1_data     <= s1_rs1_data;
            id_ex1_rs2_data     <= s1_rs2_data;
            id_ex1_imm          <= s1_imm;
            id_ex1_pc           <= s1_pc;
            id_ex1_alu_ctrl     <= s1_alu_ctrl;
            id_ex1_a_sel        <= s1_a_sel;
            id_ex1_use_imm      <= s1_use_imm;
            id_ex1_instr        <= s1_instr;                  // trace only
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ex_mem_valid   <= 1'b0;
            ex_mem1_valid  <= 1'b0;
            ex_mem1_reg_we <= 1'b0;
            ex_mem1_retire <= 1'b0;
        end else if (dbus_stall) begin
            // Hold: this MEM access is still on the bus and its request
            // signals (driven straight off these registers) have to stay
            // asserted until the slave acknowledges. Checked ahead of
            // `ex_busy_stall`, which `dbus_stall` is a member of but whose
            // bubble behavior would drop the in-flight request.
            if (defer_now) begin
                ex_mem1_valid   <= 1'b1;
                ex_mem1_reg_we  <= id_ex_reg_we && (id_ex_rd != 5'd0) && commit_ok;
                ex_mem1_rd      <= id_ex_rd;
                ex_mem1_wb_data <= ex_result;
                ex_mem1_pc      <= id_ex_pc;
                ex_mem1_instr   <= id_ex_instr;
                ex_mem1_retire  <= 1'b1;
            end
            //
            // EX/MEM holds, but EX/MEM1 need not:
        end else if (ex_busy_stall) begin
            ex_mem_valid  <= 1'b0; // multi-cycle op still running - nothing new for MEM this cycle
            ex_mem_retire <= 1'b0; // trace only, and it must bubble with ex_mem_valid:
                                    // leaving it set makes the divide or page walk
                                    // that caused this stall show up in the trace once
                                    // per stalled cycle. Found by the Spike
                                    // co-simulation, which is exactly the class of
                                    // thing an end-of-test pass/fail check cannot see.
            ex_mem1_valid  <= 1'b0;
            ex_mem1_reg_we <= 1'b0; // slot 1's forwarding is gated on reg_we
                                     // alone, so this must bubble here too
            ex_mem1_retire <= 1'b0;
        end else begin
            ex_mem_valid     <= id_ex_valid;
            ex_mem_rd        <= id_ex_rd;
            ex_mem_reg_we    <= id_ex_valid && id_ex_reg_we && commit_ok;
            ex_mem_wb_data   <= ex_result;
            ex_mem_is_load   <= id_ex_valid && id_ex_is_load;
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

            // Slot 1. `commit_ok` is slot 0's, deliberately: it is what
            // withholds the write when an interrupt is taken at slot 0, and
            // slot 1 is younger, so anything that stops slot 0 committing has
            // to stop slot 1 too. Interrupts are the only member of
            // `commit_ok` a pair can actually meet - the issue rule has
            // already excluded every instruction that can fault.
            ex_mem1_valid    <= id_ex1_valid;
            ex_mem1_reg_we   <= id_ex1_valid && (id_ex1_rd != 5'd0) && commit_ok;
            ex_mem1_rd       <= id_ex1_rd;
            ex_mem1_wb_data  <= s1_result;
            ex_mem1_pc       <= id_ex1_pc;                    // trace only
            ex_mem1_instr    <= id_ex1_instr;                 // trace only
            ex_mem1_retire   <= instret1_retire;              // trace only
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mem_wb_reg_we_r  <= 1'b0;
            trace_valid      <= 1'b0;
            mem_wb1_reg_we_r <= 1'b0;
            trace1_valid     <= 1'b0;
        end else if (dbus_stall) begin
            // Trace only: MEM/WB's contents are held below, so without this
            // an instruction stalled on the bus would be reported as retiring
            // once per stall cycle instead of once.
            trace_valid  <= 1'b0;
            trace1_valid <= 1'b0;
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

            mem_wb1_reg_we_r  <= ex_mem1_reg_we;
            mem_wb1_rd_r      <= ex_mem1_rd;
            mem_wb1_wb_data_r <= ex_mem1_wb_data;
            trace1_valid      <= ex_mem1_retire;              // trace only
            trace1_pc         <= ex_mem1_pc;                  // trace only
            trace1_instr      <= ex_mem1_instr;               // trace only
        end
    end
endmodule
