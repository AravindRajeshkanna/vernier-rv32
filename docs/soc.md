# The SoC — components and register reference

What blocks exist, where they live, what registers they have, and what to
watch out for when programming them.

This is the **reference**; `architecture.md` is the **rationale**. Where a
design decision needs explaining rather than stating, this file links there
rather than repeating it. If you are writing firmware or adding a peripheral,
start here. If you want to know *why* the interconnect arbitrates the way it
does, start at `architecture.md` section 12a.

Everything below describes `rtl/soc/soc_top.v`, the Wishbone system.
`rtl/top.v` is a different, older, flat wiring of the same CPU kept for
`sim/tb_top.v`'s regression — it has no bus, no boot ROM and no storage, and
none of this applies to it.

---

## 1. Block diagram

```
                  ┌───────────────┐
                  │   cpu_core    │  RV32IMA, M/S/U, Sv32 MMU, BTB
                  └───┬───────┬───┘
           imem port  │       │  dmem port        ptw / iptw ports
                  ┌───▼───────▼───┐                     │
                  │    cpu_wb     │  native -> Wishbone │
                  └───┬───────┬───┘                     │
        master 0 ─────┘       └───── master 1           │
         (fetch)                      (data)            │
                  ┌────────▼──────────────┐             │
                  │   wb_interconnect     │  2 masters, 8 slaves
                  └───┬──┬──┬──┬──┬──┬──┬─┘             │
        ┌─────────────┘  │  │  │  │  │  └──────────┐    │
        │        ┌───────┘  │  │  │  └────────┐    │    │
     ┌──▼───┐ ┌──▼───┐ ┌────▼┐ ┌▼────┐ ┌──────▼┐ ┌─▼────▼─┐
     │wb_rom│ │bridge│ │ SPI │ │GPIO │ │  FB   │ │ wb_ram │
     └──────┘ └──┬───┘ └─────┘ └─────┘ └───┬───┘ └────────┘
                 │                          │      port B feeds
          ┌──────┼──────┐              ┌────▼─────┐ the two MMU
       ┌──▼──┐┌──▼──┐┌──▼──┐           │  video   │ walkers
       │CLINT││PLIC ││UART │           │  timing  │
       └─────┘└──┬──┘└─────┘           └──────────┘
                 │ eip -> CPU
```

Two things this diagram is making a point about:

- **The page-table walkers are a bus master.** They used to read PTEs through
  a second port on `wb_ram`'s block RAM, on the reasoning that page tables
  live in ordinary RAM so putting them on the bus would buy nothing and cost
  arbitration. That reasoning had an expiry date: an SDRAM has one port, and
  Linux puts page tables in DRAM. `wb_ptw.v` arbitrates the two walkers into
  one Wishbone master, and a PTE can now come from any slave the interconnect
  decodes.
- **The framebuffer's scan-out is still off-bus**, on its own block RAM's
  second port. That is why adding video introduced no bus master.

---

## 2. Address map

Decoded on `addr[31:24]` through a per-slave mask. A mask of `0xFF` is one
16 MB window, which is what every slave has except the SDRAM: its mask is
`0xFE`, so it ignores bit 24 and answers to `0x90` and `0x91` alike — 32 MB,
the size of the part on the board.

| Base | Slave | Size used | Wait states |
|---|---|---|---|
| `0x0000_0000` | Boot ROM | 16 KB | 1 |
| `0x0200_0000` | CLINT | 48 KB span | 0 |
| `0x0300_0000` | PLIC | 16 KB span | 0 |
| `0x0400_0000` | UART | 12 B | 0 |
| `0x0500_0000` | GPIO | 20 B | 0 |
| `0x0600_0000` | SPI | 12 B | 0 → many |
| `0x0700_0000` | Framebuffer | 75 KB | 1 |
| `0x8000_0000` | Main RAM (block) | 64 KB (FPGA) / 256 KB (sim) | 1 |
| `0x9000_0000` | External SDRAM | 32 MB (mask `0xFE`) | ~6 on a row hit |

