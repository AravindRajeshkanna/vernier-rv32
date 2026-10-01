# Phase 5 — Run software this project did not write

OpenSBI **builds** for this core and does not **boot** on it.
[software/opensbi/README.md](../../software/opensbi/README.md) is precise about
the split and lists what is missing: a platform port for console, timer and
IPI glue, and a way to get a 521 KB `fw_jump.bin` onto the board.

**The memory half of that is answered.** Phase 2's SDRAM is proven on silicon
and reaches 16 MB, which is thirty times what `fw_jump.bin` needs — and the
loader question is answered too: `software/soc/uartload.py` sends an image
over the serial line into SDRAM and the boot ROM runs it from there, verified
on a board with a 99 KB program. Neither memory nor a way to fill it is a
blocker any more.

FreeRTOS or Zephyr is the realistic intermediate milestone, and is reachable
sooner: there is a bus, a timer, an interrupt controller and storage.

**Done when:** OpenSBI prints its banner and hands off to an S-mode payload —
**done**, and the payload now exists and boots in QEMU. The remaining gap is
this SoC, and it is one named failure rather than a category.

**The banner half is done.** `make sim_opensbi` boots OpenSBI v1.9 on this
SoC: it parses `dts/soc.dts`, finds the ns16550 console, the CLINT as
`aclint-mtimer`/`aclint-mswi` at the right frequency and the PLIC's window,
detects the hart as `rv32ima` with no PMP, builds its root domain, and stops
prepared to enter S-mode at `0x9040_0000`. What is missing is something to be
*at* that address.

## The debug loop had to be fixed first

Everything under `sim/tb_*.v` runs on Icarus, at about **11.3 thousand cycles
per second** on this SoC. Every test in the suite fits comfortably inside
that; the longest, `sim_sdramboot`, is 2.1 M cycles in three minutes.

A Linux boot does not fit. It is order 10⁸ cycles — **seven hours or more per
attempt** — on a bring-up whose characteristic failure is a silent hang with
no output at all, where the only way forward is to look at a waveform and try
again. One attempt per working day is not a debug loop.

So `soc_top` is now built under Verilator as well (`sim/verilator_soc.cpp`),
measured at **4.44 M cycles/s** on the same image and core: roughly **390×**,
turning that seven hours into about a minute. This is the cheapest thing on
the whole Phase 5 list and it multiplies everything after it, which is why it
was done before any of the RTL below.

Verilator cannot run `sim/sdram_model.v` — that model is written in
nanoseconds, with `#T_AC_NS` on the data path — so the harness carries a C++
port, and there are now two memory models that could disagree. A fast
simulator that quietly lies is worse than a slow one that does not, so
`make verilator_check` runs `sim_sdramboot` under both and requires the cycle
counts to match — to within the one cycle the two testbenches' verdict
watching differs by, which `sim/verilator_compare.py` justifies at length —
along with the refresh counts and every byte of program output, both exactly.
`sim/sdram_model.v` stays the authority; the port is checked against it.

## What is actually left, for Linux specifically

Two of the three hard blockers are now closed:

1. ~~**The page-table walkers cannot reach SDRAM.**~~ **Done.** They sat on
   `wb_ram.v`'s second block RAM port, and an SDRAM has no second port, so
   page tables could live in block RAM and nowhere else. `rtl/soc/wb_ptw.v`
   arbitrates both walkers into a third Wishbone master, so a PTE can come
   from any slave the interconnect decodes. `mmu.v` did not have to change:
   the module asserts the walker's grant in the bus's *ack* cycle and
   registers the returning word on the same edge, which reproduces the
   one-cycle-later contract the walkers were written against, whatever the
   slave's latency.
2. ~~**`mip.SEIP` is hardwired to zero and the PLIC has one M-mode context.**~~
   **Done.** `rtl/plic.v` has the standard register map and two contexts (0 =
   hart 0 M-mode, 1 = hart 0 S-mode), and `mip.SEIP` is the spec's OR of a
   software-writable bit and the controller's pin. `make sim_plic` raises a
   GPIO interrupt, has it delivered to **S-mode** through context 1, claims
   and completes it — the first program in this repository ever to take an
   external interrupt in either privilege mode.
