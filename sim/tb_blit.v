// Fill/copy-engine test: drives wb_framebuffer.v's blit-control block
// directly through the Wishbone port (no CPU, no interconnect - the same
// style tb_video.v already uses for the plain pixel path) and checks every
// pixel in the buffer against an independently-tracked expected image, not
// against a second readback of the engine itself.
//
// Fill coverage, in order: an exact-fit fill establishing the whole buffer
// as a known background (also the first real test of the FSM's address
// math across every row); an overlapping fill that must leave everything
// outside its rectangle untouched; a fill clamped at the buffer's
// bottom-right edge; a fill whose origin is entirely off the buffer; two
// degenerate zero-width/height fills; a busy-bit timing check; and a check
// that a CPU write to pixel data is genuinely stalled (not dropped, not
// acked early) while a fill is in progress.
//
// Copy coverage: a per-pixel pattern (not a solid fill) is drawn first, so
// a coordinate or byte-lane bug in the copy path has something to disturb
// that a solid colour couldn't reveal. Then a non-overlapping copy, one
// overlapping copy in each of the four directions a translation can shift
// (+x, -x, +y, -y) plus two diagonal ones, a copy clamped by running the
// source off the buffer edge, and two degenerate copies (an off-buffer
// source origin, a zero width). `expect_copy` models each one by
// snapshotting the source region before writing it to the destination -
// exactly the "read everything, then write" illusion the RTL's
// direction-aware iteration exists to provide - so the expected image is
// never itself vulnerable to the very overlap bug the RTL is being checked
// for. A separate cycle-count check confirms copy runs at roughly half a
// fill's throughput, matching the RTL's single shared read+write port.
`timescale 1ns/1ps
module tb_blit;
    localparam FB_W = 320;
    localparam FB_H = 240;
    localparam BLIT_BASE = 32'h0002_0000;

    reg clk = 0;
    reg rst = 1;
    always #20 clk = ~clk;

    reg         wb_cyc = 0, wb_stb = 0, wb_we = 0;
    reg  [31:0] wb_adr = 0, wb_dat_w = 0;
    reg  [3:0]  wb_sel = 4'hF;
    wire [31:0] wb_dat_r;
    wire        wb_ack;

    // Scan-out port is unused here - tb_video.v already covers it - so tie
    // it to a fixed, never-visible raster position.
    wb_framebuffer #(.FB_WIDTH(FB_W), .FB_HEIGHT(FB_H), .PIXEL_DOUBLE(1)) FB (
        .clk(clk), .rst(rst),
        .wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we),
        .wb_adr(wb_adr), .wb_dat_w(wb_dat_w), .wb_sel(wb_sel),
        .wb_dat_r(wb_dat_r), .wb_ack(wb_ack),
        .vid_x(12'd0), .vid_y(12'd0), .vid_de(1'b0),
        .vid_hsync(1'b1), .vid_vsync(1'b1),
        .vid_r(), .vid_g(), .vid_b(),
        .vid_de_out(), .vid_hsync_out(), .vid_vsync_out()
    );

    integer errors;

    // =====================================================================
    // Bus helpers - same one-wait-state protocol as tb_video.v's.
    // =====================================================================
    task wb_write(input [31:0] addr, input [31:0] data, input [3:0] sel);
        begin
            @(posedge clk);
            wb_adr <= addr; wb_dat_w <= data; wb_sel <= sel;
            wb_cyc <= 1; wb_stb <= 1; wb_we <= 1;
            @(posedge clk);
            while (!wb_ack) @(posedge clk);
            wb_cyc <= 0; wb_stb <= 0; wb_we <= 0;
            @(posedge clk);
        end
    endtask

    task wb_read(input [31:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            wb_adr <= addr; wb_we <= 0; wb_sel <= 4'hF;
            wb_cyc <= 1; wb_stb <= 1;
            @(posedge clk);
            while (!wb_ack) @(posedge clk);
            data = wb_dat_r;
            wb_cyc <= 0; wb_stb <= 0;
            @(posedge clk);
        end
    endtask

    // Counts the clock edges wb_read/wb_write actually waited on ack for -
    // used to prove a stall really happened, not just that the task returned.
    integer wait_cycles;
    task wb_write_timed(input [31:0] addr, input [31:0] data, input [3:0] sel,
                         output integer cycles);
        begin
            @(posedge clk);
            wb_adr <= addr; wb_dat_w <= data; wb_sel <= sel;
            wb_cyc <= 1; wb_stb <= 1; wb_we <= 1;
            cycles = 0;
            @(posedge clk);
            while (!wb_ack) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            wb_cyc <= 0; wb_stb <= 0; wb_we <= 0;
            @(posedge clk);
        end
    endtask

    task blit_write(input [31:0] off, input [31:0] data);
        wb_write(BLIT_BASE + off, data, 4'hF);
    endtask

    task blit_read(input [31:0] off, output [31:0] data);
        wb_read(BLIT_BASE + off, data);
    endtask

    task put_pixel(input integer px, input integer py, input [7:0] colour);
        integer idx;
        begin
            idx = py * FB_W + px;
            wb_write(idx & ~32'd3, {4{colour}}, 4'b0001 << (idx & 3));
        end
    endtask

    task get_pixel(input integer px, input integer py, output [7:0] colour);
        integer idx;
        reg [31:0] word;
        begin
            idx = py * FB_W + px;
            wb_read(idx & ~32'd3, word);
            case (idx & 3)
                0: colour = word[7:0];
                1: colour = word[15:8];
                2: colour = word[23:16];
                default: colour = word[31:24];
            endcase
        end
    endtask

    // Fills [x,x+w) x [y,y+h) with colour and blocks until BLIT_STATUS
    // reports done - the same wait a real driver would use.
    task fill_wait(input integer x, input integer y, input integer w,
                   input integer h, input [7:0] colour);
        reg [31:0] status;
        begin
            blit_write(32'h00, x[31:0]);
            blit_write(32'h04, y[31:0]);
            blit_write(32'h08, w[31:0]);
            blit_write(32'h0C, h[31:0]);
            blit_write(32'h10, {24'b0, colour});
            blit_write(32'h14, 32'h1);
            status = 32'h1;
            while (status[0]) blit_read(32'h18, status);
        end
    endtask

    // Copies [sx,sx+w) x [sy,sy+h) to [dx,dx+w) x [dy,dy+h), clamped and
    // blocked until BLIT_STATUS reports done - the same wait a real driver
    // would use, and the same one fill_wait already uses.
    task copy_wait(input integer dx, input integer dy, input integer sx,
                   input integer sy, input integer w, input integer h);
        reg [31:0] status;
        begin
            blit_write(32'h00, dx[31:0]);
            blit_write(32'h04, dy[31:0]);
            blit_write(32'h08, w[31:0]);
            blit_write(32'h0C, h[31:0]);
            blit_write(32'h1C, sx[31:0]);
            blit_write(32'h20, sy[31:0]);
            blit_write(32'h14, 32'h3);   // bit0 = start, bit1 = copy
            status = 32'h1;
            while (status[0]) blit_read(32'h18, status);
        end
    endtask

    // =====================================================================
    // Expected image, tracked independently of any readback.
    // =====================================================================
    reg [7:0] expected [0:FB_W*FB_H-1];
    reg [7:0] copy_snapshot [0:FB_W*FB_H-1];
    integer x, y, idx;
    reg [7:0] got;

    task expect_rect(input integer rx, input integer ry, input integer rw,
                      input integer rh, input [7:0] colour);
        integer ex, ey;
        begin
            for (ey = ry; ey < ry + rh; ey = ey + 1)
                for (ex = rx; ex < rx + rw; ex = ex + 1)
                    if (ex >= 0 && ex < FB_W && ey >= 0 && ey < FB_H)
                        expected[ey*FB_W + ex] = colour;
        end
    endtask

    // Mirrors the RTL's own clamp (smallest of the requested size and the
    // room left on either side of the translation) and models the copy as
    // "snapshot the whole source, then write the whole destination" -
    // exactly the atomic-looking result the RTL's direction-aware
    // iteration is built to produce for an overlapping copy, computed here
    // without needing that same direction trick, so this model can't share
    // a bug with the thing it's checking.
    task expect_copy(input integer dx, input integer dy, input integer sx,
                      input integer sy, input integer w, input integer h);
        integer ex, ey, cw, ch;
        integer dst_room_w, dst_room_h, src_room_w, src_room_h;
        begin
            if (dx >= FB_W || dy >= FB_H || sx >= FB_W || sy >= FB_H) begin
                cw = 0; ch = 0;
            end else begin
                dst_room_w = FB_W - dx; dst_room_h = FB_H - dy;
                src_room_w = FB_W - sx; src_room_h = FB_H - sy;
                cw = w; if (dst_room_w < cw) cw = dst_room_w;
                        if (src_room_w < cw) cw = src_room_w;
                ch = h; if (dst_room_h < ch) ch = dst_room_h;
                        if (src_room_h < ch) ch = src_room_h;
            end
            for (ey = 0; ey < ch; ey = ey + 1)
                for (ex = 0; ex < cw; ex = ex + 1)
                    copy_snapshot[ey*FB_W + ex] = expected[(sy+ey)*FB_W + (sx+ex)];
            for (ey = 0; ey < ch; ey = ey + 1)
                for (ex = 0; ex < cw; ex = ex + 1)
                    expected[(dy+ey)*FB_W + (dx+ex)] = copy_snapshot[ey*FB_W + ex];
        end
    endtask

    task check_all(input [127:0] label);
        integer mismatches;
        begin
            mismatches = 0;
            for (y = 0; y < FB_H; y = y + 1) begin
                for (x = 0; x < FB_W; x = x + 1) begin
                    get_pixel(x, y, got);
                    if (got !== expected[y*FB_W + x]) begin
                        if (mismatches < 8)
                            $display("  FAIL [%0s] at (%0d,%0d): got %02x expected %02x",
                                     label, x, y, got, expected[y*FB_W + x]);
                        mismatches = mismatches + 1;
                    end
                end
            end
            if (mismatches != 0) begin
                $display("  %0s: %0d pixel mismatches", label, mismatches);
                errors = errors + mismatches;
            end else begin
                $display("  %0s: all %0d pixels match", label, FB_W*FB_H);
            end
        end
    endtask

    reg [31:0] status;
    integer cyc, copy_cyc;

    initial begin
        errors = 0;
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (4) @(posedge clk);

        $display("=== fill engine ===");

        // ---- 1: exact-fit fill establishes the whole buffer ----
        $display("  filling the whole buffer...");
        fill_wait(0, 0, FB_W, FB_H, 8'h49);
        expect_rect(0, 0, FB_W, FB_H, 8'h49);

        // ---- 2: an in-bounds overlay, nowhere near an edge ----
        $display("  filling an interior rectangle...");
        fill_wait(50, 40, 100, 60, 8'hB6);
        expect_rect(50, 40, 100, 60, 8'hB6);

        // ---- 3: clamped at the bottom-right edge ----
        $display("  filling a rectangle clamped at the edge...");
        fill_wait(300, 220, 50, 50, 8'h1C);
        expect_rect(300, 220, 20, 20, 8'h1C);   // clamped to (320,240)

        // ---- 4: origin entirely off the buffer - must draw nothing ----
        $display("  filling a rectangle whose origin is off the buffer...");
        fill_wait(400, 50, 10, 10, 8'hFF);
        // expected[] unchanged

        // ---- 5: zero width, then zero height - must draw nothing ----
        $display("  filling zero-width and zero-height rectangles...");
        fill_wait(10, 10, 0, 10, 8'hFF);
        fill_wait(10, 10, 10, 0, 8'hFF);
        // expected[] unchanged

        check_all("fills");

        // ---- 6: BLIT_STATUS actually reports busy, not just done ----
        $display("  checking BLIT_STATUS reports busy while running...");
        blit_write(32'h00, 32'd0);
        blit_write(32'h04, 32'd0);
        blit_write(32'h08, FB_W[31:0]);
        blit_write(32'h0C, FB_H[31:0]);
        blit_write(32'h10, {24'b0, 8'h2A});
        blit_write(32'h14, 32'h1);
        blit_read(32'h18, status);
        if (!status[0]) begin
            $display("  FAIL: BLIT_STATUS.busy was 0 immediately after starting a %0dx%0d fill",
                     FB_W, FB_H);
            errors = errors + 1;
        end
        cyc = 0;
        while (status[0]) begin
            blit_read(32'h18, status);
            cyc = cyc + 1;
        end
        // A 320x240 fill is 76800 pixel-writes; a handful of polls would mean
        // the busy bit dropped almost immediately, which is not "running".
        if (cyc < 100) begin
            $display("  FAIL: fill reported done after only %0d polls", cyc);
            errors = errors + 1;
        end else begin
            $display("  busy for %0d status polls before completing", cyc);
        end
        expect_rect(0, 0, FB_W, FB_H, 8'h2A);

        // ---- 7: a CPU pixel write genuinely stalls while a fill runs ----
        $display("  checking a pixel write stalls while a fill is busy...");
        blit_write(32'h00, 32'd0);
        blit_write(32'h04, 32'd0);
        blit_write(32'h08, FB_W[31:0]);
        blit_write(32'h0C, FB_H[31:0]);
        blit_write(32'h10, {24'b0, 8'h63});
        blit_write(32'h14, 32'h1);
        // (310,230) is inside this fill's rectangle - proves the CPU's write,
        // once it does land, overwrites what the engine put there, i.e. it
        // was genuinely deferred rather than applied out of order.
        idx = 230 * FB_W + 310;
        wb_write_timed(idx & ~32'd3, {4{8'hD7}}, 4'b0001 << (idx & 3), cyc);
        if (cyc < 100) begin
            $display("  FAIL: pixel write during a fill only waited %0d cycles", cyc);
            errors = errors + 1;
        end else begin
            $display("  pixel write stalled %0d cycles behind the fill", cyc);
        end
        expect_rect(0, 0, FB_W, FB_H, 8'h63);
        expected[230*FB_W + 310] = 8'hD7;
        get_pixel(310, 230, got);
        if (got !== 8'hD7) begin
            $display("  FAIL: stalled pixel write never landed: got %02x expected d7", got);
            errors = errors + 1;
        end

        check_all("busy/stall");

        // =================================================================
        $display("=== copy engine ===");

        // A per-pixel pattern, not a solid colour - a copy that scrambled
        // coordinates or byte lanes would be invisible against a fill.
        // Same formula tb_video.v uses, for the same reason: structure in
        // both axes so a swapped coordinate shows up.
        $display("  drawing a per-pixel pattern...");
        for (y = 0; y < FB_H; y = y + 1) begin
            for (x = 0; x < FB_W; x = x + 1) begin
                got = (x[7:5] << 5) | (y[7:5] << 2) | x[1:0];
                put_pixel(x, y, got);
                expected[y*FB_W + x] = got;
            end
        end

        $display("  non-overlapping copy...");
        copy_wait(200, 10, 10, 10, 40, 30);
        expect_copy(200, 10, 10, 10, 40, 30);

        $display("  overlapping copy, +x shift...");
        copy_wait(30, 60, 10, 60, 60, 40);
        expect_copy(30, 60, 10, 60, 60, 40);

        $display("  overlapping copy, -x shift...");
        copy_wait(130, 60, 150, 60, 60, 40);
        expect_copy(130, 60, 150, 60, 60, 40);

        $display("  overlapping copy, +y shift...");
        copy_wait(10, 130, 10, 110, 50, 30);
        expect_copy(10, 130, 10, 110, 50, 30);

        $display("  overlapping copy, -y shift...");
        copy_wait(10, 160, 10, 180, 50, 30);
        expect_copy(10, 160, 10, 180, 50, 30);

        $display("  overlapping copy, diagonal +x+y shift...");
        copy_wait(220, 80, 200, 60, 50, 30);
        expect_copy(220, 80, 200, 60, 50, 30);

        $display("  overlapping copy, diagonal +x-y shift...");
        copy_wait(220, 120, 200, 140, 50, 30);
        expect_copy(220, 120, 200, 140, 50, 30);

        $display("  copy clamped by the source running off the edge...");
        copy_wait(0, 0, 300, 200, 40, 60);
        expect_copy(0, 0, 300, 200, 40, 60);

        $display("  copy whose source origin is off the buffer...");
        copy_wait(0, 200, 400, 0, 10, 10);
        expect_copy(0, 200, 400, 0, 10, 10);

        $display("  copy with zero width...");
        copy_wait(0, 210, 5, 5, 0, 10);
        expect_copy(0, 210, 5, 5, 0, 10);

        check_all("copies");

        // ---- copy is honestly half a fill's throughput, not asserted ----
        $display("  measuring copy vs. fill cycles for the same area...");
        blit_write(32'h00, 32'd0); blit_write(32'h04, 32'd0);
        blit_write(32'h08, 32'd100); blit_write(32'h0C, 32'd80);
        blit_write(32'h10, {24'b0, 8'hAA});
        blit_write(32'h14, 32'h1);
        cyc = 0; status = 32'h1;
        while (status[0]) begin blit_read(32'h18, status); cyc = cyc + 1; end
        $display("  100x80 fill: %0d status polls", cyc);
        expect_rect(0, 0, 100, 80, 8'hAA);

        blit_write(32'h1C, 32'd120); blit_write(32'h20, 32'd0);
        blit_write(32'h14, 32'h3);
        copy_cyc = 0; status = 32'h1;
        while (status[0]) begin blit_read(32'h18, status); copy_cyc = copy_cyc + 1; end
        $display("  100x80 copy: %0d status polls", copy_cyc);
        expect_copy(0, 0, 120, 0, 100, 80);

        if (copy_cyc < cyc + (cyc / 2)) begin
            $display("  FAIL: copy (%0d polls) was not meaningfully slower than fill (%0d polls)",
                     copy_cyc, cyc);
            errors = errors + 1;
        end

        check_all("throughput");

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("BLIT TEST PASSED");
        else             $display("BLIT TEST FAILED (%0d errors)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("TIMEOUT - the blit test never completed");
        $finish;
    end
endmodule