`software/soc/soc.h` is the single source of truth for software and **must be
kept in step by hand** with `soc_top.v`'s `s_base` table, `dts/soc.dts`, and
the linker scripts. Nothing generates or checks this.

An access that decodes to no slave still acks, returning zero. A bus that
never acked would wedge the CPU permanently — its pipeline freezes waiting —
turning a stray pointer into a silent hang instead of something the running
program can survive.

---

## 3. Components

### `wb_rom` — boot ROM, `0x0000_0000`

16 KB (`ROM_WORDS = 4096`), read-only, one wait state. Loaded at elaboration
by `$readmemh` from `bootrom.hex`, which makes that file a **synthesis
input** — the build scripts refuse to start without it, because the failure
mode otherwise is a board that comes up and does nothing.

`RESET_PC` is `0x0000_0000`, so the CPU starts here.

### `wb_sdram` — external SDRAM, `0x9000_0000`

A Wishbone slave in front of a 16-bit SDR SDRAM: 4 banks x 8192 rows x 512
columns, which is 32 MB on a ULX3S. A 32-bit bus word is two SDRAM accesses,
issued as one burst-of-2 command; byte lanes become DQM. The controller keeps
**one** row open, refreshes every 7.8 µs, and takes about six cycles on a row
hit and eight on a miss.

It sits *beside* block RAM rather than replacing it, which was a staging
decision: keeping both memories meant external DRAM landed as an addition that
could not regress anything.

Sv32 page tables can live here. They could not while the walkers read PTEs
through `wb_ram`'s second block RAM port — an SDRAM has no second port — which
is why `wb_ptw.v` exists. `make sim_mmusdram` is the proof: a root page table
at `0x9100_0000`, walked from S-mode for both instruction fetch and data.

The window is the full 32 MB. It was 16 MB while the decode was a bare
equality on `addr[31:24]`; the per-slave mask is what widened it, and
`wb_sdram.v` always took its row from `wb_adr[24:12]` so the controller needed
no change at all.

Verified two ways: `make sim_sdram` drives the controller directly against
`sim/sdram_model.v`, which refuses illegal protocol rather than tolerating it,
and `make sim_sdramboot` runs the whole SoC out of it on a 99 KB program that
could not have been loaded into block RAM at all.

### `wb_ram` — main memory, `0x8000_0000`

64 KB on the FPGA, 256 KB in simulation. Word-organized with byte write
enables, synchronous read, **one wait state** — that is what a block RAM
costs, and the pipeline's `dbus_wait` absorbs it.

Single-ported now. It used to carry the two MMU walkers on port B, which is
what confined page tables to block RAM; they are on the bus instead (see
`wb_ptw` below), and the block RAM's second port is simply unused — which
costs nothing, since block RAMs come with two either way.

### `clint` — timer and software interrupts, `0x0200_0000`

| Offset | Register | Notes |
|---|---|---|
| `0x0000` | `msip` | bit 0 only; writing 1 raises a software interrupt |
| `0x4000` | `mtimecmp` low 32 | |
| `0x4004` | `mtimecmp` high 32 | |
| `0xBFF8` | `mtime` low 32 | free-running, +1 per clock |
| `0xBFFC` | `mtime` high 32 | |

Offsets match a real CLINT so ordinary RISC-V code works unchanged. `mtime`
increments **every clock**, not at a fixed wall-clock rate — there is no
divider. Firmware computing a delay must scale by `CPU_HZ`.

The `time` CSR reads *this* counter rather than a private one, because SBI
timer code reads `time` and programs `mtimecmp` from it; those two have to be
the same clock or every timeout is wrong.

### `plic` — external interrupts, `0x0300_0000`

8 sources, numbered **1..8** — source 0 does not exist, matching the real
PLIC convention. 3-bit priorities.

