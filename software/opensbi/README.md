# OpenSBI — status

The goal here is an OpenSBI boot in simulation: M-mode firmware that prints
its banner and hands off to an S-mode payload. That is the next real link in
the RISC-V boot chain after this project's own boot ROM, and a meaningful
milestone short of Linux.

**Where it actually stands: it boots.** `make sim_opensbi` runs OpenSBI
v1.9 on this SoC, in simulation, and it prints its banner, detects the
platform from `dts/soc.dts`, builds its root domain and prepares to hand off
to S-mode.

| Step | Status |
|---|---|
| Builds for rv32ima with `riscv64-unknown-elf-` | ✅ `./build-opensbi.sh` |
| Platform port | ✅ **not needed** — `PLATFORM=generic` is FDT-driven, so the port is `dts/soc.dts` plus hardware the stock drivers recognise |
| Finds the console | ✅ `uart8250` — `rtl/uart.v` |
| Finds the timer and IPI | ✅ `aclint-mtimer @ 25000000Hz`, `aclint-mswi` |
| Finds the interrupt controller | ✅ the PLIC's 4 MB window appears as a domain region |
| Detects the hart | ✅ `rv32ima`, priv `v1.11`, PMP count 0 |
| **Prints its banner** | ✅ |
| Hands off to an S-mode payload | ✅ prepared — `Next Address 0x9040_0000`, `Next Mode S-mode`; there is no payload there yet |
| A kernel to hand off *to* | ❌ see docs/roadmap.md |

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
address minutes earlier. `FW_JUMP_FDT_ADDR=0x9020_0000` and
`FW_JUMP_ADDR=0x9040_0000` now, both set by `build-opensbi.sh`.

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

## What's left to actually boot it

1. **A platform port.** `platform/template/` upstream is the skeleton. It
   needs a console (this SoC's UART is not a 16550, so OpenSBI's `uart8250`
   driver won't do), plus timer and IPI hooked to the CLINT — the CLINT is
   already register-compatible with `riscv,clint0`, so that part should be
   straightforward. The PLIC is **not** layout-compatible with `riscv,plic0`
   (its threshold/claim registers are at `0x3000`/`0x3004` rather than the
   spec's per-context `0x200000` block), so either the PLIC gets remapped or
   the port skips irqchip init.
2. **Link it into SDRAM** at `0x9000_0000`, not block RAM. `fw_jump.bin` is
   521 KB against 64 KB on the board, and Phase 2 answered that: there are
   32 MB of SDRAM on a ULX3S and `rtl/soc/wb_sdram.v` reaches 16 MB of them.
   This used to say DRAM was "the reason this can never run on the current
   FPGA target", which stopped being true when a board read and wrote 256 KB
   of it — see `fpga/README.md`.

   What is *not* answered is getting the image there on hardware. A bitstream
   initialises block RAM at FPGA configuration time and SDRAM comes up
   holding nothing, so this needs a loader: the SD path (Phase 7) or a UART
   one. In simulation the testbench preloads the model and the question does
   not arise, which is exactly the kind of gap `docs/practices.md` §4 is
   about.
3. **Preload rather than loading over SPI, in simulation.** Pulling ~500 KB
   through the bit-banged SPI/SD path would cost roughly 16 M cycles just for
   the transfer. `sim/tb_sdramboot.v` already does this — it `$readmemh`s the
   image straight into the SDRAM model and runs a 99 KB program out of it.
4. **An S-mode payload** for OpenSBI to hand off to, to prove the transition.

## And to be clear about Linux

Even with all of the above, Linux needs more than this: an S-mode PLIC
context (`mip.SEIP` is currently hardwired 0, so the kernel could never
receive an external interrupt), a UART with an actual Linux driver, and tens
of megabytes of RAM. See the root `README.md` for the full gap analysis.
