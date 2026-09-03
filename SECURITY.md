# Security policy

## What this project is, and what that means for security

Vernier-RV32 is a RISC-V RV32IMA core and SoC built as an engineering project.
It is **not** a hardened or audited design, it has never been through a
security review, and it should not be treated as a trust boundary in anything
that matters. Its `pmpcfg`/`pmpaddr` CSRs exist and store correctly, but
**nothing enforces them** — treat this exactly as if PMP did not exist. It has
no debug authentication, and no side-channel countermeasures of any kind — no
constant-time guarantees, no cache (so no cache side channels, but also no
mitigation for anything else), and no attempt at speculation control beyond
the fact that it does not speculate past a branch resolution.

Please report issues anyway. The privilege boundary is a real interface with
real invariants, and it has already had a real failure — see below.

## Reporting

Use **GitHub's private vulnerability reporting** on this repository:
Security → Report a vulnerability, or
<https://github.com/AravindRajeshkanna/vernier-rv32/security/advisories/new>.

That is the only reporting channel, deliberately — it keeps the report
private until there is a fix, gives it a tracking number, and does not depend
on anyone publishing a mailbox.

Please do not open a public issue for privilege-boundary bugs until there has
been a chance to look.

Include, as far as you have it:

- Which invariant is broken, stated as an invariant ("U-mode can read an
  S-mode page", not "the MMU is wrong").
- A test that demonstrates it. A `riscv-tests`-style assembly case or an
  addition to `sim/tb_soc.v` is ideal; a Spike-vs-RTL co-simulation divergence
  is ideal.
- Whether it reproduces in simulation, on hardware, or both.
- Which commit.

This is a single-maintainer project. Expect an acknowledgement within about a
week. There is no bounty.

## What counts

**In scope**, roughly in order of how much it matters:

- **Privilege escalation** — anything letting U-mode reach S-mode or M-mode
  state, or S-mode reach M-mode state.
- **MMU faults** — page permission bits not enforced (`U`, `R`/`W`/`X`,
  `SUM`, `MXR`), a walk reading the wrong PTE, missing `A`/`D` handling, or
  `SFENCE.VMA` failing to invalidate.
- **Trap delegation** — `medeleg`/`mideleg` letting a trap reach a mode that
  should not handle it, or `mstatus.TVM`/`TW`/`TSR` failing to trap.
- **CSR access control** — a CSR readable or writable from a mode that should
  not reach it, or a WARL field accepting a value it should mask.
- **Atomics and the bus** — an AMO or LR/SC that bypasses a permission check
  (this has happened: an AMO was once permission-checked as a load, so it
  could write a read-only page), or an interconnect state that lets one master
  observe another's data.
- **The boot path** — the boot ROM accepting a malformed SD image in a way
  that lets it write outside the load region.

**Out of scope**, because they are known and documented rather than
undiscovered:

- **No PMP enforcement.** `pmpcfg0-3`/`pmpaddr0-15` are real, correctly
  read/written CSRs (`docs/roadmap.md`'s PMP entry) — but no fetch, load, or
  store path consults them. "A configured PMP region does not actually deny
  access" is this exact known gap, not a new finding — `docs/soc.md` §7 has
  the current state.
- The JTAG TAP / Debug Module has no authentication of any kind — anyone who
  can reach the JTAG pins has full System Bus Access and (`CORE=inorder`,
  simulation builds only) halt/resume/register access. `docs/debug.md` has
  the current state.
- Timing side channels. The core has a variable-latency divider and a
  multi-cycle bus; nothing is constant-time and nothing claims to be.
- Physical attacks — glitching, probing, bitstream extraction. The ECP5's
  bitstream security is Lattice's business, not this project's.
- The known-failing architectural tests in `tests/expected-failures.txt`.
- Anything in a fetched third-party suite (riscv-tests, CoreMark) — report
  those upstream.

## Track record

This is included because a security policy that implies a clean history would
be misleading. The verification layers here have found real isolation bugs:

- **The MMU never checked the PTE `U` bit.** U-mode could read and execute
  supervisor pages and vice versa — the entire user/supervisor isolation
  boundary was absent. Found by `rv32si` in the upstream architectural suite,
  not by anything this project wrote.
- **An AMO was permission-checked as a load**, so it could write a read-only
  page.
- **`mstatus.TVM`/`TW`/`TSR` did not exist**, so M-mode firmware could not
  intercept a supervisor's `SFENCE.VMA`, `satp` access, `WFI` or `SRET`.
- **`misa` under-reported**, and `medeleg` refused to delegate causes 0/4/6,
  so an S-mode kernel asking for its own misaligned-access handler silently
  never got one.

Full list and detail in [tests/README.md](tests/README.md).

## Supported versions

`main` only. This project does not maintain release branches; fixes land on
`main` and there is no backporting.