| Offset | Register | Notes |
|---|---|---|
| `0x0000 + 4*id` | priority for source `id` | 3 bits |
| `0x1000` | pending bitmap | read-only |
| `0x2000` | enable bitmap | bit `id` enables source `id` |
| `0x3000` | threshold | only sources with priority **>** this are delivered |
| `0x3004` | claim / complete | read claims, write completes |

Source assignment in `soc_top.v`:

| Source | Device |
|---|---|
| 1 | UART — **wired but unused**, the UART is polled |
| 2 | GPIO rising edge |
| 3–8 | spare, tied low |

Reading `claim` has a **side effect** — it claims the interrupt and marks it
in service. The bridge below gates the read strobe on the data master, so a
stray *instruction fetch* into PLIC space cannot silently claim an interrupt.

### `uart` — console, `0x0400_0000`

| Offset | Register | Access | Notes |
|---|---|---|---|
| `0x00` | TXDATA | W | writing a byte starts transmission |
| `0x04` | RXDATA | R | last received byte; **reading clears `rx_valid`** |
| `0x08` | STATUS | RO | bit 0 = `tx_busy`, bit 1 = `rx_valid` |

Polled, not interrupt-driven. The bit period is the `CLKS_PER_BIT` module
parameter, derived from `CLK_HZ / BAUD_RATE` in `fpga/soc_fpga.v` — **not a
runtime baud register**. Getting `CLK_HZ` wrong produces a console emitting
garbage while everything else works, which reads as a CPU bug rather than a
configuration one.

RXDATA's read side effect is why the bridge distinguishes the data master
from the fetch master.

### `wb_gpio` — 16 bidirectional pins, `0x0500_0000`

| Offset | Register | Access | Notes |
|---|---|---|---|
| `0x00` | OUT | RW | value driven on pins configured as outputs |
| `0x04` | IN | RO | synchronized pin state |
| `0x08` | DIR | RW | 1 = drive; **resets to all-inputs** |
| `0x0C` | IE | RW | per-pin interrupt enable |
| `0x10` | IP | RW | rising-edge pending, **write 1 to clear** |

Zero wait states. Inputs pass through a 2-flop synchronizer before anything
looks at them — these are genuinely asynchronous pins, and feeding a raw pin
into the edge detector would let metastability set a spurious interrupt.

**`OUT[1:0]` is mirrored onto the board LEDs** by `fpga/soc_fpga.v`, regardless of
`DIR`. That is how the boot ROM reports its progress without a serial cable;
see `BOOT_STAGE_*` in `soc.h`.

**An undriven pin has no defined level.** `fpga/constraints/ulx3s.lpf` sets
`PULLMODE=NONE` on the whole header, so a pin with its `DIR` bit clear and
nothing plugged in reads whatever it happens to float to — not 0, and not
necessarily the same value twice. Firmware that wants a known level with
nothing attached has to drive the pin. A driven pin does read back through
`IN`: the pad's input path is live whether or not the output driver is
enabled, which is what `test_gpio()` in `software/soc/main.c` relies on to
test the pins without any external wiring.

### `wb_spi` — SPI master, `0x0600_0000`

Mode 0 (CPOL=0, CPHA=0), 8 bits, MSB first. Enough to talk to an SD card.

| Offset | Register | Access | Notes |
|---|---|---|---|
| `0x00` | CTRL | RW | bit 0 = assert CS; bits 15:8 = clock divider |
| `0x04` | DATA | RW | write shifts out and in; read returns last byte |
| `0x08` | STATUS | RO | bit 0 = busy |

`SCK = CPU_HZ / (2 * (div + 1))`.

Two things will bite you:

- **A DATA write is a blocking bus access.** The slave withholds `ack` until
  all 8 bits have shifted, so the CPU sits in MEM for the whole transfer —
  no polling loop needed, but the fetch master is starved meanwhile. This is
  the only slave with real multi-cycle wait states, and therefore the only
  thing that exercises `dbus_wait` end to end.
- **`div` must be ≥ 2.** MISO is synchronized through two flops, so a
  shorter half-period samples the *previous* bit. `wb_spi.v` fails the
  simulation outright if firmware programs anything lower.

