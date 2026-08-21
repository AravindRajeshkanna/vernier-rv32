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
| Platform port | ✅ **not needed** — `PLATFORM=generic` is entirely FDT-driven, so the port *is* `dts/soc.dts` plus hardware the stock drivers recognise |
| An ns16550 console for it to find | ✅ `rtl/uart.v`, `make sim_uart16550` |
| A PLIC with an S-mode context at the standard offsets | ✅ `rtl/plic.v`, `make sim_plic` |
| Somewhere to put a 517 KB `fw_jump.bin` | ✅ **32 MB of SDRAM, proven on silicon**, all of it now reachable |
| Linked to run from SDRAM | ✅ `FW_TEXT_START=0x90010000` |
| Packed with a device tree and entered correctly | ✅ `make sbiimage`, `sbi_stub.S` |
| **Actually runs** | ⚠️ **runs through FDT parsing and hart feature detection, then `sbi_hart_init()` returns an error and it hangs** |
| Prints a banner | ❌ not yet — the console comes up after the point it stops |

## Where it actually stops, and the three things fixed getting there

OpenSBI does not boot. It gets a great deal further than it did, and the route
from "hangs at cycle 7192 with no explanation" to here was three real defects,
each found by making the machine say something the firmware could not.

### The method, because it is the reusable part

OpenSBI owns the console and brings it up late, so every failure before that
point is eight million identical silent cycles. Nothing OpenSBI can print
helps. What broke the deadlock was instrumenting the *hardware* instead —
`sim/verilator_soc.cpp` grew four things, all cheap and all general:

| | |
|---|---|
| `traps taken` + the trap CSRs | sampled a cycle *after* the trap pulse, or mcause/mepc/mtval read as the previous trap's values — three zeros, which looks exactly like "cause 0 at address 0" |
| `pc over the last N cycles` | a wedged firmware is in a tight loop, and the loop's *range* identifies it |
| `last control transfers` | a ring of non-sequential PC changes, repeats collapsed, so a two-instruction `wfi` spin does not overwrite the history that explains it |
| `+watchpc=ADDR` | dump the integer registers the first time the PC reaches an address |

Every address goes straight into `addr2line` against `fw_jump.elf`. At
4.4 M cycles/s an iteration is under two seconds, which is what made three
rounds of this practical at all.

### 1. `mstatush` did not exist

`mcause=2` (illegal instruction), `mepc=0x900100c0`,
`mtval=0x3102b073` — which decodes as `csrrc x0, 0x310, t0`, and CSR 0x310 is
**`mstatush`**. It is RV32-only and required, holding the MBE/SBE big-endian
controls, and OpenSBI's assembly startup clears them unconditionally before it
has a handler that could survive a trap. `mtvec` at that point still points at
`_start_hang`.

Fixed in `rtl/cpu_core.v` and `rtl/csr_file.v`: the CSR exists and reads zero,
which is correct for a little-endian-only implementation — the fields are
WARL. This was a genuine core bug, reachable by any RV32 firmware, and nothing
in this repository had ever executed one.

### 2. The load address was not aligned the way OpenSBI requires

Next stop: `sbi_domain_init` → `sbi_hart_hang`. Its first check is that
`_fw_rw_start - _fw_start` is a power of two and that `_fw_start` is aligned to
it. OpenSBI's linker script puts the read-write sections at the next power-of-2
boundary *above* the read-only ones, computed as an absolute address — so both
conditions only hold when `FW_TEXT_START` is itself aligned to that rounded
size. At `0x9001_0000` the offset came out `0x70000`, which is not a power of
two.

`FW_TEXT_START` is now `0x9008_0000` and `software/opensbi/mkimage.py`
**checks both conditions against the built ELF** before it will pack an image.
That is the difference between a build error naming the numbers and a
simulation that hangs before it can complain.

### 3. The build script silently built the wrong thing, twice

`FW_TEXT_START` is baked into a generated linker script that `make clean` does
not remove, so changing it rebuilt at the old address — the symbols said
`0x9001_0000` after a build that had asked for `0x9008_0000`. And `SRC` was
derived from `$(pwd)`, so running the script from the repository root cloned a
*second* copy of OpenSBI at `<repo>/build/opensbi` and built that, while the
Makefile still pointed at the copy under `software/opensbi/`.

Both are fixed: the path is relative to the script, and a stamp file forces a
clean rebuild when the address changes.

### Where it stops now

Deep in `sbi_hart_init()`, after the FDT has been parsed and hart features
detected — the trace runs through `fdt_parse_isa_extensions_all_harts` and
`generic_pmu_xlate_to_mhpmevent` before returning an error that
`init_coldboot` turns into `sbi_hart_hang()`.

```
last control transfers (oldest first):
  ...
  0x900a9cf4 -> 0x90093978     fdt_parse_isa_extensions_all_harts
  0x90093988 -> 0x90082848     generic_pmu_xlate_to_mhpmevent
  0x90082854 -> 0x90082790     sbi_hart_has_extension -> sbi_hart_init
  0x900827ac -> 0x900860d8     sbi_hart_init -> init_coldboot
  0x90086004 -> 0x900851e4     -> sbi_hart_hang
```

**PMP is ruled out**, which is worth saying because it was the stated
hypothesis in the previous round and it was wrong: `sbi_hart_pmp_init()`
returns 0 when `sbi_hart_pmp_count()` is zero, so a core with no PMP does not
fail there.

`a0` holds `0xfffffff7` (-9, `SBI_ERR_NO_SHMEM`) at the hang, but nothing in
`sbi_hart.c`, `sbi_scratch.c`, `sbi_heap.c` or `sbi_domain.c` returns that
code, so it is more likely a leftover than the error being acted on. It is
recorded here as an observation, not a diagnosis.

The next move is to narrow `sbi_hart_init`'s four calls -
`sbi_scratch_alloc_offset`, `hart_detect_features`, `sbi_hart_pmp_init`,
`sbi_hart_reinit` - with `+watchpc` on each return site.

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
