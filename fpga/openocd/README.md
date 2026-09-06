# Talking to the debug path

**Nothing here has been run against a board.** `make sim_jtag` proves the path
against the RTL; an adapter has never been connected. Treat `vernier.cfg` as a
considered starting point, not a working recipe.

## What you need

Four wires from an FT2232-class adapter to the `gn` header:

| Signal | Pin |
|---|---|
| TCK | `gn[2]` |
| TMS | `gn[3]` |
| TDI | `gn[4]` |
| TDO | `gn[5]` |

Plus ground. **Not** the ULX3S's own JTAG connector — that TAP belongs to the
ECP5's configuration engine and is what `openFPGALoader` uses.

## The first thing to check

```sh
openocd -f fpga/openocd/vernier.cfg
```

`scan_chain` should report one TAP with IDCODE `0x15256fff`. If it reports
`0x00000000` or all ones, the chain is not reaching the FPGA — check ground
and the pin mapping before anything else. If it reports the *ECP5's* IDCODE
you are on the wrong connector.

## What works, and what will not

The Debug Module does System Bus Access, and, since #79-81, real
halt/resume/register access over Abstract Command too - both proven
against the RTL (`make sim_jtag`), neither run against a real adapter, per
the caveat at the top of this file. **`gdb` will not work regardless of
either.** OpenOCD's own RISC-V target driver expects the debug spec's
full model - genuine debug-mode entry, a debug ROM, Program Buffer
instruction injection - and this Debug Module answers a hand-rolled DMI
client (`sim/tb_jtag.v`), not a standards-following one. `rtl/debug/README.md`
has the full account of what was built instead and why.

Reading a word from memory (System Bus Access):

```
riscv dmi_write 0x10 0x1          ;# dmcontrol.dmactive = 1
riscv dmi_write 0x38 0x00140000   ;# sbcs: 32-bit, read-on-address
riscv dmi_write 0x39 0x90400000   ;# sbaddress0 - the write triggers the read
riscv dmi_read  0x3c              ;# sbdata0
```

Dumping a region: also set sbcs bit 16 (autoincrement) and bit 15
(read-on-data), then read `0x3c` repeatedly.

Writing:

```
riscv dmi_write 0x38 0x00040000   ;# 32-bit, read-on-address off
riscv dmi_write 0x39 <address>
riscv dmi_write 0x3c <value>
```

`dmi_write 0x10 0x3` sets `ndmreset` alongside `dmactive` and resets
everything except the debug path itself.

Halting, reading a register, and resuming (Abstract Command):

```
riscv dmi_write 0x10 0x80000001   ;# dmcontrol: dmactive=1, haltreq=1
riscv dmi_read  0x11              ;# dmstatus - poll until allhalted (bit 9)
riscv dmi_write 0x17 0x0022100a   ;# command: read (aarsize=32-bit,
                                   ;# transfer=1, write=0), regno 0x100a = x10/a0
riscv dmi_read  0x04              ;# data0 - a0's value
riscv dmi_write 0x10 0x40000001   ;# dmcontrol: dmactive=1, resumereq=1
```

Writing a0 instead: `command = 0x0023100a` (same fields, `write=1`), value
staged into `data0` (`0x04`) *before* the `command` write, not after -
matching `rtl/debug/dm.v`'s Abstract Command FSM, which latches `data0` at
the moment it sees the `command` write. GPRs are `regno` `0x1000`-`0x101f`
(x0-x31); `dcsr` is `0x07b0`, `dpc` is `0x07b1`.

## Sizes

32-bit accesses only. `sbcs.sbaccess8` and `sbaccess16` read back as
unsupported and asking for one sets `sberror = 4`. The bus is word-organised
and every sub-word shift in this SoC lives in `rtl/soc/cpu_wb.v`, on the CPU's
side of the interconnect — duplicating a shifter in order to debug the shifter
is the wrong direction.
