# Phase 2 — Break the memory ceiling

**64 KB of block RAM is what stood between this and anything Linux-shaped.**
256 KB costs 244 ECP5 block RAMs, which no ECP5 has, and the ULX3S's 32 MB of
SDRAM was unreachable because there was no memory controller.

There is one now. `rtl/soc/wb_sdram.v` is a Wishbone slave in front of a
16-bit SDR SDRAM, and `make sim_sdramboot` runs the SoC out of it:

```
=== SDRAM acceptance test ===
Running from 0x90000000 .. 0x90080228
Loaded image is 99 KB, against 64 KB of block RAM

  code is above SDRAM_BASE      ok
  image exceeds block RAM       ok
  96 KB .rodata reads back      ok
  256 KB unique addresses       ok
  byte lanes                    ok
  halfword lanes                ok
  block RAM still reachable     ok

SDRAM-TEST: PASS
```

## Hand-written, not LiteDRAM

This file previously said "LiteDRAM via LiteX is the well-trodden path", and
for DDR it would be the only sane one. This is *SDR*: no read levelling, no
write levelling, no calibration, no PHY training — a command truth table and
six timing numbers. Against that, LiteX is a Python build dependency producing
a blob this repo could not simulate against its own model, could not put
through CI without installing a generator, and could not gate. The controller
and its model together are about 750 lines that every existing verification
layer reaches.

| | |
|---|---|
| `rtl/soc/wb_sdram.v` | the controller: power-up, one open row, burst-of-2, byte lanes via DQM, refresh every 7.8 µs |
| `sim/sdram_model.v` | a 32 MB part that **refuses illegal protocol** rather than tolerating it |
| `sim/tb_sdram.v` | `make sim_sdram` — the controller at the bus, no CPU, no toolchain |
| `sim/tb_sdramboot.v` | `make sim_sdramboot` — the SoC executing from SDRAM |
| `software/soc/sdramtest.c` + `sdramtable.S` | a program that **cannot** be a block RAM program |

## The model is the interesting half

A permissive memory model would let almost any controller pass, because every
interesting SDRAM bug is a *protocol* bug and none of them corrupt data in a
way a write-then-read test notices in simulation. They corrupt data on a
board, at temperature, weeks later. So the model checks tRCD, tRP, tRC, tRFC,
tMRD, the 100 µs power-up interval, the refresh interval, row ownership, burst
containment and the A[10] auto-precharge bit, and it takes CAS latency and
burst length **from the mode register the controller actually programmed**
rather than from what the model would prefer.

Four deliberate breaks, each red:

| Break | What it printed |
|---|---|
| Power-up wait cut from 100 µs to 10 µs | `command issued before the 100 us power-up interval` |
| Refresh never becomes due | `no AUTO REFRESH within 2x tREFI - rows are losing data` |
| Read captured one cycle early | `[00000000] = beefzzzz, expected deadbeef` |
| High beat masked by the low byte lanes | `[00000200] = 11xx3399, expected 11223399` |

The third is the one worth looking at twice: the low halfword arrives in the
high position and the second capture finds the bus already tristated. That is
what a CAS-latency error looks like, and no amount of staring at a controller
finds it as fast as one line of output does.

tRAS and tWR pass with margin and could not be made to fire by breaking the
controller, so they were checked the other way round — raised past what the
controller does, both fire. A check that cannot go red is not a check.

**And the model still did not find the one real bug.** The refresh interval
timer and the state machine both wrote `refresh_due`; the state machine's
clear won, so a tick landing on the exact cycle a refresh was issued dropped
the newly-owed refresh. One cycle in 195, found by reading the controller. A
model watches the wire, and on any given run a refresh did arrive in time —
it has no opinion about whether the controller meant to and lost track. See
`docs/practices.md` §22.

## Why a 96 KB table rather than a 256 KB memory test

Because a memory test would have passed on block RAM. `wb_interconnect.v`
decodes `addr[31:24]` alone, so the whole 16 MB window reaches whichever slave
answers, and a slave indexes with only the address bits its size needs — a
sweep over 256 KB of *block RAM* completes and reports success while quietly
writing the same 64 KB four times (`sim/tb_ramboot.v`'s header is about
exactly this). Only a program whose own image exceeds block RAM cannot be a
block RAM program, so `software/soc/sdramtable.S` is 96 KB of `.rodata` where
each word holds its own byte offset. It checks itself, it needs no generator
and no committed blob, and it makes the link fail rather than shrink.

