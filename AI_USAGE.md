# AI usage

Two things live in this document: what this project discloses about its own
development, and what it asks of contributors.

## Disclosure: how this project was built

**Vernier-RV32 was developed with substantial AI assistance**, primarily
Anthropic's Claude via Claude Code. That covers RTL, testbenches, firmware,
build tooling, and documentation — not a bolt-on at the end, but most of the
way through.

This is stated plainly because a reader evaluating a CPU core is entitled to
know how it was made, and because the honest version is more useful than
either extreme. Neither "written by an AI" nor "AI-assisted, but all the real
work was human" would describe it accurately.

What that means in practice, and what it does not:

**It does not mean the design is unverified.** The opposite pressure applied.
Because the code was written fast, verification had to be the thing that
decided what was true, and the project leans on four independent layers to do
it: directed tests, the upstream RISC-V architectural suite, instruction-level
co-simulation against Spike, and bounded formal proof. Those layers found
fifteen real bugs, listed in [tests/README.md](tests/README.md) — among them
an MMU that never checked the PTE `U` bit, which meant the entire
user/supervisor isolation boundary was simply absent. A test suite this
project did not write is what caught it.

**It does not mean claims are unchecked.** Numbers in this repository are
measured and pasted, not estimated. Hardware claims are backed by console
output recorded verbatim from a specific build. Where something has only been
done in simulation, the docs say so; where a question is open, it is written
down as open. `fpga/README.md` opens with a table separating "builds", "closes
timing", "runs on a board" and "the SD card works" for exactly this reason.

**It does mean some mistakes are AI-shaped.** The failure modes worth naming,
all of which happened here:

- *Confident wrong diagnostics.* A debugging probe decoded a flag field by
  testing two bits and falling through to a default, and so labelled newlib's
  `__SERR` bit as a buffering mode — hiding the actual finding behind a
  plausible-sounding label. The same probe sampled a guard variable after the
  code it guards had run, where a healthy system reads the same value as a
  broken one. Both would have "confirmed" a hypothesis regardless of truth.
  Both were caught by keeping a known-good baseline to disagree with.
- *Plausible-looking tests that cannot fail.* The GPIO test measured the
  testbench's loopback wire rather than a pad, and passed for months.
- *Fluent explanations of the wrong cause.* "printf hangs on hardware" was the
  accepted description of a bug for months. printf never hung.

[docs/practices.md](docs/practices.md) is largely a response to that list. Its
first three rules — a test must be able to fail, prove the instrument before
trusting it, diagnostics lie too — are there because of incidents like these.

**Accountability sits with the maintainer.** Every line in this repository was
accepted by a human who is answerable for it. AI assistance changes how code
gets written; it does not move responsibility for what the code does.

## Policy for contributors

**AI-assisted contributions are welcome.** They are how this project was
built, and a rule against them would be both hypocritical and unenforceable.
Three conditions apply.

### 1. Disclose it

Say so in the pull request description. A line is enough:

> Written with Claude Code; I reviewed and tested all of it.
> Tests written by hand.

The PR template asks. This is not a scarlet letter — it is context for the
reviewer, the same way "this is my first Verilog" or "cherry-picked from my
other branch" would be.

### 2. Be able to explain every line

You are the author. If a reviewer asks why a signal is registered here rather
than there, or what happens when two masters request the bus in the same
cycle, "that is what the model produced" is not an answer. If you cannot
defend it, do not submit it — read it until you can, or cut it.

This matters more in RTL than in most software. A subtly wrong pipeline
interlock does not throw; it produces wrong answers under a timing condition
your testbench does not reach.

### 3. Run the tests yourself

`make verify`, on your machine, with the output pasted. Not "the model says
this should pass". If you have a board, run it there too and paste that
verbatim.

### What will get a PR closed

- **Undisclosed bulk-generated changes.** Large diffs with no evidence anyone
  read them, especially sweeping "improvements" nobody asked for.
- **Fabricated evidence.** Invented test output, invented timing numbers,
  invented citations. This is the one thing here that is not a
  learning-experience conversation.
- **Generated issues.** Bug reports produced by pointing a model at the
  repository and asking what is wrong with it. Report bugs you actually hit.

Everything else is a normal review.

## A note on scale

This project is small and reviewed by one person. That constrains what can be
absorbed: a 4,000-line PR is not reviewable regardless of who or what wrote
it, and the practical limit is much lower for RTL than for docs. Open an issue
before a large change so the work is not wasted.

---

*Questions about this policy, or disagreement with it, are reasonable topics
for an issue.*