3. ~~**The interconnect decodes `addr[31:24]`** — 16 MB per slave.~~ **Done.**
   The decode compares through a per-slave mask; the SDRAM's is `0xFE`, so it
   answers to `0x90` and `0x91` alike. `wb_sdram.v` needed no change — it
   always took its row from `wb_adr[24:12]`.

## The kernel: booting to userspace, here

`software/linux/build-linux.sh` fetches Linux 6.18.45 and builds an rv32ima
kernel with an initramfs in it. **In `qemu-system-riscv32 -M virt` it boots to
userspace, and on this SoC it does too**:

```
Run /init as init process

=== VERNIER-RV32: USERSPACE ===
kernel  : Linux 6.18.45
machine : riscv32
pid     : 1
isa     : rv32ima_zicntr_zicsr_zifencei_zaamo_zalrsc
mmu     : sv32
```

`make sim_linux` reaches the marker at cycle 132,938,924 — 33 seconds of
Verilator, 5.3 seconds of wall time at 25 MHz. It parses the device tree,
brings up `earlycon`, builds memblock and the whole linear map, turns Sv32 on,
reports `Memory: 24316K/28672K available`, switches to `riscv_clocksource`,
probes `rtl/plic.v` (`mapped 8 interrupts ... for 2 contexts`) and
`rtl/uart.v` (`ttyS0 at MMIO 0x4000000 (irq = 1) is a 16450`), hands the
console over from the SBI earlycon to `ttyS0`, frees its init memory and runs
`/init`.

Three defects stood between "the kernel starts" and that, and all three are
recorded below and in `software/linux/README.md`.

**And it boots on the board.** A ULX3S / LFE5U-85F, 7,744,876 bytes sent over
the serial line into external SDRAM in one attempt, OpenSBI, the kernel, and
`/init` at pid 1. `fpga/README.md` has the transcript and what each line of it
settles — the Sv32 MMU on silicon, the ns16550 console and its 3.1% baud
error, and the 22-minute all-or-nothing transfer. PLIC interrupt *delivery* is
the one thing that boot does not prove.

## The last one: a device tree that claimed a FIFO the hardware has not

The console garbled the instant Linux took it over from the SBI earlycon —
`clk: Disabling unused clocks` came out clean, and the next line arrived as
`Fet2KoecRt=:kL`. That was *not* a decoding-rate mismatch, which the standing
note here said and which was true: the harness reported divisor 14, 224 clocks
per bit, exactly what both OpenSBI and Linux compute from `clock-frequency`.
The rate was right. Not all of the bytes were being sent.

`dts/soc.dts` said `compatible = "ns16550a"`, and `rtl/uart.v` has no FIFOs.
The device tree even carried a comment saying so, ending "so a driver that
checks will stay in 16450 mode" — and nothing checks.
`drivers/tty/serial/8250/8250_of.c` sets `UPF_FIXED_TYPE`, so `autoconfig()`
never runs and the honest `IIR` is never read. The compatible string is not a
hint that a probe confirms; it *is* the configuration. `PORT_16550A` means
`tx_loadsz = 16`, and `serial8250_tx_chars()` writes sixteen bytes into a
one-byte holding register after a single `THRE` with no status check between
them. `rtl/uart.v` takes a write only when the transmitter is free, so fifteen
of every sixteen went nowhere, with nothing in the part that could report it.

`compatible = "ns16450", "ns16550";` now — the part this is, and the register
map it can be driven through. The order is load-bearing: Linux scores a match
by its index in *that* list and takes `ns16450`, while OpenSBI's `uart8250`
driver matches `ns16550` and keeps its own console.

