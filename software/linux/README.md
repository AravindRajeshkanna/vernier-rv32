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

```
Run /init as init process

=== VERNIER-RV32: USERSPACE ===
kernel  : Linux 6.18.45
machine : riscv32
pid     : 1

--- /proc/cpuinfo ---
processor       : 0
hart            : 0
isa             : rv32imac...
mmu             : sv32

=== VERNIER-RV32-LINUX-BOOT-OK ===
```

**On this SoC it does not reach userspace yet.** It gets a long way, and the
stopping point is exact rather than a hang. `make sim_linux` produces:

| | |
|---|---|
| OpenSBI banner, platform, root domain | ✅ |
| Hands off to S-mode at `0x9040_0000` | ✅ |
| Kernel entered, `Linux version 6.18.45 ...` | ✅ |
| Device tree parsed: machine model, `bootargs`, both memory nodes | ✅ |
| SBI extensions detected (time, ipi, rfence, srst, dbcn, fwft) | ✅ |
| `earlycon=sbi` console up | ✅ |
| memblock built, OpenSBI's reserved regions honoured | ✅ |
| Sv32 paging on, kernel running at `0xC000_0000` | ✅ |
| Linear map built - all seven level-2 tables | ✅ |
| `unflatten_device_tree()` | ❌ `OF: fdt: Error -4 processing FDT` |

Everything after that is a cascade: `of_root` is NULL, the zone print faults,
and the oops handler faults reading kallsyms while trying to report it.

### What that failure is, and what it is not

`unflatten_device_tree()` walks the blob **twice** - once to size the result,
once to build it. With `memblock=debug` the log shows the *first* walk
completing and the kernel allocating 8068 bytes for the result, then the
*second* walk over the same bytes failing with `-FDT_ERR_BADOFFSET`. Same
traversal, same input, different answer.

Ruled out, each by measurement rather than by reading:

- **The blob.** `+savemem` pulls it out of SDRAM and `dtc -I dtb` decodes all
  126 lines of it, including the `reserved-memory` nodes OpenSBI added.
- **Where the blob is.** It failed identically with the device tree at
  `0x9020_0000` and at `0x91E0_0000`. (It is at `0x91E0_0000` now for a
  separate and real reason - see below.)
- **The kernel image.** `+savemem` of all 3.5 MB and `cmp` against the file:
  every byte of executable text identical, and every difference in `.data`,
  `.init.data` or the `kallsyms` sequence table, all of which the kernel
  legitimately writes.
- **The two-level page walk.** This was the strongest suspect, because
  nothing in this repository had ever made the hardware read a second PTE -
  `make sim_mmusdram` mapped megapages only, and riscv-tests never enables
  paging. `software/soc/mmutest.c` now covers 4 KB pages, VPN[0] at 0, 512
  and 1023, per-page permissions, an invalid level-2 entry, three pages in
  one megapage to catch a TLB that tags at the wrong granularity, and a
  sweep over four times the TLB's eight entries read back in reverse, so
  every hit is on an entry that was evicted and walked again. That last one
  matters here specifically: on rv32 the whole linear map is 4 KB pages, so
  Linux runs permanently in TLB eviction in a way nothing else on this SoC
  does. All pass.
- **A timing race.** The in-order and wide cores fail at byte-identical
  faulting addresses. Two unrelated pipelines do not produce the same wrong
  values by coincidence.
- **The memory map.** Removing the block-RAM `memory` node changes nothing.
- **Write-back cache holding a PTE the walker cannot see.** `cpu_wb.v`'s data
  cache is write-through, and its header says this is why.

So it is deterministic, it is not the blob, not the image, not the walker,
not the pipeline. The next thing to instrument is which *read* differs
between the two passes, which needs a watchpoint on the FDT's physical page
rather than on a PC.

### One real bug this did find

**`mstatush` was missing from the wide core.** `rtl/cpu_core.v` gained CSR
`0x310` when OpenSBI first needed it; `rtl/ooo/core_ooo.v` never did, and
nothing noticed because `make sim_opensbi` builds `CORE=inorder`. Pointed at
the wide core, OpenSBI took an illegal-instruction trap on
`csrc mstatush, t0` at cycle 6050 and hung in `_start_hang` with no console.
Fixed, and the wide core now boots OpenSBI and reaches the same point as the
in-order one.

### And one address that had to move

`FW_JUMP_FDT_ADDR` was `0x9020_0000`, below the kernel. `arch/riscv` sets
`phys_ram_base` to the kernel's own load address and drops every memory range
below it, so a device tree there is in memory the kernel has decided does not
exist. It is `0x91E0_0000` now, above the kernel, mirroring where QEMU's virt
machine puts it.

This did **not** fix the failure above, and that is worth saying plainly: it
is a real defect found while chasing a different one, and it would have bitten
as soon as the first one was fixed.

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
