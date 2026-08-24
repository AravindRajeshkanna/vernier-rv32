# Linux on this SoC

An rv32ima kernel with an initramfs, built from source for the machine in
`rtl/soc/soc_top.v`, packed into one SDRAM image with OpenSBI, and booted
under Verilator.

```sh
./software/opensbi/build-opensbi.sh   # once
./software/linux/build-linux.sh       # once: fetches and builds Linux 6.18.45
make linuximage                       # pack stub + device tree + OpenSBI + Image
make sim_linux                        # boot it
```

## Status, precisely

**This kernel boots to userspace on the board** — a ULX3S / LFE5U-85F, out of
32 MB of external SDRAM, with the image sent over the serial line by the boot
ROM's own loader. It also boots in QEMU (`qemu-system-riscv32 -M virt`) and
under Verilator, which is where all three of the defects below were found.

```
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
```

Verbatim from `make sim_linux`, which reaches the marker at cycle 132,938,924 —
33 seconds of Verilator, and 5.3 seconds of wall time on a board at 25 MHz. The
board prints the same thing.

| | |
|---|---|
| OpenSBI banner, platform, root domain, hand off to S-mode | ✅ |
| Kernel entered, device tree parsed, `earlycon=sbi` up | ✅ |
| memblock, Sv32 paging, the whole linear map | ✅ |
| `unflatten_device_tree()` | ✅ |
| `Memory: 24316K/28672K available` | ✅ |
| `SBI misaligned access exception delegation ok` | ✅ |
| `clocksource: Switched to clocksource riscv_clocksource` | ✅ |
| `riscv-plic: plic@3000000: mapped 8 interrupts ... for 2 contexts` | ✅ |
| `4000000.serial: ttyS0 at MMIO 0x4000000 (irq = 1) is a 16450` | ✅ |
| console handover from `sbi0` to `ttyS0` | ✅ |
| `Run /init as init process`, and `/init` printing | ✅ |
| **On hardware** | ✅ ULX3S / LFE5U-85F — [the transcript](../../fpga/README.md#linux-on-the-board) |
| **On the wide core** (`CORE=ooo`) | ❌ boots the whole kernel, then `Failed to execute /init (error -14)` — see below |

The `isa` line is the point of printing `/proc/cpuinfo`: it is what the kernel
parsed out of `dts/soc.dts` and believed, so a boot that gets here has proved
the device tree was read *and* acted on. `zaamo`/`zalrsc` are the kernel
spelling out what `a` decomposes into.

## The wide core: everything but `execve`

`make sim_linux CORE=ooo` had never been run. It boots almost all of the way:

```
Freeing unused kernel image (initmem) memory: 152K
Run /init as init process
Failed to execute /init (error -14)
Kernel panic - not syncing: No working init found.
```

**`-14` is `-EFAULT`.** The wide core executes the entire kernel — memblock,
Sv32 and the whole linear map, the clocksource, the PLIC probe, `ttyS0` and
the console handover, `free_initmem` — three million instructions, correctly,
and then takes a bad-address fault in `execve`.

That is one named failure at a known point rather than a category, which is
the same shape the ITLB defect had before it was found.

**The three self-checking probes were pointed at it, and all three pass:**

```
SDRAM reads checked:          14,354,365, all matched the part
decoded instructions checked: 52,823,404, all matched their PC
translations checked:         99,058,380, all agreed with the page tables
```

Nothing else in the log is anomalous either — no oops, no bad-page report, no
unexpected trap — and `make verify_ooo` passes riscv-tests, CoreMark and every
SoC test. So the wide core is not broadly broken, and whatever is wrong is
narrow.

**But there is a gap in that evidence, and it is the important part.**
`+checkdecode` reads `if_id_valid` / `if_id_pc` / `if_id_instr`, and the wide
core **dual-issues**: those name slot 0 only. Slot 1 has its own
`id_ex1_valid` / `id_ex1_pc` / `id_ex1_instr` and nothing checks them. So
"52.8 million decoded instructions all matched their PC" is a statement about
roughly half the instructions the core executed, and the half it says nothing
about is the one that only exists on this core — which is also the only core
that fails.

`sim/verilator_soc.vlt` has said so since the probe was written ("`instret_retire`
/ `id_ex_pc` describe slot 0 only... a branch trace taken from the wide core is
a sample of control flow rather than all of it"). It was recorded as a caveat
on a trace and is really a hole in the strongest instrument this project has.

**That hole is now closed, and it did not contain the bug.** `+checkdecode`
checks both slots: the same boot goes from 52,823,404 checked instructions to
**56,629,310**, and all of them still match their PC.

Two corrections fall out of doing it. The unchecked fraction was **7%**, not
the "half" assumed above — the second slot only issues one class of
single-cycle ALU op, so most cycles have nothing for it. And the wide core
decodes correctly in *both* slots, which rules out a whole class of cause: the
`execve` failure is not an instruction fetched or paired wrongly.

So four independent checks now pass on a boot that fails — bus reads,
translations, slot-0 decodes and slot-1 decodes. What none of them look at is
the *data* path: the values in registers, what stores write, CSR contents,
privilege transitions. `-EFAULT` out of `execve` is consistent with any of
those, and with the load/store path most of all. The next instrument would
have to check register writeback against an independent model of what the
instruction should have produced, which is a much larger thing than any probe
here and is essentially what `tests/cosim.py` does against Spike.

**That cosimulation was already pointed at the wide core, and it passes.**
`make verify_ooo` runs `verify CORE=ooo`, and `cosim` has been in `verify`'s
list the whole time: 82 of 82 traces match Spike instruction for instruction,
register writes included. So the data path *is* checked against an
independent model — on riscv-tests.

What that turned out to be worth is the finding. Counting which issue slot
each retirement came from: **63 of 28,262 retirements in slot 1, and 70 of
the 82 traces with none at all.** Corrupting every slot-1 result still leaves
73 of those 82 tests passing. The instrument was real and the corpus had
nothing in it for the mechanism to show up in — see
[practices.md §40](../../docs/practices.md).

`tests/vernier/pairing.S` is the workload that does exercise it: 6,143 slot-1
retirements, 97× the whole upstream corpus, matching Spike exactly on both
cores. **It did not reproduce the `execve` failure either.** So the wide core
now has an instruction-exact check on a heavily dual-issued workload, and the
bug is still not in reach of it — which narrows things further than the four
probes did, because what riscv-tests and `pairing.S` share is that neither
runs in user mode, neither has translation on, and neither is three million
instructions long.

The next instrument therefore has to be pointed at the *boot*, not at a test:
the divergence is somewhere the ISA suites structurally cannot go.

### Pointed at the boot, and it found the fault

`make linux_trapdiff` boots the same image on both cores and compares the
*traps*. That is the cheapest thing a failing boot produces that a passing one
does not, and it needed one piece of care: the two cores take different
numbers of cycles for the same instructions, so a timer interrupt lands at a
different instruction in each and the raw traces diverge within a hundred
traps for reasons that are not defects. `tests/traptrace.py` drops interrupts
and compares exceptions by `(privilege, target, cause, epc, tval)`.

Against 1,587 traps on one side and 5,761 on the other, one exception is
present on the wide core and absent on the in-order one:

```
=== exceptions in the second run and not the first ===
  x1  S->S  store/AMO page fault  at load_elf_binary+0xc30  tval 0x00040000
```

**A supervisor store page fault, in `load_elf_binary`, storing to user virtual
address `0x00040000`.** That is `execve` copying the new program's image into
the address space it just built, and `-EFAULT` is what a kernel access with a
fixup returns when it faults. Everything else matches: both cores take the
same 36 illegal instructions, the same instruction page fault, the same
misaligned load, the same breakpoint. The only other difference is the
userspace `ecall`s the wide core never reaches, because `/init` never runs.

**The fault is correct.** Freezing memory at the faulting cycle and reading
the root page table at `satp` PPN `0x908cb` gives entry 0 — the one covering
`0x00040000` — as `0x00000000`. The page genuinely is not mapped, and the MMU
was right to fault. So this is not a spurious fault to be chased in `mmu.v`:
something earlier failed to write a page-table entry that the in-order core
writes. A store went missing or went elsewhere, which is where
[the data path](#the-wide-core-everything-but-execve) was already pointing.

### What `+checkmmu` was actually checking

The probe skips two cases, both by an explicit `continue`: a translation the
hardware **faulted**, and one the C++ model cannot map. Both are defensible —
the model resolves addresses and does not model permissions, so it has nothing
to say about whether a fault was warranted — and together they mean
`translations checked: 355,033,084, all agreed` is a statement about the
*successful* half of the MMU.

The counts are now printed alongside it, and they are the point:

```
translations checked: 355033084, all agreed with the page tables
  not compared: 4 faulted in hardware, 0 the model could not map
```

**Four, out of 355 million — and one of the four is the defect.** See
[practices.md §41](../../docs/practices.md).

`CORE=ooo` is not in `make verify`'s Linux path for the same reason
`sim_linux` is not in `make verify` at all: it needs a kernel tarball off the
network.

## The last bug: one letter in a device tree

The console garbled the moment Linux took it over from the SBI earlycon:

```
clk: Disabling unused clocks
Fet2KoecRt=:kL 6mrp1-op	h		i		r_m		m	m		m
```

It was not a decoding rate mismatch — the harness reported the UART running at
divisor 14, 224 clocks per bit, which is what `+uart_clks=224` assumes and what
both OpenSBI and Linux compute from `clock-frequency`. That was true, and it
ruled out the wrong half. The rate was right; the bytes were not all being
sent.

`dts/soc.dts` said `compatible = "ns16550a"`. `rtl/uart.v` has no FIFOs — its
own header says so, and so did a comment directly above that line: *"IIR
reports bits 7:6 = 00, so a driver that checks will stay in 16450 mode."*

Nothing checks. `drivers/tty/serial/8250/8250_of.c` sets `UPF_FIXED_TYPE`, so
`uart_configure_port()` skips `autoconfig()` and the honest `IIR` is never
read. The compatible string is not a hint — it is the configuration.
`ns16550a` is `PORT_16550A` is `tx_loadsz = 16`, and `serial8250_tx_chars()`
writes sixteen bytes into a one-byte holding register after a single `THRE`
with no status check between them. `rtl/uart.v` takes a write only when the
transmitter is free, so fifteen of every sixteen were discarded — correctly,
and with nothing that could report it.

`compatible = "ns16450", "ns16550";` now. The order is load-bearing: Linux
scores a match by its index in *this* list and takes `ns16450`, while OpenSBI's
`uart8250` driver matches `ns16550` and keeps its own console.

**How it is tested.** `+checkuart` counts what software wrote to `THR` and
compares it against what the receiver decodes off the wire. Before:

```
** UART dropped a byte at cycle 127768723: 0x72 'r' was written to THR while
   the transmitter was still shifting the previous character out
...
UART bytes written to THR: 6336, **470 dropped by the transmitter**, 5866 sent
```

`r`,`e`,`e`,`i`,`n`,`g`,` `,`u`,`n`,`u`,`s`,`e` — the tail of `F`*reeing
unuse*`d`, forty-eight cycles apart where a character takes 2,240. After:
`6335 written, all 6335 sent, in order`. It runs in `make verilator_check`
(part of `make verify`) and in `make sim_linux`.

## The bug before that: an instruction executed under the wrong PC

`fdt_next_node(blob, 0)` returned `-FDT_ERR_BADOFFSET` for a device tree that
was demonstrably well formed. The reason was three instructions wide:

```
c02205b4:  jal   c0220224 <fdt_next_tag>
c02205b8:  li    a5,1
c02205bc:  bne   a0,a5,c02205ec        # -> `li s0,-4`
```

`fdt_next_tag` returned 1, `a5` should have been 1, and the branch was taken
anyway — because `a5` still held `0x38`. The pipeline trace says why:

```
cycle      fetchpc  ifidpc   ifidins  ... mis pred     | imemaddr imemdata
33147587   c0221620 c0220350 00008067 ... yes 1/c0221620| 90620350 00008067
33147588   c02205b8 ...                                 | 90620350 ...
33147604   c02205b8 ...                                 | 90621620 00300713
33147605   c02205bc c02205b8 00300713 ...               | 906205bc ...   wait
```

The `ret` at `c0220350` was predicted taken to a **stale BTB target**
(`c0221620`, left by another call site). The core detected that correctly and
redirected to `c02205b8`. But an **ITLB walk was in flight for the
mispredicted target**, and `rtl/mmu.v` answers a concluded walk from the
`va_r` it latched when the walk started. So the walk handed back
`c0221620`'s physical address, the fetch unit dutifully fetched from it — a
real instruction at a real address, so nothing downstream objected — and the
IF/ID register paired `li a4,3` from the wrong path with the corrected PC
`c02205b8`. `a5` was never written; `a4` was.

The fix is in `rtl/mmu.v` and both cores: the module now exposes `pa_va`, the
virtual address its answer is the translation *of*, and the fetch rejects an
answer that is not for the current `pc`. Rejecting costs a re-walk and cannot
livelock — the walk still installs its TLB entry.

**Why nothing caught it before.** It needs an ITLB miss and a mispredict in
flight at the same moment. Every bare-metal program here is small enough that
the ITLB stops missing after the first pass, and riscv-tests never enables
paging at all. Linux, with 4 KB pages throughout its linear map and a 2.4 MB
text section, is in ITLB eviction permanently.

**How it is tested.** `+checkdecode` compares the instruction the decoder is
holding against the instruction at its own PC, translating that PC through the
page tables independently. Before the fix it reports 35 wrong decodes in forty
million cycles; after, none in 28 million checked. It runs in
`make verilator_check`, which is part of `make verify`.

## How the pieces fit

```
0x9000_0000  sbi_stub.S        three instructions: a0=hartid, a1=dtb, jump
0x9000_8000  soc.dtb           the device tree OpenSBI parses
0x9008_0000  fw_jump.bin       OpenSBI, linked to run here
0x9040_0000  Image             Linux, with the initramfs inside it
0x91E0_0000  soc.dtb           where OpenSBI relocates it for Linux
```

`software/opensbi/mkimage.py` builds that and checks what it can: OpenSBI's
`_fw_rw_start` alignment precondition against the built ELF, the RISC-V Image
header's magic and `text_offset` against where the image puts the kernel, and
that the kernel's runtime size does not run into the device tree.

**The initramfs is inside the Image** (`CONFIG_INITRAMFS_SOURCE`), not beside
it. One blob is one transfer over `software/soc/uartload.py`, one address for
OpenSBI to jump to, and no `linux,initrd-start` handoff to get wrong.

## The kernel configuration

`vernier_rv32.config` is a fragment merged over `allnoconfig`, not a
defconfig. A defconfig carries hundreds of drivers for hardware that does not
exist here and does not fit in 32 MB of SDRAM with room left to run in. The
result is a 3.4 MB `Image`.

Two things in it are not obvious and both were found by
`kconfig-merge.py check`, which re-reads `.config` after `olddefconfig` and
fails when a requested option did not survive:

- **`CONFIG_EFI` is `default y` on riscv and `select RISCV_ISA_C`.** Asking
  for a no-C kernel is not enough on its own; EFI turns it straight back on,
  kconfig says nothing, and the build emits compressed instructions for a core
  that has none.
- **`CONFIG_HZ_100` needs `# CONFIG_HZ_250 is not set`.** HZ is a `choice`,
  and setting the one you want without clearing the default leaves the
  default.

Configuration is not sufficient anyway: `arch/riscv/Makefile` appends `_zacas`
and `_zabha` to `-march` whenever the *toolchain* supports them, keyed on
symbols with no prompt, so the compiler is allowed to emit an `amocas` no
Kconfig option would stop. `isacheck.py` therefore disassembles the finished
`vmlinux` - 641,785 instructions - and checks every mnemonic against what
`rtl/` implements. Four Svinval instructions are present and unreachable
(`has_svinval()` is false because `dts/soc.dts` does not advertise it); they
are listed by name so that a *change* in the count is visible.

## /init has no libc

There is no rv32 Linux userspace toolchain on this machine - the one cross
compiler is `riscv64-unknown-elf`, which is bare metal and whose newlib knows
nothing about Linux system calls. Building musl or glibc for riscv32 means
building a second toolchain, which is hours of work for a program whose whole
job is to prove the kernel got here.

`initramfs/init.c` makes raw `ecall`s instead, which is the same instruction a
libc would emit. It prints a banner, `uname`, its pid, and `/proc/cpuinfo` -
that last one because it shows the ISA string the kernel parsed out of
`dts/soc.dts`, so a boot that reaches it has demonstrated the device tree was
believed as well as read.

`mkcpio.py` writes the archive, replacing `usr/gen_init_cpio`, which does not
compile on macOS. It also gets `/dev/console` right: `init/main.c` opens it to
give PID 1 its file descriptors, and without it every `write()` in `init.c`
fails with `EBADF` and a working boot prints nothing at all.

## Building on macOS

`build-linux.sh` handles six specific incompatibilities, each named in its
header with what the failure looks like. The one worth knowing about here is
that BSD `sed` has no `\+`, so
`arch/riscv/kernel/vdso/gen_vdso_offsets.sh` matches nothing and produces an
**empty** `vdso-offsets.h` - and the build then fails several thousand lines
later compiling `signal.c` against an undeclared
`__vdso_rt_sigreturn_offset`.

## Getting it onto a board

```sh
make linuxpayload
./software/soc/uartload.py /dev/cu.usbserial-XXXX software/linux/build/sdram.bin
# then press reset
```

The image is 7,744,876 bytes and the loader is stop-and-wait, a round trip per
byte, so that is about **22 minutes** at 115200. `uartload.py` says so before
it starts rather than leaving a progress bar to be interpreted.

**This has been done**, in one attempt, with no dropped byte in 7.7 million:

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
```

and then OpenSBI, the kernel, and:

```
4000000.serial: ttyS0 at MMIO 0x4000000 (irq = 1, base_baud = 1562500) is a 16450
printk: legacy bootconsole [sbi0] disabled
Run /init as init process

=== VERNIER-RV32: USERSPACE ===
kernel  : Linux 6.18.45
machine : riscv32
pid     : 1
isa     : rv32ima_zicntr_zicsr_zifencei_zaamo_zalrsc
mmu     : sv32

=== VERNIER-RV32-LINUX-BOOT-OK ===
```

The full transcript, and what each line of it settles about the hardware, is
in [fpga/README.md](../../fpga/README.md#linux-on-the-board). Two things worth
knowing before you try it:

**The bitstream must have nothing preloaded** — `BOARD=ulx3s85`. A preloaded
build makes the boot ROM jump straight to block RAM without ever opening the
loader's knock window.

**Timing margin at 25 MHz is approximately zero.** Two of six placement seeds
fail to close, so `synth_ecp5.sh` retries; budget several place-and-route
attempts per bitstream.