`+checkuart` is what settles it, and it settles it in the output of the failing
run: it counts what software writes to `THR` against what the receiver decodes
off the wire, and needs no baseline, because a discarded write is a defect on
its own terms. Before, `6336 written, 470 dropped by the transmitter`, naming
the first twelve by value — `r`,`e`,`e`,`i`,`n`,`g`,` `,`u`,`n`,`u`,`s`,`e`,
the tail of "F*reeing unuse*d", 48 cycles apart where a character takes 2,240.
After, `6335 written, all 6335 sent, in order`. It runs in
`make verilator_check` and in `make sim_linux`. docs/practices.md section 32.

## The one before that: an instruction executed under the wrong PC

`unflatten_device_tree()` failed on a device tree that was demonstrably well
formed. The cause was **an instruction executed under the wrong program
counter**.

A `ret` was predicted taken to a stale BTB target left by a different call
site. The core detected the misprediction and redirected correctly — but an
**ITLB walk was in flight for the mispredicted address**, and `rtl/mmu.v`
answers a concluded walk from the `va_r` it latched when the walk began. That
is deliberate and right for the data side, where the live `va` is recomputed
from forwarding and decays under a stall. The fetch side has the opposite
property: `redirect_valid` overrides the PC freeze *on purpose*, so the PC
moves while the walk runs.

So the walk handed back the mispredicted path's physical address, the fetch
unit fetched a real instruction from a real address, and the IF/ID register
paired it with the corrected PC. `li a4,3` executed where `li a5,1` should
have. Two instructions later a `bne` took a branch it must not take, and
libfdt reported a malformed tree.

`rtl/mmu.v` now exposes `pa_va` — the virtual address its answer is the
translation of — and both cores reject an answer that is not for the current
`pc`. Rejecting costs a re-walk and cannot livelock: the walk still installs
its TLB entry.

**It needs an ITLB miss and a mispredict in flight simultaneously.** Every
bare-metal program in this repository is small enough that the ITLB stops
missing after its first pass, and riscv-tests never enables paging. Linux, with
4 KB pages throughout its linear map and 2.4 MB of text, lives in ITLB
eviction. `+checkdecode` now checks the pairing directly and runs in
`make verilator_check`; docs/practices.md section 31 is about why the three
probes that already passed could not have found it.

## Turning translation on had never included a second level

`make sim_mmusdram` mapped 4 MB megapages and nothing else, by explicit
design, so `l1_conclusive` in `mmu.v` was true on every walk this project had
ever run. riscv-tests does not cover it either — `rv32si-p-*` is the physical
variant and never enables paging. So the hardware had never read a *second*
PTE.

Linux has no such option: its linear map is megapages, which is why a kernel
runs here at all, but the fixmap, vmalloc, every `ioremap` and every page of
userspace are 4 KB pages behind a level-2 table.

`software/soc/mmutest.c` now covers it — VPN[0] at 0, 512 and 1023,
per-4-KB-page permissions, an invalid level-2 entry, three pages inside one
megapage to catch a TLB that tags at the wrong granularity, and a sweep over
four times the TLB's eight entries read back in reverse so every hit is on an
entry that was evicted and walked again. The aliasing check is the pointed
one: getting it wrong returns the *wrong page* rather than faulting, which is
the hardest shape of bug to see from software. The pressure check is there
because `best_map_size()` returns `PMD_SIZE` only under `CONFIG_64BIT`, so on
rv32 the entire linear map is 4 KB pages and Linux runs permanently in
eviction — a regime nothing else on this SoC enters. All pass —
the walker was already right, which is worth knowing rather than assuming.

What it will need, once OpenSBI hands off:

- ~~a kernel built `rv32ima` with **no C extension** (this core does not
  implement it) and `CONFIG_MMU=y` with Sv32~~ — **done**, and harder than it
  reads: `CONFIG_EFI` is `default y` on riscv and `select RISCV_ISA_C`, so
  turning C off is not enough on its own and kconfig reports nothing;
- ~~an initramfs, because there is no block device driver for the SPI card and
  the SD path is the boot ROM's, not the kernel's~~ — **done**, built into the
  Image, with a `/init` that makes raw `ecall`s because there is no rv32 Linux
  userspace toolchain on this host;
