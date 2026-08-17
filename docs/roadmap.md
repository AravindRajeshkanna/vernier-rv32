# Roadmap

Phases, ordered by what each one unblocks rather than by how interesting it is.
Each phase states what is already true, so the gap between "done" and "next" is
visible rather than implied — the same standard `fpga/README.md` applies to
hardware claims.

Nothing here is a schedule. This is a single-maintainer project and the phases
are dependency order, not dates.

---

## Phase 0 — Proven on silicon

Done, and recorded rather than asserted. A ULX3S with an LFE5U-85F boots from a
preloaded bitstream and passes its acceptance test at 25 MHz; the console
output is in [fpga/README.md](../fpga/README.md), verbatim, with the values
that make it a report about that specific build.

| | |
|---|---|
| Pipeline, M extension, atomics (AMO + LR/SC incl. reservation breaking) | ✅ on hardware |
| Traps, misaligned-access faults, `FENCE.I`, CSR counters, `misa` | ✅ on hardware |
| Wishbone interconnect, on-chip RAM with byte/half lanes | ✅ on hardware |
| CLINT, GPIO through real pads, UART, boot ROM, framebuffer memory | ✅ on hardware |
| Reset and ESP32 hold-off | ✅ on hardware |
| newlib `printf` on hardware | ✅ — was a `.data` init bug, not libc |
| riscv-tests 79/82, Spike co-simulation 82/82, 4 formal proofs | ✅ in CI |

Timing: 30.77 MHz on an 85F, 28.78 MHz on a 45F, against the board's 25 MHz.

---

## Phase 1 — Close the boot path

**The SD card is the only part of the boot chain that has never worked on
hardware**, and it is by a wide margin the cheapest open question in the
project.

A 64 GB SDXC card never answers CMD0. That is permitted — SPI mode is optional
above 32 GB — but it has not been distinguished from a wiring fault, because no
smaller card has been tried. `BOARD=ulx3s-cmd0` builds a 60-flip-flop probe,
proven against the card model by `make sim_cmd0`, that answers it in seconds.

Until this closes, every hardware run depends on preloading the program into
the bitstream, which is a bring-up crutch rather than a boot path.

**Done when:** a card ≤32 GB answers CMD0, and `BOARD=ulx3s85` boots the
acceptance test off the card rather than out of block RAM.

---

## Phase 2 — Break the memory ceiling

**64 KB of block RAM is what stands between this and anything Linux-shaped**,
and it is also what forces the firmware to stay as small as it is. 256 KB costs
244 ECP5 block RAMs, which no ECP5 has.

The ULX3S carries 32 MB of SDRAM that nothing here can reach, because there is
no memory controller. `rtl/soc/wb_ram.v` is the seam, and it is deliberately
shaped for this: everything above it speaks Wishbone and knows only a base
address and a size. LiteDRAM via LiteX is the well-trodden path.

This phase blocks Phase 5 entirely and constrains Phase 3.

**Done when:** the SoC runs a program larger than 64 KB from external memory,
and `sim_ramboot`'s 64 KB assumption is no longer the binding constraint.

---

## Phase 3 — Make it fast enough to be interesting

Every fetch and every load goes to the bus, and the interconnect is a shared
bus rather than a crossbar, so a load costs the fetch behind it a cycle.

- **An I-cache alone would be a large win** and is self-contained — it needs no
  other phase.
- **Interrupt-driven UART.** The interrupt is already wired to the PLIC; the
  driver simply polls. Small, independent.
- **Hardware PTE accessed/dirty update** in the MMU walker, so it does not
  fault when software has not pre-set those bits.

CoreMark already runs and validates its own CRCs, so there is a number to move
and a way to tell whether it moved.

**Done when:** a measured CoreMark improvement, reported with the same
disclosure `NOTICE` requires — these are unverified self-measurements, not
EEMBC-certified scores.

---

## Phase 4 — Video out

The framebuffer works and is verified by capturing a frame off the scan-out and
comparing it back (`make sim_video`), and the CPU's path to it is covered on
hardware by the acceptance test. **Nothing is routed to the HDMI pins.**

That needs a PLL and a TMDS serializer, neither of which exists. It is
independent of every other phase, which makes it a good one to pick up in
isolation.

**Done when:** a monitor shows the colour ramp the acceptance test leaves in
the framebuffer.

---

## Phase 5 — Run software this project did not write

OpenSBI **builds** for this core and does not **boot** on it.
[software/opensbi/README.md](../software/opensbi/README.md) is precise about
the split and lists what is missing: a platform port for console, timer and
IPI glue, and more RAM than there is — `fw_jump.bin` is 521 KB, which is
Phase 2's problem.

FreeRTOS or Zephyr is the realistic intermediate milestone, and is reachable
sooner: there is a bus, a timer, an interrupt controller and storage.

**Done when:** OpenSBI prints its banner and hands off to an S-mode payload.

---

## Phase 6 — Debug infrastructure

No JTAG TAP, no RISC-V Debug Module, so debugging is UART `printf` and the
loud trap handler. [docs/debug.md](debug.md) is honest about what that costs.

This is the phase that makes every other phase cheaper, which is an argument
for doing it earlier than its position here suggests. It is placed after the
others because none of them are blocked by it.

---

## Beyond the phases

**Superscalar issue and out-of-order execution** — register renaming, a
reorder buffer, reservation stations or a scoreboard, multiple execution
units. This is a microarchitecture redesign rather than an addition to this
pipeline, which is why it is not a phase: it would replace the thing the
phases are built on.

**PMP**, which [SECURITY.md](../SECURITY.md) lists as a known gap rather than
an oversight.

---

## Known defects

Open, unscheduled, and written down so they are not rediscovered.

**The intermittent `ISA-TIMEOUT` under `make verify`.** Still undiagnosed. It
self-reports rather than hanging silently, which is not the same as being
fixed, and pretending otherwise is exactly the failure mode
[practices.md](practices.md) §7 is about.

**`sim/program.hex` is 440 instructions of recovered source.**
`sim/program.S` reassembles to it byte for byte and `make check-program`
holds that, but the labels are named for byte offsets because the original had
no symbol names to recover. Anyone extending the core regression will be
working with that.
