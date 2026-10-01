# Phase 12 — Peripheral interfaces (I2C, general-purpose timers, PWM)

**Half of this phase already shipped, quietly, as part of getting the
SoC to boot at all - naming it now is catching up the roadmap to the
tree, not starting from zero.** GPIO (`rtl/soc/wb_gpio.v`, 16
bidirectional pins with edge-triggered interrupts, `0x0500_0000`), SPI
(`rtl/soc/wb_spi.v`, a real hardware master - not bit-banged - fast
enough to boot Linux off an SD card, `0x0600_0000`), and a UART
(`rtl/uart.v`, ns16550-compatible, `0x0400_0000`) are all real, wired
peripherals with their own Wishbone slaves, documented in
`docs/soc.md`'s peripheral section and exercised by more of this
project's own tests than almost anything else in the tree. What this
phase adds beyond that: a general-purpose timer distinct from
`rtl/clint.v`'s fixed-purpose `mtime`, PWM (the same hardware, see
below), and I2C.

**Why CLINT's timer doesn't already cover this.** `rtl/clint.v` gives a
single 64-bit free-running counter (`mtime`) and one compare register
(`mtimecmp`) per the RISC-V privileged spec, entirely dedicated to the
timer interrupt real firmware (OpenSBI, Linux) already depends on.
Repurposing it for anything else - a second, independent countdown, a
PWM duty cycle, a microsecond-resolution measurement - means fighting
the one hart's own scheduling clock for a resource it doesn't share.
Software-visible timing peripherals are a genuinely separate need from
"the kernel's tick," the same way this project's own boot ROM already
needed its own polling loops rather than borrowing `mtime` for
UART/SD timeouts.

**PWM is not really a fourth peripheral - it's the same hardware as the
timer, with an output pin.** A PWM channel is a free-running counter
compared against a duty-cycle register, toggling an output on
compare-match and on wraparound - exactly a general-purpose timer's own
compare-match logic, with the comparison result driving a pin instead
of (or in addition to) an interrupt. Scoping these as two separate
peripherals would double-count the actual design work; the real
open question is how many independent counter/compare channels one
timer peripheral needs, not whether PWM needs its own datapath.

**Stage 1: the timer/PWM half is done - one channel, deliberately.**
`rtl/soc/wb_timer.v`, `0x0800_0000`: a free-running counter, a period
register it wraps against, and a compare register driving both a PWM
output and a wraparound interrupt (PLIC source 3) - the same datapath
serving both duties, exactly as reasoned above. One channel answers
"how many channels" the way Phase 10's own first stage answered "how
much of the blit engine" - enough to prove the mechanism (counter,
period, compare, wraparound interrupt, PWM output) end to end through
the real bus path, not a ceiling on what this peripheral could grow
into. `docs/soc.md`'s peripheral section has the register map.

**PWM's own output pin is deliberately not routed to real silicon yet,
for the same sequencing Phase 4 (video out) already used.** Every site
on the ULX3S's own GPIO/JTAG header is already spoken for (16 pins for
GPIO, 4 for JTAG) - finding a genuinely free one means real board-
specific research this stage does not need to settle before the
datapath itself is proven. `pwm_out` is a real SoC-level port, left
unconnected in `fpga/ulx3s_top.v` with a comment naming this explicitly,
the same "prove it in simulation first, wire real pins as a later stage"
sequencing that took Phase 4 four separate stages to reach hardware.

**A real, serious bug, found only because the acceptance test's own
result - not just "it elaborates" - was checked.** Adding a tenth slave
(`S_TIMER = 9`, the new highest index) means `soc_top.v`'s `s_base`/
`s_mask` concatenations - which `docs/soc.md`'s own "Adding a
peripheral" checklist says must list the highest index *first* - needed
the new entry at the front. It was written third instead (after
`S_SDRAM`, `S_RAM`), which does not merely misconfigure the new slave:
concatenation position, not the inline comment beside it, is what
Verilog actually binds to an index, so every entry after the misplaced
one silently shifts by one slot. `S_SDRAM` read `S_RAM`'s intended base,
`S_RAM` read `S_TIMER`'s, and `S_TIMER` read `S_SDRAM`'s - three
peripherals' address decode corrupted by one misplaced line, not one.

The failure was loud, not subtle: `make sim_soc` hung in a boot loop,
the boot ROM printing "image `0x00000000` bytes" (a real, nonzero length
its own header definitely has, per the build tool's own log line
showing 6672 bytes) forever, until the whole run timed out. **Confirmed
the cause with the same discipline as any other bisection in this
file, not assumed from reading the diff:** a fresh worktree of unmodified
`main` ran the identical scenario and correctly read back the real
length, isolating the corruption to this change's own concatenation
edit before touching anything. Fixed by moving the new entry to the
front of both concatenations; re-ran `make sim_soc` clean afterward, image
length correct, every acceptance check including the new one passing.
Left here in full because a silently-corrupted address map is exactly
the kind of defect that would not announce itself nearly this clearly
on hardware, where nothing prints a boot-loop diagnosis - it happened to
be loud here only because the SD boot path's own header check is
strict, not because a bit-position mistake is inherently loud.

**The first open item: I2C's own shape, since - unlike SPI - a real
hardware master versus a bit-banged GPIO driver is a genuine choice
here, not a foregone one.** SPI became a real hardware peripheral
because nothing bit-banged could hit the throughput an SD card boot
needs; I2C's typical targets (EEPROMs, sensors - an IMU or a
temperature/humidity part are the usual ULX3S-adjacent examples) run
at 100-400 kHz, slow enough that a software-clocked GPIO driver is a
realistic option this project hasn't needed to rule out yet. A real
`wb_i2c.v` master, matching `wb_spi.v`'s own shape (a CTRL/DATA/STATUS
register set, `docs/soc.md`'s established convention), is the more
consistent answer if this project keeps treating "a bus protocol" as
"a peripheral," but the case for it needs a real target device driving
the decision, not an assumption that hardware is automatically better
than software here the way it demonstrably was for SPI.

**Done when:** the same bar every peripheral in this SoC already
clears - `docs/soc.md`'s own "Adding a peripheral" checklist, a directed
test proving the CPU's real path to it (not just that it elaborates).
The timer/PWM half clears this now; I2C still needs, specifically, a
real transaction against an actual device on a board, not just a
simulated protocol timing check standing in for one.

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

The timer and PWM half clear the "Done when" in simulation. I2C, still to do, needs a real transaction against an actual device on a board, which a simulated protocol check cannot stand in for. GPIO and the UART, which this phase lists as already shipped, have run on hardware through the earlier phases; SPI's SD-card use has not (Phase 7).

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

Stage 1 (one timer and PWM channel) has a directed test proving the CPU's real path to it, following `docs/soc.md`'s "Adding a peripheral" checklist, and runs under `make sim_soc`. I2C is not started.