- ~~`fw_payload` rather than `fw_jump`, or a loader that places the kernel
  where `fw_jump` expects it~~ — **done**: `software/opensbi/mkimage.py`
  packs the Image at `FW_JUMP_ADDR` in the same blob as the firmware, and
  checks the RISC-V Image header's `text_offset` against where it put it;
- roughly 3×10⁸ cycles per boot attempt, which is about a minute under
  Verilator and seven hours under Icarus. That ratio is why the harness was
  built first.

Then: ~~an ns16550-compatible UART~~ (**done** — `rtl/uart.v` is one, with the
divisor latch, IIR and an interrupt into PLIC source 1; `make sim_uart16550`),
~~a device tree~~ (**done** — `dts/soc.dts` describes the two-context PLIC and
the ns16550, and OpenSBI's `generic` platform is entirely FDT-driven, so that
device tree *is* the platform port), an rv32ima kernel with no `C`, and an
initramfs. Hardware PTE A/D auto-update is absent and Linux does not strictly
need it to boot.

**OpenSBI boots.** Five defects stood between "builds" and "boots": a missing
`mstatush`, a load address violating OpenSBI's own alignment precondition, a
build script that built the wrong thing two different ways, a
`FW_JUMP_FDT_ADDR` default that landed outside this SoC's 32 MB — which
matters because `fdt_get_address()` returns the root domain's `next_arg1`, so
OpenSBI reads its *own* device tree through it — and a `timebase-frequency`
in `dts/soc.dts` that was twice the real one.

`software/opensbi/README.md` records the method as well as the findings,
because the method is the reusable part: OpenSBI owns the console and brings
it up late, so every failure before that is identical silence. The way through
was instrumenting the *hardware* - retired PC, trap CSRs, a branch-transfer
ring, a register watchpoint and a memory peek, all in
`sim/verilator_soc.cpp`.

## What turning translation on for the first time cost

`make sim_mmusdram` builds an Sv32 identity map of 4 MB megapages with the
root table at `0x9100_0000` — in SDRAM, above the old decode ceiling — enters
S-mode, and checks that fetch and data both translate, that a read-only
megapage still reads, and that storing to it takes a store page fault.

It is the first thing in this repository ever to write a non-zero `satp`.
riscv-tests' supervisor set is `rv32si-p-*`, the **physical** variant: it
exercises S-mode CSRs and traps and never enables paging. So 79 passing
architectural tests and 82 of 82 matching Spike traces had between them never
run a single page-table walk driven by hardware translation.

It found two core bugs on its first run, both present since the MMU landed:

- **The fetch address is `X` while the ITLB walks**, because `mmu.v` derives
  it from a PTE register that has not been read yet. `cpu_wb.v` indexes its
  I-cache with it, so `fetch_hit` goes `X`, so `iwb_cyc` goes `X` — and
  `wb_ram.v`'s `ack_r <= a_en && !ack_r` latches that `X` permanently, since
  `!x` is `x`. One unresolved fetch wedges main memory for the rest of the
  run. Both cores now hold the last resolved address instead, which is also
  free: that address is still in the I-cache, so no bus cycle is issued at
  all — and the walker is now competing for the same bus.
- **A translated store used the previous instruction's data on a TLB hit.**
  `store_data_latched` is a register; selecting it unconditionally hands a
  store that never stalled the operand as of the end of the *previous* cycle.
  Correct under a walk, which is the only path that had ever run.

docs/practices.md section 26 is about the shape of that: a suite that passes
is not a suite that ran the code.

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

Done on hardware: OpenSBI, the Linux kernel and `/init` at pid 1 booted on a ULX3S / LFE5U-85F after 7,744,876 bytes were sent over the serial line into SDRAM in one attempt. That proves the Sv32 MMU, the ns16550 console and its baud error on silicon. PLIC interrupt delivery is the one thing that boot does not prove. The transcript is in [fpga/README.md](../../fpga/README.md).

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

`make sim_opensbi` boots OpenSBI v1.9 on this SoC, parsing `dts/soc.dts`, and the S-mode payload boots under QEMU. The Linux boot is exercised in simulation by `make sim_linux`, and the stage accounts above record the bugs each of those runs found.
