// Full M/S/U-mode CSR file: trap handling (ecall/ebreak/illegal-instruction/
// interrupts) with real trap delegation to S-mode, the Zicsr instructions
// (CSRRW/S/C and immediate forms), M-mode and S-mode interrupt-enable/
// pending views, `satp` (Sv32 root page-table pointer, shared by both the
// data and instruction MMUs), and `current_priv` (the hart's current
// privilege level) - see docs/architecture.md.
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
// timer interrupt without the Sstc extension).
//
// SEIP is the one bit here with genuinely two-sided semantics, and the spec
// is specific about it: mip.SEIP is the logical OR of a *software-writable*
// bit and the signal from the external interrupt controller. M-mode writes
// to mip set the software half; the PLIC's S-mode context (rtl/plic.v
// context 1) drives the hardware half. A read of mip returns the OR, and the
// interrupt-pending logic uses the OR, so either source can raise it.
//
// The software half is not decoration: it is how an M-mode SBI implementation
// injects an external interrupt into S-mode without a device behind it, and
// it is why the bit cannot simply be wired to the PLIC pin. Only M-mode can
// write it: the `sip` write path below reaches SSIP and nothing else, because
// S-mode clearing its own external-interrupt pending bit would let it drop an
// interrupt the PLIC is still asserting.
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
    // The PLIC's S-mode context. ORed with the software-writable SEIP bit to
    // form mip.SEIP; see the header.
    input  wire        seip_in,
    output wire [31:0] mie_out,
    output wire [31:0] mip_out,
    output wire [31:0] mideleg_out,
    output wire         mstatus_mie_out,
    output wire         sstatus_sie_out,
    output wire [1:0]   current_priv_out,

    // Performance counters. `time` is architecturally required to read the
    // *same* wall-clock the CLINT's mtimecmp compares against, so it is wired
    // straight from the CLINT rather than being a separate counter here -
    // firmware that reads `time` and programs `mtimecmp` from it (which is
    // exactly what an SBI timer implementation does) would otherwise be
    // comparing two unrelated clocks.
    input  wire [63:0]  mtime_in,
    // How many instructions completed this cycle: 0, 1, or - once a core
    // issues more than one instruction at a time - 2. A flag here would make
    // `minstret` undercount on a dual-issue core, which is a wrong
    // architectural counter rather than a slow one.
    input  wire [1:0]   instret_inc,
    output wire [31:0]  mcounteren_out,
    output wire [31:0]  scounteren_out,

    // satp, exposed directly for the data/instruction MMUs (which need it
    // every cycle, regardless of whether a CSR instruction is executing)
    output wire         satp_mode_out,
    output wire [21:0]  satp_ppn_out,

    // mstatus.MPRV/MPP, exposed for MMU-access privilege-of-record (MPRV
    // lets M-mode loads/stores act, for translation purposes only, as if
    // running at MPP's privilege - never affects instruction fetch)
    output wire         mstatus_mprv_out,
    output wire [1:0]   mstatus_mpp_out,

    // mstatus.SUM/MXR, the supervisor's two translation-control bits.
    // SUM permits S-mode data accesses to user pages; MXR makes an
    // execute-only page readable. Both are consumed by the data MMU.
    output wire         mstatus_sum_out,
    output wire         mstatus_mxr_out,

    // mstatus.TVM/TW/TSR - M-mode's three "trap what supervisor does" bits.
    // They exist so firmware can intercept operations it needs to emulate or
    // police: TVM traps S-mode's address-translation control (SFENCE.VMA and
    // satp), TW traps a supervisor WFI so an idle hart can be reclaimed, and
    // TSR traps SRET. Decode in cpu_core.v turns each into an
    // illegal-instruction trap.
    output wire         mstatus_tvm_out,
    output wire         mstatus_tw_out,
    output wire         mstatus_tsr_out
);
    localparam [1:0] PRIV_U = 2'b00, PRIV_S = 2'b01, PRIV_M = 2'b11;

    // MXL=1 (32-bit) in [31:30], plus one bit per implemented extension:
    // A=bit 0, I=bit 8, M=bit 12, S=bit 18, U=bit 20. It matters beyond
    // tidiness: M-mode firmware (OpenSBI) and any OS read `misa` to decide
    // what the hart can do, so under-reporting makes them disable features
    // the hardware actually has.
    //
    // This has now been wrong twice. It first advertised 'I' only, omitting M
    // and A; the S and U bits were then still missing even though this core
    // has full supervisor and user modes with trap delegation - which is
    // precisely the thing firmware checks before trying to hand off to an
    // S-mode payload. The Spike co-simulation caught the second one by
    // diffing the value a `csrr a0, misa` actually returned.
    localparam MISA    = 32'h4014_1101;
    localparam MHARTID = 32'h0000_0000;

    reg [1:0]  current_priv;

    reg        mstatus_mie,  mstatus_mpie;
    reg        mstatus_sie,  mstatus_spie, mstatus_spp;
    reg        mstatus_mprv;
    reg        mstatus_sum, mstatus_mxr;
    reg        mstatus_tvm, mstatus_tw, mstatus_tsr;
    reg [1:0]  mstatus_mpp;

    reg [31:0] mtvec_r, mie_r, mscratch_r, mepc_r, mcause_r, mtval_r;
    reg [31:0] stvec_r, sscratch_r, sepc_r, scause_r, stval_r;
    reg [31:0] medeleg_r, mideleg_r;
    reg        ssip_r, stip_r;
    // The software-writable half of mip.SEIP. Separate from the PLIC's pin so
    // a read can return the OR without the write having clobbered hardware
    // state, which is exactly the distinction the spec draws.
    reg        seip_sw_r;
    reg [31:0] satp_r;

    // ---- performance counters ----
    // mcycle/minstret are the machine-level counters; cycle/instret are the
    // read-only user-level *views* of the same registers (not separate
    // storage), which is what the spec requires.
    reg [63:0] mcycle_r, minstret_r;
    reg [31:0] mcounteren_r, scounteren_r;
    // mcountinhibit: bit 0 (CY) stops mcycle, bit 2 (IR) stops minstret.
    // Only those two bits exist here, matching the only two counters that do.
    // A stopped counter still reads and writes normally - it just does not
    // tick, which is what makes it possible to read a consistent pair or to
    // measure without the measurement itself counting.
    reg [31:0] mcountinhibit_r;

    assign mcounteren_out = mcounteren_r;
    assign scounteren_out = scounteren_r;

    // The counters are the one pair of CSRs that a write and the hardware
    // both drive, so their writes are handled *here* rather than in the main
    // CSR write block below. Having both blocks assign the same reg is a
    // multiple-driver conflict: Verilog leaves the outcome to whichever block
    // the simulator happens to evaluate last, and synthesis rejects it
    // outright. Keeping the two effects in one block also makes their
    // priority explicit, which the spec has an opinion about (below).
    wire csr_write_now  = we && !trap_en && !mret_en && !sret_en;
    wire mcycle_lo_we   = csr_write_now && (addr == 12'hB00);
    wire mcycle_hi_we   = csr_write_now && (addr == 12'hB80);
    wire minstret_lo_we = csr_write_now && (addr == 12'hB02);
    wire minstret_hi_we = csr_write_now && (addr == 12'hB82);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mcycle_r <= 64'b0;
        end else if (mcycle_lo_we || mcycle_hi_we) begin
            // A write wins over the tick, and suppresses it on *both* halves:
            // the two halves are one 64-bit counter, so writing either one
            // has to leave the other alone rather than letting it carry.
            mcycle_r <= {mcycle_hi_we ? wdata : mcycle_r[63:32],
                         mcycle_lo_we ? wdata : mcycle_r[31:0]};
        end else if (!mcountinhibit_r[0]) begin
            mcycle_r <= mcycle_r + 64'd1;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            minstret_r <= 64'b0;
        end else if (minstret_lo_we || minstret_hi_we) begin
            minstret_r <= {minstret_hi_we ? wdata : minstret_r[63:32],
                           minstret_lo_we ? wdata : minstret_r[31:0]};
        end else if ((instret_inc != 2'd0) && !mcountinhibit_r[2]) begin
            minstret_r <= minstret_r + {62'b0, instret_inc};
        end
    end

    // Legal delegation masks: causes this core can actually raise.
    // Exceptions {0,2,3,4,6,8,9,12,13,15} = misaligned fetch, illegal instr,
    // ebreak, misaligned load, misaligned store/AMO, ECALL-from-U,
    // ECALL-from-S, instruction/load/store page fault.
    //
    // Causes 0/4/6 were added to this mask when the corresponding traps were
    // implemented. Leaving them out was a real bug and not a cosmetic one: a
    // cause that is raiseable but not delegatable always lands in M-mode, so
    // an S-mode kernel that had asked for its own misaligned-access handler
    // silently never got one.
    localparam [31:0] MEDELEG_MASK = 32'h0000_B35D;
    // Interrupts {1,5,9} = SSI/STI/SEI - the only causes with a real
    // S-level target in this design.
    localparam [31:0] MIDELEG_MASK = 32'h0000_0222;

    wire        seip_live = seip_sw_r | seip_in;
    wire [31:0] mip_live = {20'b0, meip_in, 1'b0, seip_live, 1'b0, mtip, 1'b0,
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
    assign mstatus_sum_out  = mstatus_sum;
    assign mstatus_mxr_out  = mstatus_mxr;
    assign mstatus_tvm_out  = mstatus_tvm;
    assign mstatus_tw_out   = mstatus_tw;
    assign mstatus_tsr_out  = mstatus_tsr;
    assign mstatus_mpp_out  = mstatus_mpp;

    wire [31:0] mstatus_full = {
        9'b0,            // [31:23] reserved
        mstatus_tsr,     // TSR  [22]
        mstatus_tw,      // TW   [21]
        mstatus_tvm,     // TVM  [20]
        mstatus_mxr,     // MXR  [19]
        mstatus_sum,     // SUM  [18]
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
    // SPP/SPIE/SIE plus the two translation-control bits SUM/MXR are
    // visible (no separate flip-flops). SUM and MXR belong in the S-mode
    // view because they are the supervisor's own knobs: an OS sets them
    // around a user-memory access, and it has no access to mstatus.
    wire [31:0] sstatus_view = mstatus_full & 32'h000C_0122;

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
            12'h106: rdata = scounteren_r;
            12'h180: rdata = satp_r;
            12'h300: rdata = mstatus_full;
            12'h306: rdata = mcounteren_r;
            12'h320: rdata = mcountinhibit_r;
            // RV32 splits every 64-bit counter into a low half and an `h`
            // high half at +0x80.
            12'hB00: rdata = mcycle_r[31:0];
            12'hB02: rdata = minstret_r[31:0];
            12'hB80: rdata = mcycle_r[63:32];
            12'hB82: rdata = minstret_r[63:32];
            12'hC00: rdata = mcycle_r[31:0];      // cycle
            12'hC01: rdata = mtime_in[31:0];      // time
            12'hC02: rdata = minstret_r[31:0];    // instret
            12'hC80: rdata = mcycle_r[63:32];     // cycleh
            12'hC81: rdata = mtime_in[63:32];     // timeh
            12'hC82: rdata = minstret_r[63:32];   // instreth
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
            mstatus_sum  <= 1'b0;
            mstatus_mxr  <= 1'b0;
            mstatus_tvm  <= 1'b0;
            mstatus_tw   <= 1'b0;
            mstatus_tsr  <= 1'b0;
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
            seip_sw_r    <= 1'b0;
            satp_r       <= 32'b0;
            mcounteren_r <= 32'b0;
            mcountinhibit_r <= 32'b0;
            scounteren_r <= 32'b0;
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
                    // Same flip-flops as mstatus[19:18]: sstatus is a view,
                    // not a second copy, so a supervisor writing sstatus.SUM
                    // has to land on the bit the MMU actually reads.
                    mstatus_sum  <= wdata[18];
                    mstatus_mxr  <= wdata[19];
                end
                12'h104: mie_r <= (mie_r & ~mideleg_r) | (wdata & mideleg_r);
                // MODE is WARL and only Direct (0) and Vectored (1) are
                // legal, so bit 1 is forced to zero rather than the whole
                // field being flattened to Direct. Keeping bit 0 is what lets
                // software select vectored interrupt entry; discarding it
                // would be legal but would silently ignore the request.
                12'h105: stvec_r    <= {wdata[31:2], 1'b0, wdata[0]};
                12'h140: sscratch_r <= wdata;
                12'h141: sepc_r     <= {wdata[31:1], 1'b0};
                12'h142: scause_r   <= wdata;
                12'h143: stval_r    <= wdata;
                12'h106: scounteren_r <= wdata;
                12'h144: ssip_r     <= wdata[1];
                12'h180: satp_r     <= wdata;
                12'h306: mcounteren_r <= wdata;
                12'h320: mcountinhibit_r <= wdata & 32'h0000_0005; // CY and IR only
                // 0xB00/0xB02/0xB80/0xB82 (mcycle/minstret and their high
                // halves) are handled in their own block above, alongside the
                // hardware increment they share a register with.
                12'h300: begin
                    mstatus_mie  <= wdata[3];
                    mstatus_mpie <= wdata[7];
                    mstatus_sie  <= wdata[1];
                    mstatus_spie <= wdata[5];
                    mstatus_spp  <= wdata[8];
                    mstatus_mpp  <= wdata[12:11];
                    mstatus_mprv <= wdata[17];
                    mstatus_sum  <= wdata[18];
                    mstatus_mxr  <= wdata[19];
                    // Machine-level only: deliberately absent from the
                    // sstatus write case, since a supervisor must not be able
                    // to clear the bits that are trapping it.
                    mstatus_tvm  <= wdata[20];
                    mstatus_tw   <= wdata[21];
                    mstatus_tsr  <= wdata[22];
                end
                12'h302: medeleg_r <= wdata & MEDELEG_MASK;
                12'h303: mideleg_r <= wdata & MIDELEG_MASK;
                12'h304: mie_r      <= wdata;
                12'h305: mtvec_r    <= {wdata[31:2], 1'b0, wdata[0]}; // see stvec above
                12'h340: mscratch_r <= wdata;
                12'h341: mepc_r     <= {wdata[31:1], 1'b0};
                12'h342: mcause_r   <= wdata;
                12'h343: mtval_r    <= wdata;
                // SEIP's software half is writable here and only here: a
                // write through `sip` (0x144) must not reach it, because
                // S-mode clearing its own external-interrupt pending bit
                // would let it drop an interrupt the PLIC is still asserting.
                12'h344: begin
                    ssip_r    <= wdata[1];
                    stip_r    <= wdata[5];
                    seip_sw_r <= wdata[9];
                end
                default: ; // read-only / unimplemented - decode should have flagged illegal
            endcase
        end
    end
endmodule
