# CoreMark on this core

```
make coremark-fetch     # once: clone CoreMark at a pinned commit
make coremark
```

## Result

CoreMark builds, runs on the SoC in simulation, and **validates its own
results** — it recomputes CRCs over every one of its workloads and states
whether they match:

```
2K performance run parameters for coremark.
CoreMark Size    : 666
Total ticks      : 724750
Iterations       : 1
Compiler version : GCC15.1.0
Compiler flags   : -O2 -march=rv32im
Memory location  : STACK
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0xe714
Correct operation validated. See README.md for run and reporting rules.
```

That validation is the point. CoreMark is a much harder workload than
anything else this project runs — linked lists, matrix arithmetic, a state
machine, CRCs, all compiled at `-O2` — and it checks its own arithmetic. A
core that got a multiply, a shift, a signed comparison or a memory access
subtly wrong would fail the CRCs rather than quietly producing a number.

**724,750 cycles per iteration.**

That is 1.97x the 368,008 cycles this took before the memories became
synchronous block RAMs, and the regression is real, expected, and worth
stating plainly: with no caches, every instruction fetch and every load or
store now costs two cycles instead of one. The old number came from a memory
that could not be synthesized at all (see `fpga/README.md`), so the honest
comparison is not "it got slower" but "this is what the workload costs on
hardware that can exist".

The fix is a cache, or a fetch that presents its address a cycle early so the
block RAM's latency is hidden by the pipeline rather than exposed as a stall.
Neither exists yet; both are the obvious next performance work.

## What that number is, and is not

Working it through: at any clock rate *f*, one iteration takes 724,750 / *f*
seconds, so iterations/sec is *f* / 724,750 and

> **~1.4 CoreMark/MHz**

That is a believable figure for a 5-stage in-order RV32IM with **no caches
and a one-wait-state memory** - every fetch stalls a cycle. For reference,
the same core against the old zero-wait memory scored ~2.7, and cached
designs like VexRiscv and Rocket land in the 2-3 range. The gap between 1.4
and 2.7 is precisely the cost of having no instruction cache, and it is the
clearest argument for adding one.

**It is not a submittable CoreMark score.** EEMBC's reporting rules require a
run of at least 10 seconds, and this is 7 ms of simulated time at 100 MHz.
Reporting it as a score would be a rules violation regardless of whether the
number is right. Two further caveats:

- It is a **simulated** figure. The memory model is now realistic (a
  synchronous block RAM with one wait state, which is what the design
  actually synthesizes to), but the achievable clock is still unknown - the
  design fits an LFE5U-45F but has never been placed, routed or timed. See
  `fpga/README.md`.
- Compiler flags are `-O2 -march=rv32im`, not the aggressive per-benchmark
  flag sets vendors typically report with.

The honest use of this number is as a **regression baseline**: it is
directly comparable between two versions of this RTL, and that is what it is
here for.

## Runtime

One iteration is about 100 seconds of wall clock under Icarus (~868k
simulated cycles at roughly 9k cycles/sec). Verilator would be substantially faster, but its
harness here is wired to the flat `rtl/top.v` rather than the SoC, so the
Icarus path is what this uses.

## How the port works

Only the port layer lives in this repo; CoreMark's five source files are used
unmodified, fetched at a pinned commit by `fetch-coremark.sh`.

- **Timer**: the hart's own `cycle` CSR. Not a wall clock — there isn't one
  in simulation, and inventing seconds by dividing by an assumed clock
  frequency would turn a hard number into a guess. `time_in_secs()` returns
  ticks unchanged, so read every "secs" field in the output above as
  "cycles".
- **Output**: `printf` from newlib-nano, through `software/syscalls.c`'s
  `_write`, out `rtl/uart.v`'s TX pin, decoded back into characters by
  `sim/tb_bench.v`. The console text is the real serial byte stream.
- **`HAS_FLOAT 0`**: CoreMark's reporting prints iterations/sec and elapsed
  seconds as floats, and newlib-nano omits float formatting unless linked
  with `-u _printf_float`, which pulls in a large chunk of libc for two
  cosmetic numbers. The benchmark itself is fixed-point throughout, so its
  results are unaffected.
- **`MEM_METHOD_STACK`**: keeps the benchmark's working set off the heap, so
  a bug in `syscalls.c`'s bump allocator could never be mistaken for a CPU
  bug.
- **Loaded straight into RAM** by the testbench rather than off the simulated
  SD card. Shifting the ~22 KB image through the bit-banged SPI path costs
  around a million cycles before the first benchmark instruction runs, which
  would swamp the measurement. The boot path is still covered by
  `make sim_soc`. The image is one 32-bit word per line, matching
  `wb_ram.v`'s word-organized array.

`sim/tb_bench.v` ends the run on CoreMark's own verdict string rather than a
cycle budget, so the pass/fail is the benchmark's conclusion and not a second
opinion invented in the testbench.
