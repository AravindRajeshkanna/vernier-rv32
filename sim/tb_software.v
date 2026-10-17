`timescale 1ns/1ps
// Testbench for the real riscv64-unknown-elf-gcc-compiled demo program
// (see software/) - unlike sim/tb_top.v (the hand-assembled self-checking
// regression test, entirely unaffected by this file), this one doesn't
// check architectural state at all. It decodes the CPU's simulated UART
// TX line back into ASCII and prints it straight to the console as it
// arrives, which is the actual point: proving real compiled C code runs
// on this core and its printf output genuinely reaches a UART, not just
// "it compiled."
//
// It also keeps what it decoded and, when the time is up, compares it with
// the text software/main.c prints, character for character (EXPECT below:
// keep the two together). It says SOFTWARE TEST PASSED or SOFTWARE TEST
// FAILED, and `make sim_software` looks for the first. Until it did, this
// printed the text and nothing else, so no breakage of the core, the UART or
// the firmware could fail the target.
module tb_software;
    // Must match the CLKS_PER_BIT this testbench's `top` instance below
    // is given - both derive from the same local constant so they can't
    // drift apart.
    localparam CLKS_PER_BIT = 4;

    reg clk = 0;
    reg rst = 1;
    reg [7:0] irq_sources = 8'b0;
    wire uart_tx;

    top #(
        .INIT_FILE("firmware_imem.hex"),
        .DMEM_INIT_FILE("firmware_dmem.hex"),
        .UART_CLKS_PER_BIT(CLKS_PER_BIT)
    ) DUT (
        .clk(clk),
        .rst(rst),
        .irq_sources(irq_sources),
        .uart_tx(uart_tx),
        .uart_rx(1'b1) // idle-high; nothing drives this demo's stdin
    );

    always #5 clk = ~clk; // 100 MHz virtual clock

    // What software/main.c prints, as it arrives: every "\n" is "\r\n", which
    // _write in software/syscalls.c adds for a real terminal. Ten lines, 172
    // characters and ten CR LF pairs = 192. Change main.c's text and this
    // changes with it, EXPECT_LEN too; the first run says SOFTWARE TEST FAILED
    // if they disagree.
    localparam [15:0] CRLF = 16'h0D0A;
    localparam EXPECT_LEN = 192;
    localparam [8*EXPECT_LEN-1:0] EXPECT = {
        "Hello from RV32IMA!", CRLF,
        "This is real C, compiled with riscv64-unknown-elf-gcc,", CRLF,
        "running on a from-scratch RISC-V core, printing over a", CRLF,
        "simulated UART.", CRLF,
        "i = 0", CRLF,
        "i = 1", CRLF,
        "i = 2", CRLF,
        "i = 3", CRLF,
        "i = 4", CRLF,
        "done.", CRLF
    };
    reg [8*EXPECT_LEN-1:0] got = 0;   // the last EXPECT_LEN characters decoded, newest in the low byte
    integer                nchars = 0; // and how many in all

    // ---- UART receiver, implemented right here in the testbench, to
    // decode the DUT's own TX output back into characters (independent
    // of rtl/uart.v's RX logic, which is for the opposite direction -
    // receiving external input into the CPU) ----
    localparam [1:0] RX_IDLE = 2'd0, RX_START = 2'd1, RX_DATA = 2'd2, RX_STOP = 2'd3;
    reg [1:0]  rxsim_state = RX_IDLE;
    reg [31:0] rxsim_count;
    reg [2:0]  rxsim_bit;
    reg [7:0]  rxsim_shift;

    always @(posedge clk) begin
        if (rst) begin
            rxsim_state <= RX_IDLE;
        end else begin
            case (rxsim_state)
                RX_IDLE: begin
                    if (uart_tx == 1'b0) begin
                        rxsim_state <= RX_START;
                        rxsim_count <= 32'b0;
                    end
                end
                RX_START: begin
                    if (rxsim_count == (CLKS_PER_BIT / 2)) begin
                        rxsim_count <= 32'b0;
                        rxsim_bit   <= 3'b0;
                        rxsim_state <= RX_DATA;
                    end else rxsim_count <= rxsim_count + 32'd1;
                end
                RX_DATA: begin
                    if (rxsim_count == CLKS_PER_BIT - 1) begin
                        rxsim_count            <= 32'b0;
                        rxsim_shift[rxsim_bit] <= uart_tx;
                        if (rxsim_bit == 3'd7) rxsim_state <= RX_STOP;
                        else rxsim_bit <= rxsim_bit + 3'd1;
                    end else rxsim_count <= rxsim_count + 32'd1;
                end
                RX_STOP: begin
                    if (rxsim_count == CLKS_PER_BIT - 1) begin
                        $write("%c", rxsim_shift);
                        got    <= {got[8*(EXPECT_LEN-1)-1:0], rxsim_shift};
                        nchars <= nchars + 1;
                        rxsim_state <= RX_IDLE;
                    end else rxsim_count <= rxsim_count + 32'd1;
                end
                default: rxsim_state <= RX_IDLE;
            endcase
        end
    end

    initial begin
        rst = 1;
        repeat (2) @(posedge clk);
        rst = 0;

        // Generous budget: crt0 + newlib-nano startup + several printf
        // calls' worth of instructions, plus the UART transmission time
        // itself at this simulation CLKS_PER_BIT.
        repeat (400000) @(posedge clk);

        $display("");
        $display("---------------------------------------------");
        $display("(end of simulation - the C program spins forever after this)");
        $display("---------------------------------------------");
        if (nchars == EXPECT_LEN && got === EXPECT) $display("SOFTWARE TEST PASSED");
        else $display("SOFTWARE TEST FAILED (%0d characters received, %0d expected)", nchars, EXPECT_LEN);
        $finish;
    end

    // Safety timeout in case of a hang
    initial begin
        #10000000;
        $display("TIMEOUT - simulation did not finish in time");
        $finish;
    end
endmodule
