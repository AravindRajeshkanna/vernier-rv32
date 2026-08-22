# Debug infrastructure

Three things get called "debug infrastructure" for a soft core, and this
project has them to very different degrees. Being precise about which is
which matters more than the total count.

| | Status |
|---|---|
| UART console | ✅ working, used by every software flow here |
| Instruction tracer | ✅ working, and load-bearing (drives the Spike co-simulation) |
| JTAG / RISC-V Debug Module / OpenOCD | ❌ not implemented |

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

## JTAG and OpenOCD: not implemented

This is the honest gap. `open-ocd` is a `brew install` away and
`riscv-software-src/riscv/riscv-openocd` is in the tap already used by this
project's toolchain, so the host side is not the obstacle. The hardware is.

### What it would actually take

A working `openocd` → `gdb` flow needs three pieces, none of which exist
here:

1. **A JTAG TAP** — the 4-wire state machine (TCK/TMS/TDI/TDO), an IDCODE
   register, and the two RISC-V debug-transport registers `dtmcs` and `dmi`.
   This is the smallest piece and the most mechanical. It also has to cross
   from the JTAG clock domain into the core clock domain, which means real
   synchronizers, and clock-domain crossings are the one part of this design
   that could not be verified in simulation the way everything else here is.

2. **A Debug Module** (RISC-V Debug Spec 0.13/1.0) — the `dmcontrol`,
   `dmstatus`, `hartinfo`, `abstractcs`, `command` and `data0..n` registers,
   plus either a program buffer or abstract-command access to registers and
   memory. This is where most of the work is.

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
