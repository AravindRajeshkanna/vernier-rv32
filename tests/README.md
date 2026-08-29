# Verification

Four layers, each answering a question the one before it cannot.

| Layer | Question it answers | Run it with |
|---|---|---|
| Directed tests (`sim/tb_top.v`, `sim/tb_soc.v`) | Does the feature I just wrote work? | `make sim`, `make sim_soc` |
| Architectural tests (riscv-tests + `tests/vernier/`) | Does this core implement *RISC-V*, as judged by somebody else's suite? | `make isa` |
| Co-simulation vs Spike | Did it execute the *same instructions* as the reference model, with the same results? | `make cosim` |
| Formal (yosys + z3) | Does this module hold for *every* input, not just the ones a test tried? | `make formal` |

`make verify` runs all of them.

Neither of the upstream suites is vendored. Both are somebody else's project
with their own license, and the whole value of running them is that this
project did not write them - so they are fetched at a pinned commit
(`make isa-fetch`, `make coremark-fetch`) and a regression can never be
explained away by "upstream changed".

That independence is also their limit. riscv-tests asks whether an RV32IMA
core is an RV32IMA core and is deliberately indifferent to the
microarchitecture underneath, so it has no reason to exercise anything
specific to *this* implementation. `tests/vernier/` is where those go. It
builds into the same manifest, runs under the same harness and co-simulates
the same way - the only difference is what it is aimed at.

---

## Architectural tests (riscv-tests)

79 of 82 upstream tests pass, plus the two in `tests/vernier/` — 81 of 84 in
the run below. The three that do not are listed in
`expected-failures.txt` with reasons; `run.sh` reports them as XFAIL and
fails the run if one of them starts *passing*, so that list cannot quietly go
stale.

```
riscv-tests: 81 passed, 0 failed, 3 xfail, 0 xpass, 0 skipped
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
$ tests/cosim.py --all --core=ooo
co-simulation vs Spike: 84/84 traces pass
dual issue exercised:   0 of 59,197 retirements (0.0%) in slot 1
```