## What it costs, and the one open row

| | |
|---|---|
| Row hit | ~6 cycles |
| Row miss | ~8 cycles, one precharge and one activate |
| Refresh | every 195 cycles at 25 MHz, ~4 cycles |

One open row, not four per bank. Per-bank open rows would remove the
precharge from an interleaved pattern — and `rtl/soc/cpu_wb.v` now holds an
instruction cache and a data cache that between them absorb 96.3% of loads and
the whole of every loop, so what reaches this controller is mostly sequential
cache misses. That is an argument for measuring before building it, which is
this phase's own lesson applied to itself, not an argument that it would not
help.

## Two things this deliberately did not do

**SDRAM sits at 0x9000_0000 alongside block RAM, not instead of it.**
`wb_ram.v` carries the two page-table walker ports on its second block RAM
port. An SDRAM has no second port, so putting the walkers there means
arbitrating three requesters into one controller and running every Sv32 test
through SDRAM latency. Keeping both memories made this an addition that cannot
regress anything — the whole existing suite is untouched and green — and
leaves **Sv32 page tables in SDRAM** as the next step, named rather than
attempted in the same change.

**The window is 16 MB, not 32.** One base byte is one 16 MB slave, because the
interconnect decodes `addr[31:24]`. That is 256× block RAM and 30× the 521 KB
`fw_jump.bin` that Phase 5 needs, so it is not the binding constraint on
anything — but the part is 32 MB and half of it is unreachable until that
decode grows a per-slave mask.

## Wired to a board, but not yet run on one

The pins are placed. `fpga/constraints/ulx3s.lpf` carries all 39 SDRAM
signals, copied verbatim from the board's own `ulx3s_v20.lpf` and cross-checked
line-for-line against litex-boards' `radiona_ulx3s.py` — the same two-source
rule the SD pins went through, and the two agree on every one, including
`sdram_a[10]` at N19, the one pin that breaks the otherwise sequential run and
therefore the one a transcription would get wrong without noticing.

**Measured, on an LFE5U-85F with `--lpf-allow-unconstrained` not set:**

| | Fmax | LUT | Block RAM |
|---|---|---|---|
| Full SoC (`BOARD=ulx3s85-sdramcheck`) | **27.41 MHz** — PASS at 25 | 20% | 51% |
| The probe (`BOARD=ulx3s-sdram`) | 95.79 MHz | <1% | 0% |

27.41 MHz is **down from 30.77**, and this is the first place-and-route since
both the data cache and this controller landed, so the drop belongs to the pair
of them. The critical path is in neither: it runs from the CSR write-enable
decode to the ID/EX register file's load enable, 11.32 ns of logic against
26.03 ns of routing. Margin at the board's 25 MHz is now 10% rather than 23%.

**None of that was evidence about a chip**, and the chip settled it in two
runs. The first bitstream mostly worked and returned one wrong word in a
thousand — a read capture point sitting 5.4 ns before the part swapped one
burst beat for the next, and a write path with no hold margin at all because
the clock and the data left the FPGA together. `fpga/sdram_clk_out.v` now
clocks the part half a period out through an `ODDRX1F` and
`rtl/soc/wb_sdram.v` captures a cycle earlier to match; the two are a matched
pair. The re-run reads and writes **256 KB of external SDRAM, every address
distinct, with byte and halfword lanes and refresh** — `SDRAM-CHECK: PASS`.
Both logs, the arithmetic and what it cost to read the evidence properly are
in `fpga/README.md` and `docs/practices.md` §23.

**What 256 KB was not saying.** `wb_sdram.v` takes the row from
`wb_adr[24:12]`, so that sweep is all 512 columns, all 4 banks and **64 of
8192 rows** — row address bits A6..A12 never driven high through the CPU, on a
part a kernel needs 28 MB of. The gap is which bits toggle rather than how
many bytes are touched, so `sdramcheck.c` now writes and reads one word in
every one of the 8192 rows for 16,384 accesses, which runs in `make verify`;
forcing row bit A7 low makes it report 4,096 wrong rows while the 256 KB sweep
still passes. `make verilator_sdramfull` sweeps all 32 MB densely in about a
minute and measures a 4,031 ms retention interval against the short sweep's
31 ms.

**And it has run on the part.** `BOARD=ulx3s85-sdramfull` reports
`SDRAM-CHECK: PASS` on a ULX3S 85F over all 8192 rows, 8,388,608 unique words,
with the same 4,031 ms retention and 20 ms idle the model predicts — model and
silicon agreeing to the millisecond over 16 million accesses.
`docs/practices.md` §34.

