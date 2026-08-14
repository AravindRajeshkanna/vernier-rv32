<!--
Thanks for contributing. The checklist below is the same standard the project
applies to its own commits - see docs/practices.md, which explains why each
item is there and names the incident that put it there.

Delete any section that genuinely does not apply, and say why.
-->

## What this changes

<!-- One paragraph. What was wrong or missing, and what it does now. -->

## Why it is right

<!--
The reasoning, and what you ruled out. If you fixed a bug, what was the actual
cause - not the symptom? This project spent months believing "printf hangs on
hardware" when printf never hung.
-->

## Evidence

**`make verify` output:**

```
paste it here
```

<!--
If a layer could not run on your machine (no board, no Spike, no oss-cad-suite)
say which and why. "Did not run" is fine; silence is not.
-->

**New test that fails without this change:**

<!--
Name it, and say what it prints when the fix is reverted. If you could not make
it go red, say so - sometimes a bug is only reachable on hardware, and that is
useful to know. practices.md §1: a test that cannot fail is testing the
testbench.
-->

**Hardware, if you have a board:**

<!--
Board and revision, FPGA variant, BOARD= target, and the console output
verbatim. Post-route Fmax if you ran synthesis.
-->

## Checklist

- [ ] `make verify` passes, and the output is pasted above
- [ ] A test covers this, and I have seen it fail without the change
- [ ] If it touches anything the board runs: `make sim_ramboot` and
      `make sim_rerun` pass (PRACTICES §4, §5 - the run-once, 256 KB
      simulation hid a real bug for months)
- [ ] Any constant duplicated across Verilog/C/linker has a comment on both
      sides and a stated direction of safe error (§11)
- [ ] Anything I added is reached by something in `make verify` (§14)
- [ ] Numbers quoted are measured, not estimated
- [ ] Docs updated if behaviour or the register map changed
- [ ] I have read [CONTRIBUTING.md](https://github.com/AravindRajeshkanna/vernier-rv32/blob/main/CONTRIBUTING.md)

## AI assistance

<!--
Required - see AI_USAGE.md. One line is enough, e.g.

  Written with Claude Code; I reviewed and tested all of it. Tests by hand.
  or
  No AI assistance.

You must be able to explain and defend every line you are submitting.
-->
