// Formal properties for rtl/soc/wb_interconnect.v.
//
// An interconnect is almost entirely combinational routing, which makes it a
// natural formal target: the properties are "the right slave got selected"
// and "the right master got the answer", over every address and every
// combination of master requests at once. Its failure modes are also the
// nastiest kind to debug from a waveform - two slaves strobed at the same
// time, or an ack delivered to the master that did not make the request -
// because they surface far away as corrupted data.
module fv_interconnect #(
    parameter NUM_SLAVES = 7
)(
    input wire        m0_cyc, m0_stb,
    input wire [31:0] m0_adr,
    input wire        m1_cyc, m1_stb, m1_we,
    input wire [31:0] m1_adr, m1_dat_w,
    input wire [3:0]  m1_sel,
    input wire [NUM_SLAVES*32-1:0] s_dat_r,
    input wire [NUM_SLAVES-1:0]    s_ack
);
    // Fixed, distinct slave bases - the real map from soc_top.v. They are
    // held constant rather than left free because `s_base` is a wiring
    // constant in the real design, and leaving it free would let the solver
    // invent an aliased map (two slaves at the same base) and then report a
    // "bug" that no instantiation can produce.
    wire [NUM_SLAVES*8-1:0] s_base =
        {8'h80, 8'h06, 8'h05, 8'h04, 8'h03, 8'h02, 8'h00};

    wire [31:0] m0_dat_r, m1_dat_r;
    wire        m0_ack, m1_ack;
    wire        s_cyc, s_we, s_data_master;
    wire [NUM_SLAVES-1:0] s_stb;
    wire [31:0] s_adr, s_dat_w;
    wire [3:0]  s_sel;

    wb_interconnect #(.NUM_SLAVES(NUM_SLAVES)) DUT (
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

    integer j;
    reg [3:0] stb_count;
    always @(*) begin
        stb_count = 4'd0;
        for (j = 0; j < NUM_SLAVES; j = j + 1)
            stb_count = stb_count + {3'b0, s_stb[j]};
    end

    // Purely combinational logic, so a single unrolled step proves it for
    // every input combination; no clock or reset is involved.
    always @(*) begin
        // 1. At most one slave is ever strobed. Two slaves answering the
        //    same cycle drive the shared response mux against each other.
        assert (stb_count <= 4'd1);

        // 2. A strobed slave is the one the address actually decodes to.
        for (j = 0; j < NUM_SLAVES; j = j + 1)
            if (s_stb[j])
                assert (s_adr[31:24] == s_base[8*j +: 8]);

        // 3. Exactly one master is granted, and data outranks fetch. This is
        //    load-bearing beyond tidiness: cpu_wb.v gets atomicity for its
        //    AMO read-modify-write purely from the data master holding `cyc`
        //    and therefore continuing to win. If fetch could ever win while
        //    m1_cyc is high, an AMO would stop being atomic.
        assert (!(s_data_master && !m1_cyc));
        if (m1_cyc) assert (s_data_master);

        // 4. Acks go to the master that made the request, and only to one.
        assert (!(m0_ack && m1_ack));
        if (m0_ack) assert (m0_cyc && !m1_cyc);
        if (m1_ack) assert (m1_cyc);

        // 5. An access to an address matching no slave still acks. A bus
        //    that never acks wedges the CPU permanently, because cpu_wb.v
        //    freezes the pipeline waiting for one - so a stray pointer would
        //    become an unrecoverable hang instead of garbage data the
        //    running program can survive.
        if (m1_cyc && m1_stb && (s_stb == {NUM_SLAVES{1'b0}}))
            assert (m1_ack);
        if (m0_cyc && !m1_cyc && m0_stb && (s_stb == {NUM_SLAVES{1'b0}}))
            assert (m0_ack);

        // 6. The broadcast address is the granted master's address.
        if (m1_cyc)                assert (s_adr == m1_adr);
        else if (m0_cyc)           assert (s_adr == m0_adr);

        // 7. A fetch never writes. The instruction master has no write path
        //    at all, so if this could fail, a fetch could corrupt memory.
        if (!m1_cyc) assert (!s_we);
    end
endmodule