Bring-up is two bitstreams, in the order that narrows the problem —
`fpga/README.md` has the procedure and the LED table:

| | |
|---|---|
| `BOARD=ulx3s-sdram` | `fpga/ulx3s_sdram.v` — no CPU at all. Five cumulative LEDs: power-up, one word, walking ones over the data, one address per address bit, and survival across a ~100 ms idle, which is what proves refresh |
| `BOARD=ulx3s85-sdramcheck` | `software/soc/sdramcheck.c` — the CPU, caches and interconnect in the path, running from block RAM and hammering 256 KB of SDRAM |
| `BOARD=ulx3s85-sdramfull` | the same program over the whole 32 MB. 256 KB was 64 of 8192 rows, so seven of the thirteen row address bits had never been driven high. **`SDRAM-CHECK: PASS` on the board** |

Both have simulations (`make sim_sdramprobe`, `make sim_sdramcheck`) and both
are gated in CI, because a bring-up instrument that is itself wrong turns "the
memory does not work" into a hunt through the memory, the pinout and the clock.

**The thing most likely to need attention was `sdram_clk`**, and it was. That
paragraph used to say a straight assignment "usually works, and usually is not
a measurement". The measurement arrived and it did not work.

## Getting a program into SDRAM on a board

A bitstream initialises block RAM at FPGA configuration time. SDRAM is external
and comes up holding nothing, so an image linked at 0x9000_0000 has no way to
get there — which is why the memory could be proven and still hold no code.

The boot ROM now takes one over the serial line:

```sh
./software/soc/uartload.py /dev/cu.usbserial-XXXX software/soc/sdramtest.bin
# then press reset on the board
```

It listens for a knock for 20 ms after reset, takes a 16-byte header (magic,
load address, length, CRC32), refuses an address outside RAM or SDRAM, and
checks the CRC before it jumps. `make sim_uartload` runs the whole path — host,
ROM, SDRAM, running program — and is gated in CI.

**It is stop-and-wait, a byte at a time**, and that is the interesting part.
`rtl/uart.v`'s receiver is one byte deep with no FIFO, so a transfer that
streams depends on the receiver keeping up with the line: true with 31× margin
at 115200 on a 25 MHz board, false in simulation at four clocks per bit, where
the ROM is 1.8× too slow. An earlier version acknowledged every 256 bytes and
believed that removed the dependence; it only divided it by 256.
`docs/practices.md` §24.

That loader is also the **first user of `rtl/uart.v`'s receive path** — nothing
in this project had ever transmitted *to* the SoC, so that half of the UART was
untested RTL until now.

**Done when:** ~~the SoC runs a program larger than 64 KB from external
memory~~ — **done, on silicon.** A 99 KB program sent over the serial line into
external SDRAM on a ULX3S v3.1.8 / LFE5U-85F, fetched and executed from there,
checking 96 KB of its own `.rodata` and sweeping 256 KB — `SDRAM-TEST: PASS`.
The log is in `fpga/README.md`.

That is the whole phase as it was written at the top of this section: 64 KB of
block RAM is no longer what stands between this and anything larger.

**Still open**, and worth keeping separate because they are different sizes of
job — the loader that used to head this list is done:

| | |
|---|---|
| ~~A loader, so code can run *from* SDRAM on a board~~ | **done** — the boot ROM takes an image over the serial line. See below |
| Sv32 page tables in SDRAM | `wb_ram.v` carries the walker ports on block RAM's second port, and an SDRAM has none |
| The 16 MB window | one base byte is one 16 MB slave under this decode; the part is 32 MB |

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

SDRAM is proven on silicon. `BOARD=ulx3s85-sdramfull` reports `SDRAM-CHECK: PASS` on a ULX3S 85F over all 8192 rows and 8,388,608 unique words, and a 99 KB program sent over the serial line ran from SDRAM on a ULX3S v3.1.8 / LFE5U-85F. The full SoC closes at 27.41 MHz with the SDRAM controller in. The phase's "Done when" is met on hardware. What stays open is listed in the "Still open" table above (Sv32 page tables in SDRAM and the 16 MB window).

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

`make sim_sdramboot` runs the SoC out of SDRAM and ends with `SDRAM-TEST: PASS`; the controller is checked against a behavioural SDRAM model whose own fidelity is described in "The model is the interesting half" above.