For SD cards specifically: initialization must run at 100–400 kHz until the
card leaves idle. `SD_INIT_DIV` in `soc.h` targets ~350 kHz;
`sim/sd_card_model.v` rejects anything faster, so this cannot regress.

### `wb_framebuffer` + `video_timing` — display, `0x0700_0000`

320×240, 8 bits per pixel, **RRRGGGBB** direct colour. No palette. Linear, so
`(x,y)` is at `FB_BASE + y*320 + x` and one pixel is a plain `sb`. One wait
state.

Scanned out at 640×480@60 with pixel doubling. Scan-out uses the block RAM's
second port, so this adds **no bus master**.

**Nothing drives a display yet.** Scan-out runs in the CPU's clock domain —
there is no clock-domain crossing in the video path — and the pixel stream
leaves `fpga/soc_fpga.v` unconnected, where synthesis strips it. A real monitor
needs a 25.175 MHz pixel clock from a PLL and a TMDS serializer.

See `soc.h` for `FB_PIXEL(x,y)` and `FB_RGB(r,g,b)`.

### `wb_periph_bridge`

Adapts CLINT, PLIC and UART — which predate the bus and use a flat
address/read/write interface — onto Wishbone unchanged. It also forwards
`s_data_master`, which is what lets the PLIC and UART tell a genuine load
from an instruction fetch that happened to land in their window.

---

## 4. The bus

Wishbone B4 classic. Two masters, eight slaves, shared.

**Arbitration is fixed priority, data over fetch, locked per transfer.** Data
wins because a stalled load blocks the pipeline while a stalled fetch does
not; the lock is what keeps a multi-cycle slave from having the bus pulled
out from under it mid-transfer.

Requests are issued **combinationally** — `cyc`/`stb` come straight off the
core's request signals rather than out of a state register — so a
zero-wait-state slave completes in the cycle it starts. A registered
"go to REQUEST state" FSM would have added a cycle to every access.

`cpu_wb.v` adapts the core's two native ports to two Wishbone masters. It
also holds a **one-entry fetch buffer**: on a hit it stops driving the bus
entirely, which keeps the fetch master from re-requesting the same word every
cycle while the pipeline is held up. That buffer is not coherent with writes
— RISC-V requires `FENCE.I` before executing freshly-written code, and
`fence_i` invalidates it.

Endianness note: the core's native convention puts sub-word data in the low
lanes with the exact byte address; Wishbone wants a word-aligned address plus
`sel` lanes. `cpu_wb.v` shifts on the way out and back on the way in, which
assumes naturally-aligned accesses. This core traps misaligned accesses
anyway, so that holds — but it is an assumption.

---

## 5. Boot flow

1. CPU resets to `0x0000_0000`, in the boot ROM.
2. `bootrom.c` brings up the UART and prints a banner.
3. SPI/SD init at ~350 kHz: CMD0, CMD8, ACMD41, CMD58. Then full speed.
4. Read block 0, check the `SOC1` magic, take the image length.
5. Copy the image to `0x8000_1000` and jump to it.

Progress is published on `GPIO_OUT[1:0]` → `led[1:0]` at each step, so a hang
says which step did not finish even with no serial attached. Every failure
path prints a reason and stops.

`sim/tb_soc.v` runs the whole chain against `sim/sd_card_model.v` with
**nothing preloaded into RAM**, so a passing run is real evidence the entire
boot path works.

There is a second entry to step 5 that skips 3 and 4 entirely: if the first
word at `0x8000_1000` is already a plausible instruction (not `0` and not
`0xFFFF_FFFF`), the ROM announces it and jumps straight there. That is how
the preloading bitstreams boot — `PRELOAD_RAM` in `fpga/soc_fpga.v` hands
`wb_ram` an init file — and it is what makes the SoC testable on silicon
while the card path is still unproven. `sim/tb_ramboot.v` covers that path,
at the 64 KB the board actually has rather than `tb_soc.v`'s 256 KB.

