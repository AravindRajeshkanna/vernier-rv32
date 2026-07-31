// Minimal Verilator harness: toggles the clock, releases reset after a
// couple of cycles, runs for a fixed number of cycles, and dumps a VCD.
// (Pass/fail checking is done by the Icarus Verilog testbench; this is
// primarily useful for fast waveform generation / regression runs.)
#include "Vtop.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtop* top = new Vtop;

    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("wave_verilator.vcd");

    top->rst = 1;
    vluint64_t time_ns = 0;

    for (int cycle = 0; cycle < 100; cycle++) {
        top->clk = 0; top->eval(); tfp->dump(time_ns++);
        top->clk = 1; top->eval(); tfp->dump(time_ns++);
        if (cycle == 2) top->rst = 0;
    }

    tfp->close();
    delete top;
    return 0;
}
