# FPGA integration — status and honest caveats

**This SoC boots Linux to userspace on a ULX3S / LFE5U-85F.** Built against
the board's real pinout, closing timing at the board's 25 MHz, with a 7.4 MB
image — OpenSBI, a device tree and an rv32ima kernel with an initramfs — sent
over the serial line into 32 MB of external SDRAM by the boot ROM's own
loader, and `/init` printing back the ISA string the kernel parsed out of
`dts/soc.dts`.

Everything below is measured on that board or on the same design in
simulation, and which of the two is stated every time. What is still *not*
proven on silicon is the SD card, video scan-out, and PLIC interrupt
*delivery* — the controller is probed and mapped, but nothing has yet made it
fire on hardware.

Timing is the one number that should worry you: the margin at 25 MHz is
approximately zero and two of six placement seeds fail to close. See [Fmax is
a distribution](#fmax-is-a-distribution-not-a-number).

| Artifact | Status |
|---|---|
| Full SoC synthesis (yosys) | ✅ **runs, ~19 s** |
| Place-and-route (`nextpnr-ecp5`) | ✅ **runs** — 4 min on an 85F, 11 min on a 45F |
| Bitstream (`ecppack`) | ✅ **`ulx3s_top.bit`** — 1.1 MB on a 45F, 2.1 MB on an 85F |
| Resource usage | ✅ **measured** — 17,435 TRELLIS_COMB (20%) / 80 DP16KD (38%) / 4 MULT18X18D on an 85F; the 45F figures are stale |
| **Real pinout** | ✅ **`constraints/ulx3s.lpf`**, every pin placed, no `--lpf-allow-unconstrained` |
| **Fmax with I/O constrained** | ⚠️ **24.69–27.63 MHz** (85F, six placement seeds) — **two of six land under the board's 25 MHz and nextpnr fails the build**. Margin is approximately zero; `synth_ecp5.sh` retries seeds. See [Fmax is a distribution](#fmax-is-a-distribution-not-a-number) and [the critical path](#the-critical-path-and-one-attempt-that-did-not-work) |
| `constraints/generic.lpf` | ❌ still placeholders — superseded by `ulx3s.lpf` |
| `synth/vivado.tcl` | ❌ never executed |
| Running on a board | ✅ **ULX3S / LFE5U-85F** — boots, runs the acceptance test, `SOC-TEST: PASS` |
| Surviving a reset | ✅ **fixed** — `.data` is rebuilt at startup; two consecutive board runs are byte-identical |
| newlib / `printf` on a board | ✅ **works** — `NEWLIB-PROBE: PASS`; the old failure was the `.data` bug above, not libc |
| SD card on a board | ❌ **CMD0 unanswered** by a 64 GB SDXC card; untested below 32 GB |
| **SDRAM pins** | ✅ **confirmed on silicon** — every address, bank and byte lane, and refresh |
| **All 32 MB of SDRAM** | ✅ **confirmed on silicon** — every one of 8192 rows, 8M unique words, 4,031 ms measured retention. `BOARD=ulx3s85-sdramfull` |
| **SDRAM as data, on a board** | ✅ **`SDRAM-CHECK: PASS`** — failed first at one word in a thousand; see the clock-phase diagnosis below |
| Running *code* from SDRAM on a board | ✅ **`SDRAM-TEST: PASS`** — a 99 KB program sent over UART, run from SDRAM |
| Video scan-out on a board | ❌ **not routed** — needs a PLL and a TMDS serializer |
| **Sv32 MMU on a board** | ✅ **confirmed on silicon** — Linux runs its whole linear map through it |
| **PLIC on a board** | ⚠️ **probed, not fired** — Linux maps 8 interrupts over 2 contexts; no interrupt has been *delivered* on silicon. `BOARD=ulx3s85-plictest` settles it in one flash |
| **ns16550 console on a board** | ✅ **confirmed on silicon** — `ttyS0 ... is a 16450`, and the handover from the SBI earlycon is clean |
| **Loading 7.4 MB over UART** | ✅ **confirmed on silicon** — 22 minutes, CRC ok, no retries |
| **Linux to userspace on a board** | ✅ **`=== VERNIER-RV32-LINUX-BOOT-OK ===`** — see [Linux, on the board](#linux-on-the-board) |
| **JTAG debug path** | ⚠️ **simulated only** — TAP, DTM and a Debug Module with System Bus Access, on `gn[5:2]`. No adapter has been connected. `rtl/debug/README.md` |

## Linux, on the board

Verbatim from `software/soc/uartload.py`, which hands the console over once
the transfer is accepted, on a ULX3S / LFE5U-85F built from `BOARD=ulx3s85`:

```
7744876 bytes -> 0x90000000 (SDRAM), CRC32 7C7134CE
  at 115200 baud that is about 22 minutes - it is stop-and-wait,
  a round trip per byte (see below)
knocking - press reset on the board
  ROM answered
  sent 7744876/7744876 (100%)
  accepted; the board is running it

UART loader: 0x00762D6C bytes at 0x90000000, CRC ok
  starting program

OpenSBI v1.9-11-gc0f87f10
Platform Name               : From-scratch RV32IMA Wishbone SoC
Platform Timer Device       : aclint-mtimer @ 25000000Hz
Platform Console Device     : uart8250
Firmware Base               : 0x90080000
Firmware Size               : 569 KB
Boot HART Base ISA          : rv32ima
Boot HART ISA Extensions    : zicntr
Boot HART PMP Count         : 0
Domain0 Next Address        : 0x90400000
Domain0 Next Arg1           : 0x91e00000
Domain0 Next Mode           : S-mode

Linux version 6.18.45 (aravindrajeshkanna@iMac) (riscv64-unknown-elf-gcc
  (g1b306039a) 15.1.0, Homebrew LLD 21.1.8) #2 Sat Aug 22 15:53:52 IST 2026
OF: fdt: Ignoring memory block 0x80000000 - 0x80040000
OF: fdt: Ignoring memory range 0x90000000 - 0x90400000
Machine model: From-scratch RV32IMA Wishbone SoC
riscv: base ISA extensions aim
Memory: 24316K/28672K available (2384K kernel code, 512K rwdata, 410K rodata,
  155K init, 188K bss, 3988K reserved, 0K cma-reserved)
SBI misaligned access exception delegation ok
clocksource: Switched to clocksource riscv_clocksource
riscv-plic: plic@3000000: mapped 8 interrupts with 1 handlers for 2 contexts.
4000000.serial: ttyS0 at MMIO 0x4000000 (irq = 1, base_baud = 1562500) is a 16450
printk: legacy console [ttyS0] enabled
printk: legacy bootconsole [sbi0] disabled
clk: Disabling unused clocks
Freeing unused kernel image (initmem) memory: 152K
Run /init as init process

=== VERNIER-RV32: USERSPACE ===
kernel  : Linux 6.18.45
machine : riscv32
pid     : 1

--- /proc/cpuinfo ---
processor       : 0
hart            : 0
isa             : rv32ima_zicntr_zicsr_zifencei_zaamo_zalrsc
mmu             : sv32
mvendorid       : 0x0
marchid         : 0x0
mimpid          : 0x0
hart isa        : rv32ima_zicntr_zicsr_zifencei_zaamo_zalrsc

=== VERNIER-RV32-LINUX-BOOT-OK ===
reboot: Power off not available: System halted instead
```

### What that transcript settles

Six things were listed here as owed to a board before this was worth trying.
All six are answered, and the answers are in the lines above rather than in a
plan:

**The Sv32 MMU runs on silicon.** `mmu : sv32`, and the kernel's entire linear
map is 4 KB pages walked by `rtl/mmu.v`. Nothing before this had ever enabled
paging on hardware — the ITLB defect fixed in #28 was found in simulation
precisely because no bare-metal program here pressures a TLB.

**The ns16550 is a real console.** `ttyS0 ... is a 16450` is the device tree
correction from #32 taking effect on hardware, and the handover from the SBI
earlycon to `ttyS0` is clean — which also settles the **3.1% baud error** this
file has flagged since the beginning. OpenSBI and Linux both program divisor
14 for 111,607 baud against the host's 115,200, and every byte after the
handover in that transcript came through an FTDI at the nominal rate. It is
inside a frame's tolerance and now it is inside a frame's tolerance
*measured*.

**The UART loader carries a 7.4 MB image.** 7,744,876 bytes, stop-and-wait, a
round trip per byte, CRC verified by the ROM before it jumps — in one attempt,
with no dropped byte in 7.7 million. That is the all-or-nothing risk this file
warned about, retired by doing it.

**`base_baud = 1562500`** is 25 MHz / 16, so the kernel derived the divisor
from `clock-frequency` in `dts/soc.dts` and got the same answer OpenSBI did.

**The device tree's block-RAM node was harmless, as predicted.**
`OF: fdt: Ignoring memory block 0x80000000 - 0x80040000` — `dts/soc.dts`
declares 256 KB there and a board build has 64 KB, and `arch/riscv` drops the
range anyway because it sits below `phys_ram_base`. The lie never reached
anything that could act on it. It is still a lie and still worth fixing.

**PLIC interrupt delivery is the one thing not settled.** `mapped 8 interrupts
with 1 handlers for 2 contexts` is a successful *probe*: the driver read the
register map and claimed its contexts. Nothing in that boot proves an
interrupt was ever *taken* — the 8250 console path polls `THRE`, and `/init`
does not wait on anything. `make sim_plic` delivers one to S-mode in
simulation; silicon has not.

## Fmax is a distribution, not a number

Every Fmax in this file until now was one place-and-route run. nextpnr's
placer is a simulated-annealing search seeded from a constant, so a single
run is one sample, and the spread turns out to be **wider than the margin
being reported**:

| Target | Seed | Routed Fmax | at 25 MHz |
|---|---|---|---|
| `ulx3s85` | default | **27.63 MHz** | PASS, 10.5% |
| `ulx3s85` | 2 | **27.07 MHz** | PASS, 8.3% |
| `ulx3s85` | 3 | **25.47 MHz** | PASS, 1.9% |
| `ulx3s85-ram` | 2 | **26.62 MHz** | PASS, 6.5% |
| `ulx3s85-ram` | default | **24.87 MHz** | ❌ **FAIL** |
| `ulx3s85-ram` | 1 | **24.69 MHz** | ❌ **FAIL** |

Yosys 0.68+118 (144c707b7), nextpnr 0.11.1-8-g7c0c1c40, every pin
constrained. Reproduce any of them with
`PNR_EXTRA="--seed 3" BOARD=ulx3s85 ./fpga/synth/synth_ecp5.sh`.

**Two of six are under the constraint, and nextpnr treats that as a hard
error** — it prints `ERROR: Max frequency ... (FAIL at 25.00 MHz)`, reports
`0 warnings, 1 error` and exits 1, after eight minutes of place-and-route.
Whether a build succeeds is a weighted coin decided by a placement seed.

The first three rows of that table were this file's claim after the Linux
work: *"three seeds, all PASS, worst case 1.9% margin"*. That was three
samples of one target, and it was too optimistic — the very next build anybody
ran, `BOARD=ulx3s85-ram` on a bench, drew 24.87 and failed. Three samples do
not find a tail. **The margin here is approximately zero**, and the honest
summary is that this design does not reliably close 25 MHz.

`synth_ecp5.sh` now retries placement seeds until one closes (`SEED_TRIES`,
default 6) and prints which one won. That is the standard answer to a marginal
design and it is a mitigation, not a fix: a bitstream produced on the fourth
seed is exactly as correct as one produced on the first — the constraint is
met or it is not — but a design that needs four seeds is one bad change away
from needing forty. **Shortening the critical path is the actual fix** and is
now the top item on the pre-board list.

So "25.37 MHz, 1.5% margin" was not wrong; it was underspecified in a way that
hid a build-breaking tail. One draw from a distribution, reported as a
property of the design.

The re-measurement was overdue for a real reason — six RTL-changing commits
had landed since the last one, including the PLIC moving to the spec register
map, `rtl/uart.v` becoming an ns16550, 64-bit `mcycle`/`minstret`, and a
32-bit comparator inserted directly into the fetch path. All of that, and it
still closes.

**Read the routed number, not the placed one.** nextpnr prints "Max frequency"
twice, and on this design they disagree enormously:

```
Info: Max frequency ... : 21.51 MHz (FAIL at 25.00 MHz)   <- after placement
Info: Max frequency ... : 27.63 MHz (PASS at 25.00 MHz)   <- after routing
```

The first is an estimate made before the router has had a go at the critical
nets, and it is pessimistic by about 6 MHz here, consistently, on every seed.
Reading it costs a day of optimising a design that already passes — which is
exactly what nearly happened when these numbers were taken.

The critical path is now `CPU.mem_wb_rd_r` → the forwarding and hazard
comparators → `is_mret` → `pc`: 36.19 ns, writeback destination register
through to the next program counter. Area is 17,435 TRELLIS_COMB (20% of an
85F), 80 DP16KD (38%) and 4 MULT18X18D.

## The three peripherals Linux depends on, one bitstream each

Sv32, PLIC interrupt delivery and the ns16550's divisor latch are the parts of
this SoC that only *Linux* has exercised on silicon — and Linux exercises them
all at once, three million instructions in, with no way to attribute a failure
to any one of them.

```sh
make mmuimage    && BOARD=ulx3s85-mmutest   ./fpga/synth/synth_ecp5.sh
make plicimage   && BOARD=ulx3s85-plictest  ./fpga/synth/synth_ecp5.sh
make uart16550image && BOARD=ulx3s85-uarttest  ./fpga/synth/synth_ecp5.sh
openFPGALoader -b ulx3s fpga/build/ulx3s_top.bit
picocom -b 115200 /dev/cu.usbserial-XXXXXXX     # then tap reset
```

| Target | Verdict | What it adds to what simulation already proves |
|---|---|---|
| `ulx3s85-mmutest` | `MMU-SDRAM: PASS` | Sv32 with its page tables in the **external** part — the walkers, both TLBs and `wb_ptw.v` against a memory with real latency |
| `ulx3s85-plictest` | `PLIC-TEST: PASS` | **the one thing the Linux boot did not settle**: an interrupt actually *delivered*, to S-mode, through context 1 |
| `ulx3s85-uarttest` | `UART16550-TEST: PASS` | the divisor latch and register map, including reprogramming mid-character — which garbles on real silicon, and is meant to |

Each preloads its program into block RAM, so the boot ROM jumps straight to it
and the SD card is never touched. `cat fpga/build/ulx3s_top.bit.target` before
flashing — several targets write that one filename.

### One of them does not build today

`BOARD=ulx3s85-plictest` was run end to end to prove the target works, and it
**failed to close timing on four consecutive placement seeds**:

```
seed 1   23.79 MHz FAIL      seed 3   23.67 MHz FAIL
seed 2   24.81 MHz FAIL      seed 4   24.19 MHz FAIL
error: no placement seed closed timing in 4 attempts.
```

The target definition is correct — yosys and nextpnr both accept it, the
preload is stamped, and the fail-closed behaviour did its job by leaving no
bitstream and no stamp behind. What stopped it is the design's timing margin,
and this is the first time that margin has prevented work rather than merely
threatened to.

Read against everything else measured on this board, the distribution has
walked downward as the design has grown:

| Target | Seeds passing | Range |
|---|---|---|
| `ulx3s85`, before the debug path | 3 of 3 | 25.47–27.63 MHz |
| `ulx3s85-ram`, before the debug path | 1 of 3 | 24.69–26.62 MHz |
| `ulx3s85`, with the debug path | 1 of 3 | 24.44–25.20 MHz |
| `ulx3s85-plictest` | **0 of 4** | 23.67–24.81 MHz |

Those are different netlists rather than one experiment with a variable moved
(§38), so the table is a description and not an attribution. The conclusion it
supports is weaker than a cause and strong enough to act on: **25 MHz is no
longer reliably reachable, and a fetch pipeline stage is now blocking three
things** — this bitstream, hart control in the Debug Module, and any further
growth of the design.

**Why `plictest` is the one to flash first.** `riscv-plic: mapped 8 interrupts
with 1 handlers for 2 contexts` in the Linux transcript is a successful
*probe*: the driver read the register map and claimed its contexts. Nothing in
that boot required an interrupt to be **taken** — the 8250 console path polls
`THRE`, and `/init` waits on nothing. So interrupt delivery is the last part of
the interrupt path that exists only in simulation, and it is the one a bare
program can settle in a second.

## The critical path, and one attempt that did not work

The margin at 25 MHz is approximately zero and two of six seeds fail to close.
This is what is known about *why*, and what has been tried.

**The path**, read out of nextpnr rather than guessed:

```
CPU.pc  →  IMMU.tlb_super  →  BUSADAPT.imem_addr  →  BUS.sel_m0  →  stall terms
        →  CPU.id_ex_pred_target                                        39.68 ns
```

In words: the program counter is translated by the instruction TLB, the
physical address goes to the bus, the bus decides whether the fetch master is
granted, and that decision feeds the stall logic that clocks the pipeline
registers — **all combinationally, in one cycle**. The design has no fetch
pipeline stage; translation, arbitration and the stall that gates ID/EX are a
single path from one flop to the next.

### The attempt

PR #28 added `itlb_answer_stale = pa_va != pc` to the fetch path, and `pa_va`
is a mux selected by the MMU's walk state — so the comparator cannot start
until the walk resolves, and its output selects `imem_addr`. Since the IMMU's
`va` *is* `pc`, the predicate simplifies exactly:

```
pa_va != pc  ==  (state != S_IDLE) && (va_r != pc)
```

Both operands are registers, so the compare resolves at the clock edge in
parallel with the lookup rather than after it. The algebra is exact and the
behaviour was identical — both simulators still agreed cycle-for-cycle, with
`+checkmmu` and `+checkdecode` clean.

**It made no measurable difference**, and the change was reverted.

| Seed | Before | After |
|---|---|---|
| 1 | 24.80 MHz FAIL | 22.36 MHz FAIL |
| 2 | 24.44 MHz FAIL | 25.05 MHz PASS |
| 3 | 25.20 MHz PASS | — |

One seed better, one worse, against a spread already measured at ~3 MHz. No
evidence of improvement, so it is not in the tree: a refactor of the fetch
path — the highest-risk region in this design, and where PR #28's defect lived
— needs a demonstrated win, not a plausible one.

### The second attempt: virtual indexing

Also tried, also not shipped, and it got considerably further — far enough to
be worth writing down as a design with two open questions rather than a dead
end.

`rtl/soc/cpu_wb.v` indexes its 256-entry instruction cache with
`imem_addr[9:2]` — the *physical* address — so three arrays cannot be read
until the TLB has answered, putting a memory access in series with translation
on exactly the path above. But **256 entries of 4 bytes is 10 address bits,
and Sv32 does not translate the low 12**: the index is a page offset, not a
translation of anything, so `imem_vaddr[9:2]` and `imem_addr[9:2]` are the
same bits. Indexing by the virtual address starts the read at the clock edge
and leaves only the tag comparison downstream of the TLB. That is textbook
VIPT, and it is sound here for a checkable reason rather than by convention.

What stops it being a two-line change is `itlb_pa_hold`. While an instruction
TLB walk is in flight the core holds the last address that *was* valid, and
that address's page offset belongs to an older PC — so index and tag would
describe different addresses. Two variants were built:

| | Linux | `+checkfetch` |
|---|---|---|
| virtual index, hold unchanged | **boots** | **reports wrong words** |
| virtual index, hold splices the live page offset | **hangs after `Run /init`** | — |

The first is behaviourally correct — `+checkdecode` is clean over 40 million
instructions and the boot reaches userspace — because the core is stalled for
the whole hold window and throws the fetch away. That is the problem: "the
wrong word, discarded" is a property of the stall rather than of the fetch,
and it is precisely the reasoning this file spends its length objecting to. It
also leaves `+checkfetch` printing mismatches, and the `verilator_check` gate
greps for the *read* summary rather than the fetch one, so nothing would have
caught it.

The second removes the mismatch by holding only the page number and splicing
the live offset on — making the pairing exact in every case — and hangs the
boot after `Run /init`, for a reason not yet diagnosed. The most likely
suspect is the bus traffic it newly generates: the held address stops being
one the cache is known to hold, so a stalled fetch now misses and issues reads
for a page it will never use, filling cache lines with entries tagged to the
old page number.

### The question, settled

Should `+checkfetch` check fetches the core *discards*? **No change: it should
keep checking them.**

Its invariant is that whenever the fetch unit presents data, that data is the
word memory holds at the address on the unit's own input. That is a property
of the fetch unit, independent of what the pipeline downstream does with it -
a cache returning data that does not correspond to its own address input is
broken whether or not somebody throws the result away. Weakening it to "only
what IF/ID latches" would hide cache bugs that a stall masks today and a
pipeline change unmasks tomorrow, which is the failure mode this entire file
is a record of.

So variant 1 stays rejected on its merits rather than on a technicality, and
any fix has to satisfy the probe rather than be excused from it.

### A third variant, and what all three actually proved

Variant 3 keeps virtual indexing and adds an eight-bit check that the index
and the tag describe the same address - in parallel with the tag comparison,
so the array read still starts at the clock edge. It satisfies `+checkfetch`
completely: 181 million fetches, all matching memory, 103 million decoded
instructions all matching their PC, 377 million translations all agreeing with
the page tables.

**And Linux hangs after `Run /init`, exactly as variant 2 did.**

Three variants is enough to see what they have in common, and it is not the
indexing:

| Variant | What the fetch does on the bus during an ITLB walk | Linux |
|---|---|---|
| 1, no gating | cache **hits** the held address, issues no request | **boots** |
| 2, hold splices the live offset | misses, **issues a request** | hangs at `execve` |
| 3, index/tag pairing checked | misses, **issues a request** | hangs at `execve` |

Every variant that changes the fetch unit's bus behaviour while a walk is in
flight hangs at userspace entry. The one that leaves it alone boots. The first
attempt in this section - gating both the hit and the request on a
"translation is current" signal, so the fetch neither hit nor requested - hung
too, which fits the same pattern: what all three failures share is
`ibus_wait` being *asserted* during an instruction-TLB walk, where today it is
deasserted by a cache hit on the held address.

**So the real finding is about `rtl/cpu_core.v`, not about the cache.**
Something in the stall or redirect logic cannot tolerate `ibus_wait` and an
ITLB walk being true at the same time, and the present design never exercises
that combination because the held address is always in the instruction cache -
by construction, since it was fetched moments earlier. The comment in
`cpu_core.v` that explains the hold describes this as a happy side effect. It
is load-bearing.

That is the thing to find, and it is worth finding independently of the timing
work: it is a latent fragility that any change to the fetch path will hit, and
the next one may not be a change that can be reverted. Virtual indexing is
then a small edit on top.

### A trap worth naming

Comparing "seed 1 before" against "seed 1 after" **is not a controlled
experiment**, and reading that table as though it were is the easy mistake. A
placement seed indexes a random trajectory through a *specific* netlist;
change the netlist and the same seed number is a different draw, not the same
run with one variable moved. Two samples against three, on a distribution
3 MHz wide, cannot resolve a change of this size in either direction. The
honest statement is "no demonstrated effect", not "it helped" and not "it
hurt".

### What would actually work

Two candidates now, in increasing order of cost.

**Virtual indexing**, above — smaller, half-built, and blocked on one
interaction rather than on a design question.

**Pipelining the fetch**: register the translated address so the TLB lookup and
the bus request fall in different cycles. That is a real microarchitectural change
— it costs a cycle of fetch latency, and the I-cache, the BTB and the redirect
logic all have to cope — and it deserves its own change and its own
verification rather than being appended to something else. It is also the
thing standing between this design and hart control in the Debug Module
(`rtl/debug/README.md`).

## What 256 KB of SDRAM was and was not saying

`SDRAM-CHECK: PASS` over 256 KB has been this project's evidence that external
memory works. It is true, and much narrower than it sounds.

`rtl/soc/wb_sdram.v` maps `wb_adr[24:12]` to the row, `wb_adr[11:10]` to the
bank and `wb_adr[9:1]` to the column. So 256 KB is:

- **all 512 columns** ✅
- **all 4 banks** ✅
- **64 of 8192 rows** — row address bits **A6 through A12 never driven high**

Every bank and every column, and one two-hundredth of the rows, behind seven
address lines that had never been asserted through the CPU. A kernel needs
about 28 MB.

`software/soc/sdramcheck.c` now says so in its own output, so the short run
reports how short it is:

```
SDRAM window at 0x90000000, sweeping 256 KB of 32768 KB, against 64 KB of block RAM
  rows 0..63 of 8192, all 4 banks, all 512 columns
  the dense sweep leaves row address bits A6..A12 low; test 3 drives them
```

**The gap is which bits toggle, not how many bytes are touched**, and those
separate cleanly. One word in each of the 8192 rows drives every row address
bit for 16,384 accesses — nothing, in simulation terms — so it runs in
`make verify` on every change:

```
  all 8192 rows, one word each  ok
```

It fails when it should. Forcing row bit A7 low in `wb_sdram.v` gives:

```
  4096 of 8192 rows wrong, first at 0x90000000 (row 0)
  all 8192 rows, one word each  FAILED
  256 KB unique addresses       ok        <- the old test, on the same broken part
```

That last line is the argument for the whole change: the test this project has
been relying on passes a part with a dead address line.

### And the whole part, densely

`make verilator_sdramfull` sweeps all 32 MB — 8 million words written and read
back — in 261 million cycles, about a minute of Verilator, and it is in
`make verify`:

```
sweeping 32768 KB of 32768 KB, against 64 KB of block RAM
  rows 0..8191 of 8192, all 4 banks, all 512 columns
  all 8192 rows, one word each  ok
  32 MB unique addresses        ok
  4031 ms between writing the lowest address and reading it back
```

That last line is the one a kernel cares about and the one a short sweep could
never produce. The write pass runs bottom to top and so does the read-back, so
address 0 is read **four seconds** after it was written, with continuous
traffic through the same controller in between — against 31 ms at 256 KB. It
is measured off the CLINT's `mtime`, not derived from a spin count: the two
comments on the old idle loop said "~100 ms" and "~10 ms" four lines apart,
and the real answer is 20 ms.

### And on the part

`BOARD=ulx3s85-sdramfull` bakes that exact image into a bitstream, and it has
now run. Verbatim from the board:

```
=== RV32IMA SoC boot ROM ===
RAM already holds a program (first word 0x00009197)
  skipping SD, starting it

=== external SDRAM check (running from block RAM) ===
SDRAM window at 0x90000000, sweeping 32768 KB of 32768 KB, against 64 KB of block RAM
  rows 0..8191 of 8192, all 4 banks, all 512 columns

  single word                   ok
  walking ones, 32 bits         ok
  all 8192 rows, one word each  ok
  32 MB unique addresses        ok
  4031 ms between writing the lowest address and reading it back
  byte lanes                    ok
  halfword lanes                ok
  idled 20 ms
  survives an idle              ok
  block RAM still reachable     ok

SDRAM-CHECK: PASS
```

**8,388,608 unique words, every row, every bank, every column, on silicon.**
The claim this file carried for months — "256 KB of external SDRAM" — is now
the whole 32 MB, and the seven row address bits that had never been driven
high through the CPU have been.

Two details in that transcript are worth more than the verdict.

**The board and the model agree to the millisecond.** Simulation reports
`4031 ms` and `idled 20 ms`; the board reports `4031 ms` and `idled 20 ms`.
Both are counted off the CLINT's `mtime` over the same instruction sequence at
the same 25 MHz, so agreement is what *should* happen — and it is worth
checking precisely because it is the kind of thing that quietly does not. It
says the modelled controller and the real part take the same number of cycles
to do 16 million accesses, which is a stronger statement about
`rtl/soc/wb_sdram.v` than either run alone.

**Retention is now a measurement rather than an argument.** Four seconds
between writing the lowest address and reading it back, under continuous
traffic through the same controller, on the actual part at the actual refresh
interval. The old evidence for refresh was a 100 ms idle in the CPU-less
probe.

What a behavioural model still cannot show is marginality — the lesson this
file carries from the clock-phase failure, where simulation proved the design
self-consistent and one word in a thousand came back wrong on the part. That
is why this section ends with a board transcript and not a simulation log.

## The JTAG header, and what it costs

`gn[2]` TCK, `gn[3]` TMS, `gn[4]` TDI, `gn[5]` TDO — four ordinary header
pins reaching a bus master that can read and write any address the SoC
decodes, whether or not the CPU is cooperating. `rtl/debug/README.md` is the
design; this is its effect on the fitter.

**Not the ECP5's own JTAG.** That TAP belongs to the configuration engine and
is what `openFPGALoader` talks to. These are four GPIO pins and any
FT2232-class adapter drives them.

**The three inputs are pulled down in the LPF, and that is load-bearing.** An
unconnected CMOS input floats, and a floating TCK on a board with no debug
cable is an oscillator: it would clock the TAP through a random walk, and a
random walk that reaches Update-DR with the DMI instruction selected issues a
bus write with whatever bits happened to shift in. A pulldown makes "no cable"
mean "no clock".

### Measured, on `BOARD=ulx3s85`

| | With the debug path | Before it |
|---|---|---|
| System clock, seed that closed | **25.20 MHz** | 24.69–27.63 over six seeds |
| Seeds that failed to close | 2 of 3 | 2 of 6 |
| TCK domain | **169.66 MHz** against a 15 MHz constraint | — |
| TRELLIS_COMB | **17,021** | 17,435 |
| DP16KD | 80 (38%) | 80 (38%) |

**The critical path is CPU-internal at both ends** — source
`CPU.pc_TRELLIS_FF_Q_26`, sink `CPU.id_ex_pred_target_TRELLIS_FF_Q_26`,
39.68 ns — and contains no cell from `rtl/debug/`. That is the measurement
behind the claim that this touches the CPU nowhere: it is a bus master and one
reset term, and the fitter agrees.

TCK is constrained explicitly at 15 MHz rather than left to nextpnr's 12 MHz
default, because a number nobody chose should not appear in a timing report
next to one that was measured. It closes at eleven times that, which is what a
handful of flip-flops and a 41-bit shift register ought to do.

**Two things this table does not say.** Three seeds cannot distinguish a real
shift in the failure rate from noise against six — the design was marginal
before this and is marginal after it, and the fix for that is the critical
path, not this module. And the LUT count went *down* by 414, which I have not
accounted for; the debug logic is demonstrably in the netlist (nextpnr times
the TCK domain and reports cells under `SOC.TAP` and `SOC.DM`), so it is not
that the module vanished.

## Before you flash: check what the bitstream is

**Six board targets write the same `fpga/build/ulx3s_top.bit`** — `ulx3s85`,
`-ram`, `-probe`, `-trapcheck`, `-sdramcheck`, `-sdramfull` — carrying six
different programs, and `openFPGALoader` cannot tell them apart. Every build
now writes a stamp beside it saying which one it is:

```sh
$ cat fpga/build/ulx3s_top.bit.target
board:     ulx3s85-ram
top:       ulx3s_top
device:    LFE5U-85F CABGA381
lpf:       fpga/constraints/ulx3s.lpf
built:     2026-08-22T16:04:11Z
preloaded: sim/ramimage.hex (from software/soc/socprog.elf)
boots:     straight into the preloaded program; the SD card is not touched
```

The bitstream and its stamps are **deleted before the build starts**, so a run
that dies anywhere — nextpnr erroring, `ecppack` missing from `PATH`, a `^C` —
leaves no bitstream at all rather than the previous target's. A missing file
cannot be misread; a stale one is indistinguishable from a fresh one at the
moment you flash it.

Each build also lands at `fpga/build/<BOARD>.bit`, so a bring-up session can
keep several without re-running place-and-route.

**This is written down because it cost a session.** A `BOARD=ulx3s85-ram`
build failed in nextpnr — it drew a placement seed that missed 25 MHz by
0.13 MHz, and nextpnr fails the build over that. The bitstream from an earlier
`BOARD=ulx3s85` run stayed behind; the board was flashed with it and came up
with nothing in block RAM, fell through to the SD path it was specifically
meant to avoid, and printed:

```
=== RV32IMA SoC boot ROM ===
SPI/SD init...
  CMD0 failed after 10 tries: 0x000000FF
BOOT FAILED: no SD card
```

Every line of that is correct, and it is an accurate report about a bitstream
nobody meant to flash. The debugging it invites — the card, the slot, the SPI
wiring — is all downstream of a build that had already failed and said so.

The `.bit.ramimage.hex` stamp that existed to prevent exactly this was written
only by *preloading* targets, so the non-preload build overwrote the bitstream
and left the stamp behind, asserting that it carried a program that was no
longer in it. A stale absence is ambiguous; a stale assertion is misleading,
and it reads as evidence to somebody deciding whether to trust the artifact.

Both halves are tested:

```
$ SEED_TRIES=1 PNR_EXTRA="--seed 1" BOARD=ulx3s85-ram ./fpga/synth/synth_ecp5.sh
error: no placement seed closed timing in 1 attempts.
$ ls fpga/build/ulx3s_top.bit
ls: fpga/build/ulx3s_top.bit: No such file or directory
```

```
$ BOARD=ulx3s85-ram ./fpga/synth/synth_ecp5.sh
--- placement seed 1 of 6 ---
--- seed 1 did not close timing; trying another ---
--- placement seed 2 of 6 ---
--- timing closed on seed 2 ---
  carries:  sim/ramimage.hex  (stamped as ulx3s_top.bit.ramimage.hex)
  what it is: fpga/build/ulx3s_top.bit.target
  also as:  fpga/build/ulx3s85-ram.bit
```

If a board behaves like a different bitstream, `cat` the stamp before
debugging the design. `docs/practices.md` §35.

## The hardware run

Verbatim from `picocom -b 115200 /dev/cu.usbserial-D01595`, on a ULX3S with
an LFE5U-85F configured from `BOARD=ulx3s85-ram ./fpga/synth/synth_ecp5.sh`:

```
=== RV32IMA SoC boot ROM ===
RAM already holds a program (first word 0x00009197)
  skipping SD, starting it

MV

=== SoC acceptance test ===
Running from RAM at 0x800015F0

  RAM walking ones             ok
  RAM address uniqueness       ok
  RAM byte/half access         ok
  AMO read-modify-write        ok
  LR/SC success                ok
  LR/SC broken by store        ok
  GPIO pin readback            ok
  framebuffer read/write       ok
  CLINT mtime advances         ok
  misa reports I+M+A           ok
  cycle/time/instret           ok
  misaligned access traps      ok
  FENCE.I invalidates          ok

0 failure(s)
SOC-TEST: PASS
```

`0x00009197` is `_start`'s `auipc gp,0x9` and `0x800015F0` is `main` — both
match `nm software/soc/socprog.elf` for the build the bitstream was made from,
which is what makes this a report about *that* build rather than about
whatever was last flashed. (They read `0x00001197` and `0x80001248` when this
was first captured; the link script gained a separate load and run region for
`.data` since, which moved both.)

`MV` is not noise. `main` prints `M` on entry and `V` once it has installed its
own trap vector — two characters, before anything else can fail, so a board
that stops between reset and the first test still says how far it got.

The pinout is no longer fictional, which is a smaller claim than "this works"
but a real one: the numbers above come from builds where every port is locked
to the pin it will actually use, rather than ones where nextpnr could place
I/O wherever suited it. When that constraint was first applied it cost about
1 MHz (30.38 → 29.37 on a 45F), less than expected.

**What a board has now settled.** The ESP32 hold-off is sufficient in
practice — the board stays up. The FTDI console is legible at 115200 with no
tuning. The design runs at the ULX3S's 25 MHz oscillator without a PLL, which
is what the 30.77 MHz Fmax predicted. Bring-up took three bitstreams to get
there — a heartbeat, an SD probe, and the full SoC — and `ulx3s_diag.v` and
`ulx3s_cmd0.v` are kept in the tree because that is what made each failure
diagnosable rather than mysterious.

**What a board has not settled**, and this is the current list:

- **The SD card.** A 64 GB SDXC card never answers CMD0, which is permitted —
  SPI mode is optional above 32 GB — and it has not been distinguished from a
  wiring fault, because no smaller card has been tried. `BOARD=ulx3s-cmd0`
  answers that in seconds when one is.
- **PLIC interrupt delivery.** Linux probes the controller and claims both
  contexts on hardware, and nothing in that boot requires an interrupt to
  actually be taken — the 8250 console path polls. `make sim_plic` delivers
  one to S-mode in simulation; silicon has not.
- **Video scan-out**, which needs a PLL and a TMDS serializer.
- **Temperature, and long-run stability.** The longest thing this board has
  ever done is a 22-minute serial transfer followed by a Linux boot. Nothing
  has run for hours, and the timing margin is approximately zero.

## Why newlib died on this board: `.data` was never re-initialised

**Found, fixed, and regression-tested.** It was not newlib, the heap, or the
trap handler. `crt0_ram.S` never restored `.data`, and block RAM is
initialised when the FPGA is *configured*, not when the CPU is reset — so
tapping the reset button re-ran the program over memory the previous run had
already written. `_start` zeroed `.bss`; nothing rebuilt `.data`.

What that broke was newlib's stdio and nothing else. `__sinit` returns early
when `_impure_data.__cleanup` is non-NULL, and `__sinit` *sets* `__cleanup` on
success — so run 2 saw its own guard from run 1, skipped initialising stdout,
and left it with no `__SWR` bit. Every subsequent `printf` returned −1 and
printed nothing.

Which is why this looked like "printf hangs". It never hung. The program ran
straight past it — but `printf` was the only output channel at the time, so
"produced nothing" and "stopped" were the same observation. And because the
usual bring-up gesture is *flash, open a terminal, tap reset to catch the
banner*, essentially every run anyone ever watched was run two.

The SD path was never affected: there the loader copies the whole image,
`.data` included, on every boot. Only a preloaded bitstream re-runs stale
memory — and `make sim_ramboot` passed because it ran the program exactly
once.

The evidence chain, each link checked independently:

| Step | Finding |
|---|---|
| image says | `__cleanup` = `0x00000000` |
| board read at entry | `0x80002890` |
| `nm` says that is | `cleanup_stdio` — a value only `__sinit` ever stores |
| checksum arithmetic | that word is the **only** one of 4,834 that differed |
| consequence | `__sinit` skipped; `stdout` `_flags 0x40` = `__SERR`, no `__SWR` |

**The fix** is the standard embedded one this project never had.
`software/soc/link_ram.ld` now splits RAM into a `LOAD` region (`.text`,
`.rodata`, and `.data`'s initial values — never written) and a `RUN` region
(`.data` and `.bss` as the program uses them), and `crt0_ram.S` copies one to
the other at every startup. The image on the wire is unchanged: `.data`'s load
address still follows `.text` contiguously, so `objcopy -O binary` still emits
one flat blob.

The 4 KB hole between the two regions at `0x8000_8000` is deliberate — it is
the region the acceptance test's memory checks hammer, so the linker now fails
the build if the program grows into it instead of letting a memory test
overwrite live state.

**`make sim_rerun`** is the regression test: the program runs, the testbench
pulses reset *without* touching RAM, and it runs again. Both runs must pass.
It is in `make verify`. It uses the probe rather than the acceptance test on
purpose — the acceptance test keeps its state in `.bss`, which `_start` has
always zeroed, so it passes twice either way and would never have caught this.

### Confirmed on the board

Two consecutive runs on a ULX3S / LFE5U-85F from `BOARD=ulx3s85-probe`, the
second after a reset with no reconfiguration — which is precisely the case
that used to fail. The two transcripts are **byte-identical**, and the fields
that carried the bug read:

```
0  image 4925 words at 0x80001000...0x80005CF4
   rotate-xor checksum 0x29346809
   .data runs at 0x80009000, loaded from 0x80005C98, 23 words
   ok   crt0 rebuilt .data from the image
...
8  puts: this line came out of newlib's stdio
9  printf: 1234 formatted 0xdeadbeef
A  __cleanup at entry  0x00000000  NULL: __sinit was free to run
   stdout _flags 0x00000089 __SLBF(line-buffered) __SWR __SMBF(malloc'd buffer)

0 failure(s)
NEWLIB-PROBE: PASS
  traps taken: 0
```

Before the fix the second run read `__cleanup at entry 0x80002890`, `_flags
0x00000040 __SERR` with no `__SWR`, and `printf returned -1` with rungs 8 and
9 printing nothing at all. The checksum `0x29346809` is also what
`make sim_rerun` produces, so the silicon and the model agree on the image as
well as on the outcome.

## The instrument that found it

Neither of the two original candidates was right — the heap was fine (RAM
measures the full 64 KB, `_sbrk` and `malloc` both work) and nothing faulted
at all (`traps taken: 0`). But the handler was worth fixing on its own, and
without it none of the runs above would have been readable.

`crt0_ram.S`'s handler advanced `mepc` by 4 and returned from
**every** trap. That is correct for the one fault the acceptance test provokes
on purpose, and silently wrong for all the others: an illegal instruction, a
stray misaligned access, a jump into nothing were each stepped over, and the
program carried on with an instruction's effect simply missing. Nothing
downstream could tell that had happened — which also means the evidence for
diagnosing the printf failure was being destroyed as it was produced.

So the handler is now **loud**. A trap nobody armed prints `mcause` (spelled
out, not just numbered), `mepc`, `mtval`, `ra`, `sp` and the trap count, then
halts with `led[1:0]` alternating — a pattern no boot stage produces, so a
board with no serial cable still says "trapped" rather than sitting there the
way a successful run also does. Code that wants a trap arms one first
(`trap_arm()` in `software/soc/trap.h`), and only an armed trap is resumed.

Three bitstreams come out of this, all preloading their program into RAM
rather than booting off the card:

```bash
make ramimage    && BOARD=ulx3s85-ram       ./fpga/synth/synth_ecp5.sh   # acceptance test
make probeimage  && BOARD=ulx3s85-probe     ./fpga/synth/synth_ecp5.sh   # the newlib probe
make sim/trapimage.hex TRAPCHECK=1 && \
                    BOARD=ulx3s85-trapcheck ./fpga/synth/synth_ecp5.sh   # the handler itself
```

**Flash the third one first.** The probe's most likely outcome is a clean run
with no trap report, and that only means something if a trap report is known
to come out when there is one. `ulx3s85-trapcheck` provokes a deliberate fault
and must print the report:

| `TRAPCHECK=` | Fault | What it proves |
|---|---|---|
| `1` | unarmed misaligned load | the handler halts instead of stepping over |
| `2` | illegal instruction | the case the old handler silently skipped |
| `3` | the same, with `sp` already wrecked | the reporter's private stack works |
| `4` | a trap *during* the report | one `!`, then a halt — no report loop |

All four are checked in simulation by `make trapcheck`, which is part of `make
verify`; the board run is confirming that the silicon agrees. Case 4 exists
because that path is what runs when everything else has already failed, which
is the worst thing to leave unexecuted.

The probe (`software/soc/newlibprobe.c`) is a ladder. Each rung prints one
character *before* it runs, so a run that stops tells you where even if the
line never finished, and consecutive rungs differ by a single dependency:
RAM under the heap window → `_sbrk` → the memory `_sbrk` returned → `malloc`
→ `snprintf` (the formatter alone) → `puts` (stdio setup and `_write`) →
`printf`. It also measures where RAM actually wraps rather than trusting
`RAM_SIZE`, which is the first hypothesis answered outright.

It found the bug in three board runs, and each run narrowed it because the
rungs differ by one dependency: run 1 showed `printf` returning normally with
its output missing (so not a hang); run 2 showed `stdout` with no `__SWR` bit
and `_write` working when called directly (so not the driver); run 3 caught
`__cleanup` already set at entry, with checksum arithmetic proving it was the
only word in the image that differed.

Two of the probe's own readings were wrong before they were right, both caught
by keeping a simulation baseline to disagree with: it labelled `_flags 0x40`
as "fully buffered" when `0x40` is `__SERR`, and it sampled `__cleanup` *after*
stdio had run, where a healthy system also reads non-NULL. A diagnostic that
returns a confident wrong answer is worse than none, which is why
`make trapcheck` and the simulation baseline exist at all.

## Bringing up the SDRAM, in two steps

`rtl/soc/wb_sdram.v` is verified in simulation against a model that refuses
illegal protocol (`make sim_sdram`), and the SoC runs a 99 KB program out of it
(`make sim_sdramboot`). **None of that is evidence about a chip.** The pins are
placed from the board's own constraint file and cross-checked against
litex-boards, the bitstream builds, and timing closes — and a wrong SDRAM pin
does not fail loudly. It builds, it loads, and it quietly does not work.

So there are two bitstreams, in the order that narrows the problem. Both have a
simulation, because a diagnostic that arrives at a board untested turns "the
memory does not work" into a hunt through the memory, the pinout and the clock
when the fault is in the instrument.

### The first attempt, and what it was actually telling us

`BOARD=ulx3s85-sdramcheck`, flashed, verbatim from the console:

```
=== external SDRAM check (running from block RAM) ===
SDRAM window at 0x90000000, sweeping 256 KB against 64 KB of block RAM

  single word                   FAILED
  walking ones, 32 bits         ok
  first mismatch at 0x90001058: reads 0x47A5A808 want 0x47A5B808
  256 KB unique addresses       FAILED
  byte lanes                    ok
  halfword lanes                ok
  survives a short idle         ok
  block RAM still reachable     ok

SDRAM-CHECK: FAIL (2)
```

**Read that as "it very nearly works", not "it does not work".** The sweep is
65,536 words and the first failure is word 1,046; walking ones, both lane
tests and the idle test all passed. Whatever is wrong is marginal, and
marginal faults do not come from a pin being on the wrong ball.

Three things narrow it further:

1. **It is not aliasing.** `0x47A5A808` is not the pattern of *any* address in
   the 256 KB sweep — checked exhaustively, not eyeballed. So the read did not
   fetch some other location's data; the data itself came back corrupted.
2. **It is one bit.** `0x47A5B808 ^ 0x47A5A808 = 0x1000`, bit 12, in the *low*
   halfword — the first of the two 16-bit beats a 32-bit access is made of.
3. **That bit differs between the two beats.** The low half is `0xB808`
   (bit 12 set), the high half `0x47A5` (bit 12 clear). The value read is the
   *other beat's* value for that bit.

Point 3 is the whole diagnosis. The controller was capturing the first beat
one `tAC` — 5.4 ns — before the part replaced it with the second, so any DQ
line slower than its neighbours delivered the second beat's bit instead. It
can only ever go wrong on bits where the two beats disagree, which is exactly
what was seen and is why single-bit patterns passed.

The write side had it worse. With `sdram_clk` driven straight from the
oscillator, the clock edge and the data leave the FPGA together, so the part
sampled the bus at the moment the design changed it: a full period of setup
and **no hold at all**.

| At 25 MHz, tCK 40 ns, tAC 5.4 ns | into the window | out of it |
|---|---|---|
| Reads, clock aligned, capture at CL | 34.6 ns | **5.4 ns** |
| Reads, clock 180° out, capture at CL−1 | 14.6 ns | 25.4 ns |
| Writes, clock aligned | 40 ns | **0 ns** |
| Writes, clock 180° out | 20 ns | 20 ns |

So `fpga/sdram_clk_out.v` now emits the part's clock from an `ODDRX1F`, half a
period out, and `rtl/soc/wb_sdram.v` captures a cycle earlier to suit. **They
are a matched pair** — neither is correct without the other, which is why
there is no build option to go back to one of them.

**Confirmed on the board** — the run is immediately below. The arithmetic
above was a prediction when it was written, and it is worth keeping in that
form: a behavioural model cannot show marginality, so simulation passing proved
the design self-consistent and nothing more. What settled it was silicon.

### The re-run, on the board, with the clock moved

Same bitstream target, same board, after `fpga/sdram_clk_out.v` and the
matching capture point in `rtl/soc/wb_sdram.v`. Verbatim:

```
=== external SDRAM check (running from block RAM) ===
SDRAM window at 0x90000000, sweeping 256 KB against 64 KB of block RAM

  single word                   ok
  walking ones, 32 bits         ok
  256 KB unique addresses       ok
  byte lanes                    ok
  halfword lanes                ok
  survives a short idle         ok
  block RAM still reachable     ok

SDRAM-CHECK: PASS
```

**262,144 bytes of external SDRAM, every address distinct, through the CPU, the
caches and the interconnect.** The failing word rate went from one in a
thousand to none in 65,536, and the two changes that did it were a clock moved
half a period and a capture point moved one cycle.

The probe agrees, and reading it took one correction of its own. On the board
it showed `led[0..3]` steady with `led[4]` and `led[7]` blinking at different
rates, which looked like an intermittent refresh failure and was not: the probe
cleared every flag on each restart, and `led[4]` alone could not re-light until
the next 100 ms idle test finished, so it strobed at 3 Hz — exactly twice
`led[7]`'s rate — on a machine where everything worked. The flags now mean
"passed on the most recent attempt" and a working part shows five steady LEDs.
A diagnostic that reports success as a fault is worse than no diagnostic, which
is the same lesson as the failure rate this file opens with.

### Step 1 — the probe, with no CPU in it

```sh
make sim_sdramprobe                              # prove the instrument first
export PATH=~/tools/oss-cad-suite/bin:$PATH
BOARD=ulx3s-sdram ./fpga/synth/synth_ecp5.sh
openFPGALoader -b ulx3s fpga/build/ulx3s_sdram.bit
```

`fpga/ulx3s_sdram.v` drives the controller directly and reports through five
cumulative LEDs. It runs forever, so a marginal setup flickers rather than
showing a stable wrong answer:

| | |
|---|---|
| `led[7]` blinking | alive, ~1.5 Hz. **The only thing that should blink on a working board.** If it is not, nothing else on the display means anything |
| `led[0]` | the controller finished its 100 µs power-up. Comes on even if all else fails |
| `led[1]` | one word written and read back |
| `led[2]` | walking ones — all 32 data bits proved individually |
| `led[3]` | one address per address bit, 0 up to the top of a 32 MB part |
| `led[4]` | still correct after ~100 ms idle. **This is the one that proves refresh** |

What each stopping point means:

| Display | Read it as |
|---|---|
| heartbeat only | the controller never left power-up. Is `sdram_clk` reaching the pin? |
| `led[0]` only | commands land, data does not come back. **This is the clock-phase symptom** |
| `led[0..1]`, not `[2]` | a DQ line stuck, or two swapped |
| `led[0..2]`, not `[3]` | an address or bank line wrong |
| `led[0..3]`, not `[4]` | refresh is not reaching the part |
| `led[0..4]` steady | the memory works. Go to step 2 |
| any of `led[1..4]` flickering | it mostly works — a margin, not a wiring fault. Step 2 quantifies it |

**If it stops at `led[0]`**, the fix is in `fpga/ulx3s_top.v`'s `sdram_clk`
assignment, which drives the pin straight from the oscillator. At a 40 ns
period that is usually enough, and "usually" is not a measurement: place-and-
route puts 7.27 ns of routing between the `sdram_d` pad and its capture flop,
before any board delay. A DDR output register clocked 180° out (`ODDRX1F` with
`D0=0, D1=1`) or a PLL phase tap is the answer, and both are local changes to
that one net.

### Step 2 — the CPU, the caches and the interconnect

```sh
make sim_sdramcheck                              # the same image, simulated
BOARD=ulx3s85-sdramcheck ./fpga/synth/synth_ecp5.sh
openFPGALoader -b ulx3s fpga/build/ulx3s_top.bit
picocom -b 115200 /dev/cu.usbserial-XXXXXXX      # then tap reset
```

`software/soc/sdramcheck.c` runs **from block RAM** and hammers SDRAM as data:
walking ones, 256 KB of unique addresses (four times the block RAM), byte and
halfword lanes through `cpu_wb.v`'s lane shifting, and a short idle. Expect:

```
=== external SDRAM check (running from block RAM) ===
SDRAM window at 0x90000000, sweeping 256 KB against 64 KB of block RAM

  single word                   ok
  walking ones, 32 bits         ok
  256 KB unique addresses       ok
  byte lanes                    ok
  halfword lanes                ok
  survives a short idle         ok
  block RAM still reachable     ok

SDRAM-CHECK: PASS
```

### Step 3 — run a program *out of* SDRAM

Nothing in a bitstream can put one there: block RAM is initialised at FPGA
configuration time and SDRAM comes up holding nothing. The boot ROM takes an
image over the serial line instead.

```sh
make soc                       # the ROM, with the loader in it
make sim/sdramimage.hex        # builds software/soc/sdramtest.bin on the way
BOARD=ulx3s85 ./fpga/synth/synth_ecp5.sh
openFPGALoader -b ulx3s fpga/build/ulx3s_top.bit

./software/soc/uartload.py /dev/cu.usbserial-XXXXXXX software/soc/sdramtest.bin
# then press reset on the board
```

The order matters: the ROM listens for a knock for only 20 ms after reset, so
the script has to be running already and you reset into it. Miss it and press
reset again — nothing on the host side needs restarting.

**The bitstream must be one with nothing preloaded** — `BOARD=ulx3s85`. A
preloaded build makes the ROM jump straight to the program in block RAM
without ever opening the knock window, and the loader has no way in.
`cat fpga/build/ulx3s_top.bit.target` says which you have.

That used to fail confusingly. The acknowledgement byte was `'K'`, and every
program here prints "KB" — "64 KB of RAM", "sweeping 256 KB of 32768 KB" — so
the host matched the `'K'` of "KB" in a *running program's console output*,
reported "ROM answered", sent its header into something that was not reading,
and blamed the reply:

```
  ROM answered
error: unexpected reply 0x42 ('B') after header
```

`0x42` is the `'B'` of "KB". The board was fine and was running a different
program. `UARTLOAD_ACK` and `UARTLOAD_NAK` are ASCII control codes now
(`0x06`, `0x15`), which nothing on this console ever prints, and the host
names the likely cause when it sees a printable byte where an acknowledgement
belongs. `docs/practices.md` §36.

It sends a 16-byte header (magic, load address, length, CRC32), the ROM
refuses any address outside RAM or SDRAM, and the CRC is checked before it
jumps. Then the script hands the console over, so a load and its output are
one command:

Verbatim from a ULX3S v3.1.8 / LFE5U-85F, `/dev/cu.usbserial-D01595`:

```
102196 bytes -> 0x90000000 (SDRAM), CRC32 8336D56D
knocking - press reset on the board
  ROM answered
  sent 102196/102196 (100%)
  accepted; the board is running it

UART loader: 0x00018F34 bytes at 0x90000000, CRC ok
  starting program

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

**That is Phase 2's "done when", on silicon**: a program larger than the whole
block RAM, fetched and executed out of external memory. `0x18F34` is 102,196
bytes and matches what the host sent; the 96 KB of `.rodata` it checks is 96 KB
that arrived over a serial line, went into SDRAM, and read back word for word.

**A 500 KB image takes about 87 seconds** at 115200, and the 7.4 MB Linux
image takes 22 minutes — both done, the second one in
[Linux, on the board](#linux-on-the-board). It is stop-and-wait, one
byte at a time, because `rtl/uart.v`'s receiver is one byte deep — see
`docs/practices.md` §24 for why the chunked version that was twice as fast was
also wrong.

`uartload.py` needs nothing but the standard library — it configures the port
with `termios` directly. That is deliberate: it used to `import serial`, and
`pip` not being on PATH, `pipx` putting the library somewhere nothing can
import it, and `#!/usr/bin/env python3` picking a different interpreter from
the one it landed in between them cost a bench session, at the exact moment
somebody was trying to find out whether a *hardware* loader worked.

Two tests, in the order they fail: `make uartload-host` runs the script against
a fake board on a pty and needs no toolchain at all, and `make sim_uartload`
runs the whole path against the real RTL. Both are gated in CI.

---

## Building for a ULX3S

**The 45F and the 85F both work; the 12F and 25F do not.** The ULX3S ships
with four FPGA options, and at the default 64 KB of on-chip RAM the two
smaller ones are over their block-RAM budget by 19% and fail to place. Both
supported parts have their own build target below, and both close timing.
Measured numbers for all four are in [Which ECP5 this
fits on](#which-ecp5-this-fits-on).

The board's **32 MB of SDRAM is external to the FPGA and present on every
variant**, so it neither helps nor hurts this choice — and nothing here can
reach it yet, because there is no memory controller.

```bash
make soc                                     # boot ROM image is a synthesis input
BOARD=ulx3s85 ./fpga/synth/synth_ecp5.sh     # LFE5U-85F
# or:  BOARD=ulx3s ./fpga/synth/synth_ecp5.sh   for the 45F
cat fpga/build/ulx3s_top.bit.target           # what the bitstream actually is
openFPGALoader -b ulx3s fpga/build/ulx3s_top.bit
```

**A build can take several place-and-route attempts.** Two of six measured
placement seeds land under 25 MHz and nextpnr fails the build over it, so the
script retries seeds (`SEED_TRIES`, default 6) and prints which one closed.
Budget 8 minutes per attempt on an 85F. See [Fmax is a
distribution](#fmax-is-a-distribution-not-a-number) — the retry is a
mitigation for a margin that is approximately zero, not a property of a
healthy design.

**The FPGA variant is part of the board target, not a separate knob.** A
bitstream is device-specific and will not load on a different ECP5, the four
ULX3S variants are indistinguishable in a photo, and a stale `DEVICE=`
default would fail in a way that looks like a broken design rather than a
wrong command line. Both targets share the same pinout, wrapper and LPF and
differ only in the chip. The build prints its target up front and again on
the bitstream line.

| Target | Device | Fmax | LUT4 | EBR |
|---|---|---|---|---|
| `BOARD=ulx3s` | LFE5U-45F | 28.78 MHz † | 29% | 105/108 — 97% † |
| `BOARD=ulx3s85` | LFE5U-85F | **24.69–27.63 MHz**, 2 of 6 seeds FAIL | 17,435 comb | **80/208 — 38%** |

† the 45F row has not been re-measured since the data cache landed and is
stale in both columns. Its EBR figure in particular should improve by roughly
the same 27 blocks the 85F just gained; at 97% it had room for nothing, and
that is the number to re-measure first if the 45F matters to you.

### Where 27.41 went, and why the answer needed two runs

The 85F was **27.41 MHz** when the D-cache and SDRAM landed. It is now
**25.37 MHz**, and that is a 7.4% drop with **two** causes in it. Attributing
it to the RTL alone would have been wrong:

| | oss-cad-suite | Fmax |
|---|---|---|
| as recorded when the D-cache + SDRAM landed | `20260802` | 27.41 MHz |
| `main`, re-measured | `20260821` | **26.07 MHz** |
| walkers on the bus + 32 MB decode | `20260821` | **25.37 MHz** |

So **−1.34 MHz is the toolchain** (nextpnr `0.10-109` → `0.11.1-8`, yosys
`0.67+137` → `0.68+118`) and **−0.70 MHz is the design change**. Measuring
only the new branch against the old recorded number would have blamed the RTL
for twice what it cost. The rule this is an instance of is
docs/practices.md §20 — do not reason from a measurement whose conditions you
have already changed.

**Margin is now 1.5%** over the board's 25 MHz, down from 10%. That is thin
enough that the next change to touch the fetch or MMU path should re-measure
before it is flashed, not after.

The critical path moved, which is worth knowing because it means the new bus
master is *not* on it:

| | path | logic / routing |
|---|---|---|
| `main` | `ex_mem_mem_we` → `ex_mem_reg_we` | 10.24 / 28.12 ns |
| branch | PC register → instruction-MMU permission check → `id_ex_trap_cause` | 7.76 / 31.65 ns |

Both are **routing-dominated** — 73% and 80% of the total. That has been true
of every measurement here, and it is the reason logic-level micro-optimisation
of the critical path has never bought anything: the delay is in getting across
the die, not in the LUTs.

### The walkers leaving block RAM freed a quarter of it

Removing `wb_ram`'s second port — the one the page-table walkers used before
they became a bus master — took the 85F from **107 EBR to 80**, a 25%
reduction, for 114 more LUT4 and 40 more flip-flops. A true-dual-port memory
has to be built out of narrower block RAMs than a single-ported one of the
same capacity, so giving the port up buys the width back.

That is the opposite of what "add a third bus master" sounds like it should
cost, and it matters most for the device that is not measured here: the 45F
was at **97%** block RAM.

The two devices are no longer equivalent for a different reason as well: the
45F's remaining gap is the framebuffer, which costs 38 EBR — see
[Framebuffer cost](#framebuffer-cost).

Six more targets exist and are not general-purpose builds. Four bake a
program into the bitstream so the SoC can be exercised without a working card
(same RTL, same pinout, different `RAM_INIT_FILE`); two drop the CPU
entirely:

| Target | What it runs | Build the image first |
|---|---|---|
| `BOARD=ulx3s85-ram` | the acceptance test | `make ramimage` |
| `BOARD=ulx3s85-probe` | the newlib probe | `make probeimage` |
| `BOARD=ulx3s85-trapcheck` | one deliberate fault, to prove the trap report | `make sim/trapimage.hex TRAPCHECK=1` |
| `BOARD=ulx3s85-sdramcheck` | external SDRAM, hammered from block RAM | `make sim/sdramcheckimage.hex` |
| `BOARD=ulx3s-cmd0` | SD CMD0, in ~60 flip-flops, no CPU | — |
| `BOARD=ulx3s-sdram` | the SDRAM controller, no CPU, five LEDs | — |

The build refuses to start if the image is missing, and refuses again if the
image is older than the ELF it came from — a stale preload otherwise sails
through and bakes yesterday's program in with nothing in the log to say so,
which has already cost one full synthesize-and-flash cycle here. It prints
which image it took.

**Check your board revision first.** The four SD pins used for SPI mode are
wired differently on **v1.7** than on v2.0/v3.0/v3.1, and
`constraints/ulx3s.lpf` is for the latter. The SDRAM pins are the same across
v2.0, v3.0.x and v3.1.x — the v3.1 changes were ESP32 JTAG, GPIO0 and the OLED
header, none of which touched memory — but the *part* varies: v3.1.4 onward is
an IS42S16160G (32 MB, 9 column bits, which is what `wb_sdram.v` defaults to),
while some v3.0.x boards carry an AS4C32M16 (64 MB, **10** column bits). See
`docs/toolchain.md` §2.

| | v2.0 / v3.0 | v1.7 |
|---|---|---|
| sck | H2 | J1 |
| mosi | J1 | J3 |
| miso | J3 | K2 |
| cs_n | K2 | H1 |

On a v1.7 board the design builds, loads, and fails to find the card, because
all four signals land on the wrong pins.

Three board details that `fpga/ulx3s_top.v` handles and that are easy to get
wrong by hand: the buttons are **active high** (so reset is inverted, and
`btn[0]` is the power button rather than a general one), `wifi_gpio0` must be
**driven high** or the ESP32 can reset the board underneath a running design,
and `sd_d[2:1]` are unused in SPI mode but must not float. `make verify`
checks all three, plus GPIO bidirectionality — see `sim/tb_ulx3s.v`.

Running at some other frequency needs `CLK_HZ` in `fpga/soc_fpga.v`, `CPU_HZ`
in `software/soc/soc.h`, and `CLK_PERIOD` in `sim/tb_soc.v` changed together;
nothing checks that they agree. The ULX3S needs no PLL because its 25 MHz
oscillator is already below the design's Fmax. A faster board does:
`ecppll -i <osc_mhz> -o 25 -n pll --file pll.v` generates one.

### Getting the toolchain

There is no Homebrew cask for oss-cad-suite and no `nextpnr` formula.
(`prjtrellis` is a formula and provides the ECP5 database plus `ecppack`, but
not `nextpnr-ecp5`, which is the piece that matters.) Use YosysHQ's bundle:

```bash
curl -L -o oss-cad-suite.tgz \
  https://github.com/YosysHQ/oss-cad-suite-build/releases/latest/download/oss-cad-suite-darwin-arm64-<date>.tgz
tar xzf oss-cad-suite.tgz -C ~/tools
export PATH=~/tools/oss-cad-suite/bin:$PATH
```

## Measured: the SoC synthesizes, and fits an ECP5

Everything below is a real synthesis run rather than an estimate, and so is
the timing further down — place-and-route runs too, from the oss-cad-suite
bundle described above. **Area, Fmax and timing closure are all measured.**

The per-RAM-size table below predates the AMO retiming and so shows the
older, higher LUT counts; the 64 KB row's current numbers are in
[Utilization](#utilization-lfe5u-45f-cabga381-64-kb-ram-ulx3s-pinout). Only that one
configuration has been rebuilt since.

Full `soc_fpga` (CPU + Wishbone interconnect + boot ROM + RAM + CLINT + PLIC
+ UART + GPIO + SPI), `synth_ecp5`, by on-chip RAM size:

| RAM | LUT4 | FF | DP16KD (block RAM) | MULT18X18D |
|---|---|---|---|---|
| 32 KB | 12,289 | 6,684 | 38 | 4 |
| 64 KB | 12,363 | 6,687 | 67 | 4 |
| 128 KB | 12,591 | 6,691 | 126 | 4 |
| 256 KB | 12,512 | 6,695 | 244 | 4 |

### Framebuffer cost

`rtl/soc/wb_framebuffer.v` adds a 320x240 8bpp buffer (75 KB) and its
scan-out. Measured on the 85F, before and after:

| | Before | After | Δ |
|---|---|---|---|
| DP16KD | 67 | 105 | **+38** |
| LUT4 | 11,837 | 12,758 | +921 |
| TRELLIS_FF | 6,721 | 6,723 | +2 |

38 block RAMs for 75 KB is about 0.5 EBR/KB - near the theoretical minimum,
and notably *better* than `wb_ram.v`'s 0.95 EBR/KB for the same organization.
That was not predicted and is not fully explained; it is recorded as measured.

`FB_WIDTH`/`FB_HEIGHT` are parameters on `soc_top.v` precisely because this is
what decides which parts still fit. At the default the design fits both
supported ULX3S variants, but only just on the 45F.

Fmax also moved, 27.91 -> 30.77 MHz on the 85F. **That is not the framebuffer
making the design faster** - it is the placement sensitivity documented below,
re-rolled by adding ~900 LUTs. Do not read a speedup into it.

### Which ECP5 this fits on

Device capacities below are **as reported by nextpnr itself**, not transcribed
from a datasheet — an earlier version of this table claimed the 85F had
208,000 LUTs, which was its block-RAM count in the wrong column. Verdicts are
from actually attempting the build at `RAM_BYTES=65536`.

| Device | LUT4 | EBR | MULT18X18D | I/O | Verdict at 64 KB RAM |
|---|---|---|---|---|---|
| LFE5U-12F | 24,288 † | 56 | 28 | 197 | ❌ **needs 67 EBR — 119%** |
| LFE5U-25F | 24,288 | 56 | 28 | 197 | ❌ **needs 67 EBR — 119%** |
| LFE5U-45F | 43,848 | 108 | 72 | 245 | ✅ 29% LUT, **97% EBR**, 28.78 MHz |
| LFE5U-85F | 83,640 | 208 | 156 | 365 | ✅ 15% LUT, 50% EBR, **30.77 MHz** ‡ |

‡ this table is the measurement made when the framebuffer landed, and the two
Fmax figures in it predate the data cache and the SDRAM controller. The 85F is
now 20% LUT, 51% EBR and **27.41 MHz** — see the device table under
[Building for a ULX3S](#building-for-a-ulx3s). The EBR verdicts are unchanged,
which is what this table is actually for.

† **nextpnr targets the 25F resource database for `--12k`** — the two are the
same silicon, with the 12F sold as a reduced-capacity part. So a design that
"fits `--12k`" may still exceed what Lattice specifies for a 12F. Treat the
12F row as no better than the 25F row, and do not rely on the surplus.

Both smaller parts fail the same way and it is worth quoting, because it is
unambiguous about which resource is binding:

```
ERROR: Unable to place cell 'SOC.SOC.RAM.mem.1.7',
       no BELs remaining to implement cell type 'DP16KD'
```

Halving to `RAM_BYTES=32768` does fit the 25F die — 38/56 EBR, 12,380 LUTs,
27.70 MHz — but at ~51% LUT occupancy on a part marketed as having 12K LUTs,
with the SDRAM controller and caches that any larger goal needs still to come.

**Which part is faster has flipped, and that is the lesson.** Before the
framebuffer the 85F measured *slower* than the 45F (27.91 vs 29.37) and this
file said so, reasoning that a bigger die means longer routes. After the
framebuffer the order reverses: 30.77 on the 85F against 28.78 on the 45F.

Nothing about either die changed. What changed is that the 45F is now at 97%
block RAM, and a nearly-full device gives the placer far less freedom - which
also shows in the build time, 11 minutes against the 85F's 4. Treat "bigger is
slower" as the guess it was; the reason to pick the 85F is headroom, and on
this design headroom is now buying speed too.

Either supported part is a reasonable choice. The **45F** is the fastest of
the four and has ample room for a memory controller and caches. The **85F**
costs ~1.5 MHz and buys roughly four times the headroom, which matters if
external DRAM and a cache hierarchy are the plan. Both are measured above and
both have a build target.

The 256 KB simulation default fits **no ECP5** — 244 EBRs against the 85F's
208.

`fpga/soc_fpga.v`'s `RAM_BYTES` parameter defaults to 64 KB, and
`software/soc/soc.h` and `link_ram.ld` are built to match, so the firmware
that `make sim_soc` runs is the same firmware a 45F build would run. The
256 KB in `soc_top.v` is a simulation-only default.

Logic is essentially flat across RAM sizes, as it should be - only the memory
changes. The block RAM cost is about 0.95 EBR per KB, roughly 2x the
theoretical minimum, because a 32-bit dual-port memory with byte write
enables cannot use a DP16KD's full 18 Kbit in one instance.

### The core alone, iCE40 vs ECP5

| | iCE40 (`synth_ice40`) | ECP5 (`synth_ecp5`) |
|---|---|---|
| LUTs | 11,859 SB_LUT4 | 8,995 LUT4 |
| FFs | 5,729 | 6,035 |
| Multiplier | in LUTs | 4x MULT18X18D |

The largest iCE40 `nextpnr-ice40` targets is the HX8K at 7,680 LUTs, so **the
bare core still overshoots the biggest iCE40 by ~55%** and the iCE40 path
remains dead. The ~2,900-LUT difference on ECP5 is the multiplier: `cpu_core.v`
computes three full 32x32->64 products combinationally to cover
MUL/MULH/MULHSU/MULHU, and an ECP5 has DSP blocks to absorb them where an
iCE40 has none.

## What used to make synthesis hang, and why

Full-SoC synthesis previously ran for over ten minutes and was abandoned. It
now completes in **54 seconds**. There were two independent causes, and it is
worth recording both because only the first was ever suspected:

1. **`wb_ram.v` had asynchronous reads.** A block RAM's read port is
   registered, so yosys could not map it and fell back to building 256 KB out
   of flip-flops. Fixed by making the memory word-organized with synchronous
   reads and two ports instead of four - which costs one wait state, and
   forced a matching rework of the bus arbiter (a multi-cycle slave needs a
   locked grant) and of the MMU's page-table walker (which had assumed its
   PTE read landed combinationally).

2. **The memories' zero-fill `initial` loops.** This was the bigger one, and
   it was invisible until the first was fixed. Yosys unrolls
   `for (i = 0; i < WORDS; i = i + 1) mem[i] = 0;` into one assignment per
   word: **~43 seconds for a 1024-word array**, and effectively forever at
   65,536. The loops are simulation-only (Verilog leaves an unwritten array X,
   and the testbenches load images far smaller than the memory), so they are
   now behind `` `ifndef SYNTHESIS ``. With that one guard the same 256 KB
   array elaborates and maps to block RAM in 1.3 seconds.

   Anyone tempted to remove that guard for tidiness should re-measure first.

## Before you run any of this

On a ULX3S none of the first two apply — `constraints/ulx3s.lpf` has real
pins and `fpga/ulx3s_top.v` is already set for a 25 MHz oscillator. **For any
other board:**

1. **Replace every pin in the constraints file.** `constraints/generic.lpf`
   is still placeholders copied from no board in particular. Your vendor
   publishes a master constraints file; start from that, and write a board
   wrapper alongside `ulx3s_top.v` rather than editing it.
2. **Set `CLK_HZ` in `soc_fpga.v` to your board's actual oscillator**, along
   with `CPU_HZ` in `software/soc/soc.h` and `CLK_PERIOD` in
   `sim/tb_soc.v` — nothing checks that the three agree. The UART divisor and
   the SD initialization clock are both derived from them, and getting either
   wrong produces a console emitting garbage, or a card that never answers,
   even when timing closes perfectly. Both look like CPU bugs rather than
   configuration ones. If the oscillator is faster than the design's Fmax you
   also need a PLL — see the `ecppll` line above.

Regardless of board:

3. **Run `make soc` first.** `wb_rom.v` pulls `bootrom.hex` in with
   `$readmemh` at elaboration time, which makes it a *synthesis* input, not
   just a simulation one. Both scripts check for it and refuse to start
   without it, because the failure mode otherwise is a board that comes up
   and does nothing.

## Timing: measured, and the prediction was wrong

This section used to say 50-150 MHz was "plausible for a core this size".
Place-and-route says otherwise:

```
Max frequency for clock 'clk_25mhz': 30.77 MHz   (post-route, real pins, 85F)
```

`fpga/constraints/timing_only.lpf` therefore constrains the clock to 25 MHz,
which closes. The design is roughly **2-5x slower than the guess**, which is
worth stating plainly rather than quietly editing the range downward - an
untested estimate of a critical path is not evidence, and this is the whole
reason for running the tool.

Two numbers appear in nextpnr's log: 22.99 MHz after placement and 30.77 MHz
after routing. The second is the real one; the first is an estimate made
before the router has had a chance to fix anything.

### Utilization (LFE5U-45F, CABGA381, 64 KB RAM, ULX3S pinout)

```
LUT4          11837 / 43848    26%
DP16KD           67 /   108    62%    <- block RAM is the binding resource
MULT18X18D        4 /    72     5%
TRELLIS_IO       54 /   245    22%
DCCA              1 /    56     1%
```

### The critical path, and the AMO chain that used to be it

The first place-and-route run put the critical path here:

> **block RAM read data -> the AMO ALU -> bus write data**

It started at a DP16KD's 5.83 ns clock-to-out and ran through
`cpu_core.v`'s `amo_new_value` mux, which accounted for 12 of the path's
hops - the AMOMIN/AMOMAX signed and unsigned 32-bit comparators. The mux was
fed combinationally from `dmem_rdata`, which on an ack cycle is
combinationally the RAM's output, and drove `dwb_dat_w` straight back out to
the bus. An atomic's read-modify-write was, to static timing, one
combinational chain from memory back to memory: 35.40 ns, 28.25 MHz.

Note that the chain is *functionally* dead in the cycle it is live - the bus
write-enable is low during an AMO's read phase, so that value is never
written. Static timing has no way to know that, and there is no clean way to
declare it a false path, which is exactly why it had to be fixed structurally
rather than annotated away.

**Fixed.** `cpu_core.v` now captures the read value in `amo_rdata_q` and runs
the ALU off *that* in the following cycle, so both ends of the comparators
are bounded by flops and neither reaches memory combinationally. The phase
state moved into the core, which deleted the duplicate state machine
`cpu_wb.v` was running to sequence the same two bus phases. Measured:

| | Before | After |
|---|---|---|
| Fmax (post-route) | 28.25 MHz | **31.32 MHz** |
| Critical path | 35.40 ns | **31.93 ns** |
| LUT4 | 13,837 (31%) | **11,977 (27%)** |
| TRELLIS_FF | 6,687 | 6,719 |

(Those are the numbers from the run that measured this change. The current
build reports 30.38 MHz - two later, logically unrelated edits moved it. See
[Placement sensitivity](#placement-sensitivity-a-calibration) below, which is
the more useful lesson of the two.)

The **+32 flip-flops are exactly `amo_rdata_q`** - the core's new phase bit
replaces the one deleted from `cpu_wb.v`, netting zero. The 1,860-LUT drop
was not predicted and is the larger surprise: feeding the comparators from a
plain register instead of from the shifted, muxed `dmem_rdata` net evidently
lets yosys share a great deal more logic.

**It cost no cycles.** All 82 riscv-tests run identical cycle counts before
and after, because the SoC already spent a cycle between the read
acknowledgement and issuing the write - the register slots into a gap that
was there anyway. `rtl/top.v`'s zero-latency memory has no such gap, so an
AMO there now occupies MEM for two cycles instead of one. That path is
simulation-only.

### The critical path now

> **PC -> instruction-fetch path -> PC**

32.91 ns, of which **24.76 ns is routing and only 8.15 ns is logic**. It
starts at an ordinary flip-flop (0.52 ns clock-to-out, not a block RAM's
5.83) and runs through `cpu_core.v`'s IF stage from line 170.

There is very little logic left to remove here: **75% of this path is wire**.

### Placement sensitivity: a calibration

Three consecutive builds, each separated by a change that touched almost
nothing, put the critical path in three completely different places:

| Build | Fmax | Critical path | Routing | LUT4 | FF |
|---|---|---|---|---|---|
| After the AMO retiming | 31.32 MHz | RAM -> MMU walk -> PC | 61% | 11,977 | 6,719 |
| After rewiring 4 status LEDs | 30.64 MHz | forwarding mux -> address adder | 72% | 11,977 | 6,719 |
| After adding a 2-flop MISO synchronizer | 30.38 MHz | PC -> fetch -> PC | 75% | 12,124 | 6,721 |
| With the real ULX3S pinout (45F) | 29.37 MHz | RAM -> MMU walk -> PC | 67% | 11,837 | 6,721 |
| **Adding the framebuffer (85F)** | **30.77 MHz** | — | — | 12,758 | 6,723 |
| The same netlist on a 45F | 28.78 MHz | — | — | 12,758 | 6,723 |

The last two rows are the same netlist on two dies, 2 MHz apart - and the
*larger* one is faster, because the smaller is at 97% block RAM and the placer
has nowhere to put things.

The last row is the only one that constrains I/O, and is the number to
believe for hardware. It is also the only change in the table with a
*mechanism* behind its movement — real pins are a genuine constraint on
placement, not a perturbation — and it still only cost 1 MHz.

The middle row is the striking one: **byte-identical LUT and flip-flop
counts**, a completely different critical path, and 0.68 MHz. Nothing in the
CPU, the bus or any peripheral changed - only which four signals drive the
board LEDs.

This is **not** run-to-run noise. nextpnr is deterministic for a given
netlist - the pre-AMO design was placed twice and reported 28.25 MHz both
times. It is placement being a global optimization: perturb anything, and
every path is re-diced.

Two things follow, and they are the reason this is written down:

1. **Do not attribute a sub-MHz Fmax change to whatever you were editing.**
   The noise floor for "I changed something unrelated" is comfortably several
   tenths of a MHz on this design.
2. **A timing change is only demonstrated when the critical path moves off
   the structure it targeted.** That is what the AMO retiming did - the AMO
   ALU vanished from the report - and it is the evidence that actually
   mattered there, more than the +3.07 MHz headline.

The reverted MMU experiment in the next section is the same lesson learned
the expensive way: it was tried before the AMO path was found, and is a
warning rather than a starting point - that rewrite was independently
*incorrect*, and its correctness problem has nothing to do with whether it
would help timing now. With routing at 75% of the path, logic-depth changes
alone have limited headroom here.

### One optimization tried, and reverted

Before finding the AMO path, the obvious-looking target was the *other* long
chain the report shows: RAM output -> MMU walk result -> physical address ->
bus address decode. Making a completed page-table walk answer through the
TLB it had just filled (instead of combinationally from the walk result)
should have cut that chain at its source.

It was reverted, for two independent reasons:

1. **It measured no faster** - 28.25 MHz before, 26.61 MHz after. This file
   originally called that "placement noise either side of the same number".
   That wording is wrong and has been left visible rather than quietly
   edited: nextpnr is deterministic for a given netlist, so 26.61 MHz was a
   reproducible result, not a dice roll. The accurate reading is the one in
   [Placement sensitivity](#placement-sensitivity-a-calibration) above - the
   edit perturbed placement, everything was re-diced, and the number moved
   for reasons unrelated to the chain being targeted. Either way the
   conclusion stands: it did not help, and the AMO path was the real
   constraint.
2. **It was wrong.** The TLB is looked up with the *live* virtual address,
   and for a data access that address is `op1 + imm` recomputed from
   forwarding every cycle; across a multi-cycle walk the pipeline drains
   underneath it and the value decays. The walk result used the latched
   `va_r` and was immune. This is the same operand-drift hazard as the
   misaligned-address bug in docs/architecture.md section 12b, and the Spike
   co-simulation caught it within one run - `rv32si-p-dirty` taking a load
   page fault the reference model never takes.

Worth recording because the lesson generalizes: the critical path the tool
reports is the one to fix, not the one that looks worst by inspection.

### What would actually raise Fmax

In order of expected benefit:

1. ~~**Register the AMO result.**~~ Done - 28.25 -> 31.32 MHz, see above.
2. **Floorplan, or move to a smaller device.** This is now first on merit
   rather than last, and by a wide margin. The critical path is 75% wire and
   only 8 ns of logic; the design occupies 27% of an LFE5U-45F and is spread
   across all of it. Constraining related logic into neighbouring regions, or
   fitting a 25F at `RAM_BYTES=32768`, attacks the part that is actually
   large. The three-build table above is also the argument for this: the
   critical path keeps relocating because *placement*, not logic depth, is
   what decides it.
3. **Shorten whichever pipeline path the tool currently names.** Recent
   builds have landed on the EX-stage forwarding-mux-into-address-adder chain
   and on the IF-stage PC loop. Both are plausible targets - but check the
   calibration above before believing any single measurement of the result,
   and confirm the path actually left the report.
4. **Pipeline the bus response.** Address decode -> slave select -> response
   mux -> `ack` -> the CPU's stall logic is still a long chain, and it is
   what the second-longest paths run through.
5. **Pipeline the multiplier.** Three 32x32->64 products resolve in one EX
   stage. They map to DSPs on ECP5 so they are not currently critical, but
   they would be on a device without them.

The walk-result -> PC chain that was critical immediately after the AMO
retiming is no longer, and was never worth chasing on its own - it moved
because of an unrelated edit, not because anything was done to it.

## What is genuinely missing for "boots on hardware"

- **~~External DRAM~~** — done, and on silicon: `rtl/soc/wb_sdram.v` reads and
  writes the ULX3S's 32 MB SDR part, 256 KB of it proved address-unique on a
  board. LiteDRAM was the expected answer and was not needed; SDR is a command
  truth table and six timing numbers, and a hand-written controller is what
  every verification layer here can actually reach.
- **A way to load a program into SDRAM on a board.** This is what "external
  DRAM" turned into rather than something it removed. A bitstream initialises
  block RAM at FPGA configuration time; SDRAM comes up empty. So code still
  runs from the 64 KB of block RAM and SDRAM is data only, until the SD path
  works or a UART loader exists.
- **JTAG debug.** No RISC-V Debug Module, no TAP. Debugging is UART `printf`
  and the LEDs.
- **Ethernet.** Not attempted.
- **Flash-based boot.** The boot ROM loads from SD; a real board usually
  also wants to boot from SPI flash.
