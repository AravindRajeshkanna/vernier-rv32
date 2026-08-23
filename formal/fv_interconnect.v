// Formal properties for rtl/soc/wb_interconnect.v.
//
// An interconnect's failure modes are the nastiest kind to debug from a
// waveform - two slaves strobed at once, or an ack delivered to the master
// that did not make the request - because they surface far away as corrupted
// data. That makes it worth proving rather than testing.
//
// It gained a third master when the page-table walkers stopped reading PTEs
// through a private port on wb_ram.v and became rtl/soc/wb_ptw.v - which is
// what lets a page table live in SDRAM. Three masters means the priority
// order is no longer a single bit of "data or fetch", and the two comparisons
// in it are asserted separately below (properties 4a and 4b), because they
// are load-bearing for different reasons: data must outrank the walker or an
// AMO's read-modify-write gap stops being atomic, and the walker must outrank
// fetch or a continuous fetch stream can starve a walk.
//
// It became a *sequential* proof when the arbiter gained a lock. The
// memories are now synchronous block RAMs with a wait state, so a transfer
// spans several cycles, and a purely combinational grant would let the data
// master take the bus in the middle of the fetch master's read - after which
// the RAM's ack, which belongs to the fetch master's address, is delivered
// to the data master along with the fetch master's data. Properties 8 and 9
// below are the ones that say that cannot happen.
module fv_interconnect #(
    parameter NUM_SLAVES = 9
)(
    input wire        clk,
    input wire        rst,
    input wire        m0_cyc, m0_stb,
    input wire [31:0] m0_adr,
    input wire        m1_cyc, m1_stb, m1_we,
    input wire [31:0] m1_adr, m1_dat_w,
    input wire [3:0]  m1_sel,
    input wire        m2_cyc, m2_stb,
    input wire [31:0] m2_adr,
    // The debug module (rtl/debug/dm.v). Highest priority and the second
    // master with a write path, which is why it is here rather than assumed
    // harmless: every property below has to hold with four contenders, not
    // three, and "at most one master is selected" is exactly the kind of
    // thing that stays true by luck when a case is added.
    input wire        m3_cyc, m3_stb, m3_we,
    input wire [31:0] m3_adr, m3_dat_w,
    input wire [3:0]  m3_sel,
    input wire [NUM_SLAVES*32-1:0] s_dat_r,
    input wire [NUM_SLAVES-1:0]    s_ack
);
    // The real map from soc_top.v, all nine slaves. Held constant rather than
    // left free because `s_base`/`s_mask` are wiring constants in the real
    // design; leaving them free would let the solver invent an aliased map
    // (two slaves answering the same address) and then report a "bug" no
    // instantiation can produce.
    //
    // The SDRAM's mask is 0xFE rather than 0xFF, so it answers to 0x90 and
    // 0x91 alike: 32 MB, the size of the part on the board. That asymmetry is
    // the point of proving with the real map rather than a tidy one - a
    // masked slave is exactly where a decode bug would put two slaves on the
    // same address, and property 1 is what would catch it.
    wire [NUM_SLAVES*8-1:0] s_base =
        {8'h90, 8'h80, 8'h07, 8'h06, 8'h05, 8'h04, 8'h03, 8'h02, 8'h00};
    wire [NUM_SLAVES*8-1:0] s_mask =
        {8'hFE, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF};

    wire [31:0] m0_dat_r, m1_dat_r, m2_dat_r, m3_dat_r;
    wire        m0_ack, m1_ack, m2_ack, m3_ack;
    wire        s_cyc, s_we, s_data_master;
    wire [NUM_SLAVES-1:0] s_stb;
    wire [31:0] s_adr, s_dat_w;
    wire [3:0]  s_sel;

    wb_interconnect #(.NUM_SLAVES(NUM_SLAVES)) DUT (
        .clk(clk), .rst(rst),
        .m0_cyc(m0_cyc), .m0_stb(m0_stb), .m0_adr(m0_adr),
        .m0_dat_r(m0_dat_r), .m0_ack(m0_ack),
        .m1_cyc(m1_cyc), .m1_stb(m1_stb), .m1_we(m1_we), .m1_adr(m1_adr),
        .m1_dat_w(m1_dat_w), .m1_sel(m1_sel),
        .m1_dat_r(m1_dat_r), .m1_ack(m1_ack),
        .m2_cyc(m2_cyc), .m2_stb(m2_stb), .m2_adr(m2_adr),
        .m2_dat_r(m2_dat_r), .m2_ack(m2_ack),
        .m3_cyc(m3_cyc), .m3_stb(m3_stb), .m3_we(m3_we), .m3_adr(m3_adr),
        .m3_dat_w(m3_dat_w), .m3_sel(m3_sel),
        .m3_dat_r(m3_dat_r), .m3_ack(m3_ack),
        .s_base(s_base), .s_mask(s_mask),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we),
        .s_adr(s_adr), .s_dat_w(s_dat_w), .s_sel(s_sel),
        .s_dat_r(s_dat_r), .s_ack(s_ack),
        .s_data_master(s_data_master)
    );

    // BMC starts from an unconstrained state, so require reset in the first
    // step - otherwise the solver invents a power-on state (a lock held for a
    // master that never requested anything) that no reset sequence reaches.
    reg f_initialized = 1'b0;
    always @(posedge clk) f_initialized <= 1'b1;
    always @(*) if (!f_initialized) assume (rst);

    // ---- environment assumption: masters are Wishbone-legal ----
    // A master that has asserted cyc+stb holds them until it is acked. This
    // is not wishful thinking about the environment; it is a property of both
    // masters in this design, and cpu_wb.v's `f_busy` exists specifically to
    // guarantee it for the fetch master now that transfers span cycles.
    // Without it the solver can drop a request mid-transfer and then
    // legitimately complain that the ack went to a master that is no longer
    // asking - a "bug" that says nothing about the interconnect.
    // Both masters tie stb to cyc: cpu_wb.v drives each pair from a single
    // expression. Wishbone does permit cyc without stb - a master holding the
    // bus between transfers - but this arbiter grants on cyc alone, so such a
    // master would take the bus and then never strobe, blocking the other one
    // until it let go. No master in this SoC behaves that way, and saying so
    // is what keeps the grant-stability property below about the arbiter
    // rather than about a master that does not exist here.
    always @(*) begin
        assume (m0_cyc == m0_stb);
        assume (m1_cyc == m1_stb);
        assume (m2_cyc == m2_stb);
        assume (m3_cyc == m3_stb);
    end

    reg p_m0_pending, p_m1_pending, p_m2_pending, p_m3_pending;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            p_m0_pending <= 1'b0;
            p_m1_pending <= 1'b0;
            p_m2_pending <= 1'b0;
            p_m3_pending <= 1'b0;
        end else begin
            p_m0_pending <= m0_cyc && m0_stb && !m0_ack;
            p_m1_pending <= m1_cyc && m1_stb && !m1_ack;
            p_m2_pending <= m2_cyc && m2_stb && !m2_ack;
            p_m3_pending <= m3_cyc && m3_stb && !m3_ack;
        end
    end
    always @(*) begin
        if (p_m0_pending) assume (m0_cyc && m0_stb);
        if (p_m1_pending) assume (m1_cyc && m1_stb);
        if (p_m2_pending) assume (m2_cyc && m2_stb);
        if (p_m3_pending) assume (m3_cyc && m3_stb);
    end

    // ---- everything below is expressed over ports only ----
    // No hierarchical references into the DUT. Partly because they survive a
    // refactor, but mainly because `prep -flatten` leaves several distinct
    // nets sharing a name, so a reference like `DUT.lock` can silently bind
    // to the wrong one and produce a counterexample that describes nothing.
    //
    // "A transfer is in progress" is therefore derived the way an observer on
    // the bus would derive it: somebody is asserting cyc+stb and nobody has
    // been acked yet.
    wire any_req = (m0_cyc && m0_stb) || (m1_cyc && m1_stb) ||
                   (m2_cyc && m2_stb) || (m3_cyc && m3_stb);
    wire any_ack = m0_ack || m1_ack || m2_ack || m3_ack;

    reg p_any_req, p_any_ack, p_dm, p_rst;
    always @(posedge clk) begin
        p_any_req <= any_req;
        p_any_ack <= any_ack;
        p_dm      <= s_data_master;
        p_rst     <= rst;
    end

    // True exactly when a transfer started earlier and has not completed, so
    // arbitration must stay put.
    wire in_flight = p_any_req && !p_any_ack;

    integer j;
    reg [3:0] stb_count;
    always @(*) begin
        stb_count = 4'd0;
        for (j = 0; j < NUM_SLAVES; j = j + 1)
            stb_count = stb_count + {3'b0, s_stb[j]};
    end

    always @(*) if (!rst) begin
        // 1. At most one slave is ever strobed. Two slaves answering in the
        //    same cycle drive the shared response mux against each other.
        assert (stb_count <= 4'd1);

        // 2. A strobed slave is the one the address actually decodes to,
        //    through that slave's own mask. A slave with a mask narrower than
        //    0xFF answers to more than one base byte, which is how the SDRAM
        //    covers 32 MB.
        for (j = 0; j < NUM_SLAVES; j = j + 1)
            if (s_stb[j])
                assert ((s_adr[31:24] & s_mask[8*j +: 8]) ==
                        (s_base[8*j +: 8] & s_mask[8*j +: 8]));

        // 3. The bus is only claimed by a master that is asking for it.
        if (s_data_master) assert (m1_cyc);

        // 3b. `s_data_master` is what gates read side effects - the PLIC's
        //     claim register, the UART's RBR. The debug module must never
        //     assert it: a host reading a peripheral through rtl/debug/dm.v
        //     has to get the value without consuming it. This is one line and
        //     it is the difference between a debug port and a second CPU.
        if (m3_ack) assert (!s_data_master);

        // 4a. Data outranks the walker whenever arbitration is actually open.
        //     The `!in_flight` qualifier is the whole point of the lock: while
        //     a transfer is under way, priority does not get to preempt it.
        //
        //     This is the property that keeps atomics atomic. cpu_wb.v holds
        //     `cyc` across both phases of an AMO's read-modify-write and
        //     relies on the data master always winning to keep anyone else out
        //     of the gap - and instruction fetch carries on translating while
        //     the MEM stage sits in an AMO, so the walker genuinely can ask
        //     during it.
        // 4z. Debug outranks everything, whenever arbitration is open. It
        //     asks about once per JTAG transaction, so the cost is one
        //     arbitration slot; the benefit is that a host can read the
        //     memory of a machine whose CPU is spinning on the bus, which is
        //     the case a debugger is for.
        if (m3_cyc && !in_flight) begin
            assert (!m0_ack);
            assert (!m1_ack);
            assert (!m2_ack);
        end

        if (m1_cyc && !m3_cyc && !in_flight) begin
            assert (s_data_master);
            assert (!m2_ack);
            assert (!m0_ack);
        end

        // 4b. The walker outranks fetch. Fetch is nearly continuous, so a walk
        //     that lost to it could be starved indefinitely; the reverse
        //     cannot happen, because a walk is two reads and then it is over.
        if (m2_cyc && !m1_cyc && !m3_cyc && !in_flight) assert (!m0_ack);

        // 5. Acks go to the master that made the request, and only to one.
        assert (!(m0_ack && m1_ack));
        assert (!(m0_ack && m2_ack));
        assert (!(m1_ack && m2_ack));
        assert (!(m3_ack && m0_ack));
        assert (!(m3_ack && m1_ack));
        assert (!(m3_ack && m2_ack));
        if (m0_ack) assert (m0_cyc);
        if (m1_ack) assert (m1_cyc);
        if (m2_ack) assert (m2_cyc);
        if (m3_ack) assert (m3_cyc);

        // 6. An access to an address matching no slave still acks. A bus that
        //    never acks wedges the CPU permanently - cpu_wb.v freezes the
        //    pipeline waiting for one - so a stray pointer would become an
        //    unrecoverable hang instead of garbage data the program survives.
        //
        //    It matters for the walker too, and more than it looks: a walker
        //    reads whatever physical address a PTE names, and a half-built
        //    page table names unmapped ones. wb_ptw.v's own handling of a
        //    same-cycle ack is what turns that into a page fault rather than a
        //    re-issued read forever.
        if (m1_cyc && m1_stb && !m3_cyc && !in_flight &&
            (s_stb == {NUM_SLAVES{1'b0}}))
            assert (m1_ack);
        // The debug master needs it most: a host can ask for any address at
        // all, including ones that decode to nothing, and a debug read that
        // hangs the bus would take the machine down rather than report a hole.
        if (m3_cyc && m3_stb && !in_flight && (s_stb == {NUM_SLAVES{1'b0}}))
            assert (m3_ack);
        if (m2_cyc && m2_stb && !m1_cyc && !m3_cyc && !in_flight &&
            (s_stb == {NUM_SLAVES{1'b0}}))
            assert (m2_ack);

        // 7. The broadcast address belongs to the granted master. Only the
        //    data master is observable every cycle (`s_data_master` exists for
        //    the peripherals, not for this), so the other two are checked on
        //    the cycle that matters: the one where a slave answered them.
        if (s_data_master) assert (s_adr == m1_adr);
        if (m0_ack)        assert (s_adr == m0_adr);
        if (m2_ack)        assert (s_adr == m2_adr);
        if (m3_ack)        assert (s_adr == m3_adr);

        // 8. Only a master that *has* a write path drives `s_we` - the data
        //    master and the debug module. The fetch master and the walker
        //    have none, so if this could fail either of them could corrupt
        //    memory.
        //
        //    This said "only the data master writes" until the debug module
        //    arrived, and the prover refuted it on the first run - correctly,
        //    because the statement had become false. It is restated rather
        //    than deleted: the property worth having is not "m1 is the only
        //    writer" but "nothing writes that cannot", and those were the
        //    same sentence only while there was one writer.
        if (s_we) assert (s_data_master || m3_cyc);
    end

    // ---- the property that makes a multi-cycle slave safe ----
    //
    // Compared between registered history and the current cycle, and asserted
    // combinationally. Asserting inside `always @(posedge clk)` looks
    // equivalent and is not: after yosys's async2sync pass, register outputs
    // sampled at the edge are not consistent with the combinational signals
    // derived from them, and the solver duly reports a "counterexample" that
    // is an artifact of the sampling rather than a behavior of the design.
    always @(*) if (!rst && !p_rst && f_initialized) begin
        // 9. A transfer that started and was not acked keeps the bus.
        //
        //    This is what the lock is for, and it is the property that fails
        //    without it: the data master would take the bus mid-transfer, and
        //    the slave's ack - which belongs to the address latched when the
        //    transfer began - would be delivered to the wrong master along
        //    with the wrong data. Silent corruption, not a hang, which is why
        //    it is worth proving rather than hoping a test trips over it.
        if (in_flight) assert (s_data_master == p_dm);
    end
endmodule
