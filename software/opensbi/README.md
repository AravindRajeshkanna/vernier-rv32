# OpenSBI — status

The goal here was an OpenSBI boot: M-mode firmware that prints its banner and
hands off to an S-mode payload. That is the next real link in
the RISC-V boot chain after this project's own boot ROM, and a meaningful
milestone short of Linux.

**Where it actually stands: it boots, on a board.** OpenSBI v1.9 runs on a
ULX3S / LFE5U-85F, detects the platform from `dts/soc.dts`, builds its root
domain and hands off to a Linux kernel that reaches userspace.
`make sim_opensbi` does the same under Verilator.

| Step | Status |
|---|---|
| Builds for rv32ima with `riscv64-unknown-elf-` | ✅ `./build-opensbi.sh` |
| Platform port | ✅ **not needed** — `PLATFORM=generic` is FDT-driven, so the port is `dts/soc.dts` plus hardware the stock drivers recognise |
| Finds the console | ✅ `uart8250` — `rtl/uart.v` |
| Finds the timer and IPI | ✅ `aclint-mtimer @ 25000000Hz`, `aclint-mswi` |
| Finds the interrupt controller | ✅ the PLIC's 4 MB window appears as a domain region |
| Detects the hart | ✅ `rv32ima`, priv `v1.11`, PMP count 0 |
| **Prints its banner** | ✅ |
| Hands off to an S-mode payload | ✅ `Next Address 0x9040_0000`, `Next Mode S-mode` |
| A kernel to hand off *to* | ✅ Linux 6.18.45 rv32ima, to userspace — `software/linux/README.md` |

```
OpenSBI v1.9-11-gc0f87f10
Platform Name               : From-scratch RV32IMA Wishbone SoC
Platform Features           : medeleg
Platform HART Count         : 1
Platform IPI Device         : aclint-mswi
Platform Timer Device       : aclint-mtimer @ 25000000Hz
Platform Console Device     : uart8250
Firmware Base               : 0x90080000
Runtime SBI Version         : 3.0
Standard SBI Extensions     : rfnc,ipi,base,hsm,pmu,dbcn,fwft,legacy,sse,time
Domain0 Next Address        : 0x90400000
Domain0 Next Mode           : S-mode
Boot HART Base ISA          : rv32ima
Boot HART PMP Count         : 0
Boot HART MIDELEG           : 0x00000222
Boot HART MEDELEG           : 0x0000b109
```

## The five defects between "builds" and "boots"

None of them were findable by printing, because the thing that had failed was
always upstream of the console. Each was found by instrumenting the *machine*
— see docs/practices.md §27, which is the reusable half of this.

**1. `mstatush` did not exist.** `mcause=2`, `mtval=0x3102b073` =
`csrrc x0, 0x310, t0`. CSR 0x310 is RV32-only and required; OpenSBI's assembly
startup clears MBE/SBE unconditionally, before it has a handler that could
survive a trap. A genuine core bug, fixed in `rtl/cpu_core.v` and
`rtl/csr_file.v`.

**2. The firmware was linked where `sbi_domain_init()` refuses to run.** It
requires `_fw_rw_start - _fw_start` to be a power of two with `_fw_start`
aligned to it. `0x9001_0000` gave `0x70000`. Now `0x9008_0000`, and
`mkimage.py` checks it against the built ELF.

**3. `build-opensbi.sh` built the wrong thing, twice** — a stale generated
linker script, and a `$(pwd)`-relative source path that cloned a second
OpenSBI at the repository root.

**4. `FW_JUMP_FDT_ADDR` defaulted outside the SoC's memory.** This was the
subtle one. OpenSBI defaults it to `FW_TEXT_START + 0x2200000` = `0x9228_0000`
here, and this SoC decodes 32 MB (`0x90`–`0x91`). That matters far more than
"the next stage's device tree is misplaced", because `fdt_get_address()`
returns the *root domain's* `next_arg1` — OpenSBI reads its **own** device
tree through that pointer. Pointed at unmapped space it read zeros,
`fdt_path_offset(fdt, "/cpus")` returned `-FDT_ERR_BADMAGIC` (-9), and the
firmware stopped, having parsed the same tree successfully at its original
address minutes earlier.

`FW_JUMP_ADDR=0x9040_0000` now, which is not a choice: the rv32 Linux Image
header asks to run at RAM + 0x400000 because `setup_vm()` maps the kernel with
Sv32 megapages, and `mkimage.py` reads that field out of the built Image and
refuses a mismatch.

**`FW_JUMP_FDT_ADDR` then had to move a second time**, to `0x91E0_0000`, and
the reason was invisible until a kernel actually ran. `0x9020_0000` is *below*
`FW_JUMP_ADDR`, and `arch/riscv` sets `phys_ram_base` to the kernel's own load
address and drops every memory range beneath it — the boot log says so,
`Ignoring memory range 0x90000000 - 0x90400000`. A device tree there is in
memory the kernel has decided does not exist.

It half works, which is what makes it expensive. Linux's *early* parse reads
the blob through the fixmap and succeeds — machine model, command line, memory
nodes, reserved regions all correct. It is `unflatten_device_tree()`, later,
that fails. `0x91E0_0000` is 30 MB into the part and mirrors where QEMU's virt
machine puts it: top of RAM minus 2 MB.

