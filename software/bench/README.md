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
Total ticks      : 368079
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

**368,008 cycles per iteration**, measured over a 4-iteration run
(1,472,032 total). A single-iteration run reports 368,079, so fixed overhead
is not distorting it and the per-iteration figure is stable to about 0.02%.

## What that number is, and is not

Working it through: at any clock rate *f*, one iteration takes 368,008 / *f*
seconds, so iterations/sec is *f* / 368,008 and

> **≈ 2.7 CoreMark/MHz**

That is in the expected band for a 5-stage in-order RV32IM with single-cycle
memory and no caches — comparable to VexRiscv and Rocket, below a Cortex-M4's
~3.4. It is a plausible number rather than a suspicious one, which is worth
saying because a benchmark result that comes out *too* good usually means the
harness is measuring the wrong thing.

**It is not a submittable CoreMark score.** EEMBC's reporting rules require a
run of at least 10 seconds, and this is 3.7 ms of simulated time. Reporting
it as a score would be a rules violation regardless of whether the number is
right. Two further caveats:

- It is a **simulated** figure. Real silicon adds memory latency this SoC's
  zero-wait-state RAM does not model, and the achievable clock is unknown —
  this design does not currently fit the FPGA target at all (`fpga/README.md`).
  Cycles/iteration is a property of the microarchitecture; CoreMark/MHz on
  hardware would be lower once real memory is in the loop.
- Compiler flags are `-O2 -march=rv32im`, not the aggressive
  per-benchmark flag sets vendors typically report with.

The honest use of this number is as a **regression baseline**: it is
directly comparable between two versions of this RTL, and that is what it is
here for.

## Runtime

One iteration is about 50 seconds of wall clock under Icarus (~460k
simulated cycles at roughly 9k cycles/sec). `COREMARK_ITERS=4 make coremark`
takes about three minutes. Verilator would be substantially faster, but its
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
  `make sim_soc`.

`sim/tb_bench.v` ends the run on CoreMark's own verdict string rather than a
cycle budget, so the pass/fail is the benchmark's conclusion and not a second
opinion invented in the testbench.
