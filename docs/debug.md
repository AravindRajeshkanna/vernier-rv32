# Debug infrastructure

Three things get called "debug infrastructure" for a soft core, and this
project has them to very different degrees. Being precise about which is
which matters more than the total count.

| | Status |
|---|---|
| UART console | ✅ working, used by every software flow here |
| Instruction tracer | ✅ working, and load-bearing (drives the Spike co-simulation) |
| JTAG TAP / Debug Module (System Bus Access) | ✅ working, gated in `make verify` |
| Halt/resume, register access, single-step | ✅ working, `CORE=inorder`, simulation-only (no FPGA timing claim) - `core_ooo.v` untouched |
| Breakpoints, OpenOCD/gdb | ❌ not implemented (no debug ROM/Program Buffer - see below) |

## UART console

`rtl/uart.v`, memory-mapped at `0x0400_0000`. Polled TX and RX, with a
`CLKS_PER_BIT` parameter rather than a runtime baud divisor.

Every testbench that runs compiled code decodes the TX line back into
characters, so what appears on the console is the actual byte stream off the
serial pin, not a `$display` from inside the design. `software/syscalls.c`
routes newlib's `_write` through it, which is why `printf` works, and `_read`
through RXDATA, so `scanf` and `getchar` do too.

## Instruction tracer

`sim/tracer.v`, fed by the `trace_*` registers in `rtl/cpu_core.v`. One line
per retired instruction:

```
800000e4 00000297 x5 800000e4
800000e8 01028293 x5 800000f4
800000ec 30529073 - -
```

`<pc> <instruction> <destination register> <written value>`, with `-` where
an instruction writes no register. Enabled per-run with `+trace=<file>`, so
it costs nothing when it is not asked for.

Two details in it are not incidental:

- **The shadow PC/instruction registers ride inside the existing pipeline
  register blocks** rather than in a parallel block of their own. A separate
  block would have to restate every stall and flush condition and would drift
  out of step the first time one changed. This project has been bitten by
  exactly that shape of bug before (a value recomputed from a control signal
  that had moved on during a multi-cycle stall), so the trace is wired to be
  incapable of disagreeing with the pipeline.
- **A trapping instruction is not traced**, because it does not retire.
  Spike's `--log-commits` draws the same line - it prints an exception line
  instead of a commit line - and matching that definition is what makes the
  two traces diffable at all.

Nothing outside a testbench reads these registers, so synthesis strips them.

The tracer is a `$fdisplay` observer, not trace hardware. Real on-chip
tracing (compressed branch trace out a pin, à la RISC-V N-Trace) is a
different thing entirely, and calling this that would overstate it.

## Asking the machine, under Verilator

`sim/verilator_soc.cpp` carries the probes that exist because firmware owns
the console and says nothing when it fails. They fall into two groups, and the
distinction matters more than the list - see PRACTICES §30.

## The JTAG debug path

Four pins on the `gn` header reach a bus master that can read and write any
address the SoC decodes, while the CPU is running or wedged. `rtl/debug/`
has the design; the short version:

```
gn[2] TCK  gn[3] TMS  gn[4] TDI  gn[5] TDO
```

**What it answers that nothing else here can.** Everything below this section
is a simulation probe: `+checkreads`, `+checkfetch`, `+watchpc` and the rest
exist because in simulation you can see everything, and on a board you can see
what the firmware prints. The gap is a board that is not printing — OpenSBI
hanging before its console comes up, a boot ROM stopping with no output, a
kernel dying between `earlycon` and `ttyS0`. In all of those the interesting
state is sitting in memory and there has been no way to look at it.

**What it cannot do:** halt the hart, read its registers, or set a breakpoint.
The Debug Module implements System Bus Access only, and `rtl/debug/README.md`
explains why that half first — the other half lands on the fetch and writeback
paths of a design with almost no timing margin.

`make sim_jtag` drives the four pins the way an adapter does and is gated in
`make verify`.

**Probes that check.** Each compares the hardware against an independent model
and prints one line unless something disagrees. Add them to any run:

```sh
cd sim && ../obj_dir_soc_inorder/Vsoc_top +sdram=linuximage.hex \
    +uart_clks=224 +sdram_words=16777216 \
    +checkreads +checkfetch +checkmmu +checkdecode +checkuart
```