**5. The device tree's `timebase-frequency` was twice the real one.** OpenSBI
printed `aclint-mtimer @ 50000000Hz` against a 25 MHz `mtime`. Everything an
SBI implementation does with time derives from that number, so a factor of two
here is a factor of two in every timer a kernel programs — and it presents as
a system running at half speed rather than as an error. Found only because
OpenSBI prints what it read.

## One thing the harness has to be told

`+uart_clks=224`, not 208. OpenSBI reads `clock-frequency` from the device
tree and *rounds* the divisor: `(25e6 + 8*115200) / (16*115200)` = 14, giving
224 clocks per bit, where the obvious `25e6/(16*115200)` = 13 suggests 208.
Decoding at 208 produces convincing garbage rather than nothing, which reads
as a firmware fault instead of a decoding one — and did, for one round. The
harness now reports the divisor the UART is actually running at and names the
value to use.

## What was fixed in the CPU to get this far

OpenSBI (and any supervisor firmware) leans on platform features this core
either lacked or got wrong. All of these are now implemented and covered by
`make sim_soc`:

- **`misa` advertised `I` only** — a plain bug. The core has implemented M
  and A for several revisions, and firmware reads `misa` to decide what the
  hart can do, so under-reporting makes it disable working features.
- **No counter CSRs at all.** `cycle`/`time`/`instret` (plus the RV32 `h`
  halves and the machine-level `mcycle`/`minstret`) now exist, gated by
  `mcounteren`/`scounteren`. `time` deliberately reads the *CLINT's* `mtime`
  rather than a private counter — SBI timer code reads `time` and programs
  `mtimecmp` from it, so those two have to be the same clock.
- **Misaligned accesses were silently mis-executed.** They now trap (cause 4
  load / 6 store-AMO) with `mtval` set. This matters specifically because
  M-mode firmware *emulates* misaligned accesses — but only ever gets the
  chance if the hardware traps instead of quietly corrupting.
- **`FENCE.I` was a no-op while `cpu_wb.v` kept a fetch buffer.** That buffer
  is never coherent with writes, so a loader that copies code into RAM and
  jumps to it could execute a stale word. `FENCE.I` now invalidates it and
  redirects, and `make sim_soc` proves it with a self-modifying-code test.

## The one build wrinkle worth knowing

Modern OpenSBI hard-errors unless the linker can produce PIEs, and
`riscv64-unknown-elf-ld` cannot — it targets bare-metal ELF, not Linux, and
answers `-pie not supported`. The firmware doesn't need to be
position-independent here, so `build-opensbi.sh` makes the PIE flags
conditional on linker support instead of unconditional, and builds `FW_PIC=n`.
The patch is idempotent and the upstream commit is pinned so it can't silently
rot.

## Where this leads

`make sim_linux` boots an rv32ima Linux to userspace on this SoC through this
firmware — see `software/linux/README.md`. This section used to list what was
left to get there, and every item on it has since been answered:

- **A platform port** — not needed. `PLATFORM=generic` is FDT-driven, so
  `dts/soc.dts` is the port, and it works because the hardware the stock
  drivers look for is now really there: `rtl/uart.v` became an ns16550 and
  `rtl/plic.v` moved to the spec's per-context register map (both in #23),
  which the old text called out as the two blockers.
- **Link it into SDRAM** — `FW_TEXT_START=0x9008_0000`, and the board reads
  and writes the part on silicon (`fpga/README.md`).
- **Getting the image there on hardware** — `software/soc/uartload.py` and the
  loader in `software/soc/bootrom.c`, proved on a board with a 99 KB program.
- **Preload rather than loading over SPI in simulation** — `+sdram=` does it.
- **An S-mode payload** — the kernel.

One correction worth keeping, because it was wrong in the direction that
matters. The device tree's UART node said `compatible = "ns16550a"`, which
OpenSBI's `uart8250` driver was perfectly happy with — and which told Linux the
part had a sixteen-byte FIFO it does not have. M-mode polled `THRE` before
every byte and never noticed; the kernel wrote sixteen at a time and lost
fifteen. It now says `"ns16450", "ns16550"`, which both firmwares match and
only one of them was ever going to catch. docs/practices.md §32.

## What the board added to this

The banner above is from simulation and the board prints the same thing, with
three fields worth recording because they are properties of the hardware
rather than of the firmware:

```
Firmware Size               : 569 KB
Boot HART ISA Extensions    : zicntr
Boot HART PMP Count         : 0
Domain0 Next Arg1           : 0x91e00000
```

`zicntr` is OpenSBI reading `rtl/csr_file.v`'s counters and finding
`cycle`/`time`/`instret` where the spec says they go. `PMP Count : 0` is
honest — this core has no physical memory protection, which is why
`Domain0 Region05` covers all of memory with no M-mode restriction, and why a
domain model that would matter on a multi-tenant machine is decorative here.
`Next Arg1` is the device tree at `0x91E0_0000`, the address that took two
attempts to get right and is explained above.

The one caveat left is timing rather than firmware: margin at the board's
25 MHz is approximately zero and two of six placement seeds fail to close. See
`fpga/README.md`.
