# Verification

Four layers, each answering a question the one before it cannot.

| Layer | Question it answers | Run it with |
|---|---|---|
| Directed tests (`sim/tb_top.v`, `sim/tb_soc.v`) | Does the feature I just wrote work? | `make sim`, `make sim_soc` |
| Architectural tests (riscv-tests) | Does this core implement *RISC-V*, as judged by somebody else's suite? | `make isa` |
| Co-simulation vs Spike | Did it execute the *same instructions* as the reference model, with the same results? | `make cosim` |
| Formal (yosys + z3) | Does this module hold for *every* input, not just the ones a test tried? | `make formal` |

`make verify` runs all of them.

Neither of the upstream suites is vendored. Both are somebody else's project
with their own license, and the whole value of running them is that this
project did not write them - so they are fetched at a pinned commit
(`make isa-fetch`, `make coremark-fetch`) and a regression can never be
explained away by "upstream changed".

---

## Architectural tests (riscv-tests)

79 of 82 pass. The three that do not are listed in
`expected-failures.txt` with reasons; `run.sh` reports them as XFAIL and
fails the run if one of them starts *passing*, so that list cannot quietly go
stale.

```
riscv-tests: 79 passed, 0 failed, 3 xfail, 0 xpass, 0 skipped
```

Suites run: `rv32ui` (base integer), `rv32um` (M), `rv32ua` (A), `rv32mi`
(machine-mode CSRs and traps), `rv32si` (supervisor). Compressed, float and
bitmanip suites are skipped because the core does not implement those
extensions - running them would only prove that a missing extension is
missing.

The tests run on the **real SoC** (`rtl/soc/soc_top.v`), not a stripped
harness: same core, same Wishbone interconnect, same wait states. The single
concession is `RESET_PC`, because riscv-tests link at `0x8000_0000` and
expect to start there.

### What this found

It was not a formality. The first run was 73/82, and every one of the
failures was a real gap:

| Fixed | What was wrong |
|---|---|
| `WFI` | Trapped as an illegal instruction. The spec permits implementing it as a NOP; trapping it is not permitted, and firmware executes it unconditionally. |
| `mvendorid`/`marchid`/`mimpid` | Did not exist, so a boot-time `csrr` trapped in the middle of startup. |
| `misa` | Reported neither S nor U, despite this core having both with full trap delegation - exactly what firmware checks before handing off to an S-mode payload. |
| `misa` writes | Trapped. `misa` is WARL: an unsupported write is *ignored*, not refused, and feature-probing code writes a bit and reads it back. |
| Misaligned instruction fetch | No cause-0 trap at all. A taken branch to a non-4-byte-aligned target just fetched from it. |
| `medeleg` mask | Causes 0/4/6 were raiseable but not delegatable, so an S-mode kernel asking for its own misaligned-access handler silently never got one. |
| `minstret` | Counted trapping instructions (which by definition do not retire), and incremented a pipeline stage later than a CSR write to it could observe. |
| `mcycle`/`minstret` | **Driven from two `always` blocks at once** - undefined in simulation, rejected by synthesis. |
| `mstatus.SUM`/`MXR` | Did not exist. |
| `mstatus.TVM`/`TW`/`TSR` | Did not exist, so M-mode firmware could not intercept a supervisor's `SFENCE.VMA`, `satp` access, `WFI` or `SRET`. |
| **MMU `U` bit** | **Never checked.** U-mode could read and execute supervisor pages and vice versa - the entire user/supervisor isolation boundary was absent. |
| AMO page-fault permission | An AMO was permission-checked as a *load*, so it could write a read-only page. |
| `mcountinhibit` | Did not exist. |
| Vectored trap mode | `mtvec.MODE` was flattened to Direct, silently ignoring a request for vectored interrupt entry. |

The MMU `U` bit is the one that matters most. It also broke the legacy
hand-assembled test in `sim/tb_top.v`, which had been relying on the missing
check: its page table maps everything as one supervisor superpage (`U=0`) and
it then drops to U-mode and keeps executing. That is architecturally
impossible with the check in place. See the Part 13 note in `sim/tb_top.v`
for what that test now does and does not demonstrate.

---

## Co-simulation against Spike

`tests/cosim.py`. Runs each ISA test on both the RTL and Spike, reduces both
to the same four fields per retired instruction - `(pc, instruction,
destination register, written value)` - and diffs them. Neither side's
disassembly is parsed or trusted.

```
co-simulation vs Spike: 82/82 traces match
```

This asks a strictly harder question than the tests do. A test says "the
program reached its own pass condition"; a core can get there through a wrong
sequence, and a test only catches what it thought to assert. Co-simulation
says "every instruction, in order, wrote what the reference model wrote".

Spike is configured to match the implementation, which is the point of the
exercise rather than a way of dodging it:

- `--pmpregions=0` — this core has no PMP. Without it the two part company
  the moment riscv-tests' setup writes `pmpaddr0`.
- `--isa=rv32ima_zicsr_zifencei_zicntr` — Spike's default also includes
  `zihpm` (hpmcounter3-31), which this core does not implement.

