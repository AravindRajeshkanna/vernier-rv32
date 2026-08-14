# Practices

The working rules this project runs on. Every one of them is here because
breaking it cost real time on this repository — the examples are not
illustrations invented for a style guide, they are incidents, and each links
to the code or document that records it.

Hardware amplifies bad verification habits in a way software does not. A
failing program prints a stack trace; a failing bitstream sits there with the
heartbeat blinking. The rules below are mostly about making the machine tell
you what happened instead of leaving you to guess.

---

## 1. A test must be able to fail

The first question about any new test is not "does it pass" but "what would
make it fail, and have I seen it do that".

**The incident.** The SoC's GPIO test drove the low 8 pins and checked them on
the high 8. It passed for months. It was measuring `sim/tb_soc.v`, which fed
`gpio_out` straight back into `gpio_in` — on a real board `gpio[15:8]` is a
row of header pins with `PULLMODE=NONE` and nothing plugged into them. The
test never touched a pad. It failed the first time it met hardware.

What replaced it drives every pin with two complementary patterns (`0x5A5A`
then `0xA5A5`) and requires each to read back. A pin that is not really being
driven settles at *some* level, and no single level matches both. The
testbench now models a pad instead of a wire: undriven pins read `X`, not `0`,
so anything depending on one fails in simulation rather than on a bench.

**The rule.** Prefer a test whose passing requires the hardware to have done
something specific over one that merely observes a value it expected. If a
test cannot fail without the testbench changing, it is testing the testbench.

## 2. Prove the instrument before you trust it

A diagnostic that silently does nothing is worse than no diagnostic, because
the next person to run it and see nothing concludes there is nothing to see.

**The incidents.** `fpga/ulx3s_cmd0.v` is an SD probe that goes on a board to
answer "does the card reply to CMD0". Before it was trusted, `make sim_cmd0`
proved it against the card model: `0xFF` with no card, `0x01` when one is
inserted mid-run, `0xFF` again when removed. Otherwise a bug in the probe
would have sent someone hunting for hardware faults that were not there.

Same discipline for the trap handler. It halts and prints on any trap nobody
armed — so `make trapcheck` provokes four faults whose reports are known in
advance and scores the text that comes out, including the double-fault path,
which is the code that runs when everything else has already failed and would
otherwise never have been executed at all.

**The rule.** Every diagnostic gets its own test, and that test asserts on the
output, not just on the exit status. Run it before you believe a quiet result
from it.

## 3. Diagnostics lie too

The instrument deserves the same scepticism as the thing it measures.

**The incident.** While diagnosing the `printf` failure (§7), the probe
reported two things confidently and wrongly. It decoded newlib's `_flags` by
testing the two buffering bits and falling through to "fully buffered" — so
`0x40`, whose only set bit is `__SERR`, was labelled as a buffering mode, and
the actual finding (no `__SWR`, the FILE was never set up for writing) was
hidden behind a plausible-sounding label. Then it sampled `__cleanup` *after*
stdio had been used; `__sinit` *sets* `__cleanup` on success, so a perfectly
healthy system also reads non-NULL there. On its own, that reading would have
"confirmed" the hypothesis regardless of whether it was true.

Both were caught by keeping a simulation baseline to compare against, and the
second was caught before it ever reached hardware.

**The rule.** Decode flags one bit at a time and name them; do not collapse a
bitfield into a mode. Sample a guard variable before the thing it guards
runs, not after. And keep a known-good baseline for every diagnostic, so
"this looks wrong" can be distinguished from "this always looks like that".

## 4. Simulate the configuration that actually ships

A simulation that models a machine nobody has proves things about a machine
nobody has.

**The incident.** `make sim_soc` gave the SoC 256 KB of RAM and booted it off
the SD card model. The bitstream that runs on the board does neither: 64 KB,
because 256 KB costs 244 ECP5 block RAMs and fits no ECP5 there is, and the
program preloaded into the bitstream because the card path was unproven. Two
load-bearing differences, and nothing simulated either — so `wb_interconnect`
decoding on `addr[31:24]` alone, which makes an access past the end of RAM
alias back to the start instead of faulting, had its wrap point four times
higher in simulation than on hardware.

`sim/tb_ramboot.v` now runs that path at that size and is in `make verify`.

**The rule.** For every configuration you ship, there is a simulation of *that*
configuration. Parameters that differ between simulation and hardware are a
list you maintain deliberately, not an accident of defaults.

## 5. Run it twice

Reset is not a fresh start, and one run proves only that the first run works.

**The incident.** Block RAM is initialised when the FPGA is *configured*, not
when the CPU is reset. `crt0_ram.S` zeroed `.bss` but never restored `.data`,
so pressing reset re-ran the program over memory the previous run had already
written. What that broke was newlib's stdio and nothing else: `__sinit`
returns early when its `__cleanup` guard is non-NULL and sets that guard
itself on success, so from run 2 onward `stdout` was never initialised and
every `printf` returned −1 and printed nothing.