### A program here can run more than once over the same memory

Block RAM is initialised when the FPGA is **configured**, not when the CPU is
reset. So pressing reset — or anything else that restarts the hart — re-enters
`_start` with RAM exactly as the previous run left it. On the SD path the
loader copies the whole image again and the question does not arise; on a
preloaded bitstream it very much does.

`software/soc/crt0_ram.S` therefore rebuilds *both* halves of its writable
state on every startup: `.bss` zeroed, and `.data` copied from a pristine load
image that `link_ram.ld` keeps at a separate address. Anything you add that
needs an initial value must go through the same path — a static that is
written once and assumed to survive is a bug that will only appear on the
second run.

This is not hypothetical. `.data` was not copied until it was found the hard
way: newlib's `__sinit` skips initialisation when its `__cleanup` guard is set
and *sets* that guard itself, so from run 2 onward `stdout` was never usable
and every `printf` returned −1 silently. `make sim_rerun` is the regression
test; `fpga/README.md` has the full account.

### Traps in the RAM program

`software/soc/crt0_ram.S` installs a handler that **halts on any trap nobody
asked for**, printing `mcause` (named, not just numbered), `mepc`, `mtval`,
`ra` and `sp`, and then alternating `led[1:0]` — a pattern no boot stage
produces. Code that wants a trap calls `trap_arm(n)` first; only an armed
trap is resumed, and it is resumed at `mepc + 4`, which is correct only
because the traps anyone arms here come from 4-byte instructions that must not
be retried.

This replaced a handler that resumed from everything, which made an illegal
instruction or a stray misaligned access indistinguishable from a passing
test. `make trapcheck` provokes four faults whose reports are known in advance
and checks the text that comes out, because a diagnostic that silently does
nothing is worse than none. The fourth is a trap raised while the reporter is
already running: that path deliberately emits a single `!` straight at the
UART and stops, because anything more could fault a third time.

---

## 6. Adding a peripheral

1. Write it as a Wishbone B4 classic slave. Ack combinationally if you can;
   if you need wait states, hold `ack` low and the CPU will wait.
2. In `soc_top.v`: bump `NUM_SLAVES`, add an `S_*` index, and add entries to
   **both** the `s_base` and `s_mask` concatenations **in the right
   position** — slave `i` occupies bits `[8*i +: 8]` of each, and the
   concatenations list the highest index first. A mask of `0xFF` gives the
   usual 16 MB window; narrower masks give more, in powers of two, and must
   not overlap another slave.
3. Instantiate it, wiring `s_stb[S_YOURS]` and `s_dat_r[32*S_YOURS +: 32]`.
4. Add it to `software/soc/soc.h`, `dts/soc.dts`, and the `SOC_RTL` list in
   the `Makefile` and `fpga/synth/synth_ecp5.sh`. Note that the decode is on
   `addr[31:24]`, so your slave answers to at least a whole 16 MB window and
   anything past the end of what it implements aliases back rather than
   faulting.
5. If it has a read side effect, gate the read strobe on `s_data_master`.
6. Add a case to `software/soc/main.c`'s acceptance test.

Step 4 is the one that bites — five places, none of which check each other.

---

## 7. What is not here

- **No DMA.** The three bus masters are instruction fetch, data, and the
  page-table walkers; nothing else moves data on its own.
- **Caches are in the bus adapter, not here.** `cpu_wb.v` carries a
  direct-mapped I-cache and D-cache, one word per line. SDRAM is deliberately
  *not* cacheable, so every access to it reaches the chip.
- **The walkers do not go through either cache.** A PTE read is a plain bus
  transaction, which is what makes `SFENCE.VMA` sufficient — there is no
  cached copy of a PTE for it to have to invalidate.
- **No PMP**, no debug module, no JTAG. See `docs/debug.md`.
- **The UART interrupt is wired to the PLIC but unused** — the driver polls.

`architecture.md` section 13 covers what these mean for running larger
software, and `README.md` covers what they mean for Linux specifically.
