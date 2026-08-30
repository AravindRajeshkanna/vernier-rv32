# The debug path

Four pins to a bus master. A host can read and write any address this SoC
decodes, while the CPU is running, spinning, or wedged — and without the CPU's
cooperation or knowledge.

```
gn[2] TCK ─┐
gn[3] TMS ─┤
gn[4] TDI ─┼─→ jtag_tap.v ──→ dmi_cdc.v ──→ dm.v ──→ interconnect master 3
gn[5] TDO ─┘   (TCK domain)   (the one      (system
                               crossing)     domain)
```

| File | What it is |
|---|---|
| `jtag_tap.v` | IEEE 1149.1 TAP: the sixteen-state machine, IR, and the DRs the RISC-V debug spec defines — `IDCODE`, `BYPASS`, `dtmcs`, `dmi` |
| `dmi_cdc.v` | The single crossing between TCK and the system clock |
| `dm.v` | Debug Module: DMI registers, System Bus Access as a fourth Wishbone master, halt/resume and Abstract Command register access (`CORE=inorder`, simulation only) |

## What it does, and what it deliberately does not

**It does:** read and write SDRAM, block RAM and every peripheral register;
dump a device tree, a page table or a kernel log out of a machine that is not
talking; load a program without the boot ROM's 22-minute serial transfer;
assert `ndmreset` to restart the SoC without touching the board; halt, resume,
and read/write GPRs, `dcsr`, and `dpc` on the in-order core's hart, in
simulation.

**It does not:** single-step; execute the Program Buffer (there isn't one);
set a breakpoint; halt/resume or touch a register on `CORE=ooo` at all; any
of the above on real hardware — no debug adapter has been connected to a
board, so everything above is proven in simulation only.

The RISC-V spec offers two ways for a debugger to reach memory — abstract
commands and the program buffer, which make the *hart* do it, and System Bus
Access, which uses a bus master that has nothing to do with the hart. System
Bus Access shipped alone first, for two reasons, and the second is the one
that decided it.

**It is the half this project keeps needing.** "OpenSBI hangs before its
console comes up." "The boot ROM prints nothing." "Linux dies between
`earlycon` and `ttyS0`." Every one of those is *the memory is fine and I
cannot see it*, and none of them needed the hart stopped.

**The RISC-V debug spec's full halt/resume model lands on the critical
path.** It needs debug mode, `dcsr`-driven execution, `dret` and a debug ROM
the core vectors into — which touches the fetch redirect and the register
file write port. Two of six placement seeds already fail to close 25 MHz
(`fpga/README.md`). Adding to that path before the margin is fixed would turn
an intermittent build failure into a permanent one.

**What actually shipped is smaller than that model, on purpose.** Halt is one
term added to `rtl/cpu_core.v`'s existing `pc_freeze`/`if_id`-hold stall
machinery — the same class of stall the pipeline already handles for a
load-use hazard — not a new entry into the fetch-redirect mux. Resume
un-freezes it. Register access is a dedicated port into `regfile.v` plus two
private registers (`dcsr`, `dpc`) that never join `csr_file.v`'s CSR-
instruction path, so ordinary M/S/U-mode software has no way to reach them.
`rtl/debug/dm.v`'s Abstract Command state machine drives that same port over
the real DMI wire — single-cycle turnaround, no Wishbone traffic, no Program
Buffer (`postexec` always gets `cmderr` = not-supported). None of it touches
the timing-critical fetch path at all, which is what makes it safe to ship
before Phase 3's margin work is done.

`CORE=ooo` has none of this wired up. `dmstatus` says so honestly —
`haltreq` is accepted and ignored, `allrunning` stays 1 — and an Abstract
Command gets `cmderr` = halt/resume-required, the same as a real host would
see against any hart it can't stop. A debugger gets a hart that never halts
and a register access that never lies about succeeding, rather than either
one silently doing nothing.

## Three things worth knowing if you change it

**Only two bits cross clock domains.** The payload — address, data, op, the
response — never crosses as such: it is written in one domain, held still, and
read in the other only after a toggle has proved it has been still for two
destination clocks. Synchronising 41 bits individually is the classic way to
get this wrong, because each bit resolves independently and a word can be
sampled half-old and half-new. The failure is data-dependent and arrives once
a week.

**TCK can stop.** A debugger parks it for minutes between transactions and
drives it at 1–10 MHz when it does move. Nothing in `jtag_tap.v` may assume it
runs, which is why the TAP has no reset pin: JTAG's reset is five TCK cycles
with TMS high, and that is reachable from every state.

**The debug master does not set `s_data_master`.** That signal gates read side
effects — the PLIC's claim register, the UART's RBR — so a host reading a
peripheral through this path gets the value *without* consuming it. It is one
line in `wb_interconnect.v`, it is asserted in `formal/fv_interconnect.v`, and
it is the difference between a debug port and a second CPU.

## Testing

`make sim_jtag` bit-bangs the four pins exactly as an adapter would and checks
only values a real host reads — no hierarchical references into the design, so
it cannot pass on a TAP that shifts the right bits into the wrong register.

It checks IDCODE, BYPASS (one bit of delay, which is what proves the IR
selects anything at all), `dtmcs`, the DMI round trip through the crossing,
then SBA reads, writes, autoincrement and a distant address, then
halt/resume and Abstract Command register access over the real `dmcontrol`/
`dmstatus`/`abstractcs`/`command`/`data0` DMI registers — core-aware
throughout, since the correct answer genuinely differs between
`CORE=inorder` (a real halt/resume/register cycle) and `CORE=ooo`
(`cmderr`/`dmstatus` report honestly that neither is possible). For most of
the file, `RESET_PC` points into a pattern that makes the CPU take an
illegal instruction and trap forever, so **every SBA access in the test is
arbitrating against a CPU hammering the bus**, which is the condition a
debugger actually runs in; the block RAM image (`sim/jtagram.hex`) plants a
real two-instruction increment loop at that same `RESET_PC` instead, so the
register-access checks have a hart that is actually computing something to
halt, not one already stuck in a trap loop that never touches a GPR.

`sim/tb_cpu_halt.v` drives halt/resume and register access directly against
`rtl/cpu_core.v` — no DMI, no `dm.v` — as the more exhaustive check of the
mechanism itself (GPR stability while halted, an unrecognized `regno`, a
debug write surviving a resume/re-halt cycle).

`formal/fv_interconnect.v` proves the arbitration properties with four
masters, including that nothing without a write path can drive `s_we`.
