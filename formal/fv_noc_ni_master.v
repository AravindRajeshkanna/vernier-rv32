// Formal properties for rtl/soc/noc_ni_master.v (Phase 8 Stage 1).
//
// The master interface must never let a second request out while one is
// outstanding, and must ack its master only with a response that is really
// there. Proved over a legal master (it keeps its request, unchanged, until
// acked) and a legal network (a response comes only to a request that was
// sent, and an offered response stays until taken).
module fv_noc_ni_master (
    input wire        clk,
    input wire        rst,
    input wire        wb_cyc,
    input wire        wb_stb,
    input wire        wb_we,
    input wire [31:0] wb_adr,
    input wire [31:0] wb_dat_w,
    input wire [3:0]  wb_sel,
    input wire [3:0]  wb_dst,
    input wire [1:0]  wb_qos,
    input wire        wb_lock,
    input wire        wb_burst,
    input wire        req_ready,
    input wire        rsp_valid,
    input wire [81:0] rsp_pkt
);
    wire [31:0] wb_dat_r;
    wire        wb_ack, wb_err, req_valid, rsp_ready;
    wire [81:0] req_pkt;

    noc_ni_master #(.ID(4'd2)) DUT (
        .clk(clk), .rst(rst),
        .wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we), .wb_adr(wb_adr),
        .wb_dat_w(wb_dat_w), .wb_sel(wb_sel), .wb_dst(wb_dst), .wb_qos(wb_qos),
        .wb_lock(wb_lock), .wb_burst(wb_burst),
        .wb_dat_r(wb_dat_r), .wb_ack(wb_ack), .wb_err(wb_err),
        .req_valid(req_valid), .req_pkt(req_pkt), .req_ready(req_ready),
        .rsp_valid(rsp_valid), .rsp_pkt(rsp_pkt), .rsp_ready(rsp_ready));

    reg f_initialized = 1'b0;
    always @(posedge clk) f_initialized <= 1'b1;
    always @(*) if (!f_initialized) assume (rst);

    // a request has been sent and its last response has not been taken
    reg out;
    always @(posedge clk) begin
        if (rst) out <= 1'b0;
        else if (req_valid && req_ready) out <= 1'b1;
        else if (rsp_valid && rsp_ready && rsp_pkt[81]) out <= 1'b0;
    end

    // ---- the legal master and network ----
    reg        p_ok = 1'b0, p_m = 1'b0, p_r = 1'b0;
    reg [31:0] p_adr, p_dat;
    always @(posedge clk) begin
        p_ok  <= !rst;
        p_m   <= wb_cyc && wb_stb && !(wb_ack || wb_err);   // asking, not yet answered
        p_r   <= rsp_valid && !rsp_ready;
        p_adr <= wb_adr;
        p_dat <= wb_dat_w;
    end
    always @(*) if (f_initialized && !rst) begin
        if (p_ok && p_m) assume (wb_cyc && wb_stb && wb_adr == p_adr && wb_dat_w == p_dat);
        if (rsp_valid) assume (out);                        // only to a request that was sent
        if (p_ok && p_r) assume (rsp_valid);                // an offered response stays
        if (rsp_valid && rsp_pkt[1]) assume (rsp_pkt[81]);  // an error ends the transaction
    end

    always @(*) if (f_initialized && !rst) begin
        // 1. One request at a time.
        if (req_valid) assert (!out);

        // 2. A response is accepted exactly while one is awaited.
        assert (rsp_ready == out);

        // 3. An ack or error reaches the master only with a response that is
        //    there, only while it is asking, and never both.
        if (wb_ack || wb_err) assert (rsp_valid && out && wb_cyc && wb_stb);
        assert (!(wb_ack && wb_err));

        // 4. The request packet carries what the master asked for.
        if (req_valid) begin
            assert (req_pkt[0] == wb_lock && req_pkt[1] == wb_we && req_pkt[5:2] == wb_sel);
            assert (req_pkt[7:6] == wb_qos && req_pkt[11:8] == 4'd2 && req_pkt[15:12] == wb_dst);
            assert (req_pkt[47:16] == wb_adr && req_pkt[79:48] == wb_dat_w && req_pkt[80] == wb_burst);
        end
    end

    always @(*) if (f_initialized && !rst) begin
        cover (req_valid && req_ready);
        cover (wb_ack);
        cover (wb_err);
        cover (rsp_valid && rsp_ready && !rsp_pkt[81]);     // a burst's middle beat
    end
endmodule
