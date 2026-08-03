// Framebuffer and scan-out test: draws a known pattern through the Wishbone
// port, captures a full frame off the video output, and checks the pixels
// that came out are the pixels that went in.
//
// This is the whole verification story for the video path while there is no
// display attached. It writes the captured frame to sim/frame.ppm as well, so
// a human can look at it - but the pass/fail is the readback comparison, not
// the image. A picture that looks plausible is not evidence; a picture that
// matches what was written is.
//
// The framebuffer is driven directly here rather than by the CPU. tb_soc.v
// already proves the CPU can reach a Wishbone slave, and doing it directly
// makes this test about the video path rather than about software.
`timescale 1ns/1ps
module tb_video;
    localparam FB_W = 320;
    localparam FB_H = 240;

    // 640x480 raster, so a frame is 800x525 clocks including blanking.
    localparam H_TOTAL = 800;
    localparam V_TOTAL = 525;

    reg clk = 0;
    reg rst = 1;
    always #20 clk = ~clk;          // 25 MHz, the CPU's own clock

    // ---- Wishbone master (this testbench) ----
    reg         wb_cyc = 0, wb_stb = 0, wb_we = 0;
    reg  [31:0] wb_adr = 0, wb_dat_w = 0;
    reg  [3:0]  wb_sel = 4'hF;
    wire [31:0] wb_dat_r;
    wire        wb_ack;

    wire [11:0] raster_x, raster_y;
    wire        raster_de, raster_hsync, raster_vsync, raster_frame_start;

    video_timing VTIMING (
        .clk(clk), .rst(rst),
        .x(raster_x), .y(raster_y), .de(raster_de),
        .hsync(raster_hsync), .vsync(raster_vsync),
        .frame_start(raster_frame_start)
    );

    wire [7:0] vid_r, vid_g, vid_b;
    wire       vid_de, vid_hsync, vid_vsync;

    wb_framebuffer #(.FB_WIDTH(FB_W), .FB_HEIGHT(FB_H), .PIXEL_DOUBLE(1)) FB (
        .clk(clk), .rst(rst),
        .wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we),
        .wb_adr(wb_adr), .wb_dat_w(wb_dat_w), .wb_sel(wb_sel),
        .wb_dat_r(wb_dat_r), .wb_ack(wb_ack),
        .vid_x(raster_x), .vid_y(raster_y), .vid_de(raster_de),
        .vid_hsync(raster_hsync), .vid_vsync(raster_vsync),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .vid_de_out(vid_de),
        .vid_hsync_out(vid_hsync), .vid_vsync_out(vid_vsync)
    );

    // =====================================================================
    // Bus helpers
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

    // One pixel, via a byte-lane write - the access a software `sb` produces.
    task put_pixel(input integer px, input integer py, input [7:0] colour);
        integer idx;
        begin
            idx = py * FB_W + px;
            wb_write(idx & ~32'd3, {4{colour}}, 4'b0001 << (idx & 3));
        end
    endtask

    // =====================================================================
    // Expected image, built alongside the writes
    // =====================================================================
    reg [7:0] expected [0:FB_W*FB_H-1];
    reg [7:0] captured [0:FB_W*FB_H-1];

    integer x, y, errors, captured_px;

    // Reference expansion, mirroring wb_framebuffer.v's RRRGGGBB -> RGB888.
    function [7:0] exp_r(input [7:0] p); exp_r = {p[7:5], p[7:5], p[7:6]}; endfunction
    function [7:0] exp_g(input [7:0] p); exp_g = {p[4:2], p[4:2], p[4:3]}; endfunction
    function [7:0] exp_b(input [7:0] p); exp_b = {p[1:0], p[1:0], p[1:0], p[1:0]}; endfunction

    // =====================================================================
    // Capture: sample the pixel stream for one whole frame
    // =====================================================================
    integer cap_x, cap_y, fd;
    reg     capturing;

    initial begin
        capturing   = 0;
        cap_x       = 0;
        cap_y       = 0;
        captured_px = 0;
    end

    // The video outputs are registered, so `vid_de` and the RGB beside it
    // belong to the same pixel. Screen coordinates are counted from the
    // stream itself rather than from the raster counters, so a capture that
    // drifts is a failure rather than something this hides.
    always @(posedge clk) begin
        if (capturing && !rst) begin
            if (vid_de) begin
                // Pixel-doubled: only the even screen pixel of each pair, and
                // only even lines, correspond to a distinct buffer pixel.
                if ((cap_x[0] == 1'b0) && (cap_y[0] == 1'b0) &&
                    (cap_x[11:1] < FB_W) && (cap_y[11:1] < FB_H)) begin
                    captured[cap_y[11:1] * FB_W + cap_x[11:1]] <=
                        {vid_r[7:5], vid_g[7:5], vid_b[7:6]};
                    captured_px = captured_px + 1;
                end
                cap_x = cap_x + 1;
            end
            // End of a visible line: `de` falling.
            if (!vid_de && (cap_x != 0)) begin
                cap_x = 0;
                cap_y = cap_y + 1;
            end
        end
    end

    // =====================================================================
    initial begin
        errors = 0;
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (4) @(posedge clk);

        $display("=== framebuffer + scan-out ===");
        $display("  drawing %0dx%0d...", FB_W, FB_H);

        // A pattern with structure in both axes and all three channels, so a
        // swapped coordinate, a dropped bit or a wrong byte lane all show up.
        for (y = 0; y < FB_H; y = y + 1) begin
            for (x = 0; x < FB_W; x = x + 1) begin
                expected[y*FB_W + x] = (x[7:5] << 5) | (y[7:5] << 2) | x[1:0];
            end
        end

        // Write it through the bus one pixel at a time. Slow, and
        // deliberately so: this is the access pattern software actually uses.
        for (y = 0; y < FB_H; y = y + 1)
            for (x = 0; x < FB_W; x = x + 1)
                put_pixel(x, y, expected[y*FB_W + x]);

        $display("  wrote %0d pixels, capturing a frame...", FB_W*FB_H);

        // Start clean at the top of a frame.
        @(posedge raster_frame_start);
        @(posedge clk);
        cap_x = 0; cap_y = 0; captured_px = 0;
        capturing = 1;

        // One full frame, plus slack for the registered outputs.
        repeat (H_TOTAL * V_TOTAL + 16) @(posedge clk);
        capturing = 0;

        $display("  captured %0d distinct buffer pixels", captured_px);
        if (captured_px != FB_W*FB_H) begin
            $display("  FAIL: expected %0d, got %0d", FB_W*FB_H, captured_px);
            errors = errors + 1;
        end

        // ---- compare ----
        for (y = 0; y < FB_H; y = y + 1) begin
            for (x = 0; x < FB_W; x = x + 1) begin
                if (captured[y*FB_W + x] !== expected[y*FB_W + x]) begin
                    if (errors < 8)
                        $display("  FAIL at (%0d,%0d): got %02x expected %02x",
                                 x, y, captured[y*FB_W + x], expected[y*FB_W + x]);
                    errors = errors + 1;
                end
            end
        end

        // ---- write the frame out for a human to look at ----
        fd = $fopen("frame.ppm", "w");
        $fwrite(fd, "P3\n%0d %0d\n255\n", FB_W, FB_H);
        for (y = 0; y < FB_H; y = y + 1) begin
            for (x = 0; x < FB_W; x = x + 1)
                $fwrite(fd, "%0d %0d %0d\n",
                        exp_r(captured[y*FB_W + x]),
                        exp_g(captured[y*FB_W + x]),
                        exp_b(captured[y*FB_W + x]));
        end
        $fclose(fd);
        $display("  wrote sim/frame.ppm");

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("VIDEO TEST PASSED");
        else             $display("VIDEO TEST FAILED (%0d pixel mismatches)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #500_000_000;
        $display("TIMEOUT - the video test never completed");
        $finish;
    end
endmodule
