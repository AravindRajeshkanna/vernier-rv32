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

**In QEMU (`qemu-system-riscv32 -M virt`) this kernel boots to userspace.**
That is the whole chain except the hardware: the config, the ISA restriction,
the cpio format, `/dev/console`, the libc-free `/init` and its raw system
calls are all proven end to end.

**On this SoC it now reaches the last initcall before `/init`.**

| | |
|---|---|
| OpenSBI banner, platform, root domain, hand off to S-mode | ✅ |
| Kernel entered, device tree parsed, `earlycon=sbi` up | ✅ |
| memblock, Sv32 paging, the whole linear map | ✅ |
| `unflatten_device_tree()` | ✅ **fixed — see below** |
| `Memory: 24316K/28672K available` | ✅ |
| `SBI misaligned access exception delegation ok` | ✅ |
| `clocksource: Switched to clocksource riscv_clocksource` | ✅ |
| `riscv-plic: plic@3000000: mapped 8 interrupts ... for 2 contexts` | ✅ |
| `4000000.serial: ttyS0 at MMIO 0x4000000 (irq = 1) is a 16550A` | ✅ |
| console handover from `sbi0` to `ttyS0` | ✅ |
| `clk: Disabling unused clocks` | ✅ |
| everything after that | ❌ **the console output garbles** |

The remaining failure is the next one to chase: after Linux takes the console
over from the SBI earlycon, the bytes coming out are mangled. It is not a
decoding rate mismatch — the harness reports the UART running at divisor 14,
224 clocks per bit, which is what `+uart_clks=224` assumes and what both
OpenSBI and Linux compute from `clock-frequency` in `dts/soc.dts`. So it is
either `rtl/uart.v`'s transmitter or the 8250 driver's use of it.

## The bug that was in the way: an instruction executed under the wrong PC

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

The image is 7.5 MB and the loader is stop-and-wait, a round trip per byte, so
that is about **22 minutes** at 115200. `uartload.py` says so before it starts
rather than leaving a progress bar to be interpreted. This has not been run on
hardware - there is no reason to spend 22 minutes sending an image that does
not finish booting in simulation.