| | Checks |
|---|---|
| `+checkreads` | every word the interconnect acknowledges, against the modelled SDRAM |
| `+checkfetch` | every instruction the core consumes - which `+checkreads` cannot see, because an I-cache hit never reaches the bus |
| `+checkmmu` | every address both TLBs resolve, against an Sv32 walk of the same tables |
| `+checkdecode` | that the instruction the decoder holds is the instruction at the PC it is attributed to. The only one of these that can see a *pairing* go wrong - see PRACTICES §31 - and the one that found a core executing an instruction from a mispredicted path under the corrected PC. |
| `+checkuart` | that every byte written to the UART's holding register comes out on the wire, in order. The console is what all of the above report *through*, so when it is the broken thing the evidence and the fault are the same signal - output arrives thinned, and every reading of it is a guess about the decoder. This watches both ends independently. See PRACTICES §32. |

**Probes that report.** These print state for you to read, which means you
need a theory of what they mean. That theory has been wrong three times here,
so treat a surprising reading as a question about the probe first:

| | |
|---|---|
| `+watchpc=ADDR` | integer registers when a *retired* instruction is at ADDR. `+watchlast` takes the last occurrence rather than the first. |
| `+watchskew=N` | how many cycles later to read the register file (default 3). Not a tuning knob: at N=0 the one or two instructions *before* the watched PC have not written back, so a dump at a function entry shows the *previous* call's arguments. |
| `+peek=ADDR` | one 32-bit word at the end of the run, up to four times |
| `+savemem=ADDR:LEN:FILE` | a region of SDRAM to a file, for `dtc`, `objdump` or `cmp` to judge |
| `+readtrace=ADDR:LEN:FILE` | every read inside a region as `cycle address data master`, for watching software walk a structure |
| `+traptrace=FILE` | every trap as `cycle pc`. Traps are the one thing that interrupts an instruction sequence without appearing in it. |
| `+pipetrace=FROM:TO:FILE` | one line per cycle over a window: fetch PC, the PC and instruction in IF/ID, the writeback, and the redirect and prediction state. For a 33-million-cycle boot where a waveform is not an option - an unwindowed VCD of one once filled a 228 GB disk. |
| `+stopon=TEXT` | end the run when TEXT comes out of the UART. Software this project did not write ends a boot by printing, not by storing a verdict word. |

## OpenOCD/gdb: still not implemented

**Update:** the two pieces below marked done were built after the "three
pieces" analysis in this section was first written, and shipped the JTAG TAP
and Debug Module (#34). The section is kept as-is rather than rewritten,
because the remaining gap (item 3) is exactly the reasoning that was already
here — only the status of items 1 and 2 changed.

A working `openocd` → `gdb` flow needs three pieces:

1. ~~**A JTAG TAP**~~ — **done.** `rtl/debug/jtag_tap.v`: the 4-wire state
   machine (TCK/TMS/TDI/TDO), an IDCODE register, and the two RISC-V
   debug-transport registers `dtmcs` and `dmi`, crossing from the JTAG clock
   domain into the core clock domain through `rtl/debug/dmi_cdc.v`.

2. ~~**A Debug Module**~~ — **partly done.** `rtl/debug/dm.v` implements the
   `dmcontrol`/`dmstatus`/DMI register set and System Bus Access (a fourth
   Wishbone master that reads and writes memory without the hart's
   cooperation). It does not implement the program buffer or abstract-command
   register/memory access, which is what the rest of this section is about.

3. **Debug mode in the core** — and this is the part that reaches into
   `cpu_core.v` rather than bolting on beside it:
   - `dcsr` and `dpc` CSRs, and a fourth privilege state (debug mode) that is
     not one of M/S/U.
   - `EBREAK` conditionally entering debug mode instead of trapping.
   - A `dret` instruction.
   - A halt request that stops the pipeline cleanly at an instruction
     boundary, and a resume that restarts it — including getting the
     in-flight EX/MEM state right, which is precisely where this core's
     trickiest existing bugs have lived.
   - Single-step, which means retiring exactly one instruction and halting
     again.

The debug-spec **trigger module** (`tselect`/`tdata1`/`tdata2`, hardware
breakpoints) is the same feature family, which is why
`rv32mi-p-breakpoint` is the one riscv-tests failure attributable to it —
see `tests/expected-failures.txt`.

### Why it was not done in this pass

It is a milestone, not a task. Item 3 alone is comparable in size to the M/S/U
privilege work, and it touches the pipeline-control logic that the rest of
this round's verification work was busy proving correct. Doing both at once
would have meant the new tests were chasing a moving target.

There is also an ordering argument. The value of JTAG is interactive
debugging on real hardware — and this design does not fit on the FPGA target
yet (`fpga/README.md`: the core alone is ~55% over the largest iCE40's LUT
budget, and the full SoC does not finish synthesis). Until that is fixed,
JTAG would be debugging a simulation, which the tracer and co-simulation
already do more thoroughly than a `gdb` prompt would: they check every
retired instruction against a reference model, which no interactive session
does.

The sequence that makes sense is: make it fit, then add the debug module,
then attach OpenOCD to real silicon.
