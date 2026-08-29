// core_ooo.v - the wide/out-of-order core. Phase 1 of docs/roadmap.md.
//
// ---- Stage 1d: renaming, a reorder buffer, out-of-order issue ----
//
// Stages 1a-1c (git history) built a parallel core, a decoupled fetch
// buffer with narrow dual issue, and out-of-order completion via a store
// buffer and a load-completion buffer. docs/roadmap.md's Phase 1 section
// root-caused what was actually worth building next: renaming and a
// scoreboard are worth nothing on their own (WAR/WAW are already
// impossible under in-order issue), a reorder-buffer-only completion slot
// is worth 0.14%, and the real value - an independent instruction issuing
// around a stalled one - needs real out-of-order issue, which needs both
// of those as preconditions. That is what this stage adds.
//
// ---- What changed from stage 1c ----
//
//   - A RAT (register alias table) and a 64-entry physical register file
//     (rtl/ooo/regfile_phys.v) replace direct architectural writes.
//     Renaming happens at dispatch: a destination register gets a fresh
//     physical register, and the old mapping is stashed in the ROB entry
//     so it can be undone.
//   - An 8-entry ROB. Dispatch pushes into it; retire pops the head once
//     the head has executed. The ROB *is* the issue window - there is no
//     separate reservation-station array, because scanning eight entries
//     for the oldest ready one is cheaper than keeping a second structure
//     in sync with it.
//   - Out-of-order issue, for two classes: plain integer ALU ops (OP minus
//     M, OP-IMM, LUI, AUIPC - the class stage 1b's second decode slot
//     already isolated, now issued from anywhere in the window rather
//     than only from an adjacent pair), and loads. A load may issue once
//     its address is known, no older, still-pending store might alias it -
//     see "The load-store queue" below - and its target is ordinary memory
//     (mirrors `cpu_wb.v`'s own D-cache `dc_cacheable` test): a load to a
//     register with a real read side effect never issues speculatively,
//     because a squashed load's result being merely discarded is not the
//     same as the side effect - the byte a UART's receive register handed
//     over, say - never having happened. Such a load instead defers to the
//     ROB head the same way a load needing address translation already
//     did, and only executes once it is provably the oldest instruction.
//   - Everything else - branches/JAL/JALR, CSR ops, ECALL/EBREAK/MRET/
//     SRET/fences, MUL/DIV, AMO/LR/SC - executes only once it is the ROB
//     head. This is deliberate: these are exactly the instructions whose
//     reordering is expensive to get right (memory ordering, precise
//     traps, interrupt sampling), and the measured value is not there -
//     the 14,231-cycle "successor depends on the load" ceiling that
//     justified this stage is dominated by plain ALU ops. Executing them
//     at the ROB head is what stage 1c already did (the ROB head is this
//     core's old EX stage, one level of indirection later), so the
//     trap/CSR/MMU/AMO logic below is close to stage 1c's, retargeted.
//   - Misprediction and trap recovery no longer flush a single register.
//     A ROB entry on the wrong path is undone by walking the ROB from the
//     tail backward to the culprit, restoring each entry's destination
//     register to the mapping it overwrote - which the entry already
//     carries, for exactly this purpose - and freeing the physical
//     register it had allocated. This is the "or rollback" half of
//     docs/roadmap.md's "RAT checkpointing or rollback": no separate
//     checkpoint storage, because the ROB's own entries are already an
//     undo log, in the order that undoes them correctly.
//
// ---- The load-store queue ----
//
// A store's address and data are computed out of order, the same way a
// load's address is, and held in a small store-queue slot alongside its
// ROB entry - but the memory *write* does not happen until the store
// retires, reusing stage 1c's store-buffer/dbus handoff for the write
// itself. A load may issue only once every older, not-yet-retired store
// either has a known, provably non-overlapping address, or has already
// retired. An older store whose address is not yet computed blocks a
// younger load conservatively. There is no store-to-load forwarding: an
// aliasing load simply waits for the store to retire rather than
// receiving a forwarded value - simpler, at some cost this core does not
// try to hide. AMO/LR/SC are not part of any of this: they execute only
// at the ROB head, because "the reservation and the write happen in the
// same indivisible step" is far easier to keep true when nothing is
// reordered around it.
//
// ---- What this deliberately does not do ----
//
// Dispatch and retire are one instruction wide, not two. Stage 1b measured
// dual dispatch at 0.04% of a run - worth more as measurement than as
// feature - and out-of-order issue over an eight-entry window should
// recover at least that much on its own, without keeping a same-cycle
// pair's rename atomic. Branches execute only at the ROB head rather than
// being reordered themselves - the rollback mechanism above still applies,
// since dispatch past an unresolved branch is speculative even when the
// branch itself does not reorder, but a branch's own resolution never
// jumps the queue. A load that needs address translation is held at the
// ROB head rather than given a second concurrent MMU walk (this core has
// one data-MMU walker). Every one of these is a disclosed simplification
// of "1d as designed," not an omission - docs/roadmap.md records what each
// one costs against the measured ceiling it was scoped from.
//
// ---------------------------------------------------------------------------
// A RV32IMA CPU core (base integer ISA + Zicsr + the M multiply/divide
// extension + the A atomic extension), with full M/S/U privilege modes and
// trap delegation, timer/software/external interrupts (a real prioritized/
// claimable PLIC), a data AND instruction Sv32 MMU (independent TLBs/
// walkers), and a BTB + 2-bit saturating-counter dynamic branch predictor.
// Harvard architecture: separate instruction and data memory ports.
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

    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    output wire         itlb_wait_stall,

    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire         dmem_we,
    output wire         dmem_re,
    output wire [1:0]   dmem_size,
    input  wire [31:0] dmem_rdata,
    input  wire         dmem_rvalid,
    output wire         dmem_is_amo,

    input  wire         ibus_wait,
    input  wire         dbus_wait,

    output wire        ptw_req,
    output wire [31:0] ptw_addr,
    input  wire        ptw_gnt,
    input  wire [31:0] ptw_rdata,

    output wire        iptw_req,
    output wire [31:0] iptw_addr,
    input  wire        iptw_gnt,
    input  wire [31:0] iptw_rdata,

    input  wire         mtip,
    input  wire         msip_in,
    input  wire         meip,
    input  wire         seip,
    input  wire [63:0]  mtime_in,

    output wire         fence_i,
    output wire         trap
);

    // ---- forward declarations ----
    // Every net that is logically "produced late" (by the CSR file, by
    // retire, by the recovery walk) but referenced "early" (by IF-stage
    // translation, by decode's privilege checks, by the issue/execute
    // logic that feeds retire in the first place) has to be declared here.
    // See rtl/ooo/core_ooo.v's stage-1c header for why: iverilog rejects a
    // wire referenced before any declaration of it exists, textually.
    wire [1:0] current_priv;
    wire       satp_mode;
    wire [21:0] satp_ppn;
    wire        sfence_en;
    wire        csr_mstatus_tvm, csr_mstatus_tw, csr_mstatus_tsr;
    wire        csr_mstatus_mprv;
    wire [1:0]  csr_mstatus_mpp;
    wire        csr_mstatus_sum, csr_mstatus_mxr;
    wire [31:0] csr_mcounteren, csr_scounteren;
    wire        interrupt_taken;
    wire        retire_fire;
    wire        head_ex_commit;
    wire        head_dbus_stall;
    wire        head_fence_drain_stall;
    wire        head_mmu_busy;
    wire        btb_train_en;
    wire [31:0] btb_train_pc, btb_train_target;
    wire        btb_train_taken;
    wire        recovery_fire, recovery_keep_culprit;

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
    localparam [2:0] WB_MEM    = 3'd6; // AMO/LR result only - plain loads are Class B2

    // Class B's operand-A source. AUIPC and LUI don't read rs1 at all -
    // bits [19:15] of a U-type instruction are immediate bits, not a
    // register field - so renaming them as if they were a real source
    // register and then reading that back is simply the wrong operand.
    // Stage 1c's slot 1 had the same A_REG/A_PC/A_ZERO selector for the
    // same reason; it did not survive the rewrite into this file and its
    // absence was a real bug (AUIPC silently computing `0 + imm` instead
    // of `pc + imm`), found by tracing a failing riscv-test rather than by
    // inspection.
    localparam [1:0] A_REG = 2'd0, A_PC = 2'd1, A_ZERO = 2'd2;

    localparam PREGS   = 64;
    localparam PW      = 6;
    localparam FREE_N  = PREGS - 32;
    localparam FREE_AW = 5;

    localparam ROB_DEPTH = 8;
    localparam ROB_AW    = 3;

    localparam FB_DEPTH = 4;
    localparam FB_AW    = 2;

    // =======================================================================
    // IF stage - unchanged from stage 1c
    // =======================================================================
    reg [31:0] pc;

    wire ifetch_mmu_active = satp_mode && (current_priv != PRIV_M);
    wire itlb_req = ifetch_mmu_active;
    wire itlb_resolved, itlb_fault, itlb_busy;
    wire [31:0] itlb_pa;
    wire [31:0] itlb_pa_va;

    mmu IMMU (
        .clk(clk), .rst(rst),
        .req(itlb_req), .va(pc), .is_store(1'b0), .is_fetch(1'b1),
        .is_user(current_priv == PRIV_U), .sum(1'b0), .mxr(1'b0),
        .sfence(sfence_en), .satp_ppn(satp_ppn),
        .resolved(itlb_resolved), .fault(itlb_fault), .pa(itlb_pa),
        .pa_va(itlb_pa_va), .busy(itlb_busy),
        .ptw_req(iptw_req), .ptw_addr(iptw_addr),
        .ptw_gnt(iptw_gnt), .ptw_rdata(iptw_rdata)
    );

    wire itlb_answer_stale = itlb_pa_va != pc;
    wire itlb_ok           = itlb_resolved && !itlb_answer_stale;

    assign itlb_wait_stall = itlb_req && !itlb_ok;
    wire itlb_fault_now  = itlb_req && itlb_ok && itlb_fault;

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

    wire btb_pred_taken;
    wire [31:0] btb_pred_target;

    btb BTB (
        .clk(clk), .rst(rst),
        .predict_pc(pc),
        .predicted_taken(btb_pred_taken), .predicted_target(btb_pred_target),
        .train_en(btb_train_en), .train_pc(btb_train_pc),
        .train_taken(btb_train_taken), .train_target(btb_train_target)
    );

    // =======================================================================
    // IF/ID: the same 4-deep fetch buffer as stage 1c, popped one at a time
    // =======================================================================
    reg [31:0] fb_pc      [0:FB_DEPTH-1];
    reg [31:0] fb_instr   [0:FB_DEPTH-1];
    reg        fb_fault   [0:FB_DEPTH-1];
    reg        fb_ptaken  [0:FB_DEPTH-1];
    reg [31:0] fb_ptarget [0:FB_DEPTH-1];

    reg [FB_AW-1:0] fb_head, fb_tail;
    reg [FB_AW:0]   fb_count;

    wire fb_empty = (fb_count == 0);

    wire        if_id_valid        = !fb_empty;
    wire [31:0] if_id_pc           = fb_pc[fb_head];
    wire [31:0] if_id_instr        = fb_instr[fb_head];
    wire        if_id_ifetch_fault = fb_fault[fb_head];
    wire        if_id_pred_taken   = fb_ptaken[fb_head];
    wire [31:0] if_id_pred_target  = fb_ptarget[fb_head];

    // =======================================================================
    // ID stage: decode - unchanged from stage 1c's slot-0 decoder
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
    wire is_amo     = (d_opcode == OPC_AMO) && (d_funct3 == 3'b010);
    wire is_branch  = (d_opcode == OPC_BRANCH);
    wire is_jal     = (d_opcode == OPC_JAL);
    wire is_jalr    = (d_opcode == OPC_JALR);
    wire is_lui     = (d_opcode == OPC_LUI);
    wire is_auipc   = (d_opcode == OPC_AUIPC);
    wire is_system  = (d_opcode == OPC_SYSTEM);
    wire is_miscmem = (d_opcode == OPC_MISCMEM);
    wire is_fence_i = is_miscmem && (d_funct3 == 3'b001);

    wire is_lr = is_amo && (d_funct5 == 5'b00010);
    wire is_sc = is_amo && (d_funct5 == 5'b00011);
    wire amo_funct5_ok = (d_funct5 == 5'b00010) || (d_funct5 == 5'b00011) || (d_funct5 == 5'b00001) ||
                          (d_funct5 == 5'b00000) || (d_funct5 == 5'b00100) || (d_funct5 == 5'b01100) ||
                          (d_funct5 == 5'b01000) || (d_funct5 == 5'b10000) || (d_funct5 == 5'b10100) ||
                          (d_funct5 == 5'b11000) || (d_funct5 == 5'b11100);
    wire amo_illegal = is_amo && !amo_funct5_ok;

    wire is_muldiv  = is_op && (d_funct7 == 7'b0000001);

    wire is_csr    = is_system && (d_funct3 != 3'b000);
    wire is_priv   = is_system && (d_funct3 == 3'b000);
    wire is_ecall  = is_priv && (d_funct12 == 12'h000);
    wire is_ebreak = is_priv && (d_funct12 == 12'h001);
    wire is_mret   = is_priv && (d_funct12 == 12'h302);
    wire is_sret   = is_priv && (d_funct12 == 12'h102);
    wire is_sfence_vma = is_priv && (d_funct7 == 7'b0001001);
    wire is_wfi        = is_priv && (d_funct12 == 12'h105);

    wire mret_priv_ok    = (current_priv == PRIV_M);
    wire sret_priv_ok    = (current_priv == PRIV_M) ||
                           ((current_priv == PRIV_S) && !csr_mstatus_tsr);
    wire sfence_priv_ok  = (current_priv == PRIV_M) ||
                           ((current_priv == PRIV_S) && !csr_mstatus_tvm);
    wire wfi_priv_ok     = (current_priv == PRIV_M) ||
                           ((current_priv == PRIV_S) && !csr_mstatus_tw);

    wire csr_imm_form   = is_csr && d_funct3[2];
    wire csr_set_clear  = (d_funct3[1:0] == 2'b10) || (d_funct3[1:0] == 2'b11);
    wire csr_will_write = !csr_set_clear || (d_rs1 != 5'd0);

    function automatic csr_addr_ok;
        input [11:0] a;
        begin
            case (a)
                12'h100, 12'h104, 12'h105, 12'h106, 12'h140, 12'h141, 12'h142,
                12'h143, 12'h144, 12'h180,
                12'h300, 12'h301, 12'h302, 12'h303, 12'h304, 12'h305, 12'h306,
                12'h310,
                12'h320,
                12'h340, 12'h341, 12'h342, 12'h343, 12'h344,
                12'hB00, 12'hB02, 12'hB80, 12'hB82,
                12'hC00, 12'hC01, 12'hC02, 12'hC80, 12'hC81, 12'hC82,
                12'hF11, 12'hF12, 12'hF13,
                12'hF14: csr_addr_ok = 1'b1;
                default: csr_addr_ok = 1'b0;
            endcase
        end
    endfunction

    function automatic csr_addr_ro;
        input [11:0] a;
        begin
            case (a)
                12'hF11, 12'hF12, 12'hF13, 12'hF14,
                12'hC00, 12'hC01, 12'hC02, 12'hC80, 12'hC81, 12'hC82: csr_addr_ro = 1'b1;
                default: csr_addr_ro = 1'b0;
            endcase
        end
    endfunction

    wire csr_funct3_ok    = !is_csr || (d_funct3 != 3'b100);

    wire       is_ucounter = is_csr && (d_csr_addr[11:5] == 7'b1100_000);
    wire [4:0] counter_idx = d_csr_addr[4:0];
    wire counter_denied = is_ucounter &&
        (((current_priv != PRIV_M) && !csr_mcounteren[counter_idx]) ||
         ((current_priv == PRIV_U) && !csr_scounteren[counter_idx]));

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
                3'b001:  if (d_funct7 != 7'b0000000) alu_op_illegal = 1'b1;
                3'b101:  if (d_funct7 != 7'b0000000 && d_funct7 != 7'b0100000) alu_op_illegal = 1'b1;
                default: ;
            endcase
        end
    end

    wire branch_funct3_ok = !is_branch || (d_funct3 != 3'b010 && d_funct3 != 3'b011);
    wire load_funct3_ok   = !is_load  || (d_funct3 != 3'b011 && d_funct3 != 3'b110 && d_funct3 != 3'b111);
    wire store_funct3_ok  = !is_store || (d_funct3 == 3'b000 || d_funct3 == 3'b001 || d_funct3 == 3'b010);

    wire illegal = !valid_opcode || alu_op_illegal || !branch_funct3_ok ||
                   !load_funct3_ok || !store_funct3_ok || csr_illegal || priv_illegal || amo_illegal;

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
    // LUI/AUIPC force ADD (4'b0000) regardless of what `d_funct3` reads:
    // bits [14:12] of a U-type instruction are immediate bits, not a real
    // funct3 field, so using them as one picks a near-random ALU op. Stage
    // 1c's slot 1 had this exact override (`s1_alu_ctrl`); it did not
    // survive being folded into a single dispatch-time `d_alu_ctrl`, and
    // silently turned every AUIPC into whatever `alu_exec` its immediate's
    // low bits happened to select - found the same way as the A_PC bug
    // above, via a Spike co-simulation diff.
    wire [3:0] d_alu_ctrl = (is_lui || is_auipc) ? 4'b0000 : {(use_funct7b5 & d_funct7[5]), d_funct3};

    reg [31:0] d_imm;
    always @(*) begin
        case (d_opcode)
            OPC_STORE:  d_imm = d_imm_s;
            OPC_BRANCH: d_imm = d_imm_b;
            OPC_LUI, OPC_AUIPC: d_imm = d_imm_u;
            OPC_JAL:    d_imm = d_imm_j;
            OPC_AMO:    d_imm = 32'b0;
            default:    d_imm = d_imm_i;
        endcase
    end

    reg [2:0] d_wb_sel;
    always @(*) begin
        case (d_opcode)
            OPC_LUI:            d_wb_sel = WB_LUI;
            OPC_AUIPC:          d_wb_sel = WB_AUIPC;
            OPC_JAL, OPC_JALR:  d_wb_sel = WB_PC4;
            OPC_LOAD:           d_wb_sel = WB_MEM;
            OPC_AMO:            d_wb_sel = WB_MEM;
            default:            d_wb_sel = is_csr ? WB_CSR : (is_muldiv ? WB_MULDIV : WB_ALU);
        endcase
    end

    wire d_reg_we_raw = is_op || is_opimm || is_lui || is_auipc || is_jal || is_jalr ||
                          is_load || is_csr || is_amo;
    wire d_reg_we     = d_reg_we_raw && !suppress_effects;
    wire d_mem_we     = is_store && !suppress_effects;
    wire d_csr_we     = is_csr && csr_will_write && !suppress_effects;

    wire uses_rs1 = is_op || is_opimm || is_load || is_store || is_branch || is_jalr || is_amo ||
                    (is_csr && !csr_imm_form);
    wire uses_rs2 = is_op || is_store || is_branch || is_amo;

    // Out-of-order class: plain integer ALU. Everything else executes only
    // at the ROB head (see the header).
    //
    // `&& !illegal`: an illegal instruction whose opcode field happens to
    // match OP/OP-IMM/LUI/AUIPC (e.g. a well-formed R-type opcode with an
    // undefined funct7, as opposed to a garbage opcode field) was still
    // `d_is_alu_class`, since that classification never looked at
    // legality - only at the opcode bits. `headS_valid` unconditionally
    // excludes anything is_alu_class (that class retires through Class B,
    // never the head), so an illegal-but-ALU-shaped instruction's
    // `rob_is_trap_event` bit sat there true forever: correctly computed
    // at dispatch, never once reachable by the only logic that acts on it.
    // It just completed as an undefined ALU result and retired normally,
    // trap never taken. Found via the SoC acceptance program's own
    // deliberately-illegal-R-type instruction: one fewer trap-handler
    // entry than every other cause of entry accounted for.
    wire d_is_alu_class = ((is_op && !is_muldiv) || is_opimm || is_lui || is_auipc) && !illegal;

    // =======================================================================
    // Renaming: RAT + physical register file
    // =======================================================================
    reg [PW-1:0] rat [0:31];
    reg          preg_busy [0:PREGS-1];

    reg [PW-1:0] free_list [0:FREE_N-1];
    reg [FREE_AW-1:0] free_head, free_tail;
    reg [FREE_AW:0]   free_count;
    wire free_empty = (free_count == 0);

    wire [PW-1:0] rs1_preg = rat[d_rs1];
    wire [PW-1:0] rs2_preg = rat[d_rs2];

    wire [31:0] rf_rdata1, rf_rdata2;

    // =======================================================================
    // The reorder buffer
    // =======================================================================
    reg               rob_valid   [0:ROB_DEPTH-1];
    reg               rob_issued  [0:ROB_DEPTH-1]; // execution/address computation begun (or, for Class S, finished)
    reg               rob_done    [0:ROB_DEPTH-1]; // result (or exception) known - ready to retire
    reg [31:0]        rob_pc      [0:ROB_DEPTH-1];
    reg [31:0]        rob_instr   [0:ROB_DEPTH-1];
    reg               rob_has_rd  [0:ROB_DEPTH-1];
    reg [4:0]         rob_arch_rd [0:ROB_DEPTH-1];
    reg [PW-1:0]      rob_old_preg[0:ROB_DEPTH-1];
    reg [PW-1:0]      rob_new_preg[0:ROB_DEPTH-1];

    reg               rob_r1_ready[0:ROB_DEPTH-1];
    reg [PW-1:0]      rob_r1_tag  [0:ROB_DEPTH-1];
    reg [31:0]        rob_r1_val  [0:ROB_DEPTH-1];
    reg               rob_r2_ready[0:ROB_DEPTH-1];
    reg [PW-1:0]      rob_r2_tag  [0:ROB_DEPTH-1];
    reg [31:0]        rob_r2_val  [0:ROB_DEPTH-1];

    reg [2:0]  rob_wb_sel   [0:ROB_DEPTH-1];
    reg [3:0]  rob_alu_ctrl [0:ROB_DEPTH-1];
    reg        rob_is_op    [0:ROB_DEPTH-1];
    reg [1:0]  rob_a_sel    [0:ROB_DEPTH-1]; // Class B only: A_REG/A_PC/A_ZERO
    reg [31:0] rob_imm      [0:ROB_DEPTH-1];
    reg [2:0]  rob_funct3   [0:ROB_DEPTH-1];
    reg [1:0]  rob_mem_size [0:ROB_DEPTH-1];
    reg        rob_is_load  [0:ROB_DEPTH-1];
    reg        rob_is_store [0:ROB_DEPTH-1];
    reg        rob_is_amo   [0:ROB_DEPTH-1];
    reg [4:0]  rob_funct5   [0:ROB_DEPTH-1];
    reg        rob_is_branch[0:ROB_DEPTH-1];
    reg        rob_is_jal   [0:ROB_DEPTH-1];
    reg        rob_is_jalr  [0:ROB_DEPTH-1];
    reg        rob_pred_taken [0:ROB_DEPTH-1];
    reg [31:0] rob_pred_target[0:ROB_DEPTH-1];
    reg        rob_is_csr   [0:ROB_DEPTH-1];
    reg        rob_csr_we   [0:ROB_DEPTH-1];
    reg        rob_csr_imm_form[0:ROB_DEPTH-1];
    reg [11:0] rob_csr_addr [0:ROB_DEPTH-1];
    reg [31:0] rob_zimm     [0:ROB_DEPTH-1];
    reg        rob_is_trap_event[0:ROB_DEPTH-1];
    reg [31:0] rob_trap_cause[0:ROB_DEPTH-1];
    reg [31:0] rob_trap_val [0:ROB_DEPTH-1];
    reg        rob_is_mret  [0:ROB_DEPTH-1];
    reg        rob_is_sret  [0:ROB_DEPTH-1];
    reg        rob_is_muldiv[0:ROB_DEPTH-1];
    reg        rob_is_sfence_vma[0:ROB_DEPTH-1];
    reg        rob_is_fence_i[0:ROB_DEPTH-1];
    reg        rob_is_alu_class[0:ROB_DEPTH-1];
    reg        rob_needs_mmu[0:ROB_DEPTH-1]; // a load that turned out to need translation - held to the head

    reg [31:0] rob_result   [0:ROB_DEPTH-1];

    reg [31:0] sq_addr [0:ROB_DEPTH-1];
    reg [1:0]  sq_size [0:ROB_DEPTH-1];
    reg [31:0] sq_wdata[0:ROB_DEPTH-1];

    reg [ROB_AW-1:0] rob_head, rob_tail;
    reg [ROB_AW:0]   rob_count;
    wire rob_empty = (rob_count == 0);
    wire rob_full  = (rob_count == ROB_DEPTH);

    // =======================================================================
    // Completion buses (CDB): one per completion source. A dispatching
    // instruction, and every waiting ROB entry, snoop all three every
    // cycle.
    // =======================================================================
    wire          cdbS_valid, cdbB_valid, cdbL_valid;
    wire [PW-1:0] cdbS_preg, cdbB_preg, cdbL_preg;
    wire [31:0]   cdbS_val,  cdbB_val,  cdbL_val;

    // src_ready(), src_value(), and the exclude-own-bus
    // src_value_ex_s()/src_value_ex_b() used to live here as functions. All
    // four are gone now, every call site inlined instead: `src_value`'s
    // continuous-assignment callers were the first found to be affected by
    // iverilog's unreliable re-evaluation of a function's internal reads
    // (the CDBs, here) in this version - see the note by `dispatch_r1_ready`
    // below - but its two remaining callers, both inside procedural `always`
    // blocks, were later found to be affected too (the load-address scan
    // above `issL_addr_calc`, and the store address/data computation near
    // `sq_addr`/`sq_wdata`): being procedural was not sufficient on its own:
    // calling the same `automatic` function more than once with different
    // arguments within one evaluation - across a loop, across concurrently
    // triggered always blocks, or both - was enough to trigger the same
    // class of stale result. Inlining every call site removed the function
    // entirely rather than trying to characterize exactly which procedural
    // shapes are safe.

    // Resolving an entry's *own* operands while computing the value that
    // entry is about to drive onto its own completion bus must not consult
    // that same bus - `rob_r1_ready` already being true never means "ready
    // via my own not-yet-computed result" (a fresh physical register is
    // never a live source tag until some *other* instruction reads it), so
    // the value can never actually come from here - but the reference
    // alone is a structural combinational cycle otherwise. Class S and
    // Class B's operand reads (below, inlined rather than through a
    // function - see the note above) each exclude their own bus for this
    // reason.

    regfile_phys #(.PREGS(PREGS), .PW(PW)) RF (
        .clk(clk),
        .rs1_a(rs1_preg), .rs2_a(rs2_preg),
        .rdata1_a(rf_rdata1), .rdata2_a(rf_rdata2),
        .we0(cdbS_valid), .rd0(cdbS_preg), .wdata0(cdbS_val),
        .we1(cdbB_valid), .rd1(cdbB_preg), .wdata1(cdbB_val),
        .we2(cdbL_valid), .rd2(cdbL_preg), .wdata2(cdbL_val)
    );

    // =======================================================================
    // Dispatch admission
    // =======================================================================
    wire dispatch_needs_preg = d_reg_we_raw && !suppress_effects && (d_rd != 5'd0);
    wire dispatch_can_go = if_id_valid && !rob_full &&
                          (!dispatch_needs_preg || !free_empty) && !recovery_fire;
    wire [PW-1:0] alloc_preg = free_list[free_head];

    // Inlined rather than calling src_ready()/src_value(): both are
    // `function`s, and a function called from a *continuous* assignment
    // (as opposed to from inside a procedural `always` block, where this
    // is not a problem) only reliably re-evaluates when its own arguments
    // change in this iverilog version - a change to a signal the function
    // reads internally (here, any of the three CDBs) does not reliably
    // retrigger it. regfile_wide.v's header documents the same failure
    // mode for exactly the same reason and inlines its bypass logic for
    // it; this hit it for real, corrupting a branch's operand with a
    // long-stale CDB match from an earlier, unrelated cycle - found via a
    // Spike co-simulation diff, not by inspection.
    wire dispatch_r1_ready = (rs1_preg == {PW{1'b0}}) || !preg_busy[rs1_preg] ||
                             (cdbS_valid && (cdbS_preg == rs1_preg)) ||
                             (cdbB_valid && (cdbB_preg == rs1_preg)) ||
                             (cdbL_valid && (cdbL_preg == rs1_preg));
    wire dispatch_r2_ready = (rs2_preg == {PW{1'b0}}) || !preg_busy[rs2_preg] ||
                             (cdbS_valid && (cdbS_preg == rs2_preg)) ||
                             (cdbB_valid && (cdbB_preg == rs2_preg)) ||
                             (cdbL_valid && (cdbL_preg == rs2_preg));
    wire [31:0] dispatch_r1_val =
        (rs1_preg == {PW{1'b0}})                  ? 32'b0 :
        (cdbS_valid && (cdbS_preg == rs1_preg))   ? cdbS_val :
        (cdbB_valid && (cdbB_preg == rs1_preg))   ? cdbB_val :
        (cdbL_valid && (cdbL_preg == rs1_preg))   ? cdbL_val :
                                                     rf_rdata1;
    wire [31:0] dispatch_r2_val =
        (rs2_preg == {PW{1'b0}})                  ? 32'b0 :
        (cdbS_valid && (cdbS_preg == rs2_preg))   ? cdbS_val :
        (cdbB_valid && (cdbB_preg == rs2_preg))   ? cdbB_val :
        (cdbL_valid && (cdbL_preg == rs2_preg))   ? cdbL_val :
                                                     rf_rdata2;

    // =======================================================================
    // Issue select: oldest ready entry per class, scanning the ROB itself
    // =======================================================================
    // Each combinational scan below gets its own loop variable rather than
    // sharing one module-scope integer. They used to share `ri`: legal
    // Verilog, but a real bug in simulation - a variable written by one
    // `always` process and read by another creates a dependency between
    // otherwise-unrelated processes that has nothing to do with the logic
    // being described, and iverilog spent forever re-triggering these
    // three blocks (and the sequential block's own reset loops, which also
    // used `ri`) off each other's loop-counter writes instead of ever
    // settling. Synthesis would have unrolled every one of these anyway;
    // this only ever mattered for simulation.
    integer riB, riST, riL;

    reg               issB_found;
    reg [ROB_AW-1:0]  issB_idx;
    always @(*) begin
        issB_found = 1'b0;
        issB_idx   = rob_head;
        for (riB = 0; riB < ROB_DEPTH; riB = riB + 1) begin
            if (!issB_found && (riB[ROB_AW:0] < rob_count)) begin
                if (rob_valid[(rob_head + riB[ROB_AW-1:0])] &&
                    rob_is_alu_class[(rob_head + riB[ROB_AW-1:0])] &&
                    !rob_issued[(rob_head + riB[ROB_AW-1:0])] &&
                    rob_r1_ready[(rob_head + riB[ROB_AW-1:0])] &&
                    rob_r2_ready[(rob_head + riB[ROB_AW-1:0])]) begin
                    issB_found = 1'b1;
                    issB_idx   = rob_head + riB[ROB_AW-1:0];
                end
            end
        end
    end

    // ---- store address/data computation: out of order, like a load ----
    reg               issST_found;
    reg [ROB_AW-1:0]  issST_idx;
    always @(*) begin
        issST_found = 1'b0;
        issST_idx   = rob_head;
        for (riST = 0; riST < ROB_DEPTH; riST = riST + 1) begin
            if (!issST_found && (riST[ROB_AW:0] < rob_count)) begin
                if (rob_valid[(rob_head + riST[ROB_AW-1:0])] &&
                    rob_is_store[(rob_head + riST[ROB_AW-1:0])] &&
                    !rob_issued[(rob_head + riST[ROB_AW-1:0])] &&
                    rob_r1_ready[(rob_head + riST[ROB_AW-1:0])] &&
                    rob_r2_ready[(rob_head + riST[ROB_AW-1:0])]) begin
                    issST_found = 1'b1;
                    issST_idx   = rob_head + riST[ROB_AW-1:0];
                end
            end
        end
    end

    // A load may issue once its own address is computable and no older,
    // not-yet-issued store's address is unknown, nor any older, issued
    // store's address provably overlaps - both checked directly in
    // `lsq_load_ok` below (word-granularity, per the header's disclosed
    // simplification).
    function automatic lsq_load_ok;
        input [ROB_AW-1:0] lidx;
        input [31:0]       laddr;
        // `integer`, not `[ROB_AW-1:0]` - a loop counter has to be able to
        // reach ROB_DEPTH to ever stop. A ROB_AW-wide (3-bit) counter can
        // only ever hold 0..7, so `k < ROB_DEPTH` (8) was true for every
        // representable value and this loop never terminated - the actual
        // cause of the hang chased down to here: issB and issST's scans
        // use the same pattern but never call a function with a loop of
        // its own, so they never hit it.
        integer k;
        reg [ROB_AW:0]   age;
        reg              blocked;
        begin
            blocked = 1'b0;
            age = lidx - rob_head;
            for (k = 0; k < ROB_DEPTH; k = k + 1) begin
                if ({{1{1'b0}}, k[ROB_AW-1:0]} < age) begin
                    if (rob_valid[rob_head + k[ROB_AW-1:0]] && rob_is_store[rob_head + k[ROB_AW-1:0]]) begin
                        if (!rob_issued[rob_head + k[ROB_AW-1:0]])
                            blocked = 1'b1;
                        else if (sq_addr[rob_head + k[ROB_AW-1:0]][31:2] == laddr[31:2])
                            blocked = 1'b1;
                    end
                    // An AMO never computes its address ahead of time the
                    // way a store does (it executes only at the ROB head,
                    // read-modify-write in one go) - `sq_addr` is never
                    // populated for one, so there is no address to compare
                    // against. Block conservatively on any older,
                    // not-yet-retired AMO, same as an older store with an
                    // unknown address. Missing this let a younger load
                    // issue straight past a pending AMO and read memory
                    // before the AMO's write landed - found via a Spike
                    // co-simulation diff on rv32ua-p-amoadd_w (the readback
                    // after an AMOADD came back X).
                    if (rob_valid[rob_head + k[ROB_AW-1:0]] && rob_is_amo[rob_head + k[ROB_AW-1:0]])
                        blocked = 1'b1;
                end
            end
            lsq_load_ok = !blocked;
        end
    endfunction

    reg               issL_found;
    reg [ROB_AW-1:0]  issL_idx;
    reg [31:0]        issL_addr_calc;
    // Scratch registers for the per-iteration address computation below,
    // inlined rather than calling `src_value` - see the note above `src_value`
    // itself: a function called from certain contexts does not reliably
    // re-evaluate against a live CDB in this iverilog version, and this scan
    // (a loop, inside `always @(*)`, calling `src_value` and passing its
    // result into a second function, `lsq_load_ok`) is a more elaborate
    // invocation shape than any of the already-inlined call sites - not
    // proven safe by their precedent, so not worth the risk of leaving it as
    // a function call. Found the same way as those: a Spike co-simulation
    // diff, this time on the SoC newlib probe, not a riscv-tests trace - a
    // `lw` computed the right address on paper but read back a value that
    // belonged to neither the address nor any register in the instruction.
    reg [ROB_AW-1:0] issL_scan_idx;
    reg [PW-1:0]     issL_scan_tag;
    reg [31:0]       issL_scan_addr;
    always @(*) begin
        issL_found     = 1'b0;
        issL_idx       = rob_head;
        issL_addr_calc = 32'b0;
        issL_scan_idx  = rob_head;
        issL_scan_tag  = {PW{1'b0}};
        issL_scan_addr = 32'b0;
        for (riL = 0; riL < ROB_DEPTH; riL = riL + 1) begin
            if (!issL_found && (riL[ROB_AW:0] < rob_count)) begin
                issL_scan_idx = rob_head + riL[ROB_AW-1:0];
                if (rob_valid[issL_scan_idx] &&
                    rob_is_load[issL_scan_idx] &&
                    !rob_issued[issL_scan_idx] &&
                    rob_r1_ready[issL_scan_idx]) begin
                    issL_scan_tag  = rob_r1_tag[issL_scan_idx];
                    issL_scan_addr =
                        (issL_scan_tag == {PW{1'b0}})               ? 32'b0 :
                        (cdbS_valid && (cdbS_preg == issL_scan_tag)) ? cdbS_val :
                        (cdbB_valid && (cdbB_preg == issL_scan_tag)) ? cdbB_val :
                        (cdbL_valid && (cdbL_preg == issL_scan_tag)) ? cdbL_val :
                                                                        rob_r1_val[issL_scan_idx];
                    issL_scan_addr = issL_scan_addr + rob_imm[issL_scan_idx];
                    // `issL_scan_addr[31:24] == 8'h80 || == 8'h00`: mirrors
                    // rtl/soc/cpu_wb.v's `dc_cacheable` exactly (RAM at
                    // 0x80xxxxxx, ROM at 0x00xxxxxx are the only addresses
                    // without a read side effect - see that wire's own
                    // comment). A load whose target is neither must not be
                    // allowed to issue speculatively: speculation is free
                    // for ordinary RAM (a squashed load's result is just
                    // discarded) but not for a register with a real read
                    // side effect, and this core has no rollback for a
                    // hardware event that already happened. Found via
                    // sim_uartload: the boot ROM's UART receive loop polls
                    // the UART's status register in a tight loop whose exit
                    // branch mispredicts on the very last byte it needs, and
                    // the load reading the data register on the mispredicted
                    // path had already dequeued the real byte from the
                    // UART's one-deep receive buffer by the time the
                    // misprediction was discovered and the load's own result
                    // discarded - the byte was gone, and the ROM waited
                    // forever for one that had already arrived.
                    //
                    // Excluded here, at discovery, rather than at
                    // `loadL_can_start` below (where `!dmem_mmu_active`
                    // already excludes the *other* case a load must not
                    // start out of order): gating discovery instead of the
                    // go-signal lets a side-effecting load simply be skipped
                    // in favor of a younger, safe one also waiting in the
                    // ROB, the same way an address-hazard-blocked candidate
                    // already is by `lsq_load_ok` below - rather than
                    // "found" and then perpetually refused, which would
                    // serialize the whole out-of-order load port behind it
                    // until it reaches the ROB head. `load_via_head` below
                    // picks it up once it does.
                    if ((issL_scan_addr[31:24] == 8'h80 || issL_scan_addr[31:24] == 8'h00) &&
                        lsq_load_ok(issL_scan_idx, issL_scan_addr)) begin
                        issL_found     = 1'b1;
                        issL_idx       = issL_scan_idx;
                        issL_addr_calc = issL_scan_addr;
                    end
                end
            end
        end
    end

    // An out-of-order-issued load's misalignment was never checked at issue:
    // this covers a load taking the OOO load port directly (Class B2
    // retirement), which never touches `head_mem_misaligned` below at all.
    // A misaligned `lw` silently read across a word boundary using a
    // single, wrongly-aligned bus transaction instead of trapping for the
    // software handler to emulate, as the RV spec requires when hardware
    // does not support it. Found via a Spike co-simulation diff on
    // rv32mi-p-lw-misaligned. Fixed by checking here, at issue, and - if
    // misaligned - never touching the bus at all; instead the entry is
    // marked done-with-a-pending-trap-event (below) and `headS_valid` is
    // widened just enough to let a trap-flagged load reach the existing
    // Class S trap-taking logic once it becomes the head, the same path
    // illegal-instruction/ecall traps already use.
    //
    // A load that instead takes `load_via_head` (MMU translation, or a
    // side-effecting address) *does* reach the ROB head and does hit
    // `head_mem_misaligned` below - `head_is_mem_op`'s third disjunct is
    // exactly that case. See `head_misaligned_cause`'s own comment for the
    // bug that gap left.
    reg issL_misaligned;
    always @(*) begin
        case (rob_mem_size[issL_idx])
            2'b01:   issL_misaligned = issL_addr_calc[0];
            2'b10:   issL_misaligned = |issL_addr_calc[1:0];
            default: issL_misaligned = 1'b0;
        endcase
    end
    wire issL_trap_now = issL_found && issL_misaligned;

    // =======================================================================
    // Execute: Class B (ALU)
    // =======================================================================
    function automatic [31:0] alu_exec;
        input [31:0] a, b;
        input [3:0]  op;
        begin
            case (op)
                4'b0000: alu_exec = a + b;
                4'b1000: alu_exec = a - b;
                4'b0001: alu_exec = a << b[4:0];
                4'b0010: alu_exec = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
                4'b0011: alu_exec = (a < b) ? 32'd1 : 32'd0;
                4'b0100: alu_exec = a ^ b;
                4'b0101: alu_exec = a >> b[4:0];
                4'b1101: alu_exec = $signed(a) >>> b[4:0];
                4'b0110: alu_exec = a | b;
                4'b0111: alu_exec = a & b;
                default: alu_exec = 32'b0;
            endcase
        end
    endfunction

    // Inlined, not src_value_ex_b() - see the note by dispatch_r1_val above.
    wire [31:0] issB_a_reg =
        (rob_r1_tag[issB_idx] == {PW{1'b0}})                        ? 32'b0 :
        (cdbS_valid && (cdbS_preg == rob_r1_tag[issB_idx]))         ? cdbS_val :
        (cdbL_valid && (cdbL_preg == rob_r1_tag[issB_idx]))         ? cdbL_val :
                                                                       rob_r1_val[issB_idx];
    wire [31:0] issB_op1 = (rob_a_sel[issB_idx] == A_PC)   ? rob_pc[issB_idx] :
                           (rob_a_sel[issB_idx] == A_ZERO) ? 32'b0 :
                                                              issB_a_reg;
    wire [31:0] issB_op2 =
        (rob_r2_tag[issB_idx] == {PW{1'b0}})                        ? 32'b0 :
        (cdbS_valid && (cdbS_preg == rob_r2_tag[issB_idx]))         ? cdbS_val :
        (cdbL_valid && (cdbL_preg == rob_r2_tag[issB_idx]))         ? cdbL_val :
                                                                       rob_r2_val[issB_idx];
    wire [31:0] classB_b_operand = rob_is_op[issB_idx] ? issB_op2 : rob_imm[issB_idx];
    wire [31:0] classB_result = alu_exec(issB_op1, classB_b_operand, rob_alu_ctrl[issB_idx]);

    assign cdbB_valid = issB_found;
    assign cdbB_preg  = rob_new_preg[issB_idx];
    assign cdbB_val   = classB_result;

    // =======================================================================
    // Execute: Class S (whatever is at the ROB head)
    // =======================================================================
    // A load normally retires through Class B2, never this head path - the
    // exceptions are a load `issL` already marked with a pending trap event
    // (a misaligned address, see `issL_trap_now` above), which has nothing
    // left to execute and needs exactly this module's existing trap-taking
    // logic (CSR write, redirect, ROB-walk squash), and a not-yet-issued
    // load while data-side paging is active (`load_via_head` below) - the
    // out-of-order load port has no MMU of its own, so `loadL_addr_phys`
    // was always a raw virtual address, correct only because every load
    // this core had ever actually exercised happened to run with paging
    // off for data. The Sv32 data MMU test (`tb_top.v`'s Part 8) issues a
    // load whose virtual address is never a valid physical one, and that
    // load's out-of-order completion read whatever `dmem`'s array happened
    // to hold out of bounds - X in simulation - and broadcast it as a real
    // register value. Found via `rob_count` itself going X a few cycles
    // later (every arithmetic update after that point poisoned the next),
    // traced back through the CDB to a load's own completion.
    wire [1:0] effective_priv_for_data = (current_priv == PRIV_M && csr_mstatus_mprv) ? csr_mstatus_mpp : current_priv;
    wire dmem_mmu_active = satp_mode && (effective_priv_for_data != PRIV_M);
    // The ROB-head-specific counterpart of the out-of-order scan's own
    // address-range exclusion above (same reasoning, same `dc_cacheable`-
    // mirroring test) - needed here too because `issL_idx`/`issL_addr_calc`
    // can point at a *different*, younger ROB entry than `rob_head` (if the
    // head is not yet r1-ready, a later load can be the one currently
    // found), so this re-derives the head's own target address directly
    // from `head_mem_addr_virt` below instead of reusing those. Gated on
    // `rob_r1_ready[rob_head]`: until the base register is known the address
    // cannot be evaluated, and until it is, this load has not been "found"
    // by the scan above either, so nothing is lost by waiting the same way.
    // `head_mem_addr_virt` depends only on `headS_op1`/`rob_imm[rob_head]`,
    // neither of which depends on `load_via_head` or `headS_valid`, so
    // reading it here (defined later in this file) is an ordinary forward
    // wire reference, not a new dependency loop.
    wire load_target_needs_head = rob_is_load[rob_head] && rob_r1_ready[rob_head] &&
        !(head_mem_addr_virt[31:24] == 8'h80 || head_mem_addr_virt[31:24] == 8'h00);
    wire load_via_head = rob_is_load[rob_head] && !rob_is_trap_event[rob_head] &&
                         !rob_issued[rob_head] && (dmem_mmu_active || load_target_needs_head);
    wire headS_valid = !rob_empty && rob_valid[rob_head] && !rob_is_alu_class[rob_head] &&
                       (!rob_is_load[rob_head] || rob_is_trap_event[rob_head] || load_via_head);
    // `load_via_head ||`: a load's r2 tag is never meaningful (loads are
    // I-type; bits [24:20] of the encoding are part of the immediate, not
    // a real source register - see the dispatch-time note on d_rs2), so
    // gating a load's own readiness on it was a real, newly-introduced
    // requirement no load ever had before load_via_head existed (the
    // out-of-order load-issue scan below only ever checked rob_r1_ready).
    // If that garbage r2 tag happened to alias a physical register whose
    // real producer had not dispatched yet, this load - now stuck at the
    // ROB head, since load_via_head only applies once it cannot issue any
    // other way - blocked retirement forever, which blocked the ROB from
    // ever draining, which blocked that producer from ever dispatching:
    // a genuine circular-wait deadlock. Found by booting Linux: the kernel
    // enables paging in its first few hundred instructions and never
    // disables it again, so every load for the rest of a real boot routes
    // through here - a case the synthetic MMU test in tb_top.v, brief and
    // over almost immediately, never exercised at anything like this
    // scale. The boot hung completely, before the kernel's own console
    // init could print a single line; CORE=inorder, untouched, booted
    // this same image to userspace without incident.
    wire headS_ready = headS_valid && rob_r1_ready[rob_head] &&
                       (load_via_head || rob_r2_ready[rob_head]);

    // Inlined, not src_value_ex_s() - see the note by dispatch_r1_val above.
    // This exact function/continuous-assignment interaction is what
    // corrupted a branch's operand with a stale CDB match (found via a
    // Spike co-simulation diff on rv32ui-p-add).
    wire [31:0] headS_op1 =
        (rob_r1_tag[rob_head] == {PW{1'b0}})                  ? 32'b0 :
        (cdbB_valid && (cdbB_preg == rob_r1_tag[rob_head]))   ? cdbB_val :
        (cdbL_valid && (cdbL_preg == rob_r1_tag[rob_head]))   ? cdbL_val :
                                                                 rob_r1_val[rob_head];
    wire [31:0] headS_op2 =
        (rob_r2_tag[rob_head] == {PW{1'b0}})                  ? 32'b0 :
        (cdbB_valid && (cdbB_preg == rob_r2_tag[rob_head]))   ? cdbB_val :
        (cdbL_valid && (cdbL_preg == rob_r2_tag[rob_head]))   ? cdbL_val :
                                                                 rob_r2_val[rob_head];

    wire [31:0] head_mem_addr_virt = headS_op1 + rob_imm[rob_head];
    wire [31:0] head_jalr_target   = (headS_op1 + rob_imm[rob_head]) & ~32'h1;
    wire [31:0] head_jal_target    = rob_pc[rob_head] + rob_imm[rob_head];
    wire [31:0] head_branch_target = rob_pc[rob_head] + rob_imm[rob_head];

    reg head_branch_taken;
    always @(*) begin
        case (rob_funct3[rob_head])
            3'b000:  head_branch_taken = (headS_op1 == headS_op2);
            3'b001:  head_branch_taken = (headS_op1 != headS_op2);
            3'b100:  head_branch_taken = ($signed(headS_op1) <  $signed(headS_op2));
            3'b101:  head_branch_taken = ($signed(headS_op1) >= $signed(headS_op2));
            3'b110:  head_branch_taken = (headS_op1 <  headS_op2);
            3'b111:  head_branch_taken = (headS_op1 >= headS_op2);
            default: head_branch_taken = 1'b0;
        endcase
    end

    wire head_is_control_flow = rob_is_branch[rob_head] || rob_is_jal[rob_head] || rob_is_jalr[rob_head];
    wire head_actual_taken = (rob_is_branch[rob_head] && head_branch_taken) ||
                             rob_is_jal[rob_head] || rob_is_jalr[rob_head];
    wire [31:0] head_actual_target = rob_is_jal[rob_head]  ? head_jal_target  :
                                      rob_is_jalr[rob_head] ? head_jalr_target :
                                                              head_branch_target;
    wire head_fetch_misaligned = head_is_control_flow && head_actual_taken && head_actual_target[1];

    wire head_is_mem_op = headS_valid && (rob_is_store[rob_head] || rob_is_amo[rob_head] || load_via_head);

    reg head_misaligned_sized;
    always @(*) begin
        case (rob_mem_size[rob_head])
            2'b01:   head_misaligned_sized = head_mem_addr_virt[0];
            2'b10:   head_misaligned_sized = |head_mem_addr_virt[1:0];
            default: head_misaligned_sized = 1'b0;
        endcase
    end
    wire head_mem_misaligned = head_is_mem_op && !head_mmu_busy &&
                          (rob_is_amo[rob_head] ? (|head_mem_addr_virt[1:0]) : head_misaligned_sized);
    // Store/AMO address misaligned (cause 6) per the RV privileged spec,
    // *unless* the head instruction is a load - `load_via_head` (MMU
    // translation, or, since the sim_uartload fix, a side-effecting
    // address) is the third disjunct in `head_is_mem_op` above, and a
    // misaligned load is cause 4. Mirrors `cpu_core.v`'s own
    // `misaligned_cause` exactly. A misaligned `lw` under Sv32 - which
    // riscv-tests, running bare-metal, never exercises - hit this: Linux's
    // own `check_unaligned_access_emulated` self-test deliberately issues
    // one, and the wrong cause routed it to the kernel's store-misaligned
    // handler, which then failed to decode a load and panicked.
    wire [31:0] head_misaligned_cause = (rob_is_store[rob_head] || rob_is_amo[rob_head]) ? 32'd6 : 32'd4;

    wire head_need_translate = head_is_mem_op && !head_mem_misaligned &&
                               satp_mode && (effective_priv_for_data != PRIV_M);
    wire [31:0] head_mmu_pa;
    wire head_mmu_resolved, head_mmu_fault;
    wire head_is_lr_ex      = rob_is_amo[rob_head] && (rob_funct5[rob_head] == 5'b00010);
    wire head_mmu_access_is_write = rob_is_store[rob_head] || (rob_is_amo[rob_head] && !head_is_lr_ex);

    mmu MMU (
        .clk(clk), .rst(rst),
        .req(head_need_translate), .va(head_mem_addr_virt), .is_store(head_mmu_access_is_write), .is_fetch(1'b0),
        .is_user(effective_priv_for_data == PRIV_U),
        .sum(csr_mstatus_sum), .mxr(csr_mstatus_mxr),
        .sfence(sfence_en), .satp_ppn(satp_ppn),
        .resolved(head_mmu_resolved), .fault(head_mmu_fault), .pa(head_mmu_pa),
        .pa_va(),
        .busy(head_mmu_busy),
        .ptw_req(ptw_req), .ptw_addr(ptw_addr),
        .ptw_gnt(ptw_gnt), .ptw_rdata(ptw_rdata)
    );

    wire head_mmu_wait_stall = head_need_translate && !head_mmu_resolved;
    wire head_mmu_fault_now  = head_need_translate && head_mmu_resolved && head_mmu_fault;
    wire [31:0] head_mmu_cause = head_mmu_access_is_write ? 32'd15 : 32'd13;
    wire [31:0] head_mem_phys_addr = head_need_translate ? head_mmu_pa : head_mem_addr_virt;

    wire head_is_muldiv_now = headS_valid && rob_is_muldiv[rob_head];
    wire head_is_div_now    = head_is_muldiv_now && rob_funct3[rob_head][2];
    wire div_busy, div_done;
    wire [31:0] div_quotient, div_remainder;
    wire div_start = head_is_div_now && !div_busy;

    muldiv_div DIVU (
        .clk(clk), .rst(rst),
        .start(div_start),
        .dividend(headS_op1), .divisor(headS_op2), .is_signed(!rob_funct3[rob_head][0]),
        .quotient(div_quotient), .remainder(div_remainder),
        .busy(div_busy), .done(div_done)
    );

    wire head_div_stall = head_is_div_now && !div_done;
    wire [31:0] head_div_result = rob_funct3[rob_head][1] ? div_remainder : div_quotient;

    wire signed [63:0] head_mul_ss = $signed({{32{headS_op1[31]}}, headS_op1}) * $signed({{32{headS_op2[31]}}, headS_op2});
    wire        [63:0] head_mul_uu = {32'b0, headS_op1} * {32'b0, headS_op2};
    wire signed [63:0] head_mul_su = $signed({{32{headS_op1[31]}}, headS_op1}) * $signed({32'b0, headS_op2});
    reg [31:0] head_mul_result;
    always @(*) begin
        case (rob_funct3[rob_head][1:0])
            2'b00: head_mul_result = head_mul_ss[31:0];
            2'b01: head_mul_result = head_mul_ss[63:32];
            2'b10: head_mul_result = head_mul_su[63:32];
            2'b11: head_mul_result = head_mul_uu[63:32];
        endcase
    end

    wire [31:0] csr_rdata, csr_rdata_rmw;
    wire [31:0] csr_mtvec, csr_stvec, csr_mepc, csr_sepc;
    wire        csr_trap_to_s;
    wire [31:0] csr_mie, csr_mip, csr_mideleg;
    wire        csr_mstatus_mie, csr_sstatus_sie;
    wire [31:0] csr_op_operand = rob_csr_imm_form[rob_head] ? rob_zimm[rob_head] : headS_op1;
    reg  [31:0] csr_new_value;
    always @(*) begin
        case (rob_funct3[rob_head][1:0])
            2'b01:   csr_new_value = csr_op_operand;
            2'b10:   csr_new_value = csr_rdata_rmw | csr_op_operand;
            2'b11:   csr_new_value = csr_rdata_rmw & ~csr_op_operand;
            default: csr_new_value = csr_rdata;
        endcase
    end

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
    wire any_interrupt_pending = interrupt_pending_m || interrupt_pending_s;

    wire [31:0] interrupt_cause =
        interrupt_pending_m ? (m_mei ? 32'h8000_000B : m_msi ? 32'h8000_0003 : m_mti ? 32'h8000_0007 :
                                m_sei ? 32'h8000_0009 : m_ssi ? 32'h8000_0001 : 32'h8000_0005) :
                               (s_sei ? 32'h8000_0009 : s_ssi ? 32'h8000_0001 : 32'h8000_0005);

    wire head_busy_now = head_div_stall || head_mmu_wait_stall || head_dbus_stall;
    assign interrupt_taken = headS_valid && rob_r1_ready[rob_head] && rob_r2_ready[rob_head] &&
                             any_interrupt_pending && !head_busy_now;

    wire head_synchronous_trap = (headS_valid && rob_is_trap_event[rob_head]) || head_mmu_fault_now ||
                                 head_mem_misaligned || head_fetch_misaligned;
    assign head_ex_commit = !head_dbus_stall && !head_fence_drain_stall;
    wire head_take_trap = headS_valid && (interrupt_taken || head_synchronous_trap) && head_ex_commit;

    wire [31:0] head_cause_for_csr = interrupt_taken ? interrupt_cause :
                                 (rob_is_trap_event[rob_head] ? rob_trap_cause[rob_head] :
                                 (head_mem_misaligned  ? head_misaligned_cause :
                                 (head_mmu_fault_now   ? head_mmu_cause :
                                 (head_fetch_misaligned ? 32'd0 : rob_trap_cause[rob_head]))));
    wire [31:0] head_val_for_csr   = interrupt_taken ? 32'b0 :
                                 (rob_is_trap_event[rob_head] ? rob_trap_val[rob_head] :
                                 (head_mem_misaligned  ? head_mem_addr_virt :
                                 (head_mmu_fault_now   ? head_mem_addr_virt :
                                 (head_fetch_misaligned ? head_actual_target : rob_trap_val[rob_head]))));

    wire head_mret_en = headS_valid && rob_is_mret[rob_head] && !interrupt_taken && head_ex_commit;
    wire head_sret_en = headS_valid && rob_is_sret[rob_head] && !interrupt_taken && head_ex_commit;
    assign trap = head_take_trap;

    wire fence_i_head = headS_valid && rob_is_fence_i[rob_head];
    wire sfence_head  = headS_valid && rob_is_sfence_vma[rob_head];
    assign sfence_en = sfence_head && headS_ready && head_ex_commit && !interrupt_taken;
    // `fence_i` is an output port cpu_wb.v uses to invalidate its icache
    // (`if (fence_i) ic_valid <= 0;`) - it was declared in the port list for
    // interface compatibility but never actually driven anywhere in this
    // rewrite, so the icache never invalidated on a fence.i and every
    // self-modifying-code test kept serving stale cached instruction bytes.
    // Found via a Spike co-simulation diff on rv32ui-p-fence_i: a patched
    // instruction read back as its pre-patch encoding.
    assign fence_i = fence_i_head && headS_ready && head_ex_commit && !interrupt_taken;

    csr_file CSR (
        .clk(clk), .rst(rst),
        .addr(rob_csr_addr[rob_head]), .we(headS_valid && rob_is_csr[rob_head] && rob_csr_we[rob_head] && !interrupt_taken && head_ex_commit),
        .wdata(csr_new_value), .rdata(csr_rdata), .rdata_rmw(csr_rdata_rmw),
        .trap_en(head_take_trap), .trap_pc(rob_pc[rob_head]), .trap_cause(head_cause_for_csr), .trap_val(head_val_for_csr),
        .mtvec_out(csr_mtvec), .stvec_out(csr_stvec), .trap_to_s_out(csr_trap_to_s),
        .mret_en(head_mret_en), .mepc_out(csr_mepc),
        .sret_en(head_sret_en), .sepc_out(csr_sepc),
        .mtip(mtip), .msip_in(msip_in), .meip_in(meip), .seip_in(seip),
        .mie_out(csr_mie), .mip_out(csr_mip), .mideleg_out(csr_mideleg),
        .mstatus_mie_out(csr_mstatus_mie), .sstatus_sie_out(csr_sstatus_sie),
        .current_priv_out(current_priv),
        .mtime_in(mtime_in), .instret_inc({1'b0, retire_fire}),
        .mcounteren_out(csr_mcounteren), .scounteren_out(csr_scounteren),
        .satp_mode_out(satp_mode), .satp_ppn_out(satp_ppn),
        .mstatus_mprv_out(csr_mstatus_mprv), .mstatus_mpp_out(csr_mstatus_mpp),
        .mstatus_sum_out(csr_mstatus_sum), .mstatus_mxr_out(csr_mstatus_mxr),
        .mstatus_tvm_out(csr_mstatus_tvm), .mstatus_tw_out(csr_mstatus_tw),
        .mstatus_tsr_out(csr_mstatus_tsr)
    );

    wire [31:0] head_tvec         = csr_trap_to_s ? csr_stvec : csr_mtvec;
    wire        head_tvec_vectored = head_tvec[0] && head_cause_for_csr[31];
    wire [31:0] head_tvec_offset  = {24'b0, head_cause_for_csr[5:0], 2'b00};
    wire [31:0] head_trap_redirect_target =
        {head_tvec[31:2], 2'b00} + (head_tvec_vectored ? head_tvec_offset : 32'b0);
    wire [31:0] head_mispredict_recovery_target = head_actual_taken ? head_actual_target : (rob_pc[rob_head] + 32'd4);
    wire head_mispredict = headS_valid && head_is_control_flow &&
                      ((rob_pred_taken[rob_head] != head_actual_taken) ||
                       (head_actual_taken && (rob_pred_target[rob_head] != head_actual_target)));

    wire head_redirect_valid = headS_ready && head_ex_commit &&
                          (interrupt_taken || head_synchronous_trap || head_mispredict ||
                           head_mret_en || head_sret_en || fence_i_head || sfence_head);
    reg [31:0] head_redirect_target;
    always @(*) begin
        if (interrupt_taken)            head_redirect_target = head_trap_redirect_target;
        else if (head_synchronous_trap) head_redirect_target = head_trap_redirect_target;
        else if (head_mispredict)       head_redirect_target = head_mispredict_recovery_target;
        else if (head_mret_en)          head_redirect_target = csr_mepc;
        else if (head_sret_en)          head_redirect_target = csr_sepc;
        else                            head_redirect_target = rob_pc[rob_head] + 32'd4; // fence_i/sfence
    end

    assign btb_train_en     = headS_ready && head_is_control_flow && head_ex_commit && !head_fetch_misaligned;
    assign btb_train_pc     = rob_pc[rob_head];
    assign btb_train_taken  = head_actual_taken;
    assign btb_train_target = head_actual_target;

    assign recovery_fire = head_redirect_valid;
    assign recovery_keep_culprit = head_mispredict && !head_take_trap && !interrupt_taken;

    // =======================================================================
    // Memory port arbitration
    // =======================================================================
    reg        sb_valid;
    reg [31:0] sb_addr, sb_wdata;
    reg [1:0]  sb_size;

    // Port arbitration priority, strictly: an in-flight load already on the
    // bus > the store buffer already draining > the ROB head's own store/
    // AMO > a new load starting. The first two are already-committed
    // Wishbone transactions - once a request is asserted it has to stay
    // asserted, address and all, until the bus acknowledges it, so nothing
    // below may reassign the port out from under one. This was a real bug:
    // `port_owned_by_store` only checked `sb_valid`, not `loadL_active`, so
    // a store or AMO reaching the ROB head could silently steal the port
    // from an in-flight load. `dmem_rvalid` would then arrive for the
    // store/AMO's transaction while `loadL_active` was still set, and
    // `loadL_finish = loadL_active && dmem_rvalid` would broadcast the
    // store/AMO's read data as the load's result - a real value into a
    // real register, wrong. Found via a Spike co-simulation diff on
    // rv32ui-p-add: `beqz x5` read 0x303 for x5 instead of 0.
    wire port_taken_by_load  = loadL_active;
    wire port_taken_by_store = !port_taken_by_load && sb_valid;

    // `&& !head_mmu_wait_stall`: a store whose address needs translation
    // must not touch the real bus until the walk resolves. Before this,
    // `head_mem_phys_addr` fell through to `head_mmu_pa`, which mmu.v only
    // guarantees valid `when resolved` (see its own port comment) - on a
    // TLB miss the walk is still mid-flight, `pte1_r` hasn't even been
    // fetched yet, and `head_mmu_pa` reads as a garbage address derived
    // from an all-zero PTE. Asserting `dmem_we` with that address anyway
    // put a bogus, permanently-held write on the CPU's own data master
    // (m1), and since wb_interconnect.v gives m1 strict priority over the
    // page-table walker (m2, rtl/soc/wb_ptw.v) - by design, so an AMO's
    // read-modify-write can't be preempted mid-gap - that bogus write
    // starved the walker of the bus forever, so the walk that would have
    // resolved `head_mmu_pa` and cleared the condition never got to run: a
    // self-sustaining deadlock. Found by booting Linux: the tiny synthetic
    // Sv32 test in tb_top.v never has enough concurrent bus traffic to
    // turn a TLB miss into this race, but a real boot's page-table walks
    // do. CORE=inorder never asserts its own equivalent write until after
    // its (single-instruction-at-a-time) translation has already
    // completed, so it never had this bug to begin with.
    // `&& !head_mmu_fault_now`: `head_mmu_wait_stall` clears the instant the
    // walk resolves, fault or not, so a store whose translation resolves to
    // a page fault reached this port on the very same cycle the fault is
    // detected - `head_mem_phys_addr` was `head_mmu_pa`, now a *real*
    // address (the walk had already fetched the actual PTE), so unlike the
    // mid-walk garbage-address case above, this write landed exactly on the
    // page under test. Found via `make verify_ooo`: sim_mmusdram's read-only
    // page checks ("store to read-only faults" correctly ok, "read-only
    // page unchanged" FAILED) after the fix above - the fault-taking path
    // and this port-ownership path both fire off `head_mmu_resolved`, and
    // nothing between them stopped the second from writing to a page the
    // first was in the middle of rejecting.
    // `&& !head_mem_misaligned`: a third instance of the same shape as the
    // two above, missed in the same pass - a misaligned store is supposed
    // to take a trap *instead of* writing (the load path already gets this
    // right: `loadL_can_start` below excludes `issL_misaligned`), but this
    // port-ownership condition had no misalignment check of its own, so it
    // fired anyway on the very same cycle `head_take_trap` did, writing the
    // (misaligned) address before the trap it also took ever reached
    // software. Found via CI on riscv-tests' own rv32mi-p-ma_addr, which
    // this session's local `make verify_ooo` runs had already been hitting
    // and mischaracterizing as the project's pre-existing, unrelated
    // ma_addr divergence rather than checking it against a real baseline -
    // root-caused precisely with a targeted trace: `sh zero,1(s0)` at
    // 0x80002001 correctly computed its address and correctly took a
    // misaligned-store trap on the first possible cycle, but the byte at
    // that address read back as the just-written zero instead of its
    // original nonzero value, because `head_plain_store_now` had let the
    // write reach the bus in the same cycle.
    wire head_plain_store_now = headS_valid && rob_is_store[rob_head] &&
                                rob_issued[rob_head] && headS_ready &&
                                !head_mmu_wait_stall && !head_mmu_fault_now &&
                                !head_mem_misaligned;
    wire head_store_absorbed  = head_plain_store_now && !port_taken_by_load && !sb_valid && dbus_wait;

    reg        amo_wr_phase;
    reg [31:0] amo_rdata_q;
    reg        reservation_valid;
    reg [31:0] reservation_addr;
    wire sc_match   = reservation_valid && (reservation_addr == head_mem_phys_addr);
    wire head_is_sc_ex = rob_is_amo[rob_head] && (rob_funct5[rob_head] == 5'b00011);
    wire sc_success = head_is_sc_ex && sc_match;
    // An AMO may not even start using the bus while a load or the store
    // buffer already owns it - same reasoning as `head_store_absorbed`.
    wire amo_active = headS_valid && rob_is_amo[rob_head] && headS_ready &&
                      !head_mmu_wait_stall && !head_mmu_fault_now &&
                      !head_mem_misaligned &&
                      !port_taken_by_load && !port_taken_by_store;
    reg [31:0] amo_new_value;
    wire amo_writes = (rob_is_amo[rob_head] && !head_is_lr_ex && !head_is_sc_ex) || sc_success;
    wire amo_done   = amo_active && (amo_wr_phase ? !dbus_wait
                                                  : (dmem_rvalid && !amo_writes));
    wire amo_stall  = headS_valid && rob_is_amo[rob_head] && headS_ready && !amo_done;

    reg        loadL_active;
    reg [ROB_AW-1:0] loadL_rob_idx;
    reg [31:0] loadL_addr_phys;
    reg [2:0]  loadL_funct3;
    // The culprit a recovery keeps (if any) is always the ROB head, and a
    // head is never a load - so any load still in flight when recovery
    // fires is unconditionally on the squashed side. Its ROB slot gets
    // reused by a new instruction well before dmem_rvalid finally arrives
    // for the old (abandoned) bus transaction; without this bit, that late
    // arrival wrote rob_done/rob_result/preg_busy and broadcast on cdbL
    // using rob_new_preg[loadL_rob_idx] read *after* the slot was reused,
    // corrupting whatever unrelated instruction now lived there.
    reg        loadL_squashed;
    // A load can complete on the very same cycle it starts (dmem_rvalid
    // already high while loadL_can_start fires - impossible on the SoC's
    // Wishbone bus, where an ack is always registered, but the flat
    // testbench's dmem_rvalid is tied permanently high). loadL_active
    // still gets registered for that case exactly as any other load - an
    // earlier attempt at skipping it made `loadL_finish`/`cdbL_valid`
    // combinationally depend on `loadL_can_start` for the same-cycle case,
    // and `issL_addr_calc`'s own inlined CDB-bypass check reads
    // `cdbL_valid` from within the very same `issL_found` block that
    // computes `loadL_can_start`'s `issL_found` input - a direct
    // combinational cycle (Verilator's UNOPTFLAT check caught it;
    // iverilog silently picked some evaluation order and the SoC gate's
    // trapcheck cases failed). Latching the early result instead avoids
    // that entirely: the extra cycle after issue still happens, but it
    // completes off this register, not off a fresh read, so the "extra
    // cycle" no longer touches the bus at all (see the dmem_re mux).
    reg        loadL_early_done;
    reg [31:0] loadL_early_rdata;

    wire port_owned_by_store = !port_taken_by_load &&
                               (sb_valid || head_plain_store_now || amo_active);
    // `!dmem_mmu_active`: while data-side paging is on, every load defers
    // to `load_via_head` instead (see the note above `headS_valid`) rather
    // than starting out-of-order with an untranslated virtual address.
    //
    // `!head_load_owns_port`: the missing half of the symmetry
    // `head_load_owns_port` itself already keeps (its own definition ends
    // `!port_taken_by_load && !sb_valid` - it already yields to loadL and
    // to the store buffer). Without this, a ROB-head load that must go via
    // `load_via_head` - any MMIO/peripheral address, per
    // `load_target_needs_head`, not just while paging - can finish with
    // `dmem_rvalid` high on the exact cycle a *different*, younger loadL
    // load is starting. `loadL_early_done <= dmem_rvalid` (below) has no way
    // to tell that the response and its own address never met: the address
    // mux gives head_load_owns_port strict priority over `loadL_can_start`
    // (see `dmem_addr` below), so loadL's own request was never actually
    // driven that cycle, but its early-done latch fires anyway and claims
    // whatever `dmem_rdata` shows - the head load's data, not its own.
    // Found by instruction-level tracing on `sim_uartirq CORE=ooo`: the
    // handler's `tx_irq_count++` read back 1 on its very first execution
    // (nothing had ever written anything but 0), one cycle after the PLIC
    // claim read completed with `rdata=1` (a real, correct claim ID for
    // `UART_SRC`) - the very next load stole it. The claimed source then
    // never got its matching `complete` write (the instruction that was
    // meant to issue it ran off a since-corrupted register state instead),
    // leaving it `in_service` forever and the interrupt permanently unable
    // to re-arm - `docs/roadmap.md`'s Known Defects entry for
    // `sim_uartirq CORE=ooo`.
    wire loadL_can_start = issL_found && !issL_misaligned && !port_owned_by_store &&
                           !loadL_active && !dmem_mmu_active && !head_load_owns_port;
    // `loadL_active && !loadL_early_done`: the extra cycle after an
    // early-done load (see the note above loadL_early_done) must not
    // re-request the bus - the data is already latched, and re-asserting
    // dmem_re against a side-effecting register (the PLIC's claim/
    // complete register) would silently consume a second event.
    // `port_taken_by_load` (loadL_active, unconditionally) still holds the
    // port reserved against other users for that same cycle; dmem_addr
    // stays driven to loadL_addr_phys too, just with neither dmem_re nor
    // dmem_we asserted, which is inert.
    wire port_owned_by_load  = (loadL_active && !loadL_early_done) ||
                               (!port_owned_by_store && loadL_can_start);

    // `sq_wdata` is populated only by `issST`, which only ever selects
    // `rob_is_store` entries - an AMO's ROB entry is `rob_is_amo`, not
    // `rob_is_store`, so `sq_wdata[rob_head]` was never written for one and
    // held whatever garbage/X was last in that ROB slot. Use `headS_op2`
    // instead: AMO only executes at the ROB head (`amo_active` requires
    // `headS_ready`, which already requires `rob_r2_ready[rob_head]`), so
    // it is always resolved and CDB-bypassed correctly by the time this is
    // read. Found via a Spike co-simulation diff on rv32ua-p-amoadd_w: the
    // memory readback after the AMOADD came back X.
    always @(*) begin
        case (rob_funct5[rob_head])
            5'b00000: amo_new_value = amo_rdata_q + headS_op2;
            5'b00001: amo_new_value = headS_op2;
            5'b00100: amo_new_value = amo_rdata_q ^ headS_op2;
            5'b01100: amo_new_value = amo_rdata_q & headS_op2;
            5'b01000: amo_new_value = amo_rdata_q | headS_op2;
            5'b10000: amo_new_value = ($signed(amo_rdata_q) < $signed(headS_op2)) ? amo_rdata_q : headS_op2;
            5'b10100: amo_new_value = ($signed(amo_rdata_q) > $signed(headS_op2)) ? amo_rdata_q : headS_op2;
            5'b11000: amo_new_value = (amo_rdata_q < headS_op2) ? amo_rdata_q : headS_op2;
            5'b11100: amo_new_value = (amo_rdata_q > headS_op2) ? amo_rdata_q : headS_op2;
            default:  amo_new_value = amo_rdata_q;
        endcase
    end
    wire dmem_we_amo = amo_active && amo_wr_phase;
    // The store/AMO arms below are each already false whenever
    // `port_taken_by_load` or `port_taken_by_store` holds (`amo_active`
    // bakes that in directly; `head_plain_store_now` doesn't, so every mux
    // arm that uses it is qualified explicitly here rather than relying on
    // priority order alone - `dmem_we` in particular has no "load" arm of
    // its own to fall through from, so an unqualified `head_plain_store_now`
    // would assert a write against whatever address the load put on the
    // bus).
    wire head_store_owns_port = head_plain_store_now && !port_taken_by_load && !sb_valid;
    // The head-load counterpart of `head_store_owns_port`: a not-yet-issued
    // load, held at the head because `dmem_mmu_active` routed it there
    // instead of `loadL_can_start`, actually using the bus once nothing
    // higher-priority (an in-flight out-of-order load, a draining store
    // buffer write) already owns it. `load_via_head` alone would also be
    // true before that - this only asserts once it can actually go.
    wire head_load_owns_port = load_via_head && headS_ready &&
                               !head_mmu_wait_stall && !head_mmu_fault_now &&
                               !head_mem_misaligned &&
                               !port_taken_by_load && !sb_valid;

    assign dmem_addr  = port_taken_by_load ? loadL_addr_phys :
                        sb_valid ? sb_addr :
                        head_store_owns_port ? head_mem_phys_addr :
                        head_load_owns_port ? head_mem_phys_addr :
                        amo_active ? head_mem_phys_addr :
                        loadL_can_start ? issL_addr_calc : 32'b0;
    assign dmem_wdata = sb_valid ? sb_wdata :
                        amo_active ? (amo_wr_phase ? (head_is_sc_ex ? headS_op2 : amo_new_value) : 32'b0) :
                        head_store_owns_port ? sq_wdata[rob_head] : 32'b0;
    assign dmem_we    = sb_valid ? 1'b1 :
                        head_store_owns_port ? 1'b1 :
                        dmem_we_amo;
    assign dmem_re    = (port_owned_by_load || head_load_owns_port) ? 1'b1 : 1'b0;
    // AMO had no arm of its own here and fell through to the 2'b0 (byte)
    // default for both its read and write phases - every RV32A AMO is
    // word-sized (there is no `.b`/`.h` AMO), so this shrank every AMO's
    // bus transaction to a single byte lane, leaving the other 3 bytes of
    // the word unwritten/unread (X in simulation, since this was often the
    // first write to that word). Found alongside the `sq_wdata`/`headS_op2`
    // fix above via the same rv32ua-p-amoadd_w diff.
    assign dmem_size  = sb_valid ? sb_size :
                        port_owned_by_load ? (loadL_active ? loadL_funct3[1:0] : rob_funct3[issL_idx][1:0]) :
                        head_store_owns_port ? sq_size[rob_head] :
                        head_load_owns_port ? rob_mem_size[rob_head] :
                        amo_active ? 2'b10 : 2'b0;
    // While the store buffer still owns the port, `dmem_addr`/`dmem_we`
    // above reflect its drain, not this AMO - asserting `dmem_is_amo` at
    // the same time would tell the bus adapter to treat a plain store's
    // single-phase write as part of an RMW sequence.
    assign dmem_is_amo = amo_active && !sb_valid;

    // The head's store/AMO must wait, not just for the bus to acknowledge,
    // but for the bus to be its own to ask in the first place - a load or
    // the store buffer already owning the port blocks it exactly like an
    // unacknowledged request would.
    wire head_dbus_wait_stall = head_store_owns_port && dbus_wait && !head_store_absorbed;
    wire head_store_port_blocked = head_plain_store_now && (port_taken_by_load || sb_valid);
    wire head_amo_port_blocked   = headS_valid && rob_is_amo[rob_head] && headS_ready &&
                                   (port_taken_by_load || port_taken_by_store) && !amo_active;
    // A store computes its address/data out of order via `issST`, which
    // might not have reached it yet by the time it becomes the ROB head -
    // `issST` is a single port, shared with every other not-yet-issued
    // store in the window, so there is no guarantee it is done before this
    // entry is oldest. Every other stall term above is keyed off
    // `head_plain_store_now`/`head_store_owns_port`, which themselves
    // require `rob_issued[rob_head]` - so a store that simply has not
    // issued yet triggers none of them and `head_ex_commit` was true
    // regardless, retiring the instruction without ever asserting
    // `dmem_we`. The write silently never happened. Found via a Spike
    // co-simulation diff on rv32ui-p-sb: a byte-store's value read back as
    // whatever had been there before.
    wire head_store_not_issued_stall = headS_valid && rob_is_store[rob_head] && !rob_issued[rob_head];
    // Mirrors head_dbus_wait_stall/head_store_port_blocked for a head-load:
    // wait for the read to actually complete once it owns the port, or for
    // the port to free up if something else (an in-flight out-of-order
    // load, a draining store buffer write) still has it.
    wire head_load_dbus_wait_stall = head_load_owns_port && !dmem_rvalid;
    wire head_load_port_blocked    = load_via_head && headS_ready &&
                                     (port_taken_by_load || sb_valid);
    assign head_dbus_stall = head_dbus_wait_stall || amo_stall ||
                             head_store_port_blocked || head_amo_port_blocked ||
                             head_store_not_issued_stall ||
                             head_load_dbus_wait_stall || head_load_port_blocked;
    assign head_fence_drain_stall = headS_valid && sb_valid &&
                                  (rob_is_fence_i[rob_head] || rob_is_sfence_vma[rob_head]);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sb_valid <= 1'b0; sb_addr <= 32'b0; sb_wdata <= 32'b0; sb_size <= 2'b0;
        end else if (sb_valid) begin
            if (!dbus_wait) sb_valid <= 1'b0;
        end else if (head_store_absorbed) begin
            sb_valid <= 1'b1;
            sb_addr  <= head_mem_phys_addr;
            sb_wdata <= sq_wdata[rob_head];
            sb_size  <= sq_size[rob_head];
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst)                          amo_wr_phase <= 1'b0;
        else if (!amo_active || amo_done) amo_wr_phase <= 1'b0;
        else if (!amo_wr_phase && dmem_rvalid && amo_writes)
                                          amo_wr_phase <= 1'b1;
    end
    always @(posedge clk) begin
        if (amo_active && !amo_wr_phase && dmem_rvalid)
            amo_rdata_q <= dmem_rdata;
    end

    wire any_successful_write = (head_plain_store_now && !sb_valid && !dbus_wait) || dmem_we_amo;
    wire any_sc_this_cycle    = amo_active && head_is_sc_ex;
    // A plain store retires from the ROB as soon as it hands off to the
    // store buffer (`sb_valid`, see `head_store_absorbed`), not once its
    // write actually lands on the bus - `rob_head` has already moved on to
    // the next instruction by the time `sb_valid`'s own transaction
    // completes. `any_successful_write`'s `head_plain_store_now` term
    // therefore never sees that completion (it requires `rob_is_store` at
    // the *current* head, which by then is someone else), so a plain store
    // never broke a live LR/SC reservation at all - checked ahead of the
    // `head_dbus_stall` hold below because the instruction stalled at the
    // head *is* what is waiting on this same `sb_valid` to clear (SC/AMO
    // cannot start while the store buffer still owns the port), so this
    // can never coincide with a same-cycle LR needing to set the
    // reservation instead. Found via rv32ua-p-lrsc-style traffic on the SoC
    // acceptance test ("LR/SC broken by store"): an intervening plain
    // store never invalidated the reservation, so the following SC
    // succeeded when it should have failed.
    wire sb_write_completing = sb_valid && !dbus_wait;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            reservation_valid <= 1'b0; reservation_addr <= 32'b0;
        end else if (sb_write_completing) begin
            reservation_valid <= 1'b0;
        end else if (head_dbus_stall) begin
            // hold
        end else if (head_take_trap) begin
            reservation_valid <= 1'b0;
        end else if (amo_active && head_is_lr_ex) begin
            reservation_valid <= 1'b1;
            reservation_addr  <= head_mem_phys_addr;
        end else if (any_sc_this_cycle || any_successful_write) begin
            reservation_valid <= 1'b0;
        end
    end

    // The PLIC's claim/complete register has a read side effect (each read
    // claims the next pending source), which is what made the extra cycle
    // below a real bug rather than a harmless duplicate read: a load
    // issued into `loadL_active` that also happened to see `dmem_rvalid`
    // already high on its own issuing cycle (only possible with this flat
    // testbench's permanently-high `dmem_rvalid`) still asserted
    // `dmem_re`/`dmem_addr` again the following cycle purely because
    // `loadL_active` was set - a second, spurious claim that silently
    // consumed the *next* pending interrupt source too. Found via the SoC
    // acceptance program's PLIC test: the first claim came back holding
    // the second interrupt's source number, and the second interrupt this
    // consumed never arrived - one trap short of the expected count,
    // traced from a `beq` whose own operand was correct (the read
    // genuinely returned the wrong claim value, not a stale register
    // elsewhere). `loadL_early_done`/`loadL_early_rdata` capture that
    // same-cycle result so the following cycle can complete off it
    // without re-asserting the port at all (see the dmem_re mux below).
    wire loadL_finish = loadL_active && (dmem_rvalid || loadL_early_done) && !loadL_squashed;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            loadL_active     <= 1'b0;
            loadL_squashed   <= 1'b0;
            loadL_early_done <= 1'b0;
        end else if (loadL_active) begin
            if (dmem_rvalid || loadL_early_done) begin
                loadL_active     <= 1'b0;
                loadL_squashed   <= 1'b0;
                loadL_early_done <= 1'b0;
            end else if (recovery_fire) begin
                loadL_squashed <= 1'b1;
            end
        end else if (loadL_can_start) begin
            loadL_active      <= 1'b1;
            loadL_squashed    <= recovery_fire;
            loadL_rob_idx     <= issL_idx;
            loadL_addr_phys   <= issL_addr_calc;
            loadL_funct3      <= rob_funct3[issL_idx];
            loadL_early_done  <= dmem_rvalid;
            loadL_early_rdata <= dmem_rdata;
        end
    end

    // On the completing cycle itself, `dmem_rdata` is live and correct.
    // On the extra cycle after an early-done load (see loadL_early_done
    // above), the port is no longer being driven for this load at all
    // (the dmem_re mux below excludes it), so `dmem_rdata` could show
    // anything - use the value latched at issue time instead.
    wire [31:0] loadL_effective_rdata = loadL_early_done ? loadL_early_rdata : dmem_rdata;
    reg [31:0] loadL_rdata_sized;
    always @(*) begin
        case (loadL_funct3)
            3'b000:  loadL_rdata_sized = {{24{loadL_effective_rdata[7]}},  loadL_effective_rdata[7:0]};
            3'b001:  loadL_rdata_sized = {{16{loadL_effective_rdata[15]}}, loadL_effective_rdata[15:0]};
            3'b010:  loadL_rdata_sized = loadL_effective_rdata;
            3'b100:  loadL_rdata_sized = {24'b0, loadL_effective_rdata[7:0]};
            3'b101:  loadL_rdata_sized = {16'b0, loadL_effective_rdata[15:0]};
            default: loadL_rdata_sized = loadL_effective_rdata;
        endcase
    end

    assign cdbL_valid = loadL_finish;
    assign cdbL_preg  = rob_new_preg[loadL_rob_idx];
    assign cdbL_val   = loadL_rdata_sized;


    reg [31:0] head_amo_lr_result;
    always @(*) begin
        if (head_is_lr_ex)      head_amo_lr_result = dmem_rdata;
        else if (head_is_sc_ex) head_amo_lr_result = sc_success ? 32'd0 : 32'd1;
        else                    head_amo_lr_result = amo_rdata_q;
    end

    // Sign/zero-extension for a load completing via `head_load_owns_port` -
    // the same case `loadL_rdata_sized` handles for the ordinary
    // out-of-order load port, keyed off this instruction's own funct3
    // instead of the latched `loadL_funct3`.
    reg [31:0] head_load_rdata_sized;
    always @(*) begin
        case (rob_funct3[rob_head])
            3'b000:  head_load_rdata_sized = {{24{dmem_rdata[7]}},  dmem_rdata[7:0]};
            3'b001:  head_load_rdata_sized = {{16{dmem_rdata[15]}}, dmem_rdata[15:0]};
            3'b010:  head_load_rdata_sized = dmem_rdata;
            3'b100:  head_load_rdata_sized = {24'b0, dmem_rdata[7:0]};
            3'b101:  head_load_rdata_sized = {16'b0, dmem_rdata[15:0]};
            default: head_load_rdata_sized = dmem_rdata;
        endcase
    end

    reg [31:0] headS_result;
    always @(*) begin
        case (rob_wb_sel[rob_head])
            WB_PC4:    headS_result = rob_pc[rob_head] + 32'd4;
            WB_CSR:    headS_result = csr_rdata;
            WB_MULDIV: headS_result = rob_funct3[rob_head][2] ? head_div_result : head_mul_result;
            WB_MEM:    headS_result = rob_is_amo[rob_head] ? head_amo_lr_result : head_load_rdata_sized;
            default:   headS_result = 32'b0;
        endcase
    end

    // Class S "issue" (start of execution) happens the instant it is ready
    // and the head, for anything that is not a store/AMO needing the bus
    // (those issue via the same mechanism but their completion is gated on
    // the bus below). `head_exec_done` says the head has finished whatever
    // multi-cycle thing it was doing.
    wire head_exec_done = headS_ready && !head_div_stall && !head_mmu_wait_stall && !head_dbus_stall;

    assign cdbS_valid = head_exec_done && head_ex_commit && !rob_done[rob_head];
    assign cdbS_preg  = rob_new_preg[rob_head];
    assign cdbS_val   = headS_result;

    // =======================================================================
    // Retire
    // =======================================================================
    // A load carrying a pending trap event (see `issL_trap_now`) is
    // excluded here even though `rob_done` is already set for it - it must
    // retire through `head_class_s_can_retire`'s trap-taking path instead
    // of writing a (nonexistent) result to its destination register.
    wire head_class_b_or_load_can_retire =
        (rob_valid[rob_head] && rob_is_alu_class[rob_head] && rob_done[rob_head]) ||
        (rob_valid[rob_head] && rob_is_load[rob_head] && rob_done[rob_head] && !rob_is_trap_event[rob_head]);
    wire head_class_s_can_retire = headS_valid && head_exec_done && head_ex_commit;

    assign retire_fire = !rob_empty &&
                         (head_class_b_or_load_can_retire ||
                          (head_class_s_can_retire && !head_take_trap));

    // =======================================================================
    // Retire trace (simulation only) - sim/tracer.v and tests/cosim.py hook
    // these by hierarchical reference (see sim/tb_isa.v), the same contract
    // stage 1c and cpu_core.v both use. Dispatch/retire are one instruction
    // wide here (see the header), so slot 1 is permanently tied off - the
    // in-order core already does exactly this for the same reason.
    //
    // A trapping instruction is excluded automatically: it never sets
    // `retire_fire` (`head_class_s_can_retire && !head_take_trap`) and it
    // retires nowhere else either - `recovery_fire`'s branch invalidates it
    // without tracing it, matching "a trapping instruction does not retire"
    // (docs/debug.md's tracer section, and Spike's own --log-commits, which
    // draws the same line).
    //
    // A mispredicted branch is different: it *did* retire, correctly, as
    // itself - only what is younger is wrong - so it needs to be traced
    // even though it takes the `recovery_fire` branch of the sequential
    // block rather than the ordinary `retire_fire` one
    // (`recovery_keep_culprit` is exactly this case).
    wire retire_trace_fire = retire_fire || (recovery_fire && recovery_keep_culprit);
    wire [31:0] retire_trace_rd_data =
        (rob_is_alu_class[rob_head] || rob_is_load[rob_head]) ? rob_result[rob_head] : headS_result;

    wire        trace_valid   = retire_trace_fire;
    wire [31:0] trace_pc      = rob_pc[rob_head];
    wire [31:0] trace_instr   = rob_instr[rob_head];
    wire        trace_rd_we   = rob_has_rd[rob_head];
    wire [4:0]  trace_rd      = rob_arch_rd[rob_head];
    wire [31:0] trace_rd_data = retire_trace_rd_data;

    wire        trace1_valid    = 1'b0;
    wire [31:0] trace1_pc       = 32'b0;
    wire [31:0] trace1_instr    = 32'b0;
    wire        trace1_rd_we    = 1'b0;
    wire [4:0]  trace1_rd       = 5'b0;
    wire [31:0] trace1_rd_data  = 32'b0;

    // sim/verilator_soc.vlt's `public_flat_rd` list names these under
    // cpu_core.v's own pipeline-stage-register names, on the claim that
    // "both cores carry all of these under the same names" - true for
    // if_id_pc/if_id_instr/if_id_valid, which this module already has
    // verbatim, but stage 1d has no ID/EX/MEM/WB stage registers to name
    // in the first place, so the rest were never actually implemented:
    // the claim held for however long verilator_soc's own build was never
    // reached for CORE_OOO (every earlier gate failed first), so nothing
    // ever exercised it. Aliased onto the trace infrastructure a few lines
    // up, which already carries exactly this information for
    // sim/tracer.v/tests/cosim.py's use: `id_ex_pc`/`instret_retire` mark
    // the retiring instruction (this core's nearest equivalent to
    // in-order's EX stage, for BTB training and trap PC alike);
    // `mem_wb_reg_we`/`mem_wb_rd`/`mem_wb_wb_data` are the architectural
    // write that retirement commits; `id_ex_reg_we`/`id_ex_pred_taken`/
    // `id_ex_pred_target` are the head's own destination-need and
    // recorded prediction, read at the same point `head_mispredict`
    // itself compares them; `id_ex1_*` stays tied off, matching
    // `trace1_*` - stage 1d dispatches and retires one instruction wide
    // by design, so there never is a second slot to name.
    wire        instret_retire    = trace_valid;
    wire [31:0] id_ex_pc          = trace_pc;
    wire        mem_wb_reg_we     = trace_rd_we;
    wire [4:0]  mem_wb_rd         = trace_rd;
    wire [31:0] mem_wb_wb_data    = trace_rd_data;
    wire        id_ex_reg_we      = rob_has_rd[rob_head];
    wire        id_ex_pred_taken  = rob_pred_taken[rob_head];
    wire [31:0] id_ex_pred_target = rob_pred_target[rob_head];
    wire        redirect_valid    = head_redirect_valid;
    wire        mispredict        = head_mispredict;
    wire        id_ex1_valid      = trace1_valid;
    wire [31:0] id_ex1_pc         = trace1_pc;
    wire [31:0] id_ex1_instr      = trace1_instr;

    // =======================================================================
    // Fetch buffer / PC control
    // =======================================================================
    wire fb_dispatch_fire = dispatch_can_go;
    wire fb_pop  = fb_dispatch_fire;
    wire if_stall = itlb_wait_stall || ibus_wait;
    wire fb_push = !recovery_fire && !sfence_en && !if_stall && (fb_count < FB_DEPTH[FB_AW:0]);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pc <= RESET_PC;
        end else if (recovery_fire) begin
            pc <= head_redirect_target;
        end else if (sfence_en) begin
            pc <= rob_pc[rob_head] + 32'd4;
        end else if (!fb_push) begin
            // hold
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
        end else if (recovery_fire || sfence_en) begin
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
            if (fb_pop) fb_head <= fb_head + {{(FB_AW-1){1'b0}}, 1'b1};
            fb_count <= fb_count + {{FB_AW{1'b0}}, fb_push} - {{FB_AW{1'b0}}, fb_pop};
        end
    end

    // =======================================================================
    // RAT / ROB / free-list: dispatch, issue-completion latching, retire,
    // and recovery, all in one block. Recovery takes priority (it discards
    // whatever the rest of this cycle's logic computed for anything it
    // squashes); the rest are independent per-signal updates that can
    // co-occur in an ordinary cycle.
    // =======================================================================
    // `ri` here is private to this one sequential process - unlike the
    // issB/issST/issL loop variables above, there is only one writer, so
    // sharing it across this block's several `for` loops is fine.
    integer ri;
    integer fk;
    reg [ROB_AW-1:0] rb_idx;
    integer free_push_n;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rob_head  <= {ROB_AW{1'b0}};
            rob_tail  <= {ROB_AW{1'b0}};
            rob_count <= {(ROB_AW+1){1'b0}};
            free_head  <= {FREE_AW{1'b0}};
            free_tail  <= {FREE_AW{1'b0}};
            free_count <= FREE_N[FREE_AW:0];
            for (ri = 0; ri < 32; ri = ri + 1)     rat[ri] <= ri[PW-1:0];
            for (ri = 0; ri < PREGS; ri = ri + 1)  preg_busy[ri] <= 1'b0;
            // `ri` ranges 0..FREE_N-1 (0..31 for PREGS=64), so `ri+32`
            // ranges 32..63 - always within PW bits by construction, just
            // not something Verilator can prove from a 32-bit `integer`.
            /* verilator lint_off WIDTHTRUNC */
            for (ri = 0; ri < FREE_N; ri = ri + 1) free_list[ri] <= (ri + 32);
            /* verilator lint_on WIDTHTRUNC */
            for (ri = 0; ri < ROB_DEPTH; ri = ri + 1) begin
                rob_valid[ri]  <= 1'b0;
                rob_issued[ri] <= 1'b0;
                rob_done[ri]   <= 1'b0;
            end
        end else if (recovery_fire) begin
            // Undo every rename from the tail back to the culprit
            // (inclusive on a trap, exclusive - it retires normally,
            // handled below - on a mispredict). Walking youngest-first
            // means, for an architectural register renamed more than once
            // in the squashed range, the *oldest* squashed rename's
            // restore is the one left standing - exactly the mapping
            // that held right before the squashed range began.
            free_push_n = 0;
            for (fk = 0; fk < ROB_DEPTH; fk = fk + 1) begin
                rb_idx = rob_tail - 1 - fk[ROB_AW-1:0];
                if (rob_valid[rb_idx] &&
                    ((rb_idx != rob_head) || !recovery_keep_culprit)) begin
                    if (rob_has_rd[rb_idx]) begin
                        rat[rob_arch_rd[rb_idx]] <= rob_old_preg[rb_idx];
                        preg_busy[rob_new_preg[rb_idx]] <= 1'b0;
                        free_list[free_tail + free_push_n[FREE_AW-1:0]] <= rob_new_preg[rb_idx];
                        free_push_n = free_push_n + 1;
                    end
                    rob_valid[rb_idx] <= 1'b0;
                end
            end
            // The culprit itself, on a mispredict, retires normally here
            // (it executed correctly, just not as predicted) rather than
            // through the ordinary retire path below, to avoid advancing
            // rob_head twice in the same cycle. That meant the ordinary
            // `if (cdbS_valid) ... preg_busy[...] <= 0 ...` completion
            // logic further down - which lives in this same always block's
            // *other* branch - never ran for it, even on a cycle where
            // `cdbS_valid` was genuinely 1: `regfile_phys`'s actual write
            // still happened (its `we0`/`wdata0` ports are driven by the
            // combinational `cdbS_valid`/`cdbS_val`, outside this block
            // entirely), but nothing ever cleared the busy bit on the
            // physical register that write landed in. Any instruction
            // still waiting on that register waited forever. Found via a
            // Spike co-simulation diff on rv32ui-p-jal: a JAL's own link
            // register retired with the right value and then never became
            // readable.
            if (recovery_keep_culprit && rob_valid[rob_head] && rob_has_rd[rob_head]) begin
                free_list[free_tail + free_push_n[FREE_AW-1:0]] <= rob_old_preg[rob_head];
                free_push_n = free_push_n + 1;
                preg_busy[rob_new_preg[rob_head]] <= 1'b0;
            end
            if (recovery_keep_culprit) rob_valid[rob_head] <= 1'b0;
            free_tail  <= free_tail + free_push_n[FREE_AW-1:0];
            free_count <= free_count + free_push_n[FREE_AW:0];
            rob_head  <= rob_head + {{(ROB_AW-1){1'b0}}, 1'b1};
            rob_tail  <= rob_head + {{(ROB_AW-1){1'b0}}, 1'b1};
            rob_count <= {(ROB_AW+1){1'b0}};
        end else begin
            // ---- retire: free the head's old physical register ----
            if (retire_fire) begin
                if (rob_has_rd[rob_head]) begin
                    free_list[free_tail] <= rob_old_preg[rob_head];
                    free_tail  <= free_tail + {{(FREE_AW-1){1'b0}}, 1'b1};
                    free_count <= free_count + {{FREE_AW{1'b0}}, 1'b1} -
                                 (dispatch_can_go && dispatch_needs_preg ? {{FREE_AW{1'b0}}, 1'b1} : {(FREE_AW+1){1'b0}});
                end else begin
                    free_count <= free_count -
                                 (dispatch_can_go && dispatch_needs_preg ? {{FREE_AW{1'b0}}, 1'b1} : {(FREE_AW+1){1'b0}});
                end
                rob_valid[rob_head] <= 1'b0;
                rob_head <= rob_head + {{(ROB_AW-1){1'b0}}, 1'b1};
            end else if (dispatch_can_go && dispatch_needs_preg) begin
                free_head  <= free_head + {{(FREE_AW-1){1'b0}}, 1'b1};
                free_count <= free_count - {{FREE_AW{1'b0}}, 1'b1};
            end
            if (retire_fire && dispatch_can_go && dispatch_needs_preg)
                free_head <= free_head + {{(FREE_AW-1){1'b0}}, 1'b1};

            rob_count <= rob_count + (dispatch_can_go ? {{ROB_AW{1'b0}},1'b1} : {(ROB_AW+1){1'b0}})
                                    - (retire_fire     ? {{ROB_AW{1'b0}},1'b1} : {(ROB_AW+1){1'b0}});

            // ---- CDB broadcast: every waiting entry snoops every bus ----
            // An operand not ready at dispatch (its producer was still
            // in flight) has to be woken up here when that producer
            // completes - this is the actual wakeup half of "wakeup and
            // select." Skipping this and only ever resolving readiness at
            // dispatch would leave any entry that dispatched before its
            // producer finished permanently stuck, since nothing else
            // here ever revisits `rob_r1_ready`/`rob_r2_ready` again.
            for (ri = 0; ri < ROB_DEPTH; ri = ri + 1) begin
                if (rob_valid[ri] && !rob_r1_ready[ri]) begin
                    if (cdbS_valid && (cdbS_preg == rob_r1_tag[ri])) begin
                        rob_r1_ready[ri] <= 1'b1; rob_r1_val[ri] <= cdbS_val;
                    end else if (cdbB_valid && (cdbB_preg == rob_r1_tag[ri])) begin
                        rob_r1_ready[ri] <= 1'b1; rob_r1_val[ri] <= cdbB_val;
                    end else if (cdbL_valid && (cdbL_preg == rob_r1_tag[ri])) begin
                        rob_r1_ready[ri] <= 1'b1; rob_r1_val[ri] <= cdbL_val;
                    end
                end
                if (rob_valid[ri] && !rob_r2_ready[ri]) begin
                    if (cdbS_valid && (cdbS_preg == rob_r2_tag[ri])) begin
                        rob_r2_ready[ri] <= 1'b1; rob_r2_val[ri] <= cdbS_val;
                    end else if (cdbB_valid && (cdbB_preg == rob_r2_tag[ri])) begin
                        rob_r2_ready[ri] <= 1'b1; rob_r2_val[ri] <= cdbB_val;
                    end else if (cdbL_valid && (cdbL_preg == rob_r2_tag[ri])) begin
                        rob_r2_ready[ri] <= 1'b1; rob_r2_val[ri] <= cdbL_val;
                    end
                end
            end

            // ---- Class B completion ----
            if (issB_found) begin
                rob_issued[issB_idx] <= 1'b1;
                rob_done[issB_idx]   <= 1'b1;
                rob_result[issB_idx] <= classB_result;
                if (rob_has_rd[issB_idx]) preg_busy[rob_new_preg[issB_idx]] <= 1'b0;
            end

            // ---- store address/data computation ----
            // `src_value` inlined here too - see the note above its
            // definition and above the load-side scan that replaced its
            // other two call sites.
            if (issST_found) begin
                rob_issued[issST_idx] <= 1'b1;
                sq_addr[issST_idx]  <= ((rob_r1_tag[issST_idx] == {PW{1'b0}})                       ? 32'b0 :
                                        (cdbS_valid && (cdbS_preg == rob_r1_tag[issST_idx])) ? cdbS_val :
                                        (cdbB_valid && (cdbB_preg == rob_r1_tag[issST_idx])) ? cdbB_val :
                                        (cdbL_valid && (cdbL_preg == rob_r1_tag[issST_idx])) ? cdbL_val :
                                                                                                 rob_r1_val[issST_idx])
                                       + rob_imm[issST_idx];
                sq_wdata[issST_idx] <= (rob_r2_tag[issST_idx] == {PW{1'b0}})                       ? 32'b0 :
                                       (cdbS_valid && (cdbS_preg == rob_r2_tag[issST_idx])) ? cdbS_val :
                                       (cdbB_valid && (cdbB_preg == rob_r2_tag[issST_idx])) ? cdbB_val :
                                       (cdbL_valid && (cdbL_preg == rob_r2_tag[issST_idx])) ? cdbL_val :
                                                                                                rob_r2_val[issST_idx];
                sq_size[issST_idx]  <= rob_mem_size[issST_idx];
            end

            // ---- load issue / completion ----
            if (loadL_can_start) begin
                rob_issued[issL_idx] <= 1'b1;
            end
            if (loadL_finish) begin
                rob_done[loadL_rob_idx]   <= 1'b1;
                rob_result[loadL_rob_idx] <= loadL_rdata_sized;
                if (rob_has_rd[loadL_rob_idx]) preg_busy[rob_new_preg[loadL_rob_idx]] <= 1'b0;
            end
            // A misaligned load never touches the bus at all - mark it done
            // with a pending trap event right here instead, cause 4 (load
            // address misaligned per the RISC-V privileged spec; distinct
            // from the store/AMO side's cause 6). `headS_valid` and
            // `head_class_b_or_load_can_retire` above route this to the
            // existing Class S trap-taking path once it reaches the head.
            if (issL_trap_now) begin
                rob_issued[issL_idx]        <= 1'b1;
                rob_done[issL_idx]          <= 1'b1;
                rob_is_trap_event[issL_idx] <= 1'b1;
                rob_trap_cause[issL_idx]    <= 32'd4;
                rob_trap_val[issL_idx]      <= issL_addr_calc;
            end

            // ---- Class S completion (head only) ----
            if (cdbS_valid) begin
                rob_issued[rob_head] <= 1'b1;
                rob_done[rob_head]   <= 1'b1;
                rob_result[rob_head] <= headS_result;
                if (rob_has_rd[rob_head]) preg_busy[rob_new_preg[rob_head]] <= 1'b0;
            end

            // ---- dispatch: rename + push a new ROB entry ----
            if (dispatch_can_go) begin
                rob_valid[rob_tail]      <= 1'b1;
                rob_issued[rob_tail]     <= 1'b0;
                rob_done[rob_tail]       <= 1'b0;
                rob_pc[rob_tail]         <= if_id_pc;
                rob_instr[rob_tail]      <= if_id_instr;
                rob_has_rd[rob_tail]     <= dispatch_needs_preg;
                rob_arch_rd[rob_tail]    <= d_rd;
                rob_old_preg[rob_tail]   <= rat[d_rd];
                rob_new_preg[rob_tail]   <= dispatch_needs_preg ? alloc_preg : {PW{1'b0}};

                rob_r1_ready[rob_tail]   <= dispatch_r1_ready;
                rob_r1_tag[rob_tail]     <= rs1_preg;
                rob_r1_val[rob_tail]     <= dispatch_r1_val;
                rob_r2_ready[rob_tail]   <= dispatch_r2_ready;
                rob_r2_tag[rob_tail]     <= rs2_preg;
                rob_r2_val[rob_tail]     <= dispatch_r2_val;

                rob_wb_sel[rob_tail]     <= d_wb_sel;
                rob_alu_ctrl[rob_tail]   <= d_alu_ctrl;
                rob_is_op[rob_tail]      <= is_op;
                rob_a_sel[rob_tail]      <= is_auipc ? A_PC : (is_lui ? A_ZERO : A_REG);
                rob_imm[rob_tail]        <= d_imm;
                rob_funct3[rob_tail]     <= d_funct3;
                rob_mem_size[rob_tail]   <= d_funct3[1:0];
                rob_is_load[rob_tail]    <= is_load && !suppress_effects;
                rob_is_store[rob_tail]   <= d_mem_we;
                rob_is_amo[rob_tail]     <= is_amo && !suppress_effects;
                rob_funct5[rob_tail]     <= d_funct5;
                rob_is_branch[rob_tail]  <= is_branch;
                rob_is_jal[rob_tail]     <= is_jal;
                rob_is_jalr[rob_tail]    <= is_jalr;
                rob_pred_taken[rob_tail] <= if_id_pred_taken;
                rob_pred_target[rob_tail]<= if_id_pred_target;
                rob_is_csr[rob_tail]     <= is_csr;
                rob_csr_we[rob_tail]     <= d_csr_we;
                rob_csr_imm_form[rob_tail]<= csr_imm_form;
                rob_csr_addr[rob_tail]   <= d_csr_addr;
                rob_zimm[rob_tail]       <= d_zimm;
                rob_is_trap_event[rob_tail]<= is_trap_event;
                rob_trap_cause[rob_tail] <= d_trap_cause;
                rob_trap_val[rob_tail]   <= d_trap_val;
                rob_is_mret[rob_tail]    <= is_mret;
                rob_is_sret[rob_tail]    <= is_sret;
                rob_is_muldiv[rob_tail]  <= is_muldiv;
                rob_is_sfence_vma[rob_tail]<= is_sfence_vma;
                rob_is_fence_i[rob_tail] <= is_fence_i;
                // A load/store/AMO/branch/CSR/trap-event is never alu-class,
                // even if suppressed (illegal etc.) - suppressed instructions
                // still execute the Class-S path once at the head, producing
                // no architectural effect, exactly as stage 1c's `commit_ok`
                // gating did for a single EX register.
                rob_is_alu_class[rob_tail] <= d_is_alu_class;

                if (dispatch_needs_preg) begin
                    rat[d_rd]            <= alloc_preg;
                    preg_busy[alloc_preg]<= 1'b1;
                end

                rob_tail <= rob_tail + {{(ROB_AW-1){1'b0}}, 1'b1};
            end
        end
    end

    // =======================================================================
    // Testbench-observability-only counters
    // =======================================================================
    // Required by sim/tb_top.v's own pass/fail check (`EXPECT_MISPREDICTS`),
    // carried over unchanged in meaning from stage 1c: every taken
    // redirect due to a branch/JAL/JALR resolving differently than
    // predicted.
    reg [31:0] mispredict_count;
    always @(posedge clk or posedge rst) begin
        if (rst) mispredict_count <= 32'b0;
        else if (head_mispredict && head_ex_commit) mispredict_count <= mispredict_count + 32'd1;
    end

    // Without these, "out-of-order issue works" is unfalsifiable the same
    // way dual issue was in stage 1b (docs/practices.md section 1): an
    // issue-select that always just picks the ROB head would sail through
    // every functional test by being indistinguishable from an in-order
    // machine. `ooo_alu_issue_count`/`ooo_load_issue_count` count every
    // Class-B/B2 issue; the `_reorder` pair counts only the ones that
    // issued something other than the oldest eligible entry in program
    // order - i.e., cycles where reordering actually happened rather than
    // merely being available.
    reg [31:0] ooo_alu_issue_count, ooo_alu_reorder_count;
    reg [31:0] ooo_load_issue_count, ooo_load_reorder_count;
    reg [31:0] ooo_store_issue_count;
    reg [31:0] rob_full_stall_count;
    reg [31:0] dispatch_count, retire_count;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ooo_alu_issue_count   <= 32'b0;
            ooo_alu_reorder_count <= 32'b0;
            ooo_load_issue_count  <= 32'b0;
            ooo_load_reorder_count<= 32'b0;
            ooo_store_issue_count <= 32'b0;
            rob_full_stall_count  <= 32'b0;
            dispatch_count        <= 32'b0;
            retire_count          <= 32'b0;
        end else begin
            if (issB_found) begin
                ooo_alu_issue_count <= ooo_alu_issue_count + 32'd1;
                if (issB_idx != rob_head) ooo_alu_reorder_count <= ooo_alu_reorder_count + 32'd1;
            end
            if (loadL_can_start) begin
                ooo_load_issue_count <= ooo_load_issue_count + 32'd1;
                if (issL_idx != rob_head) ooo_load_reorder_count <= ooo_load_reorder_count + 32'd1;
            end
            if (issST_found) ooo_store_issue_count <= ooo_store_issue_count + 32'd1;
            if (if_id_valid && rob_full) rob_full_stall_count <= rob_full_stall_count + 32'd1;
            if (dispatch_can_go) dispatch_count <= dispatch_count + 32'd1;
            if (retire_fire)     retire_count   <= retire_count + 32'd1;
        end
    end

endmodule
