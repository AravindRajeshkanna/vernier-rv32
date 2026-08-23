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
| `dm.v` | Debug Module: DMI registers, and System Bus Access as a fourth Wishbone master |

## What it does, and what it deliberately does not

**It does:** read and write SDRAM, block RAM and every peripheral register;
dump a device tree, a page table or a kernel log out of a machine that is not
talking; load a program without the boot ROM's 22-minute serial transfer;
assert `ndmreset` to restart the SoC without touching the board.

**It does not:** halt, resume or single-step the hart; read CPU registers or
CSRs; set a breakpoint.

That split is the design, not a stopping point. The RISC-V spec offers two
ways for a debugger to reach memory — abstract commands and the program
buffer, which make the *hart* do it, and System Bus Access, which uses a bus
master that has nothing to do with the hart. This implements the second.

Two reasons, and the second is the one that decided it.

**It is the half this project keeps needing.** "OpenSBI hangs before its
console comes up." "The boot ROM prints nothing." "Linux dies between
`earlycon` and `ttyS0`." Every one of those is *the memory is fine and I
cannot see it*, and none of them needed the hart stopped.

**Halt/resume lands on the critical path.** It needs debug mode, `dcsr`,
`dpc`, `dret` and a debug ROM the core vectors into — which touches the fetch
redirect and the register file write port. Two of six placement seeds already
fail to close 25 MHz (`fpga/README.md`). Adding to that path before the margin
is fixed would turn an intermittent build failure into a permanent one. This
module touches the CPU nowhere: it is a bus master and one reset term.

`dmstatus` says all of this honestly — `allrunning` is hardwired 1, `haltreq`
is accepted and ignored — so a debugger that tries to halt gets a hart that
never halts rather than a lie.

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
then SBA reads, writes, autoincrement and a distant address. Throughout,
`RESET_PC` points into the test pattern so the CPU takes an illegal
instruction, vectors to a zeroed ROM and traps forever — **every debug access
in the test is arbitrating against a CPU hammering the bus**, which is the
condition a debugger actually runs in.

`formal/fv_interconnect.v` proves the arbitration properties with four
masters, including that nothing without a write path can drive `s_we`.
