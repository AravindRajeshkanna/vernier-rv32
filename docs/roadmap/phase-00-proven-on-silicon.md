# Phase 0 — Proven on silicon

Done, and recorded rather than asserted. A ULX3S with an LFE5U-85F boots from a
preloaded bitstream and passes its acceptance test at 25 MHz; the console
output is in [fpga/README.md](../../fpga/README.md), verbatim, with the values
that make it a report about that specific build.

| | |
|---|---|
| Pipeline, M extension, atomics (AMO + LR/SC incl. reservation breaking) | ✅ on hardware |
| Traps, misaligned-access faults, `FENCE.I`, CSR counters, `misa` | ✅ on hardware |
| Wishbone interconnect, on-chip RAM with byte/half lanes | ✅ on hardware |
| CLINT, GPIO through real pads, UART, boot ROM, framebuffer memory | ✅ on hardware |
| Reset and ESP32 hold-off | ✅ on hardware |
| newlib `printf` on hardware | ✅ — was a `.data` init bug, not libc |
| riscv-tests 79/82, Spike co-simulation 82/82, 5 formal proofs | ✅ in CI |

Timing: **27.41 MHz on an 85F** against the board's 25 MHz, as of the data
cache and the SDRAM controller. It was 30.77 before those two; the 45F's
28.78 predates them and has not been re-measured. See `docs/toolchain.md` §2.

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

Everything in the table above ran on a ULX3S with an LFE5U-85F, loaded from a preloaded bitstream, and passed its acceptance test at 25 MHz. The console output is in [fpga/README.md](../../fpga/README.md). Timing is **27.41 MHz on an 85F**; the 45F's 28.78 MHz predates the data cache and the SDRAM controller and has not been re-measured.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

The same design is checked without a board on every change: riscv-tests 79/82, Spike co-simulation 82/82 and 5 formal proofs, as recorded when this phase was written. Later phases raised those counts; the current counts are in Phase 1's and Phase 13's accounts.
