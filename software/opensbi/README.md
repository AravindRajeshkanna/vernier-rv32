# OpenSBI — status

The goal here is an OpenSBI boot in simulation: M-mode firmware that prints
its banner and hands off to an S-mode payload. That is the next real link in
the RISC-V boot chain after this project's own boot ROM, and a meaningful
milestone short of Linux.

**Where it actually stands:** OpenSBI now *builds* for this core. It does not
yet *boot* on it. Being precise about that split:

| Step | Status |
|---|---|
| OpenSBI builds for rv32ima with `riscv64-unknown-elf-` | ✅ done, `./build-opensbi.sh` |
| CPU platform features OpenSBI relies on | ✅ done (see below) |
| Platform port (console / timer / IPI glue) | ❌ not written |
| Somewhere to put a 521 KB `fw_jump.bin` | ✅ **32 MB of SDRAM, proven on silicon** — 16 MB reachable through the current address decode |
| A way to *load* it there on a board | ❌ a bitstream initialises block RAM; SDRAM comes up empty |
| Actually boots and prints a banner | ❌ not attempted |

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