The second line only ever prints under `--core=ooo` - it reads as a
regression and is not one; see "Which issue slot, and why the number is
printed" below for why 0 is now the permanent, correct value there. "84/84
traces pass" counts an accepted, registered divergence as a pass, same as it
always has for `rv32mi-p-breakpoint` - and one of the 84 here is exactly
that: `rv32si-p-dirty`, which diverges from Spike only on the wide core
(`tests/cosim.py`'s `EXPECTED_DIVERGENCE_CORES`). Plain `tests/cosim.py
--all` (`CORE=inorder`, what `make cosim` runs by default) is also
**84/84**, but for a different reason - `rv32si-p-dirty` genuinely matches
there, not registered - and has no second line, since the in-order core has
no slot 1 to
report on.

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

**What the four fields cannot contain.** A store writes no register, so `rd`
and `value` are empty for one and the comparison reduces to "a store retired
at this PC". Where it went and what it wrote are not checked here, or by
riscv-tests, or by `+checkdecode`, or by `+checkmmu` — see
[practices.md §43](../docs/practices.md). `+writetrace` in
`sim/verilator_soc.cpp` is the only probe that sees a store's address.

Three classes of value are exempt from comparison, each for a stated reason:
the cycle/instret counters (microarchitectural, not architectural), the
machine identity CSRs (Spike reports `marchid` 5, this core reports 0, and
the spec says 0 means "not implemented"), and one whole trace,
`rv32mi-p-breakpoint`, listed in `EXPECTED_DIVERGENCE` because Spike
implements debug triggers and this core does not.

### Which issue slot, and why the number is printed

**This section is history, not current behavior.** It describes stage
1b/1c's fixed slot-0/slot-1 dual dispatch. Stage 1d replaced that design
with register renaming and an age-ordered ROB (`docs/roadmap.md`'s "Stage 1d
was built anyway"): the core now dispatches and retires one instruction
wide, "slot 1" is not a concept it has, and `vernier-p-pairing` retires 0
in slot 1 unconditionally — see `tests/dual-issue-floor.txt`'s "stage 1d:
floor retired" note. The incident below is why the floor mechanism existed
at all, and is left in place for that reason; it is not a live check
anymore. Its replacement is `ooo_alu_reorder_count`/`ooo_load_reorder_count`
(`sim/tb_bench.v`, `sim/tb_top.v`): not just that an instruction issued, but
that it issued *out of program order* — the stronger claim, and one that
does not depend on any particular dispatch width.

Under stage 1b/1c's `CORE=ooo`, the summary reported how many retirements
came out of the second issue slot. It was there because the suite was green
and the number was **63 out of 28,262 — 0.22%**, with 70 of the 82 traces
retiring none at all.

Dual issue was, at the time, the only thing that made `rtl/ooo/core_ooo.v` a
different core from `rtl/cpu_core.v`. Corrupting every slot-1 result
(`ex_mem1_wb_data <= s1_result ^ 1`) left **73 of the 82 upstream tests
still passing**; the nine that failed were the five loads and four divides,
which failed incidentally because a stall happened to leave two instructions
in the fetch buffer. Nothing in the corpus was aimed at the second slot, and
nothing should have been — see [practices.md §40](../docs/practices.md).

`tests/vernier/pairing.S` was the workload built to be. Each iteration opened
with a divide, whose 33 cycles in EX filled the 4-deep fetch buffer, and the
run of independent ALU ops behind it drained that buffer two at a time:
**6,143 slot-1 retirements, 97× the entire upstream corpus**, matching Spike
exactly.

`tests/dual-issue-floor.txt` held a floor under it, and that was not
belt-and-braces. Set `issue_pair = 1'b0` and `pairing.S` **still reached its
own pass condition and still matched Spike instruction for instruction** —
single-issuing it was a correct execution — so without the floor it would
have reported PASS/MATCH forever while testing nothing.

The floor was checked in two places on purpose, reading one number from one
file. `cosim.py` needs Spike and is a local gate; `run.sh` is what CI's
`riscv-tests (ooo)` job runs. With it only in `cosim.py`, a change that stops
forming pairs would have passed every other job in CI. With the fault
injected, back when the floor was 4,000:

```
  vernier-p-pairing            UNDER-ISSUED (passed, but retired 0 in slot 1; needs 4000)
riscv-tests: 79 passed, 1 failed, 3 xfail, 0 xpass, 0 skipped
```

Both messages say the test *passed*, so a reader does not go hunting for a
wrong value that is not there. `tests/dual-issue-floor.txt` still holds a
floor for `vernier-p-pairing` — it is `0` now, by design, per the "stage 1d:
floor retired" note there, so this exact failure mode cannot be demonstrated
against current `main`. It stays here as the record of why the check exists
and how it reads when it fires.

### What this found

- **`misa` missing the S and U bits** — invisible to the ISA tests, caught
  immediately by diffing the value a `csrr a0, misa` actually returned.
- **A bug in the tracer itself.** `ex_mem_retire` was not cleared when EX/MEM
  bubbles, so an instruction stalled on a divide or a page walk was reported
  as retiring once per stalled cycle. That is exactly the class of thing an
  end-of-test pass/fail check cannot see.
- `mcountinhibit` and vectored `mtvec`, both as control-flow divergences.
- **How little of the wide core it was covering**, above. Not a defect in the
  RTL, and the most useful thing co-simulation has reported.

---

## Formal

`formal/run.sh`. Bounded model checking with yosys → SMT2 → `yosys-smtbmc` →
z3. SymbiYosys (`sby`) is the usual driver and is not packaged for Homebrew,
so the two steps it would wrap are done directly.

```
formal: 5 proved, 0 refuted, 0 errored (bound = 12 cycles)
```

| Module | Properties |
|---|---|
| `plic` | `eip` is exactly "something is claimable"; a claim names an eligible source, and the *highest-priority* one; claim reads 0 when nothing is claimable; an in-service source is never handed out again |
| `btb` | No prediction without a tag match (the aliasing property); a predicted-taken entry is really in a taken counter state; training touches only the entry it indexes |
| `regfile` | x0 always reads zero, including when a write to x0 is in flight; the write-to-read bypass is correct on both ports; the write path never touches x0's storage |
| `regfile_wide` | x0 reads zero on all four ports; the bypass returns the written value from either write port; two ports reading one register agree; and port 1 (the younger instruction) wins when a dual-issue pair writes the same register |
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

## External memory

`make sim_sdram` and `make sim_sdramboot` are two layers rather than one, in
the order they fail.

`sim_sdram` drives `rtl/soc/wb_sdram.v` directly from a testbench against
`sim/sdram_model.v`. No CPU, no toolchain, no program — Wishbone transactions
in, data out, and a failure names the word, the address and the value. It runs
in CI's `rtl` job for that reason: it is the fastest thing here that can catch
a memory-controller bug.

`sim_sdramboot` runs the whole SoC out of SDRAM on a 99 KB program. That is
the layer that answers "does it actually work", and it is also the slow one at
2.2 M cycles.

The model is where most of the checking lives, and it is worth knowing that
when reading either test's output: it refuses illegal protocol — tRCD, tRP,
tRC, tRFC, the 100 µs power-up interval, the refresh interval, row ownership,
burst containment, and CAS latency taken from the mode register the controller
actually programmed. So `SDRAM TEST PASSED` asserts a great deal that the log
never mentions. `docs/practices.md` §22 is about why that model was written
from the datasheet rather than from the controller, and what was done to prove
it can still say no.

## The layer none of this is: a board

Every layer above answers a question the one before it cannot, and the honest
end of that list is that **the last one is silicon**, and it found something.

`rtl/soc/wb_sdram.v` passed its unit test against a model that refuses illegal
protocol, passed a 99 KB program executing out of SDRAM, passed the probe,
passed CI on both cores — and then failed on a board at one word in a
thousand. The capture edge sat 5.4 ns before the part swapped one burst beat
for the next, and writes had no hold margin at all because the clock and the
data left the FPGA together.

**No simulation here could have caught that**, and it is worth being precise
about why rather than filing it as bad luck. A behavioural model has ideal
edges: a signal is either sampled in time or it is not, so a margin of 5.4 ns
and a margin of 25 ns both simply pass. Marginality is a property of real
silicon at a real temperature, and the only instrument that reports it is a
board. `docs/practices.md` §23 is what reading that evidence properly took —
the *rate* carried the diagnosis, and a test that stopped at the first
mismatch had been throwing it away.

The lesson for this file is not "add another layer". It is that
`make verify` being green is a statement about self-consistency, and the two
bring-up bitstreams in `fpga/README.md` exist because that is not the same as
working.

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

There was a second, quieter way to report the in-order core's result under the
other core's name, and it went unnoticed for two stages: `rtl/top.v`
instantiated `cpu_core` with no `CORE_OOO` selection at all, so `make sim
CORE=ooo` compiled the wide core into the image, instantiated the in-order one,
and passed. The other targets all reach the CPU through `rtl/soc/soc_top.v`,
which did select correctly, so the suite as a whole was never testing the wrong
core — but that one testbench was, and its `TEST PASSED` meant nothing about
the core it named. Fixed in stage 1b.

The lesson is narrower than "check the knob": the knob *was* checked, by
breaking `core_ooo.v` on purpose and confirming `CORE=ooo` went red while
`CORE=inorder` stayed green. That check proves a selector selects somewhere. It
does not prove it selects everywhere, and a suite with more than one top level
needs the question asked once per top level.

Re-running that check after the fix is worth recording for a second reason.
The first attempt broke `OR` in the ALU, and `make sim CORE=ooo` passed — not
because the selector was still broken, but because `sim/program.hex` never
executes an `OR`. Breaking `ADD` instead fails it immediately (`mem[0]` reads
18 where 15 is expected). A deliberate-breakage check is only evidence if the
thing broken is on a path the test actually walks, which is §1 applied to §1.