Every simulation ran the program exactly once, so every simulation passed.
And because the usual bring-up gesture is *flash, open a terminal, tap reset
to catch the banner*, essentially every run anyone watched on hardware was
run two. `make sim_rerun` now runs the program, pulses reset without touching
RAM, and runs it again.

**The rule.** Anything with an initial value must be rebuilt at startup, not
assumed to survive. Test the second run, not just the first — and pick a test
program that would actually notice. `sim_rerun` uses the newlib probe rather
than the acceptance test precisely because the acceptance test keeps its
state in `.bss`, which `_start` has always zeroed, so it passes twice either
way.

## 6. Make the verdict machine-checkable

If a human has to read the output to know whether it passed, it will
eventually pass while broken.

**The practice.** Every SoC simulation ends with the firmware writing a magic
word (`"PASS"` / `"FAIL"`) to a fixed address the testbench reads back, so the
result is a value rather than an impression. The console output is still
printed — it is decoded off the CPU's actual serial TX pin by a receiver state
machine in the testbench, not a canned string — but it is evidence, not the
verdict. `tests/run.sh` and `sim/trapcheck.sh` return exit codes; `make
sim_rerun` greps its own log and fails the build.

Expected failures are held in `tests/expected-failures.txt` with reasons, and
`run.sh` fails the run if one of them starts *passing*, so the list cannot
quietly go stale.

## 7. Route around a defect and you have not fixed it

Workarounds are legitimate. Calling one a fix is not.

**The incident.** When `printf` appeared to hang on hardware, the acceptance
test was rewritten to print through a libc-free console. That was the right
call for the test — a test of the SoC should not be able to fail inside the C
library — and it was recorded as explicitly *not* an answer to the question.
That honesty is why the question was still open to be answered later, and the
answer turned out to be a `.data` initialisation bug in this project's own
startup code, not newlib at all (§5).

The same standard applies to the intermittent `ISA-TIMEOUT` under `make
verify`: it now self-reports instead of hanging silently, and the docs say
plainly that self-reporting was not a fix and the cause is still unknown.

**The rule.** When you work around something, write down what you did not
find out. A known unknown gets revisited; a silently patched one does not.

## 8. Read the failure, do not pattern-match it

**The incident.** "Reached `main` and stopped dead on its first `printf`" was
the accepted description of the bug in §5 for months. `printf` never hung. It
returned, reported failure, and its output was discarded — but `printf` was
the only output channel at the time, so "produced nothing" and "stopped" were
the same observation. The moment the program had an independent way to speak,
the symptom dissolved.

**The rule.** Before theorising about a cause, check that the symptom is
described correctly. Give the system a second, independent channel for
reporting — one that does not depend on the subsystem under suspicion.

## 9. Narrow by one dependency at a time

**The practice.** `software/soc/newlibprobe.c` is a ladder: RAM under the heap
→ `_sbrk` → the memory `_sbrk` returned → `malloc` → `snprintf` (formatter,
no heap or stdio) → `puts` (stdio setup and `_write`) → `printf`. Consecutive
rungs differ by a single dependency, and each prints one character *before* it
runs, so a run that stops tells you where even if the line never finished.

That structure is what turned "newlib is broken" into "`__sinit` was locked
out by a stale guard word" in three board runs, each of which eliminated a
specific layer rather than gathering general information.

## 10. Prefer arithmetic to inspection

**The incident.** The stale `.data` bug was confirmed not by looking at memory
and judging it wrong, but by a rotate-xor checksum over the whole 4,834-word
image. Expected ⊕ observed was `0x01448400`, and rotating the suspect value
`0x80002890` by its position in the image gives exactly `0x01448400` — proving
that word was the *only* one of 4,834 that differed. `nm` then showed the
value was `cleanup_stdio`, a function address only `__sinit` ever stores.

**The rule.** When you can turn "this looks wrong" into a number that can only
have one explanation, do it. It is faster than more inspection and it does not
depend on your judgement being sharp at the end of a long session.

## 11. Every duplicated constant is a defect waiting

Some constants cannot be shared across a language boundary: software cannot
read a synthesis parameter, and a linker script cannot include a C header.

**The practice.** Where duplication is unavoidable, it is named, commented on
both sides, and the direction of safe error is stated. `CPU_HZ` in
`software/soc/soc.h` must agree with `CLK_HZ` in `fpga/soc_fpga.v`, and the
comment says: if you get it wrong, get it wrong *high*, because
over-estimating makes SCK slower than intended (harmless) while
under-estimating pushes the SD init clock above the 400 kHz ceiling, which
real cards reject. `RAM_SIZE` vs `RAM_BYTES`, `soc.h` vs `soc_top.v`'s
`s_base` table vs `dts/soc.dts` vs the linker scripts are the same hazard.
`docs/soc.md` names all five places a new peripheral must be registered and
says outright that none of them check each other.

