# Roadmap

Phases, ordered by what each one unblocks rather than by how interesting it is,
with one exception: Phase 1 is ordered first because it is a redesign of the
machine every later phase builds on, and is cheaper to do before they widen the
surface it has to preserve.
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

## Phase 1 — Superscalar issue and out-of-order execution

**This is a redesign, not an increment**, and it is worth being plain about
that before it is worth being enthusiastic about it. Every other phase adds to
the machine in `rtl/cpu_core.v`; this one replaces it. The current core is
1,342 lines of five-stage, single-issue, in-order pipeline, and roughly 140 of
those lines are load-bearing for privilege, the Sv32 MMU and the A extension —
none of which get simpler when instructions stop retiring in the order they
were fetched.

What it actually requires, each item a dependency of the ones after it:

| | Piece | Why it is not optional |
|---|---|---|
| 1 | Register renaming — a RAT and a physical register file | WAR and WAW hazards stop being stalls and start being wrong answers |
| 2 | A reorder buffer | precise traps. This core takes misaligned-access, page and illegal-instruction traps, and `mepc` must name the faulting instruction |
| 3 | Reservation stations or a scoreboard | the wakeup/select loop, which is where the Fmax goes |
| 4 | Multiple execution units | including the existing multi-cycle divider, which already stalls in-order today |
| 5 | A load-store queue with memory disambiguation | loads may not pass an aliasing store; `LR`/`SC` reservations and AMO atomicity must survive reordering |
| 6 | Misprediction recovery | RAT checkpointing or rollback, replacing today's single-cycle flush |
| 7 | Wider fetch and decode | otherwise the back end starves and none of the above shows up as throughput |

And the constraints that do not relax while it happens:

- **Co-simulation still compares every retired instruction against Spike.**
  This is the good news: an out-of-order machine still retires in order, so
  82/82 remains exactly the right check, and it is a brutal one.
- **79/82 architectural tests, 4 formal proofs, and a hardware run** are the
  standing bar. `docs/practices.md` §1 applies with force here: a superscalar
  core that passes because the tests never create the hazard is the most
  expensive kind of test that cannot fail.
- **Timing.** The design closes at 30.77 MHz on an 85F with the critical path
  running from a block RAM read port through the MMU walk result to the PC. A
  wakeup/select loop is a classic critical path, and "it is faster in cycles"
  is not a result until Fmax is measured alongside it.
- **Area.** The 45F is already at 97% block RAM. A physical register file and a
  ROB are not free, and this may become 85F-only.

**Done when:** `make verify_ooo` is green — including 82/82 co-simulation —
with more than one instruction retiring per cycle on CoreMark, and a measured
Fmax and utilisation reported next to the cycle count rather than instead of
it.

### How it is being built

`rtl/ooo/core_ooo.v`, a second core with the identical port list, selected by
`make verify CORE=ooo` (or `make verify_ooo`). `rtl/cpu_core.v` is untouched
and stays the default, because it is the only design here that has run on
silicon and evolving it in place would leave no working baseline to diff a
regression against.

| Stage | | Status |
|---|---|---|
| 1a | Parallel core, behaviourally identical, whole suite green | ✅ done |
| 1b | 2-wide fetch/decode, dual issue for independent ALU ops | in progress — see below |
| 1c | Scoreboard: out-of-order completion, in-order retire | |
| 1d | Renaming, reorder buffer, reservation stations, LSQ | |

Stage 1a is deliberately empty of microarchitecture: the file starts as a
byte-for-byte copy of `cpu_core.v` with the module renamed, and the commit
proves the second core passes everything the first does. That is not a
formality. It means every later stage has a harness already known to work, and
a diff that contains only the change being made rather than the change plus a
rewrite of the privilege, MMU and atomics logic that fifteen bugs went into
getting right (`tests/README.md`).

#### Stage 1b, and a constraint found while starting it

**The fetch port is one 32-bit word per cycle**, and that decides the shape of
this stage. `imem_addr`/`imem_rdata` on both cores are a single word, `cpu_wb.v`
holds a one-entry fetch buffer, and the Wishbone interconnect is a shared bus
where an instruction fetch already contends with data. A two-wide back end fed
by a one-wide front end cannot exceed 1 IPC on straight-line code no matter how
good the issue logic is.

So dual issue here is worth having for a narrower reason than "two per cycle":
the fetch port is *idle* during multi-cycle stalls — a divider, an MMU walk, a
data-bus wait — and a buffer that runs ahead during those windows can hand the
back end two instructions when the stall clears. That is a real gain on this
design, and it is not the same as a 2 IPC machine.

Getting to a genuine 2-wide front end means widening the fetch interface, which
is not a change to `core_ooo.v` alone: it reaches `cpu_wb.v`, the interconnect,
and `wb_ram.v`'s port structure. That is a phase-scale change of its own, and
it belongs in the plan rather than being discovered halfway through the issue
logic.

**Landed for 1b so far:** `rtl/ooo/regfile_wide.v`, the 4-read/2-write register
file the pair needs, with formal properties in `formal/fv_regfile_wide.v`.
Two writes to the same architectural register in one cycle is a legal pair
(`addi a0,..` ; `addi a0,..`) rather than something the issue logic should
forbid, so port 1 is defined as the younger and wins in both the array and the
bypass — and that is the property the proof exists for, since getting it
backwards is wrong rather than slow, and wrong only when a pair happens to
share a destination.

**Still to do for 1b:** the fetch buffer, dual decode, the second ALU, the
issue rule and its hazard checks, and branch/trap redirect across two slots.

The `CORE` knob was checked the way `docs/practices.md` §1 asks: breaking
`core_ooo.v` on purpose fails `CORE=ooo` and leaves `CORE=inorder` green, so
the selector demonstrably selects rather than silently doing nothing.

This phase is ordered first because it is the largest and because everything
it touches is easier to change before, not after, the phases below add
external memory, caches and a debug module to the surface it has to preserve.

---

## Phase 2 — Close the boot path

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

## Phase 3 — Break the memory ceiling

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

## Phase 4 — Make it fast enough to be interesting

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

## Phase 5 — Video out

The framebuffer works and is verified by capturing a frame off the scan-out and
comparing it back (`make sim_video`), and the CPU's path to it is covered on
hardware by the acceptance test. **Nothing is routed to the HDMI pins.**

That needs a PLL and a TMDS serializer, neither of which exists. It is
independent of every other phase, which makes it a good one to pick up in
isolation.

**Done when:** a monitor shows the colour ramp the acceptance test leaves in
the framebuffer.

---

## Phase 6 — Run software this project did not write

OpenSBI **builds** for this core and does not **boot** on it.
[software/opensbi/README.md](../software/opensbi/README.md) is precise about
the split and lists what is missing: a platform port for console, timer and
IPI glue, and more RAM than there is — `fw_jump.bin` is 521 KB, which is
Phase 2's problem.

FreeRTOS or Zephyr is the realistic intermediate milestone, and is reachable
sooner: there is a bus, a timer, an interrupt controller and storage.

**Done when:** OpenSBI prints its banner and hands off to an S-mode payload.

---

## Phase 7 — Debug infrastructure

No JTAG TAP, no RISC-V Debug Module, so debugging is UART `printf` and the
loud trap handler. [docs/debug.md](debug.md) is honest about what that costs.

This is the phase that makes every other phase cheaper, which is an argument
for doing it earlier than its position here suggests. It is placed after the
others because none of them are blocked by it.

---

## Beyond the phases

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
