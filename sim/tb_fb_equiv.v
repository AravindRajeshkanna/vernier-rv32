// rtl/soc/wb_framebuffer.v held equal, cycle for cycle, to the module it was restructured from
// (sim/wb_framebuffer_ref.v, the same file as it stood before its memory writes moved out of the FSM's
// asynchronous-reset block into one clock-only write port; docs/roadmap/index.md, "Common known defects").
//
// The restructure exists so that yosys sees block RAM instead of 614,400 flip-flops (fpga/synth/framebuffer_synth.sh
// holds that), and it had to change nothing a program or a monitor can see. tb_blit.v and tb_video.v check the engine
// and the scan-out against images they model themselves; they would not notice a write that happens one cycle later, or
// to the wrong lane in a corner nobody drew. This does not model anything. It drives the same traffic into both
// modules and compares what comes out of them, every cycle, and what is stored in them, every 1,000 cycles and at the
// end. Any difference at all fails.
//
// Traffic, per shape (three shapes: 16x12 pixel-doubled, 20x15 not doubled - both with banks that are not a power of
// two, so the divide and modulo in the address decode are exercised - and the real 320x240):
//   - CPU pixel writes with every byte-enable pattern, to every bank and past the end of the buffer, and pixel reads;
//   - the nine control registers written and read, including values far outside the buffer (the clamps);
//   - fill, copy and line operations, started and left to run while the CPU keeps trying to use the buffer (those
//     accesses stall in the module; that is part of what is compared), some with a reset in the middle of them;
//   - a master that sometimes holds its strobe for a cycle after the ack, and sometimes gives up while waiting;
//   - the raster scan, with the position jumping about at random now and then, off the edge of the buffer included.
// Both modules see exactly the same inputs; none of them has to be a legal bus cycle for the comparison to mean
// something, but most of them are, because a legal one is what reaches the interesting states.
//
// A pass that did not exercise anything is not a pass, so the run also requires: every bank written by the CPU, every
// byte lane written by the engine, all sixteen byte-enable patterns, every operation busy for a while, a line that
// was clipped, a reset in the middle of an operation, and a non-zero word in every bank at the end.
`timescale 1ns/1ps

module fb_equiv_pair #(
    parameter FB_W   = 16,
    parameter FB_H   = 12,
    parameter PD     = 1,
    parameter SEED   = 1,
    parameter CYCLES = 200000,
    parameter SMALL  = 0          // 1: keep operations small (the 320x240 shape would spend a long time on a full-screen fill)
)(
    input  wire clk,
    output reg  done,
    output reg  failed
);
    localparam BLIT = 32'h0002_0000;
    localparam WORDS = (FB_W * FB_H + 3) / 4;
    localparam NBANKS = 8;
    localparam BANK_WORDS = (WORDS + NBANKS - 1) / NBANKS;

    reg         rst;
    reg         wb_cyc, wb_stb, wb_we;
    reg  [31:0] wb_adr, wb_dat_w;
    reg  [3:0]  wb_sel;
    reg  [11:0] vid_x, vid_y;
    reg         vid_de, vid_hsync, vid_vsync;

    wire [31:0] n_dat_r, r_dat_r;
    wire        n_ack, r_ack;
    wire [7:0]  n_r, n_g, n_b, r_r, r_g, r_b;
    wire        n_de, n_hs, n_vs, r_de, r_hs, r_vs;

    wb_framebuffer #(.FB_WIDTH(FB_W), .FB_HEIGHT(FB_H), .PIXEL_DOUBLE(PD)) NEW (
        .clk(clk), .rst(rst),
        .wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we),
        .wb_adr(wb_adr), .wb_dat_w(wb_dat_w), .wb_sel(wb_sel),
        .wb_dat_r(n_dat_r), .wb_ack(n_ack),
        .vid_x(vid_x), .vid_y(vid_y), .vid_de(vid_de), .vid_hsync(vid_hsync), .vid_vsync(vid_vsync),
        .vid_r(n_r), .vid_g(n_g), .vid_b(n_b),
        .vid_de_out(n_de), .vid_hsync_out(n_hs), .vid_vsync_out(n_vs)
    );
    wb_framebuffer_ref #(.FB_WIDTH(FB_W), .FB_HEIGHT(FB_H), .PIXEL_DOUBLE(PD)) REF (
        .clk(clk), .rst(rst),
        .wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we),
        .wb_adr(wb_adr), .wb_dat_w(wb_dat_w), .wb_sel(wb_sel),
        .wb_dat_r(r_dat_r), .wb_ack(r_ack),
        .vid_x(vid_x), .vid_y(vid_y), .vid_de(vid_de), .vid_hsync(vid_hsync), .vid_vsync(vid_vsync),
        .vid_r(r_r), .vid_g(r_g), .vid_b(r_b),
        .vid_de_out(r_de), .vid_hsync_out(r_hs), .vid_vsync_out(r_vs)
    );

    // ---- randomness: one seed per shape, so a failure reproduces ----
    integer seed;
    function [31:0] rnd32(input integer dummy);
        begin rnd32 = $random(seed); end
    endfunction
    function integer rnd(input integer n);          // 0 .. n-1
        reg [31:0] r;
        begin r = $random(seed); rnd = (r >> 1) % n; end
    endfunction

    // ---- the comparison ----
    integer cycle_n;
    integer mism;
    wire [31+1+24+3:0] n_all = {n_dat_r, n_ack, n_r, n_g, n_b, n_de, n_hs, n_vs};
    wire [31+1+24+3:0] r_all = {r_dat_r, r_ack, r_r, r_g, r_b, r_de, r_hs, r_vs};
    always @(negedge clk) begin
        cycle_n = cycle_n + 1;
        if (cycle_n > 4 && n_all !== r_all) begin
            mism = mism + 1;
            if (mism <= 6)
                $display("MISMATCH %0dx%0d at cycle %0d: new %h  ref %h", FB_W, FB_H, cycle_n, n_all, r_all);
        end
    end

    // Every stored word, bank by bank. `===`, so an unknown against a zero is a difference too.
    integer w;
    integer words_bad;
    integer nz [0:7];
    task compare_memories;
        integer bk;
        begin
            for (bk = 0; bk < 8; bk = bk + 1) nz[bk] = 0;
            for (w = 0; w < BANK_WORDS; w = w + 1) begin
                if (NEW.mem0[w] !== REF.mem0[w]) words_bad = words_bad + 1;
                if (NEW.mem1[w] !== REF.mem1[w]) words_bad = words_bad + 1;
                if (NEW.mem2[w] !== REF.mem2[w]) words_bad = words_bad + 1;
                if (NEW.mem3[w] !== REF.mem3[w]) words_bad = words_bad + 1;
                if (NEW.mem4[w] !== REF.mem4[w]) words_bad = words_bad + 1;
                if (NEW.mem5[w] !== REF.mem5[w]) words_bad = words_bad + 1;
                if (NEW.mem6[w] !== REF.mem6[w]) words_bad = words_bad + 1;
                if (NEW.mem7[w] !== REF.mem7[w]) words_bad = words_bad + 1;
                if (REF.mem0[w] != 0) nz[0] = nz[0] + 1;
                if (REF.mem1[w] != 0) nz[1] = nz[1] + 1;
                if (REF.mem2[w] != 0) nz[2] = nz[2] + 1;
                if (REF.mem3[w] != 0) nz[3] = nz[3] + 1;
                if (REF.mem4[w] != 0) nz[4] = nz[4] + 1;
                if (REF.mem5[w] != 0) nz[5] = nz[5] + 1;
                if (REF.mem6[w] != 0) nz[6] = nz[6] + 1;
                if (REF.mem7[w] != 0) nz[7] = nz[7] + 1;
            end
        end
    endtask
    always @(negedge clk) if (cycle_n > 4 && cycle_n % 1000 == 0) compare_memories;

    // ---- coverage, read off the reference's own internals ----
    integer cov_cpu_bank [0:7];
    integer cov_eng_lane [0:3];
    integer cov_sel [0:15];
    integer cov_busy_fill, cov_busy_copy, cov_busy_line, cov_line_clipped, cov_reset_busy, cov_ops, cov_wait_aborts;
    wire eng_writes = REF.blit_busy_r && !(REF.blit_op_r == 2'd1 && !REF.copy_phase_r) &&
                      (REF.blit_op_r != 2'd2 || REF.line_plot_ok);
    wire cpu_writes = REF.a_en && wb_we && !REF.ack_r && !REF.blit_busy_r && !REF.is_blit_region && !rst;
    integer k;
    initial begin
        for (k = 0; k < 8; k = k + 1) cov_cpu_bank[k] = 0;
        for (k = 0; k < 4; k = k + 1) cov_eng_lane[k] = 0;
        for (k = 0; k < 16; k = k + 1) cov_sel[k] = 0;
        cov_busy_fill = 0; cov_busy_copy = 0; cov_busy_line = 0; cov_line_clipped = 0;
        cov_reset_busy = 0; cov_ops = 0; cov_wait_aborts = 0;
        mism = 0; words_bad = 0; cycle_n = 0;
    end
    always @(posedge clk) if (!rst) begin
        if (cpu_writes) begin
            cov_cpu_bank[REF.a_bank] = cov_cpu_bank[REF.a_bank] + 1;
            cov_sel[wb_sel] = cov_sel[wb_sel] + 1;
        end
        if (eng_writes) cov_eng_lane[REF.blit_byte_lane] = cov_eng_lane[REF.blit_byte_lane] + 1;
        if (REF.blit_busy_r && REF.blit_op_r == 2'd0) cov_busy_fill = cov_busy_fill + 1;
        if (REF.blit_busy_r && REF.blit_op_r == 2'd1) cov_busy_copy = cov_busy_copy + 1;
        if (REF.blit_busy_r && REF.blit_op_r == 2'd2) begin
            cov_busy_line = cov_busy_line + 1;
            if (!REF.line_plot_ok) cov_line_clipped = cov_line_clipped + 1;
        end
    end

    // ---- the raster, jumping about now and then ----
    integer rx, ry;
    initial begin rx = 0; ry = 0; vid_x = 0; vid_y = 0; vid_de = 0; vid_hsync = 1; vid_vsync = 1; end
    always @(posedge clk) begin
        #1;
        if (rnd(16) == 0) begin
            vid_x = rnd(4096);
            vid_y = rnd(4096);
        end else begin
            rx = rx + 1;
            if (rx >= FB_W * (PD ? 2 : 1) + 6) begin
                rx = 0;
                ry = ry + 1;
                if (ry >= FB_H * (PD ? 2 : 1) + 3) ry = 0;
            end
            vid_x = rx;
            vid_y = ry;
        end
        vid_de    = (rx < FB_W * (PD ? 2 : 1)) && (ry < FB_H * (PD ? 2 : 1));
        vid_hsync = !(rx >= FB_W * (PD ? 2 : 1) + 2 && rx < FB_W * (PD ? 2 : 1) + 4);
        vid_vsync = !(ry == FB_H * (PD ? 2 : 1) + 1);
    end

    // ---- the CPU's side ----
    localparam MAXWAIT = 2000;
    // One bus cycle. Holds the strobe until the ack (or gives up after `abort_at` cycles of waiting, if that is
    // non-negative), then sometimes keeps it for a cycle more, like a master that is a little slow to drop it.
    task xfer(input we, input [31:0] adr, input [31:0] dat, input [3:0] sel, input integer abort_at);
        integer waited;
        integer extra;
        begin
            wb_cyc = 1; wb_stb = 1; wb_we = we; wb_adr = adr; wb_dat_w = dat; wb_sel = sel;
            waited = 0;
            @(posedge clk); #1;
            while (!n_ack && waited < MAXWAIT && !(abort_at >= 0 && waited >= abort_at)) begin
                waited = waited + 1;
                @(posedge clk); #1;
            end
            if (!n_ack && abort_at >= 0 && waited >= abort_at) cov_wait_aborts = cov_wait_aborts + 1;
            extra = (rnd(8) == 0) ? 1 + rnd(2) : 0;
            while (extra > 0) begin @(posedge clk); #1; extra = extra - 1; end
            wb_cyc = 0; wb_stb = 0; wb_we = 0;
            // idle bus: junk the module must ignore
            wb_adr = rnd32(0); wb_dat_w = rnd32(0); wb_sel = rnd(16);
            extra = rnd(4);
            while (extra > 0) begin @(posedge clk); #1; extra = extra - 1; end
        end
    endtask

    // A pixel-region address: word w (which may be past the end of the buffer), junk in the bits the module ignores.
    function [31:0] pix_adr(input integer wd);
        begin pix_adr = {rnd32(0) & 32'hFFFC_0000, 1'b0, 17'd0} | ((wd << 2) & 32'h0001_FFFC) | (rnd(4)); end
    endfunction
    function [31:0] reg_adr(input integer r);
        begin reg_adr = (rnd32(0) & 32'hFFFC_0000) | BLIT | ((r << 2) & 32'h3C) | rnd(4); end
    endfunction

    // A reset pulse, sometimes with a CPU write held on the bus all the way through it and for a cycle after: the module
    // writes nothing while it is in reset, and the first cycle out of reset is an ordinary one.
    task reset_pulse;
        integer t;
        begin
            rst = 1;
            if (rnd(2) == 0) begin
                wb_cyc = 1; wb_stb = 1; wb_we = 1; wb_adr = pix_adr(rnd(WORDS + 8)); wb_dat_w = rnd32(0); wb_sel = 1 + rnd(15);
            end
            t = 1 + rnd(3);
            while (t > 0) begin @(posedge clk); #1; t = t - 1; end
            rst = 0;
            if (wb_stb) begin @(posedge clk); #1; end
            wb_cyc = 0; wb_stb = 0; wb_we = 0;
        end
    endtask

    task pixel_write;
        reg [3:0] s;
        begin
            s = rnd(4) == 0 ? 4'hF : rnd(16);
            xfer(1'b1, pix_adr(rnd(WORDS + 8)), rnd32(0), s, (rnd(6) == 0) ? rnd(6) : -1);
        end
    endtask
    task pixel_read;
        begin xfer(1'b0, pix_adr(rnd(WORDS + 8)), rnd32(0), rnd(16), (rnd(6) == 0) ? rnd(6) : -1); end
    endtask
    task reg_read;
        begin xfer(1'b0, reg_adr(rnd(16)), rnd32(0), 4'hF, -1); end
    endtask

    // A coordinate or size: mostly small and on the buffer, sometimes exactly at its edge, sometimes absurd.
    function [11:0] pick(input integer limit);
        integer c;
        begin
            c = rnd(16);
            if (c < 10)      pick = rnd(limit + 1);
            else if (c < 12) pick = limit;
            else if (c < 13) pick = 0;
            else if (c < 14) pick = limit - 1;
            else if (c < 15) pick = 4095;
            else             pick = rnd(4096);
        end
    endfunction
    function [11:0] pick_size(input integer limit);
        begin pick_size = SMALL ? 1 + rnd(8) : ((rnd(8) == 0) ? pick(limit) : 1 + rnd(limit)); end
    endfunction

    // A line longer than about 2,000 pixels never finishes in the module (and in the reference, which is the same
    // there): the Bresenham step doubles a 13-bit error term into 13 bits (docs/roadmap/phase-10-gpu.md, Known defects).
    // Equal is equal, but the engine would sit busy until the next reset and the run would learn nothing, so the end
    // points of a line stay far under that (LINE_MAX, still many times the size of the buffer). Fill and copy take
    // any 12-bit value: they clamp.
    localparam LINE_MAX = 300;
    function [11:0] line_end(input [11:0] v);
        reg [11:0] near;
        begin
            near = 2 * ((FB_W > FB_H) ? FB_W : FB_H) + 1;        // most lines start and end on or near the buffer
            line_end = (v <= near) ? v : ((rnd(8) == 0) ? (v % LINE_MAX) : (v % near));
        end
    endfunction

    task setup_regs(input integer op);
        reg [11:0] x0, y0, x1, y1;
        begin
            x0 = pick(FB_W); y0 = pick(FB_H); x1 = pick(FB_W); y1 = pick(FB_H);
            if (op == 2) begin x0 = line_end(x0); y0 = line_end(y0); x1 = line_end(x1); y1 = line_end(y1); end
            xfer(1'b1, reg_adr(0), x0,                4'hF, -1);   // BLIT_X
            xfer(1'b1, reg_adr(1), y0,                4'hF, -1);   // BLIT_Y
            xfer(1'b1, reg_adr(2), pick_size(FB_W),   4'hF, -1);   // BLIT_W
            xfer(1'b1, reg_adr(3), pick_size(FB_H),   4'hF, -1);   // BLIT_H
            xfer(1'b1, reg_adr(4), rnd32(0),          4'hF, -1);   // BLIT_COLOR
            xfer(1'b1, reg_adr(7), x1,                4'hF, -1);   // BLIT_SRC_X
            xfer(1'b1, reg_adr(8), y1,                4'hF, -1);   // BLIT_SRC_Y
        end
    endtask

    // Start an operation, then keep using the bus while it runs, sometimes reset in the middle of it.
    task blit_op;
        integer op, n, spin, do_reset, t;
        begin
            op = rnd(3);
            setup_regs(op);
            cov_ops = cov_ops + 1;
            xfer(1'b1, reg_adr(5), {29'd0, op[1:0], 1'b1}, 4'hF, -1);   // BLIT_CTRL
            do_reset = (rnd(6) == 0);
            if (do_reset) begin                   // a reset a few cycles into the operation, while it is running
                t = 1 + rnd(6);
                while (t > 0) begin @(posedge clk); #1; t = t - 1; end
                if (REF.blit_busy_r) cov_reset_busy = cov_reset_busy + 1;
                reset_pulse;
            end
            n = 1 + rnd(40);
            for (spin = 0; spin < n; spin = spin + 1) begin
                case (rnd(5))
                    0: reg_read;
                    1: pixel_read;
                    2: pixel_write;
                    3: xfer(1'b0, reg_adr(6), 32'd0, 4'hF, -1);       // STATUS
                    default: begin @(posedge clk); #1; end
                endcase
            end
            // let it finish: poll STATUS (bounded)
            spin = 0;
            while (REF.blit_busy_r && spin < 100000) begin
                if (rnd(4) == 0) xfer(1'b0, reg_adr(6), 32'd0, 4'hF, -1);
                else begin @(posedge clk); #1; end
                spin = spin + 1;
            end
        end
    endtask

    // ---- the run ----
    integer i, bad;
    initial begin
        done = 0; failed = 0;
        seed = SEED;
        rst = 1; wb_cyc = 0; wb_stb = 0; wb_we = 0; wb_adr = 0; wb_dat_w = 0; wb_sel = 4'hF;
        repeat (4) @(posedge clk);
        #1 rst = 0;
        setup_regs(0);                        // every register written once before anything reads or uses it
        while (cycle_n < CYCLES) begin
            case (rnd(12))
                0, 1, 2, 3: pixel_write;
                4, 5:       pixel_read;
                6:          reg_read;
                7:          begin : any_reg                       // any register, junk value - but never a start bit:
                                reg [31:0] v;                     // operations are started by blit_op, with bounded parameters
                                integer ri;
                                ri = rnd(16);
                                v = (ri == 5) ? (pick(4095) & ~32'd1) : pick(4095);
                                xfer(1'b1, reg_adr(ri), v, 4'hF, -1);
                            end
                8, 9, 10:   blit_op;
                default: begin
                    if (rnd(40) == 0) reset_pulse;     // a reset between operations
                    else begin @(posedge clk); #1; end
                end
            endcase
        end
        repeat (4) @(posedge clk);
        compare_memories;

        bad = 0;
        if (mism != 0)      begin $display("FAIL %0dx%0d: %0d cycles with a different output", FB_W, FB_H, mism); bad = 1; end
        if (words_bad != 0) begin $display("FAIL %0dx%0d: %0d stored words differ", FB_W, FB_H, words_bad); bad = 1; end
        for (i = 0; i < 8; i = i + 1) begin
            if (cov_cpu_bank[i] == 0 && i * BANK_WORDS < WORDS) begin $display("FAIL %0dx%0d: the CPU never wrote bank %0d", FB_W, FB_H, i); bad = 1; end
            if (nz[i] == 0 && i * BANK_WORDS < WORDS)           begin $display("FAIL %0dx%0d: bank %0d holds only zeros at the end", FB_W, FB_H, i); bad = 1; end
        end
        for (i = 0; i < 4; i = i + 1)
            if (cov_eng_lane[i] == 0) begin $display("FAIL %0dx%0d: the engine never wrote byte lane %0d", FB_W, FB_H, i); bad = 1; end
        for (i = 0; i < 16; i = i + 1)
            if (cov_sel[i] == 0) begin $display("FAIL %0dx%0d: byte-enable pattern %b never written", FB_W, FB_H, i[3:0]); bad = 1; end
        if (cov_busy_fill < 50 || cov_busy_copy < 50 || cov_busy_line < 50) begin
            $display("FAIL %0dx%0d: too little engine activity (fill %0d, copy %0d, line %0d busy cycles)", FB_W, FB_H, cov_busy_fill, cov_busy_copy, cov_busy_line); bad = 1; end
        if (cov_line_clipped == 0) begin $display("FAIL %0dx%0d: no line was ever clipped", FB_W, FB_H); bad = 1; end
        if (cov_reset_busy == 0)   begin $display("FAIL %0dx%0d: no reset ever landed in the middle of an operation", FB_W, FB_H); bad = 1; end
        $display("%0dx%0d%s: %0d cycles, %0d operations; busy cycles fill %0d copy %0d line %0d (%0d clipped); %0d resets mid-operation; %0d abandoned waits; %0d differing outputs, %0d differing words",
                 FB_W, FB_H, PD ? " doubled" : "", cycle_n, cov_ops, cov_busy_fill, cov_busy_copy, cov_busy_line, cov_line_clipped,
                 cov_reset_busy, cov_wait_aborts, mism, words_bad);
        failed = bad;
        done = 1;
    end
endmodule

module tb_fb_equiv;
    reg clk = 0;
    always #5 clk = ~clk;

    wire done_a, done_b, done_c, bad_a, bad_b, bad_c;
    fb_equiv_pair #(.FB_W(16),  .FB_H(12),  .PD(1), .SEED(11), .CYCLES(200000), .SMALL(0)) A (.clk(clk), .done(done_a), .failed(bad_a));
    fb_equiv_pair #(.FB_W(20),  .FB_H(15),  .PD(0), .SEED(22), .CYCLES(200000), .SMALL(0)) B (.clk(clk), .done(done_b), .failed(bad_b));
    fb_equiv_pair #(.FB_W(320), .FB_H(240), .PD(1), .SEED(33), .CYCLES(200000), .SMALL(1)) C (.clk(clk), .done(done_c), .failed(bad_c));

    initial begin
        wait (done_a && done_b && done_c);
        #20;
        if (bad_a || bad_b || bad_c) $display("FRAMEBUFFER EQUIVALENCE FAILED");
        else                         $display("FRAMEBUFFER EQUIVALENCE PASSED");
        $finish;
    end

    // a run that does not end is a failure, not a hang
    initial begin
        #4000000000;
        $display("FRAMEBUFFER EQUIVALENCE FAILED: timeout");
        $finish;
    end
endmodule