Where a check *is* possible, it exists: `fpga/synth/synth_ecp5.sh` refuses to
build if the preload image is older than the ELF it came from, and
`link_ram.ld` carries `ASSERT`s that name which neighbour the program has
grown into rather than leaving you with "region overflowed by 112 bytes".

## 12. A stale artifact is worse than a missing one

Missing stops the build. Stale sails through and produces a result about
something other than what you think you are testing.

**The incidents.** A bitstream was once built with a stale `ramimage.hex`,
baking in a program from before a fix and reproducing a bug that was already
solved — a full synthesize-and-flash cycle to notice. `make trapcheck` writes
the same image filename for each of its four cases, so it deletes the image
when it finishes rather than leaving whichever case ran last to be picked up
by a bitstream build. And every `$readmemh` image rule in the `Makefile` lists
`Makefile` itself as a prerequisite, because the word/byte layout of each
image is decided by the `bin2hex` flags there — without it, changing a
memory's organisation leaves an image that loads silently and wrong, which
cost real debugging time when `wb_ram.v` went from byte- to word-organised.

**The rule.** Build products carry their provenance. `synth_ecp5.sh` stamps
each bitstream with a copy of the image inside it, so "which program is in
this `.bit`?" is answerable from the filesystem rather than from memory.

## 13. Fail fast, and say what to do

**The incident.** A synthesis run got through 56 seconds of yosys before dying
on `nextpnr-ecp5: command not found`, because Homebrew ships yosys but has no
nextpnr formula. The script validated the boot ROM image and the preload image
before starting — but not the tools that consume them.

It now checks all three up front and prints the `export PATH=...` line.

**The rule.** Check preconditions in cost order, cheapest first. An error
message should name the fix, not just the problem.

## 14. Anything nothing builds will rot

**The incident.** `fpga/top_fpga.v` sat in the tree for months with unconnected
page-table-walker ports, because no target built it. `sim/tb_ulx3s.v` now
exists specifically so the board wrapper — pin direction, polarity, tie-offs —
cannot rot the same way, and it is part of `make verify`.

**The rule.** If a file is not built by something in `make verify`, either
wire it in or delete it. There is no third state that stays honest.

## 15. Layers, each answering what the one before cannot

Four verification layers, described in full in `tests/README.md`:

| Layer | The question only it answers |
|---|---|
| Directed tests | Does the feature I just wrote work? |
| Architectural tests (riscv-tests) | Does this implement *RISC-V*, as judged by someone else's suite? |
| Co-simulation vs Spike | Did it execute the *same instructions*, or reach the right answer a wrong way? |
| Formal (yosys + z3) | Does this hold for *every* input, not just the ones a test tried? |

The upstream suites are deliberately not vendored — the value of running them
is that this project did not write them — and are pinned to a commit so a
regression can never be explained away by "upstream changed".

Two of these exist specifically to catch what the others cannot.
Co-simulation found nothing the tests found; it asks a strictly harder
question. Formal covers roughly 2^30 PLIC priority/enable/pending/threshold
combinations that no test suite is going to enumerate.
`formal/fv_selftest.v` is a property that **must** fail, proving the flow can
still go red.

## 16. Write down what is not true yet

**The practice.** `fpga/README.md` opens with a table separating "builds",
"closes timing", "has been loaded onto a board" and "the SD card works",
because those are different claims and conflating them is how a project starts
lying about itself. `software/opensbi/README.md` says OpenSBI *builds* but
does not *boot*, and lists the four things standing in the way.
`tests/README.md` lists the three architectural tests that fail and why.

**The rule.** Status is per-claim, not per-project. "Works" is not a status.
When something has only been done in simulation, say so; when it has been done
on hardware, record the run verbatim, with the values that make it a report
about *that* build.

---

## Conventions

**Commits** are imperative and say what changed and why it matters — `Test
GPIO through a pad, not through a testbench`, `Report a trap in the loaded
program instead of losing it`. The body carries the reasoning and the
incident; commit messages here are where the history of *why* lives.

**Comments** explain the decision, not the syntax. A comment that says what
the next line does is noise; one that says why the obvious alternative was
rejected, or what broke last time, is why `rtl/soc/wb_ram.v` opens with three
paragraphs about why it is word-organised with synchronous reads.

**Numbers are measured, not estimated.** `fpga/README.md` once said 50–150 MHz
was "plausible for a core this size". Place-and-route said 28.78. That section
now carries the measured critical path and a note that the prediction was
wrong.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for how to get changes in.
