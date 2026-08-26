# Where Vernier-RV32 sits among open-source 32-bit RISC-V cores

A reader who already knows PicoRV32 or VexRiscv will reasonably ask "why
this one, and not that one." This is that comparison, written the way the
rest of this repo tries to write everything: what is actually true, what is
this project's own measurement versus a widely-repeated public claim about
someone else's, and where this core is behind rather than papering over it.

## 1. Method, and its limits

Every number in `README.md` and `fpga/README.md` about *this* core is
something `make verify` or a board run actually produced. That is not true
of the other cores below - this project has not built, synthesized, or
benchmarked any of them. Their rows describe well-documented, stable
characteristics (instruction set, privilege modes, pipeline shape, whether
an MMU exists) that are safe to state without measuring them here. Where a
peer project publishes its own LUT count, Fmax, or CoreMark/MHz score, this
file says so rather than restating a specific figure as fact - those numbers
move between toolchain versions and configurations, and only the source
project's own current repository is authoritative for them. `docs/NOTICE`'s
"CoreMark scores from this repository are unverified self-measurements, not
EEMBC-certified ones" is this project's own rule for its own numbers; the
same caution applies, doubled, to anyone else's.

## 2. The field

| | ISA | Privilege / MMU | Pipeline | Linux-capable | HDL | License |
|---|---|---|---|---|---|---|
| **Vernier-RV32** | RV32IMA + Zicsr | M/S/U, Sv32 | 5-stage in-order, **and** a second superscalar/OOO core sharing the same SoC | Yes - boots to userspace, in simulation and on an FPGA board | Verilog | Apache-2.0 WITH SHL-2.1 |
| SERV | RV32I(+M via a companion core) | M-mode only, no MMU | Bit-serial - one bit per cycle, not pipelined in the usual sense | No | Verilog | ISC |
| PicoRV32 | RV32IMC(E) | M-mode only, no MMU | Single-cycle-ish, not a classic multi-stage pipeline | No | Verilog | ISC |
| Ibex | RV32IMC(B) | M/U, no MMU | 2-stage in-order | No | SystemVerilog | Apache-2.0 |
| NEORV32 | RV32I + a wide set of standard/custom extensions | M/U, no MMU | 2-stage in-order | No | VHDL | BSD-3-Clause |
| VexRiscv | RV32I, extensions and features added per-plugin (M, A, C, MMU, caches...) | Configurable up to M/S/U with an MMU, plugin-dependent | Configurable, 2-5 stages | Yes, in MMU+cache configurations (e.g. the Linux-on-LiteX-VexRiscv project) | SpinalHDL (generates Verilog) | MIT |
| SweRV EH1/EH2 | RV32IMC | M-mode only, no MMU | 9-stage, dual-issue in-order | No | SystemVerilog | Apache-2.0 |
| Rocket Chip | Primarily RV64GC; RV32 is a supported but less common configuration | M/S/U, Sv32/Sv39 depending on XLEN | In-order single-issue (an out-of-order sibling, BOOM, is RV64-only) | Yes, extensively (SiFive Freedom, Chipyard-based chips) | Chisel (generates Verilog) | BSD |
| CVA6 (Ariane) | Primarily RV64GC; a RV32 configuration exists (CV32A6) | M/S/U, Sv32/Sv39 | 6-stage single-issue in-order | Yes | SystemVerilog | Solderpad Hardware License |

A few of these need a caveat the table can't carry: SERV's "companion core"
M-extension and PicoRV32's optional interrupt mechanism are both
non-standard extras layered on a deliberately minimal base, not full PLIC/
CLINT-style privileged architecture. VexRiscv and Rocket Chip are not single
fixed designs but *generators* - "VexRiscv" or "Rocket" names a space of
configurations, and the row above describes the space's ceiling, not any one
build of it.

## 3. Three groups, and where this core doesn't fit neatly into any of them

**The minimalists - SERV, PicoRV32.** Built to be as small as possible and
succeed at it; neither has an MMU or privilege modes beyond M, and neither
targets Linux. They are the right answer when the question is "the smallest
possible RISC-V core," which is not a question this project is answering -
Vernier-RV32's caches, MMU and dual pipeline cost real area that a
minimalist core spends nothing on.

**The configurable middle - Ibex, NEORV32, VexRiscv, SweRV.** Production
microcontroller-class cores, several already taped out in real silicon
(Ibex in OpenTitan) or shipped in real products. Three of the four have no
MMU and are not Linux targets by design - they are built for RTOS or
bare-metal workloads where an MMU is overhead, not a missing feature.
VexRiscv is the exception: its plugin architecture *can* assemble an
MMU-and-cache configuration capable of Linux, which is the closest any peer
here comes to what Vernier-RV32 does by default rather than by opt-in
configuration.

