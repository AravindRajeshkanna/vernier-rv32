// Full M/S/U-mode CSR file: trap handling (ecall/ebreak/illegal-instruction/
// interrupts) with real trap delegation to S-mode, the Zicsr instructions
// (CSRRW/S/C and immediate forms), M-mode and S-mode interrupt-enable/
// pending views, `satp` (Sv32 root page-table pointer, shared by both the
// data and instruction MMUs), and `current_priv` (the hart's current
// privilege level) - see ARCHITECTURE.md.
//
// Legality of a CSR address (implemented vs. not, read-only vs. RW,
// minimum privilege) is checked outside this module, in cpu_core.v's
// decode - this module just stores and serves whatever address it's
// given, and independently derives (from its own current_priv/medeleg/
// mideleg state) which privilege level a given trap actually lands in.
//
// S-mode interrupt causes (SSI=1/STI=5/SEI=9) are *separate* mip/mie bits
// from the M-level ones (MSI=3/MTI=7/MEI=11), not delegated aliases of
// them - there's no hardware S-mode timer/software-interrupt source in
// this design, so SSIP/STIP are ordinary software-writable storage (an
// M-mode handler is expected to service the real MTI and then manually
// set mip.STIP before `mret`, exactly how real systems emulate an S-mode
// timer interrupt without the Sstc extension). SEIP is hardwired 0 - the
// PLIC (see rtl/plic.v) only delivers to M-mode this round.
module csr_file (
    input  wire        clk,
    input  wire        rst,

    // CSR instruction read/write port (driven from EX)
    input  wire [11:0] addr,
    input  wire        we,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    // trap-entry port: on trap_en, latches epc/cause/tval and pushes the
    // *IE bit into *PIE (clearing *IE) for whichever of M/S this trap
    // resolves to - trap_to_s_out reports that resolution combinationally
    // (derived from current_priv + medeleg/mideleg + trap_cause, valid the
    // same cycle trap_en is asserted) so cpu_core.v can pick the matching
    // vector/epc for its redirect.
    input  wire        trap_en,
    input  wire [31:0] trap_pc,
    input  wire [31:0] trap_cause,
    input  wire [31:0] trap_val,
    output wire [31:0] mtvec_out,
    output wire [31:0] stvec_out,
    output wire        trap_to_s_out,

    // mret/sret ports: restore *IE from *PIE, report the matching epc as
    // the redirect target.
    input  wire        mret_en,
    output wire [31:0] mepc_out,
    input  wire        sret_en,
    output wire [31:0] sepc_out,

    // live interrupt-pending sources (the MSIP/MTIP/MEIP bits are
    // read-only from software's perspective - these are hardware inputs,
    // not writable via mip)
    input  wire        mtip,
    input  wire        msip_in,
    input  wire        meip_in,
    output wire [31:0] mie_out,
    output wire [31:0] mip_out,
    output wire [31:0] mideleg_out,
    output wire         mstatus_mie_out,
    output wire         sstatus_sie_out,
    output wire [1:0]   current_priv_out,

    // satp, exposed directly for the data/instruction MMUs (which need it
    // every cycle, regardless of whether a CSR instruction is executing)
    output wire         satp_mode_out,
    output wire [21:0]  satp_ppn_out,

    // mstatus.MPRV/MPP, exposed for MMU-access privilege-of-record (MPRV
    // lets M-mode loads/stores act, for translation purposes only, as if
    // running at MPP's privilege - never affects instruction fetch)
    output wire         mstatus_mprv_out,
    output wire [1:0]   mstatus_mpp_out
);
    localparam [1:0] PRIV_U = 2'b00, PRIV_S = 2'b01, PRIV_M = 2'b11;

    localparam MISA    = 32'h4000_0100; // RV32I: MXL=1 (32-bit), extension bit 'I'
    localparam MHARTID = 32'h0000_0000;

    reg [1:0]  current_priv;

    reg        mstatus_mie,  mstatus_mpie;
    reg        mstatus_sie,  mstatus_spie, mstatus_spp;
    reg        mstatus_mprv;
    reg [1:0]  mstatus_mpp;

    reg [31:0] mtvec_r, mie_r, mscratch_r, mepc_r, mcause_r, mtval_r;
    reg [31:0] stvec_r, sscratch_r, sepc_r, scause_r, stval_r;
    reg [31:0] medeleg_r, mideleg_r;
    reg        ssip_r, stip_r;
    reg [31:0] satp_r;

    // Legal delegation masks: causes this core can actually raise.
    // Exceptions {2,3,8,9,12,13,15} = illegal instr, ebreak, ECALL-from-U,
    // ECALL-from-S, instruction/load/store page fault.
    localparam [31:0] MEDELEG_MASK = 32'h0000_B30C;
    // Interrupts {1,5,9} = SSI/STI/SEI - the only causes with a real
    // S-level target in this design.
    localparam [31:0] MIDELEG_MASK = 32'h0000_0222;

    wire [31:0] mip_live = {20'b0, meip_in, 1'b0, 1'b0, 1'b0, mtip, 1'b0,
                             stip_r, 1'b0, msip_in, 1'b0, ssip_r, 1'b0};

    assign mie_out          = mie_r;
    assign mip_out          = mip_live;
    assign mideleg_out      = mideleg_r;
    assign mstatus_mie_out  = mstatus_mie;
    assign sstatus_sie_out  = mstatus_sie;
    assign current_priv_out = current_priv;
    assign satp_mode_out    = satp_r[31];
    assign satp_ppn_out     = satp_r[21:0];
    assign mstatus_mprv_out = mstatus_mprv;
    assign mstatus_mpp_out  = mstatus_mpp;

    wire [31:0] mstatus_full = {
        9'b0,            // [31:23] reserved
        1'b0,            // TSR  [22]
        1'b0,            // TW   [21]
        1'b0,            // TVM  [20]
        1'b0,            // MXR  [19]
        1'b0,            // SUM  [18]
        mstatus_mprv,    // MPRV [17]
        2'b00,           // XS   [16:15]
        2'b00,           // FS   [14:13]
        mstatus_mpp,     // MPP  [12:11]
        2'b00,           // WPRI [10:9]
        mstatus_spp,     // SPP  [8]
        mstatus_mpie,    // MPIE [7]
        1'b0,            // UBE  [6]
        mstatus_spie,    // SPIE [5]
        1'b0,            // WPRI [4]
        mstatus_mie,     // MIE  [3]
        1'b0,            // WPRI [2]
        mstatus_sie,     // SIE  [1]
        1'b0             // WPRI [0]
    };
    // sstatus is a masked *view* of the same mstatus storage - only
    // SPP/SPIE/SIE are visible (no separate flip-flops).
    wire [31:0] sstatus_view = mstatus_full & 32'h0000_0122;

    assign mtvec_out = mtvec_r;
    assign stvec_out = stvec_r;
    assign mepc_out  = mepc_r;
    assign sepc_out  = sepc_r;

    // Trap delegation: a trap lands in S instead of M only if the hart
    // wasn't already in M (traps never move to a *less* privileged mode
    // than where they occurred) and the specific cause is delegated.
    wire        is_interrupt = trap_cause[31];
    wire [4:0]  cause_num    = trap_cause[4:0];
    wire        deleg_bit    = is_interrupt ? mideleg_r[cause_num] : medeleg_r[cause_num];
    wire        trap_to_s    = (current_priv != PRIV_M) && deleg_bit;
    assign trap_to_s_out = trap_to_s;

    always @(*) begin
        case (addr)
            12'h100: rdata = sstatus_view;
            12'h104: rdata = mie_r & mideleg_r;
            12'h105: rdata = stvec_r;
            12'h140: rdata = sscratch_r;
            12'h141: rdata = sepc_r;
            12'h142: rdata = scause_r;
            12'h143: rdata = stval_r;
            12'h144: rdata = mip_live & mideleg_r;
            12'h180: rdata = satp_r;
            12'h300: rdata = mstatus_full;
            12'h301: rdata = MISA;
            12'h302: rdata = medeleg_r;
            12'h303: rdata = mideleg_r;
            12'h304: rdata = mie_r;
            12'h305: rdata = mtvec_r;
            12'h340: rdata = mscratch_r;
            12'h341: rdata = mepc_r;
            12'h342: rdata = mcause_r;
            12'h343: rdata = mtval_r;
            12'h344: rdata = mip_live;
            12'hF14: rdata = MHARTID;
            default: rdata = 32'b0;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            current_priv <= PRIV_M;
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mstatus_sie  <= 1'b0;
            mstatus_spie <= 1'b0;
            mstatus_spp  <= 1'b0;
            mstatus_mprv <= 1'b0;
            mstatus_mpp  <= PRIV_M;
            mtvec_r      <= 32'b0;
            mie_r        <= 32'b0;
            mscratch_r   <= 32'b0;
            mepc_r       <= 32'b0;
            mcause_r     <= 32'b0;
            mtval_r      <= 32'b0;
            stvec_r      <= 32'b0;
            sscratch_r   <= 32'b0;
            sepc_r       <= 32'b0;
            scause_r     <= 32'b0;
            stval_r      <= 32'b0;
            medeleg_r    <= 32'b0;
            mideleg_r    <= 32'b0;
            ssip_r       <= 1'b0;
            stip_r       <= 1'b0;
            satp_r       <= 32'b0;
        end else if (trap_en) begin
            if (trap_to_s) begin
                sepc_r       <= trap_pc;
                scause_r     <= trap_cause;
                stval_r      <= trap_val;
                mstatus_spie <= mstatus_sie;
                mstatus_sie  <= 1'b0;
                mstatus_spp  <= current_priv[0]; // current_priv is S or U here (1 bit: 0=U,1=S)
                current_priv <= PRIV_S;
            end else begin
                mepc_r       <= trap_pc;
                mcause_r     <= trap_cause;
                mtval_r      <= trap_val;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
                mstatus_mpp  <= current_priv;
                current_priv <= PRIV_M;
            end
        end else if (mret_en) begin
            current_priv <= mstatus_mpp;
            mstatus_mie  <= mstatus_mpie;
            mstatus_mpie <= 1'b1;
            mstatus_mpp  <= PRIV_U;
            if (mstatus_mpp != PRIV_M) mstatus_mprv <= 1'b0;
        end else if (sret_en) begin
            current_priv <= {1'b0, mstatus_spp};
            mstatus_sie  <= mstatus_spie;
            mstatus_spie <= 1'b1;
            mstatus_spp  <= 1'b0;
        end else if (we) begin
            case (addr)
                12'h100: begin
                    mstatus_sie  <= wdata[1];
                    mstatus_spie <= wdata[5];
                    mstatus_spp  <= wdata[8];
                end
                12'h104: mie_r <= (mie_r & ~mideleg_r) | (wdata & mideleg_r);
                12'h105: stvec_r    <= {wdata[31:2], 2'b00};
                12'h140: sscratch_r <= wdata;
                12'h141: sepc_r     <= {wdata[31:1], 1'b0};
                12'h142: scause_r   <= wdata;
                12'h143: stval_r    <= wdata;
                12'h144: ssip_r     <= wdata[1];
                12'h180: satp_r     <= wdata;
                12'h300: begin
                    mstatus_mie  <= wdata[3];
                    mstatus_mpie <= wdata[7];
                    mstatus_sie  <= wdata[1];
                    mstatus_spie <= wdata[5];
                    mstatus_spp  <= wdata[8];
                    mstatus_mpp  <= wdata[12:11];
                    mstatus_mprv <= wdata[17];
                end
                12'h302: medeleg_r <= wdata & MEDELEG_MASK;
                12'h303: mideleg_r <= wdata & MIDELEG_MASK;
                12'h304: mie_r      <= wdata;
                12'h305: mtvec_r    <= {wdata[31:2], 2'b00};
                12'h340: mscratch_r <= wdata;
                12'h341: mepc_r     <= {wdata[31:1], 1'b0};
                12'h342: mcause_r   <= wdata;
                12'h343: mtval_r    <= wdata;
                12'h344: begin ssip_r <= wdata[1]; stip_r <= wdata[5]; end
                default: ; // read-only / unimplemented - decode should have flagged illegal
            endcase
        end
    end
endmodule
