// Formal properties for rtl/soc/wb_interconnect.v.
//
// An interconnect's failure modes are the nastiest kind to debug from a
// waveform - two slaves strobed at once, or an ack delivered to the master
// that did not make the request - because they surface far away as corrupted
// data. That makes it worth proving rather than testing.
//
// It became a *sequential* proof when the arbiter gained a lock. The
// memories are now synchronous block RAMs with a wait state, so a transfer
// spans several cycles, and a purely combinational grant would let the data
// master take the bus in the middle of the fetch master's read - after which
// the RAM's ack, which belongs to the fetch master's address, is delivered
// to the data master along with the fetch master's data. Properties 8 and 9
// below are the ones that say that cannot happen.
module fv_interconnect #(
    parameter NUM_SLAVES = 7
)(
    input wire        clk,
    input wire        rst,
    input wire        m0_cyc, m0_stb,
    input wire [31:0] m0_adr,
    input wire        m1_cyc, m1_stb, m1_we,
    input wire [31:0] m1_adr, m1_dat_w,
    input wire [3:0]  m1_sel,
    input wire [NUM_SLAVES*32-1:0] s_dat_r,
    input wire [NUM_SLAVES-1:0]    s_ack
);
    // Fixed, distinct slave bases - the real map from soc_top.v. Held
    // constant rather than left free because `s_base` is a wiring constant in
    // the real design; leaving it free would let the solver invent an aliased
    // map (two slaves at the same base) and then report a "bug" no
    // instantiation can produce.
    wire [NUM_SLAVES*8-1:0] s_base =
        {8'h80, 8'h06, 8'h05, 8'h04, 8'h03, 8'h02, 8'h00};

    wire [31:0] m0_dat_r, m1_dat_r;
    wire        m0_ack, m1_ack;
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
        .s_base(s_base),
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
    end

    reg p_m0_pending, p_m1_pending;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            p_m0_pending <= 1'b0;
            p_m1_pending <= 1'b0;
        end else begin
            p_m0_pending <= m0_cyc && m0_stb && !m0_ack;
            p_m1_pending <= m1_cyc && m1_stb && !m1_ack;
        end
    end
    always @(*) begin
        if (p_m0_pending) assume (m0_cyc && m0_stb);
        if (p_m1_pending) assume (m1_cyc && m1_stb);
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
    wire any_req = (m0_cyc && m0_stb) || (m1_cyc && m1_stb);
    wire any_ack = m0_ack || m1_ack;

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

        // 2. A strobed slave is the one the address actually decodes to.
        for (j = 0; j < NUM_SLAVES; j = j + 1)
            if (s_stb[j])
                assert (s_adr[31:24] == s_base[8*j +: 8]);

        // 3. The bus is only claimed by a master that is asking for it.
        if (s_data_master) assert (m1_cyc);

        // 4. Data outranks fetch whenever arbitration is actually open. The
        //    `!in_flight` qualifier is the whole point of the lock: while a
        //    transfer is under way, priority does not get to preempt it.
        if (m1_cyc && !in_flight) assert (s_data_master);

        // 5. Acks go to the master that made the request, and only to one.
        assert (!(m0_ack && m1_ack));
        if (m0_ack) assert (m0_cyc);
        if (m1_ack) assert (m1_cyc);

        // 6. An access to an address matching no slave still acks. A bus that
        //    never acks wedges the CPU permanently - cpu_wb.v freezes the
        //    pipeline waiting for one - so a stray pointer would become an
        //    unrecoverable hang instead of garbage data the program survives.
        if (m1_cyc && m1_stb && !in_flight && (s_stb == {NUM_SLAVES{1'b0}}))
            assert (m1_ack);

        // 7. The broadcast address belongs to the granted master.
        if (s_data_master) assert (s_adr == m1_adr);
        else if (s_cyc)    assert (s_adr == m0_adr);

        // 8. A fetch never writes. The instruction master has no write path,
        //    so if this could fail a fetch could corrupt memory.
        if (!s_data_master) assert (!s_we);
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
