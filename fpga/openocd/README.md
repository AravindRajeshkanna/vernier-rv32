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

The Debug Module implements System Bus Access only: it reads and writes
memory, and it cannot halt the hart or read CPU registers. `gdb` will not work
— see `rtl/debug/README.md` for why that half was built first.

Reading a word:

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

## Sizes

32-bit accesses only. `sbcs.sbaccess8` and `sbaccess16` read back as
unsupported and asking for one sets `sberror = 4`. The bus is word-organised
and every sub-word shift in this SoC lives in `rtl/soc/cpu_wb.v`, on the CPU's
side of the interconnect — duplicating a shifter in order to debug the shifter
is the wrong direction.
