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
completing and the kernel allocating 8068 bytes for what it measured, then the
*second* walk over the same bytes failing. Same traversal, same input,
different answer.

The second round of instrumentation localised that a long way further. The
failing call is exactly:

```
fdt_next_node(blob = 0x9de00000, offset = 0, &depth)  ->  -FDT_ERR_BADOFFSET
```

- `blob` is `dtb_early_va`, the fixmap address of the device tree, and it is
  correct.
- `offset` is 0, the root node, so this is the *first* step of the second
  pass - it fails immediately, not part-way through.
- libfdt can only return that from `fdt_check_node_offset_()`, which means
  `fdt_next_tag()` did not report `FDT_BEGIN_NODE` for the root.
- Every memory read that call makes is verified correct (below), and the tag
  it reads at struct offset 0 is `0x00000001` - `FDT_BEGIN_NODE`.

So the data is right and the answer is wrong.

### What has been ruled out, and how

Nothing here is an argument from reading the RTL. Each line is a measurement
over a whole boot.

| Suspect | Instrument | Result |
|---|---|---|
| The blob on disk | `dtc -I dtb` on what `+savemem` pulled out of SDRAM | 126 lines, valid |
| The blob at the failing moment | `+savemem` at 30M and at 200M cycles, `cmp` | byte-identical; nothing writes it |
| The blob's structure | an independent walker in Python implementing libfdt's own `fdt_next_tag` rules | 20 nodes, well-formed, walk completes |
| Where the blob is | ran with the tree at `0x9020_0000` and at `0x91E0_0000` | identical failure |
| The kernel image | `+savemem` of all 3.5 MB, `cmp` against the file | every byte of executable text identical |
| **What memory hands back** | `+checkreads` | **19,911,640 SDRAM reads, all matched the part** |
| **What the core executes** | `+checkfetch` | **133,755,481 fetches, all matched memory** |
| **Address translation** | `+checkmmu`, walking the page tables in C++ | **125,322,100 translations, all agreed** |
| The two-level page walk | `software/soc/mmutest.c`, extended | passes |
| TLB refill under pressure | same, 4x the entry count | passes |
| A timing race | both cores | byte-identical faulting addresses |
| The memory map | dropped the block-RAM `memory` node | no change |
| A write-back cache hiding a PTE | `cpu_wb.v` is write-through, and SDRAM is not even in `dc_cacheable` | n/a |

The three self-checking probes are the substantial part. Between them they say
that for the whole of a Linux boot, this SoC delivered the right word from the
right address for every instruction and every load. That is a strong statement
about the memory system and the MMU, and it is now a repeatable one.

### Where it actually stops: a register write that does not arrive

The instruction sequence is three long. `fdt_next_tag()` returns, `a5` is set
to 1, and the result is compared against it:

```
c02205b4:  jal   c0220224 <fdt_next_tag>
c02205b8:  li    a5,1
c02205bc:  bne   a0,a5,c02205ec <.L144>     <- .L144 is `li s0,-4`
```

`fdt_next_tag` returns `FDT_BEGIN_NODE`, which is 1, so `a0 == a5` and the
branch must not be taken. It is taken exactly once, on the 53rd and last
execution, and that is where `-FDT_ERR_BADOFFSET` comes from.

At that execution `a5` holds **0x38** - the value it had inside
`fdt_offset_ptr`, before `li a5,1`. The write did not arrive.

That claim is only worth making because the probe reading it is calibrated at
the *same PC*:

| | `a0` | `a5` | branch |
|---|---|---|---|
| first execution of `0xc02205bc` | 1 | **1** | not taken, correct |
| last (53rd) execution | 1 | **0x38** | taken, wrong |

Same instruction, same probe, same sampling skew - so the probe can read `a5`
there, and on the last pass the register genuinely does not hold what the
instruction before it wrote. `li a5,1` retires 53 times, the same count as the
`jal` before it and the `bne` after it, so it is not being skipped.

And nothing interrupts the sequence: `+traptrace` logs all 215 traps of the
boot, and **none of them fall within 20,000 cycles** of that instruction.

### What is not yet known

The mechanism. Forcing `predicted_taken` low in `rtl/btb.v` moves the failure
somewhere else entirely - the kernel stops earlier, in a spin, with no FDT
error at all - but that experiment proves nothing: removing branch prediction
changes the timing of everything, so *any* timing-sensitive defect would move.
It is recorded here as a thing tried, not as evidence.

Worth correcting from the previous round, too: "both cores fail identically"
was over-read. The identical oops addresses are all downstream of
`of_root == NULL`, so they only show that both cores end up with a failed
unflatten - not that the same instruction misbehaved in each. A
timing-sensitive bug was never actually excluded.

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