Three classes of value are exempt from comparison, each for a stated reason:
the cycle/instret counters (microarchitectural, not architectural), the
machine identity CSRs (Spike reports `marchid` 5, this core reports 0, and
the spec says 0 means "not implemented"), and one whole trace,
`rv32mi-p-breakpoint`, listed in `EXPECTED_DIVERGENCE` because Spike
implements debug triggers and this core does not.

### What this found

- **`misa` missing the S and U bits** — invisible to the ISA tests, caught
  immediately by diffing the value a `csrr a0, misa` actually returned.
- **A bug in the tracer itself.** `ex_mem_retire` was not cleared when EX/MEM
  bubbles, so an instruction stalled on a divide or a page walk was reported
  as retiring once per stalled cycle. That is exactly the class of thing an
  end-of-test pass/fail check cannot see.
- `mcountinhibit` and vectored `mtvec`, both as control-flow divergences.

---

## Formal

`formal/run.sh`. Bounded model checking with yosys → SMT2 → `yosys-smtbmc` →
z3. SymbiYosys (`sby`) is the usual driver and is not packaged for Homebrew,
so the two steps it would wrap are done directly.

```
formal: 4 proved, 0 refuted, 0 errored (bound = 12 cycles)
```

| Module | Properties |
|---|---|
| `plic` | `eip` is exactly "something is claimable"; a claim names an eligible source, and the *highest-priority* one; claim reads 0 when nothing is claimable; an in-service source is never handed out again |
| `btb` | No prediction without a tag match (the aliasing property); a predicted-taken entry is really in a taken counter state; training touches only the entry it indexes |
| `regfile` | x0 always reads zero, including when a write to x0 is in flight; the write-to-read bypass is correct on both ports; the write path never touches x0's storage |
| `wb_interconnect` | At most one slave strobed; the strobed slave matches the decode; exactly one master granted, data over fetch; acks go only to the requesting master; an unmapped access still acks; a fetch never writes |

The PLIC is the best target here and the reason this layer exists. Its job is
priority arbitration over 8 priorities, 8 enables, 8 pending bits and a
threshold - roughly 2^30 configurations, which simulation cannot cover and a
solver can. This module already shipped a bug of exactly that shape (the
claim encoder overwrote its answer on every eligible source instead of
comparing priorities, degenerating into "lowest eligible ID wins"). A
directed test happened to catch it; the properties now make it
uncatchable-by-accident.

**What is and is not established.** BMC proves the properties for every input
sequence up to 12 cycles from reset. That is a proof over all *inputs* -
which is what simulation cannot do - but not over all *time*. Unbounded proof
would need k-induction. For the interconnect (combinational) the distinction
does not arise; for the PLIC and BTB it genuinely does, and the bounded claim
is the honest one.

### The flow self-test

`formal/run.sh` first checks `formal/fv_selftest.v`, a property that **must
fail**, and refuses to run anything else unless the solver reports FAILED.

This is not ceremony. The first version of this flow reported every property
as passing because yosys was silently discarding the assertions - they need
`read_verilog -sv`, and newer yosys emits `$check` cells that must be lowered
with `async2sync; dffunmap; chformal -lower` before `write_smt2` will emit
them. A formal setup that proves nothing looks exactly like one that proves
everything. A green board only means something if the board can go red.

---

## Where the properties live

Two shapes, for a reason rather than by accident:

- `formal/fv_*.v` wrappers, where the properties only need the module's
  ports. Keeps the RTL clean.
- `` `ifdef FORMAL `` blocks inside `rtl/plic.v` and `rtl/btb.v`, where they
  need the module's internal *arrays*. Yosys cannot follow a hierarchical
  reference into a submodule's array with a variable index, so a wrapper
  cannot express them at all.

Both are compiled only under `-DFORMAL`; simulation and synthesis never see
them.

---

## Running these in CI

`.github/workflows/ci.yml` runs the architectural suite and formal on every
push, alongside the RTL regression and both SoC boot paths.

**Spike co-simulation is deliberately not in CI.** It needs Spike built from
source, which would dominate the run time, and it is the layer least likely to
regress silently — a divergence shows up as a specific instruction mismatch
rather than as a slow drift. It stays a local gate; `CONTRIBUTING.md` asks for
its output in a pull request.

FPGA place-and-route is not in CI either: it is 4–11 minutes on an ECP5, the
placement is stochastic (see `docs/toolchain.md` §6), and the numbers in
`fpga/README.md` are recorded by hand from real runs so that a single noisy
placement cannot quietly move a published figure.

---

## Two cores, the same suites

`make verify` runs everything against `rtl/cpu_core.v`, the in-order design
that has run on hardware. `make verify_ooo` runs the identical suites against
`rtl/ooo/core_ooo.v`, the wide core being built for Phase 1 of
`docs/roadmap.md`.

Both must be green. The point of running one suite against two cores is that a
regression in either cannot hide behind the other, and co-simulation is what
makes that strict: an out-of-order machine still retires in order, so
"every retired instruction matches Spike" stays exactly the right question to
ask of it.

`verify_ooo` deletes the simulation binaries before and after it runs. They do
not encode which core they were built with, and running a stale one would
report the in-order core's result under the other core's name.