**The Linux-capable heavyweights - Rocket Chip, CVA6.** Both boot Linux
routinely and both back real silicon efforts; both are also primarily RV64
designs (RV32 is a secondary, less-traveled configuration for each) and both
come from generator toolchains (Chisel, in Rocket's case) rather than a
single fixed RTL tree meant to be read start to finish. Both have
verification infrastructure well beyond what a single-maintainer project can
match - Rocket via the Chipyard ecosystem, CVA6 via OpenHW Group's
industrial UVM-based flow.

Vernier-RV32's actual position: MMU-and-Linux-capable like the heavyweights,
but RV32-native rather than RV64-with-an-RV32-mode, a single readable
Verilog tree rather than a generator's output, and built by one person with
disclosed AI assistance (`AI_USAGE.md`) rather than an organization. Whether
that trade is worth it depends entirely on what the reader is optimizing
for - the rest of this file is about naming the trade honestly, not about
declaring a winner.

## 4. What's distinct about this project specifically

- **Linux-capable at a size a single person can hold in their head.** The
  whole SoC - core, MMU, caches, interconnect, peripherals - is Verilog you
  can read start to finish in an afternoon, unlike a Chisel or SpinalHDL
  generator's output or an industrial UVM testbench's surrounding
  infrastructure.
- **Two core implementations sharing one SoC.** `rtl/cpu_core.v` (in-order,
  proven on hardware) and `rtl/ooo/core_ooo.v` (superscalar/out-of-order,
  `docs/roadmap.md` Phase 1) plug into the identical bus adapter, memory map
  and peripheral set - `make verify CORE=ooo` runs the *same* regression
  suite against both. None of the peers above offer two independent
  microarchitectures behind one unchanged SoC boundary.
- **Verification density unusual for the size class.** riscv-tests, formal
  proofs, and per-instruction co-simulation against Spike (84/84 traces) all
  run in `make verify`, alongside directed red/green tests for specific
  historical bugs (`tests/README.md` names fifteen of them, including a
  missing MMU permission check that this project's own AI-assisted history
  produced and its verification layers caught). SERV, PicoRV32, Ibex and
  NEORV32 are all well-tested by their own communities, but none publish a
  Spike-co-simulation gate at this granularity as part of their default CI.
- **Runs on real, inexpensive hardware, with the gaps stated.** A $60-class
  ULX3S board, not an ASIC prototype or a data-center FPGA - and
  `fpga/README.md` says plainly what still doesn't work (SD card above 32
  GB, HDMI scan-out) rather than only describing what does.

## 5. Where it's behind

- **No PMP.** `SECURITY.md` lists this as a known gap, not an oversight -
  every peer with M/S/U privilege and any security posture (Ibex/OpenTitan
  especially) treats physical memory protection as load-bearing.
- **One proven FPGA target.** The ULX3S/ECP5-85F is the only board this
  project has actually run on; VexRiscv (via LiteX) and Rocket/CVA6 (via
  their respective ecosystems) both span many more boards and, for the
  latter two, real silicon.
- **Timing margin is presently the project's own bottleneck** -
  `docs/roadmap.md` Phase 6 records `BOARD=ulx3s85` closing on some
  placement seeds and not others against a 25 MHz constraint, and names it
  as what is blocking further debug-infrastructure work. A dedicated
  microcontroller core like Ibex or SweRV, with no MMU and a much shorter
  critical path, comfortably clears far higher Fmax on the same class of
  FPGA.
- **No independently certified performance number.** CoreMark here
  validates its own CRCs and nothing more; there is no published
  CoreMark/MHz figure to set against SweRV's or Ibex's, certified or
  otherwise, and this file is not going to manufacture one.
- **PCIe, DDR and video output are unbuilt.** `docs/roadmap.md` Phases 4,
  8 and 9 - framebuffer logic exists and is verified in simulation, but
  nothing is routed to HDMI pins, and the PCIe/DDR phases are explicitly
  blocked on choosing a board that has them, which the current ULX3S
  target does not.

## 6. Picking one

If the actual goal is the smallest possible RISC-V implementation, SERV or
PicoRV32 are the right answer and this project is not competing with them.
If the goal is a proven microcontroller core for an RTOS or bare-metal
workload, Ibex, NEORV32 or SweRV are more mature choices with real silicon
or product history behind them. If the goal is a production Linux-capable
core with industrial-grade verification and RV64 is acceptable or preferred,
Rocket Chip or CVA6 are better resourced than a single-maintainer project can
be. Vernier-RV32's niche is narrower: a from-scratch, single-tree, RV32
Linux-capable core small enough to actually read, with two microarchitectures
behind one unchanged SoC boundary and a verification suite built specifically
to catch the failure modes AI-assisted RTL development produces
(`AI_USAGE.md`). That is a real, if specific, thing to optimize for - and,
per section 5, a real set of things it costs.
