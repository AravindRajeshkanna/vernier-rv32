# ARCHITECTURE.md — How This CPU Works

This document explains the Verilog source in `rtl/`, module by module, and
how they fit together into a complete RV32I CPU. For setup and simulation
instructions, see `README.md` instead — this file is about the design
itself.

## 1. Big picture

This is a **5-stage pipelined** CPU: instructions flow through
**IF → ID → EX → MEM → WB** — fetch, decode, execute, memory access,
writeback — with a different instruction occupying each stage every clock
cycle. That overlap is what makes a pipeline faster than the single-cycle
design this project started as: each stage only needs to do 1/5th of the
work within a clock period, so the clock can run much faster, even though
any individual instruction still takes 5 cycles to fully retire.

It implements **RV32IMA** (base integer ISA + the **M** multiply/divide
extension + the **A** atomic extension) plus **Zicsr**, **full M/S/U
privilege modes with real trap delegation**, timer/software/external
**interrupts** (the external source now a real prioritized/claimable
**PLIC**), a **Sv32 MMU covering both data and instruction fetch** (two
independent TLBs/walkers sharing one page-table structure), and a **BTB +
2-bit saturating-counter branch predictor**. It's still single-issue and
in-order — no superscalar issue, no out-of-order execution/speculation —
see `README.md` for what that next step would look like.

### Module hierarchy

```
top.v                          (simulation top level)
 ├── cpu_core.v                (the CPU itself)
 │    ├── regfile.v            (32 x 32-bit registers)
 │    ├── csr_file.v           (M/S-mode CSRs + current_priv)
 │    ├── muldiv_div.v         (multi-cycle DIV/DIVU/REM/REMU)
 │    ├── mmu.v                (TLB + Sv32 walker - instantiated twice: data + instruction)
 │    └── btb.v                (branch target buffer)
 ├── imem.v                    (instruction memory / ROM)
 ├── dmem.v                    (data memory / RAM, 3 read ports)
 ├── clint.v                   (timer/software-interrupt peripheral)
 └── plic.v                    (prioritized/claimable external interrupt controller)
```

`fpga/top_fpga.v` mirrors `top.v` but for real hardware — same modules,
wired to physical clock/reset/LED pins instead of a testbench.

### Architecture style: Harvard, not Von Neumann

Unchanged from the single-cycle version: instructions and data live in
**two separate memories** (`imem` and `dmem`), each with their own address
space starting at 0. Both already do combinational reads and synchronous
writes, one access per cycle — exactly what a pipelined IF stage (fetch)
and MEM stage (load/store) need. `dmem` now has **three** read ports
alongside its main read/write port: one for the data MMU's walker, one for
the instruction MMU's walker (section 6) — page tables for both code and
data mappings live in the same RAM, they just each need a read path that
doesn't contend with the MEM stage's own loads/stores or with each other.

## 2. `cpu_core.v` — the pipeline

The five stages are separated by four pipeline registers: `if_id`,
`id_ex`, `ex_mem`, `mem_wb`. Each carries a `valid` bit; when clear, the
slot is a **bubble** — every stage gates its side effects (`reg_we`,
`mem_we`, `csr_we`, redirecting the PC, ...) on the relevant `valid` bit,
so a bubble can flow through the pipeline without ever writing anything.
Reset clears `pc` to `RESET_PC` and clears every pipeline register's
`valid` bit, so the pipeline "boots" by flooding itself with bubbles for
the first few cycles while real instructions fill it in.

### 2a. IF — fetch, and now translation

```verilog
reg [31:0] pc;
wire ifetch_mmu_active = satp_mode && (current_priv != PRIV_M);
```

`pc` still advances by 4 each cycle by default, but when `satp` is enabled
and the hart is running below M, every fetch now goes through its own
instruction MMU (an `mmu.v` instance, section 6) before `imem_addr` is
driven. IF is, for the first time, a stage that can itself **stall** (an
ITLB miss freezes `pc`) and **fault** (a missing/insufficient-permission
mapping is an instruction page fault, cause 12) — see 2c and 2d for how
that plumbs through without corrupting the existing load-use/busy-stall
machinery. The predicted next `pc` (section "BTB" below) also gets decided
here, before `if_id` latches.

### 2b. ID — decode

Field/immediate slicing is identical to the single-cycle core (same five
immediate encodings, same bit-shuffle caveats for B-type and J-type), plus
a new field extraction for AMO's `funct5` (`instr[31:27]`). What's
different from a single-cycle design is *what happens* to the decoded
fields: instead of driving the ALU directly, ID produces a compact bundle
of control signals (`reg_we`, `wb_sel`, `is_branch`, `is_csr`, `is_muldiv`,
`is_amo`, `is_trap_event`, ...) that gets latched into `id_ex` for the EX
stage to actually act on next cycle.

ID is also where **illegal-instruction detection** happens: an
unrecognized opcode, a bad `funct7` on OP/OP-IMM, a reserved branch
`funct3`, a CSR instruction targeting an unimplemented, read-only-on-write,
or **insufficient-privilege** address (see 2d/section 8), a reserved
SYSTEM encoding, an unrecognized AMO `funct5`, or an MRET/SRET/SFENCE.VMA
executed below the privilege it requires, all set `illegal`. An
instruction-fetch page fault discovered in IF (`if_id_ifetch_fault`)
overrides whatever the garbage instruction bits at that PC would otherwise
decode to — every one of these becomes a trap (the fetch fault at cause
12; everything else at cause 2) carried down the pipeline just like
ECALL/EBREAK. `FENCE` (the MISC-MEM opcode) is deliberately treated as a
legal no-op rather than illegal, since real toolchains emit it routinely.

`current_priv` (from `csr_file.v`) is read combinationally here too —
needed for ECALL's cause (8/9/11 by privilege), for gating MRET/SRET/
SFENCE.VMA/CSR-address legality, and it's safe to read this early for the
same reason reading `mstatus.MIE` in EX is safe: every event that changes
it (trap-entry, MRET, SRET) is *also* a `redirect_valid` source, flushing
`if_id`/`id_ex` at the same edge, so no in-flight decode ever observes a
stale value.

The register file is read here (combinationally, `rs1`/`rs2`) and written
in WB (synchronously) — same single `regfile` instance doing both, same
"x0 hardwired to zero" behavior as before (see `regfile.v`, section 5).

### 2c. Hazards: forwarding and *three* kinds of stall/bubble condition

Two instructions close together in the pipeline can be flowing through it
simultaneously while one still needs the other's result — a **data
hazard**. This core resolves it a few ways:

- **Forwarding**: a small unit compares `id_ex`'s `rs1`/`rs2` against
  `ex_mem`'s and `mem_wb`'s destination register, and feeds the most
  recent match's value straight into the EX stage's operands (`op1`,
  `op2_reg`) instead of the stale value `id_ex` latched back in ID. This
  covers a producer 1 or 2 instructions ahead, with no stall at all.
- **Load-use stall** (`load_use_stall`): forwarding can't produce a value
  that doesn't exist yet. A load's — or now an AMO/LR's — data isn't ready
  until it reaches MEM, so if the instruction right behind one needs its
  destination register, the hazard-detect unit freezes `pc` and `if_id`
  for one cycle and inserts a bubble into `id_ex` instead. One cycle
  later, the result is sitting in `mem_wb`, forwarding picks it up
  normally, and the dependent instruction proceeds. (`id_ex_is_load_like`
  covers both loads and AMO/LR/SC uniformly — they all produce their `rd`
  value the same way, in MEM, so they need the same stall.)
- **Busy stall** (`ex_busy_stall`): a DIV/DIVU/REM/REMU or a translating
  load/store/AMO takes multiple cycles to produce a result (section 3,
  section 6). Unlike the load-use stall, the *same* instruction has to
  stay in EX across all of those cycles — `id_ex` holds its own contents
  unchanged (rather than becoming a bubble) while `ex_mem` is fed bubbles,
  until the divider or the data-MMU walker signals done.
- **IF-stage stall** (`if_stall` = `itlb_wait_stall`, new): an ITLB miss
  freezes `pc` too, but it is a **fundamentally different, independent**
  condition from the two above, and folding it into the same signal that
  drives `id_ex`'s hold/bubble logic (`id_ex_stall` =
  `load_use_stall || ex_busy_stall`) would silently double-execute an
  instruction. Here's why: `if_stall` is about whether *IF* has something
  new to hand to `id_ex`; `id_ex_stall` is about whether *id_ex* is free
  to accept whatever `if_id` currently holds. Those can disagree — a fetch
  can be mid-walk while `id_ex` is completely free to advance this cycle —
  and if `if_id`'s "hold vs. bubble" decision used the same combined
  signal `id_ex` uses, a cycle where `id_ex_stall=0` but `if_stall=1`
  would let `id_ex` consume `if_id`'s current instruction *and* have
  `if_id` re-present that same instruction again next cycle, since nothing
  told it its content had already been taken. `if_id`'s register block is
  therefore a genuine 3-way split:

  ```verilog
  // redirect_valid   -> if_id_valid <= 0                (flush)
  // id_ex_stall      -> hold if_id unchanged             (content not yet consumed)
  // if_stall         -> if_id_valid <= 0                 (content WAS consumed; IF has nothing new)
  // else             -> normal latch (+ ifetch_fault/BTB prediction bits)
  ```

  `id_ex`'s own hold/bubble logic needs **no awareness of `if_stall` at
  all** — it already reacts correctly to whatever `if_id_valid` says.
  `pc` itself freezes under *either* condition (`pc_freeze = id_ex_stall
  || if_stall`), since IF obviously can't advance while its own fetch is
  unresolved either.

A subtlety this project ran into earlier and is still worth calling out:
forwarding paths only exist for 1 and 2 instructions ahead, and the plain
synchronous-write/combinational-read register file only resolves a
dependency "for free" once the producer is **4 or more** instructions
ahead. That leaves a gap at exactly 3 instructions ahead that neither
mechanism covers, which `regfile.v` closes directly with an explicit
same-cycle write-to-read bypass (section 5) — a real bug an earlier update
found and fixed, not a hypothetical.

A second, related subtlety is specific to `ex_busy_stall`: while an
instruction is frozen in `id_ex` for many cycles, the *rest* of the
pipeline keeps moving underneath it, so `ex_mem`/`mem_wb` (and therefore
forwarding) only reflect a stalled instruction's neighbors for a cycle or
two before draining away to bubbles. A translating store/AMO's data
operand would drift back to a stale value by the time the walk resolves
if it were re-derived from live forwarding at that point — `cpu_core.v`
instead snapshots the forwarded operand once, on the walk's first cycle
(`store_data_latched`), the same way `mmu.v` itself snapshots the virtual
address (`va_r`) it's translating. The divider sidesteps this entirely by
capturing its own operands once at `start`.

### 2d. EX — ALU, M/A extensions, MMU request, CSRs, and every redirect

This is where the original single-cycle core's `alu_exec` function still
lives, fed by the forwarded operands. The M extension's multiply is
combinational right alongside it (section 3); DIV/DIVU/REM/REMU hand off
to `muldiv_div.v`. A load/store/AMO's effective address is computed here
too and, when translation is actually active (see below), handed to the
data `mmu.v` instance for translation before it's allowed to reach
`ex_mem`.

**Translation only applies below M now** — `effective_priv_for_data =
(current_priv==M && mstatus.MPRV) ? mstatus.MPP : current_priv`, and
`need_translate = is_mem_op && satp.MODE && (effective_priv_for_data !=
M)`. This replaces an earlier stand-in ("translate unconditionally
whenever `satp.MODE=1`") that existed only because this core used to have
no privilege level below M for a real boundary to make sense against —
now that S/U modes exist, translation follows the real spec condition
(S/U execution, or an M-mode access acting on `MPP`'s behalf via `MPRV` —
which never affects instruction fetch, spec-mandated, hence
`ifetch_mmu_active` in 2a checking only `current_priv`, not `MPRV`).

EX is also where **every** change of control flow gets resolved, with a
priority order (highest first): **a pending, enabled interrupt** > **a
synchronous exception** (illegal instruction/ECALL/EBREAK/instruction-page
fault from ID/IF, or a data-MMU page fault discovered once a walk
concludes) > **a branch/JAL/JALR misprediction** > **MRET/SRET**. A
**mispredict**, not "any taken branch/jump," is what redirects now (see
"BTB" below) — the 2-cycle flush shape (the instruction in `id_ex` and the
one in `if_id` both turn into bubbles the same edge `pc` jumps) is
unchanged, it's just paid less often.

An interrupt is different from every other redirect source in one
important way: it **preempts whatever instruction is currently in EX
entirely**, even one that would otherwise complete normally — including
an MRET/SRET, whose own privilege-restore side effect must be suppressed
exactly like `reg_we`/`mem_we`/CSR-`we` already are (`mret_en`/`sret_en`
both gate on `!interrupt_taken`), since an interrupt-preempted MRET/SRET
never architecturally completes and must not pop `mstatus`/`current_priv`
either — it's simply re-fetched, unmodified, after the interrupt handler
returns. `mmu_fault_now` similarly must gate `ex_mem`'s `reg_we`/`mem_we`
(`commit_ok = !interrupt_taken && !mmu_fault_now`) — a page-faulting
access is discovered only once the walk resolves, well after those bits
were latched true for what looked, at decode time, like an ordinary
access. Interrupts are only sampled when EX isn't already in the middle
of a busy divide/walk (`!ex_busy_stall`) — a multi-cycle op always runs to
completion first.

CSR instructions (CSRRW/S/C and their immediate forms) read the old CSR
value and compute+write the new one in this same stage, using
`csr_file.v` (section 8) as a small synchronous register file.

**A extension (AMO/LR/SC)** also resolves address translation and the
load-use-stall/forwarding machinery here identically to an ordinary
load/store (`is_mem_op_now` includes `id_ex_is_amo`) — but the actual
read-modify-write happens one stage later, in MEM (see 2e).

### 2e. MEM and WB

`dmem_addr/wdata/we/size` are driven from `ex_mem` for an ordinary
load/store exactly as before. **AMO/LR/SC now add a second write path
computed combinationally in MEM itself**: because `dmem.v`'s port is
combinational-read/synchronous-write, an AMO's read-modify-write completes
in a single MEM-stage cycle — `dmem_rdata` (the *old* value, visible
combinationally before this cycle's write takes effect at the edge, just
like an ordinary load) feeds both `rd` (via `mem_result`, the same path a
load's sign-extended value already uses) and a combinational ALU
(`amoswap`/`amoadd`/`amoxor`/`amoand`/`amoor`/`amomin(u)`/`amomax(u)`)
whose result becomes `dmem_wdata` for the RMW ops. `LR.W` sets a
`reservation_valid`/`reservation_addr` pair; `SC.W`'s success check and
write-enable are resolved **in MEM, not EX** — for back-to-back `LR;SC`,
`SC` reaches EX the very cycle `LR` is in MEM, and `LR`'s reservation
update doesn't land until the edge ending that cycle, so checking it a
stage later (when `SC` itself is in MEM) is what actually sees the
just-set reservation rather than a stale pre-`LR` value. Any `SC` (success
or failure), any successful write anywhere, or any trap invalidates the
reservation.

A load's raw word gets sign/zero-extended here as before; an AMO/LR's old
value needs no extension (word-only). The result is latched into
`mem_wb`. WB itself is just `regfile`'s write port, fed directly by
`mem_wb`'s contents.

## 3. M extension (RV32M)

`OP` with `funct7=0000001` selects one of eight ops by `funct3`:
MUL(000)/MULH(001)/MULHSU(010)/MULHU(011)/DIV(100)/DIVU(101)/REM(110)/
REMU(111).

- **Multiply**: combinational, right in EX, alongside `alu_exec`. Three
  64-bit products (signed×signed, unsigned×unsigned, and signed×unsigned
  by zero-extending the unsigned operand into a wider signed value) cover
  all four ops — MUL takes the low 32 bits of any of them (sign-agnostic
  at that width), the other three take the high 32 bits of the matching
  product. No stall.
- **Divide**: `muldiv_div.v`, a 32-iteration restoring shift-subtract
  divider operating on operand magnitudes (sign of dividend/divisor
  stripped going in, RISC-V's quotient-XOR-sign / remainder-takes-
  dividend-sign rule reapplied coming out). Divide-by-zero
  (quotient=all-1s, remainder=dividend) and the `INT_MIN / -1` signed-
  overflow case (quotient=dividend, remainder=0) are special-cased to
  finish in 1 cycle rather than run the iteration, per spec. Exposes a
  `start`/`busy`/`done` handshake and drives `ex_busy_stall` (2c).

## 3a. A extension (RV32A: AMO and LR/SC)

Opcode `0101111`, `funct3=010` (word-only, all this core implements).
`funct5` (`instr[31:27]`) selects the operation:
`LR`(00010)/`SC`(00011)/`AMOSWAP`(00001)/`AMOADD`(00000)/`AMOXOR`(00100)/
`AMOAND`(01100)/`AMOOR`(01000)/`AMOMIN`(10000)/`AMOMAX`(10100)/
`AMOMINU`(11000)/`AMOMAXU`(11100); `aq`/`rl` are decoded but functionally
ignored (this core is single-hart and in-order, so there is nothing for
them to fence against). The read-modify-write mechanics live in MEM
(section 2e); decode and hazard handling treat AMO/LR like a load with a
possible conditional write, described in 2b/2c.

Out of scope, documented rather than silently wrong: AMO/LR/SC targeting
the CLINT or PLIC MMIO windows is undefined — the RMW would go through
those peripherals' `*_rdata`/`*_we`, not a real atomic operation against
their internal state machines.

## 4. Full M/S/U privilege modes and trap delegation

`current_priv` (in `csr_file.v`, `2'b11`=M/`2'b01`=S/`2'b00`=U, reset to
M) is real state now, not an assumption. A trap lands in **S** instead of
**M** only if the hart wasn't already in M (traps never move to a *less*
privileged mode than where they occurred) and the specific cause's bit is
set in `medeleg` (exceptions) or `mideleg` (interrupts) — computed inside
`csr_file.v` from its own `current_priv`/deleg registers and exposed as
`trap_to_s_out`, so `cpu_core.v` just picks `stvec`/`sepc` vs.
`mtvec`/`mepc` off that one bit. `MRET` is legal only from M; the new
`SRET` (SYSTEM/`funct3=0`/`funct12=0x102`) is legal from S or M.
`SFENCE.VMA` requires at least S. ECALL's cause is 8 (U) / 9 (S) / 11 (M)
by the privilege it executed at.

CSR minimum-privilege is read directly off address bits `[9:8]`
(`00`=U/`01`=S/`11`=M) — this is the RISC-V spec's own encoding for that
field, so every CSR here (existing and new) is gated correctly with no
per-address table needed: `current_priv < addr[9:8]` is illegal.

**S-mode interrupt causes are separate bits, not delegated aliases of the
M-level ones**: SSI=1/STI=5/SEI=9 vs. the existing MSI=3/MTI=7/MEI=11.
There's no hardware S-timer or S-software-interrupt source in this
design, so `mip.SSIP`/`mip.STIP` are ordinary software-writable storage —
an M-mode handler is expected to service the real MTI and then manually
set `mip.STIP` before `mret`, exactly how real systems emulate an S-mode
timer interrupt without the Sstc extension. `mip.SEIP` stays hardwired 0
(the PLIC, section 9, only delivers to M this round). Interrupt
targeting/priority (`cpu_core.v`) now has to determine, per candidate
cause, whether it's even a candidate for **its own** target privilege
(`tgt_s_* = (current_priv != M) && mideleg[cause]`), then let any
M-targeted candidate win over any S-targeted one (M outranks S
regardless of specific cause), with EI > SI > TI priority within each
target — a materially bigger computation than the old, single-level
`mstatus.MIE && (meip||msip||mtip)` check, since M-mode interrupts are
never maskable by `mstatus.MIE` while running below M, and likewise for
S-targeted ones and `sstatus.SIE` while running below S.

`mstatus` gained real `MPRV` (bit 17) and `MPP` (bits `[12:11]`, now RW)
alongside the pre-existing `MIE`/`MPIE`, plus `SPP`(bit8)/`SPIE`(bit5) for
S-mode entry/return; `sstatus` (0x100) is a masked *view* of the same
underlying storage (`mstatus_full & 0x122`), not separate flip-flops.
`MXR`/`SUM`/`TVM`/`TW`/`TSR` stay hardwired 0 — documented gaps, not
silent ones. `MRET` clears `MPRV` whenever it's returning to a non-M
mode (`if (MPP != M) MPRV <= 0`) — a real spec requirement: without it,
firmware that sets `MPRV` and then `MRET`s to S/U without clearing it
would incorrectly keep redirecting that mode's own ordinary accesses
through `MPP` forever.

## 5. `regfile.v` — register file

32 registers, `x0` hardwired to zero, asynchronous read / synchronous
write — plus an **explicit same-cycle write-to-read bypass**:
`assign rdataN = (we && rd==rsN) ? wdata : regs[rsN];`. Section 2c
explains why this is load-bearing and not a defensive nicety: without it,
a producer exactly 3 instructions ahead of its consumer computes the
wrong answer, silently, because it falls into the one gap neither
explicit pipeline forwarding nor the plain array's natural timing covers.

## 6. `mmu.v` — a shared Sv32 MMU, instantiated for both data and fetch

`mmu.v` is a single, generic "translate one VA to PA with a permission
check" design, instantiated **twice** by `cpu_core.v`: once as the data
MMU (EX, `is_store` selects R vs. W permission), once as the instruction
MMU (IF, `is_fetch=1` selects the X-permission check instead — a new
`tlb_x` array alongside the pre-existing cached `R`/`W`/`A`/`D` bits).
Both share `satp` (one real Sv32 address space per spec — the page table
is shared, not duplicated) but have **independent TLBs and independent
walker read ports into `dmem`** (`ptw_addr`/`ptw_rdata` for data,
`iptw_addr`/`iptw_rdata` for instructions), so a data walk and a fetch
walk never contend or block each other.

An 8-entry fully-associative TLB sits in front of a 2-level Sv32 walker
FSM per instance:

- **TLB hit**: translated address and a cached-permission check
  (`R`/`W`/`X`/`A`/`D` bits, captured at install time) both resolve
  combinationally, no stall. Permissions are trusted on every hit and
  never re-walked — per spec, software must `SFENCE.VMA` after changing a
  PTE that could be cached, so a stale hit either succeeds correctly or
  faults correctly as long as that contract is honored. `SFENCE.VMA`
  flushes **both** TLBs together.
- **TLB miss**: the walker reads up to two PTEs through its own
  dedicated read-only `dmem` port — one state per level, since level 2's
  address depends on level 1's PTE content. Resolves to either a physical
  address (installed into the TLB; the pipeline unstalls and effectively
  retries as a hit) or a fault.
- **No hardware A/D update**: a PTE whose Accessed bit (or Dirty bit, for
  a store) isn't already set faults rather than being auto-set, avoiding
  a read-modify-write path through the walker.

**Two deliberate, spec-deviating simplifications, stated up front:**

1. Physical addresses beyond 32 bits are silently truncated — this
   core's whole memory system is 32-bit addressed, so PPN fields wider
   than that never point anywhere real anyway.
2. **This core is Harvard (separate `imem`/`dmem` physical arrays), but
   real Sv32 has one unified physical address space behind one page
   table.** The resolution here: the instruction MMU's resolved `pa`
   wires straight to `imem_addr`, the data MMU's resolved `pa` wires
   straight to `dmem_addr` — a static wiring fact, not a runtime mux
   (`imem.v` already ignores every address bit above its own word-index
   width, so there's no ambiguity about which array a given `pa` reaches).
   The one real consequence: a code-page PTE's PPN and a data-page PTE's
   PPN can numerically overlap without referring to the same physical
   location, since they're never used to address the same array — the
   test program's page tables pick non-overlapping PPN ranges anyway,
   purely so a human reading them later isn't misled into assuming a
   single flat PA space, even though the hardware doesn't require it.

A walk/permission-miss is a synchronous exception, but unlike
illegal-instruction/ECALL/EBREAK (known in ID) a *data* fault is only
known once the walk resolves *in EX* (folded into `synchronous_trap` via
`mmu_fault_now`, `mcause` 13/15), and an *instruction* fault is known in
**IF**, even earlier (folded into ID's `illegal`-equivalent machinery via
`if_id_ifetch_fault`, `mcause` 12 — section 2b/2c). `mtval` is the
faulting virtual address (data faults) or faulting PC (instruction
faults).

`SFENCE.VMA` (SYSTEM/`funct3=0`, distinguished from ECALL/EBREAK/MRET/
SRET by `funct7=0001001` since it has real `rs1`/`rs2` operands, and
requiring at least S privilege) is a global flush of both TLBs — the
`rs1`/`rs2` selective-flush hint is ignored, always legal per spec, just
less precise.

`mmu.v` lives inside `cpu_core.v`'s boundary (like `csr_file.v` and
`muldiv_div.v`) — translation is conceptually part of "the CPU," so the
only new ports crossing `cpu_core`'s boundary are the two walkers' raw
physical reads, which `top.v` wires straight to `dmem`'s 2nd and 3rd
ports.

### `btb.v` — branch target buffer

A 64-entry direct-mapped table (index = `pc[7:2]`, tag = the remaining
high bits), each entry a valid bit, tag, cached target, and a 2-bit
saturating counter (reset value `01`, "weakly not-taken," so a cold entry
behaves like static predict-not-taken until it's actually been seen).
Consulted combinationally at IF for every fetch; trained at EX for every
branch/JAL/JALR that reaches EX (`id_ex_valid` — never a flushed/bubbled
instruction, so there's no risk of training on a mispredicted shadow that
never should have run, since a control-flow instruction's own redirect
fires before anything younger commits). A tag miss allocates; a tag hit
saturates the counter and *always* overwrites the cached target (a
changed target — e.g. a `JALR` return address — must win even without a
counter change).

The prediction changes what "redirect" means in EX (section 2d): instead
of "any taken branch/jump always redirects," only a genuine **mispredict**
does — including a case that never existed before, "predicted taken but
actually not taken," which recovers to `pc+4` rather than to a computed
branch/jump target. `cpu_core.v` keeps an internal `mispredict_count`
purely for testbench observability (`sim/tb_top.v` reads it via a
hierarchical reference) — there's no other way to confirm from outside
the core that the predictor is actually avoiding flushes on a hot loop
rather than just moving the bug around.

## 7. `imem.v` / `dmem.v` — memories

`imem` is unchanged: a combinational-read ROM (perfect for IF, which
needs an instruction back within the same cycle it presents an address —
now a *physical* address, post-translation when active). `dmem` has two
independent, read-only combinational ports beyond its main read/write
port: one for the data MMU's walker, one for the instruction MMU's walker
— page tables for both code and data mappings live in the same RAM
(populated by `sw` before `satp` is enabled, same as a real boot
sequence), so each walker gets a way to read it without contending with
the MEM stage's own loads/stores or with the other walker. Real block
RAMs commonly support this (true/simple multi-port); it's the same
technique here, just extended to a third port.

## 8. `csr_file.v` — M/S-mode CSRs

| Addr | Name | Access | Notes |
|---|---|---|---|
| 0x100 | `sstatus` | RW | masked view of `mstatus`: SIE/SPIE/SPP only |
| 0x104 | `sie` | RW | masked view of `mie`, restricted to `mideleg`'s bits |
| 0x105 | `stvec` | RW | direct mode only; low 2 bits forced to 0 |
| 0x140 | `sscratch` | RW | plain storage |
| 0x141 | `sepc` | RW | low bit forced to 0; separate storage from `mepc` |
| 0x142 | `scause` | RW | plain storage |
| 0x143 | `stval` | RW | plain storage |
| 0x144 | `sip` | RW (partial) | masked view of `mip`; only `SSIP` is writable here |
| 0x180 | `satp` | RW | Sv32 `MODE`(bit31)/`ASID`(stored, unused)/`PPN` |
| 0x300 | `mstatus` | RW (partial) | real `MIE`/`MPIE`/`MPP`/`MPRV`/`SIE`/`SPIE`/`SPP`; `MXR`/`SUM`/`TVM`/`TW`/`TSR` hardwired 0 |
| 0x301 | `misa` | RO | reports RV32I |
| 0x302 | `medeleg` | RW (masked) | only bits {2,3,8,9,12,13,15} - causes this core can raise |
| 0x303 | `mideleg` | RW (masked) | only bits {1,5,9} - SSI/STI/SEI, the only real S-level causes |
| 0x304 | `mie` | RW | MSIE(3)/MTIE(7)/MEIE(11)/SSIE(1)/STIE(5)/SEIE(9) |
| 0x305 | `mtvec` | RW | direct mode only; low 2 bits forced to 0 |
| 0x340 | `mscratch` | RW | plain storage |
| 0x341 | `mepc` | RW | low bit forced to 0 |
| 0x342 | `mcause` | RW | plain storage |
| 0x343 | `mtval` | RW | plain storage |
| 0x344 | `mip` | RW (partial) | MSIP/MTIP/MEIP hardware-live and read-only; SSIP/STIP software-writable; SEIP hardwired 0 |
| 0xF14 | `mhartid` | RO | always 0 |

It has ports for: a generic read/write port (what CSRRW/S/C use), a
trap-entry port (asserted for exactly one cycle from EX, resolving to
either M or S internally via `trap_to_s_out` — see section 4), separate
MRET and SRET ports each with their own epc output, the live
interrupt-source inputs, and `satp`/`current_priv`/`mstatus.MPRV`/
`mstatus.MPP` exposed directly as outputs (not just through the generic
read port) since the MMUs and the interrupt-priority logic need them
every cycle regardless of whether a CSR instruction happens to be
executing. Whether a given CSR instruction *would* actually write
anything, and whether it's even legal to reach this module in the first
place, is decided statically in `cpu_core.v`'s ID stage — this module
just stores and serves whatever address and value it's handed, and
independently derives (from its own `current_priv`/`medeleg`/`mideleg`
state) which privilege a given trap actually lands in.

## 9. `plic.v` — prioritized, claimable external interrupts

A simplified real PLIC: `NUM_SOURCES` (default 8) level-triggered sources,
numbered 1..N (0 doesn't exist, matching the real convention), each with a
3-bit priority, feeding a single M-mode context through the standard
enable/threshold/claim-complete model. The piece a naive design tends to
omit: an `in_service` bit per source, set on claim and cleared on the
matching `complete` write — without it, a still-asserted level source
would look pending again immediately after claim, before software even
gets a chance to `complete` it, and the whole claim/complete protocol
wouldn't demonstrate anything real. A source can only (re-)become pending
while it isn't already in service. Claiming priority-encodes the
highest-priority pending+enabled+above-threshold source (ties go to the
lowest ID) — genuinely comparing priorities against each other, not just
picking the lowest matching ID, which is easy to get wrong (an earlier
draft of this module did exactly that; the fix is a running "best
candidate so far" comparison in the priority-encode loop).

Deliberately out of scope, documented rather than implicit: only one
context (M-mode) is implemented — no S-mode/`SEIP` delivery. Real `SEIP`
semantics (an OR of a hardware pin and a software-writable `mip` bit) are
a fiddly spec corner not worth risking in this pass. Sources are
level-triggered only, no edge-detect gateway configuration.

`top.v` decodes a 64KB window at `0x0300_0000` in front of the `dmem`
bus, alongside the pre-existing CLINT window at `0x0200_0000`. The PLIC's
single `eip` output feeds `cpu_core`'s `meip` port directly, so
`cpu_core.v` itself needed **no changes** for this feature — only
`top.v`/`top_fpga.v` wiring plus the new peripheral. `top.v`'s external
input changed from a single `irq_ext` wire to `irq_sources[7:0]`, one per
PLIC source; a new `dmem_re` output from `cpu_core.v` (asserted exactly
when a real load is reading a given cycle's `dmem_addr`) lets the PLIC
tell a genuine claim-register read apart from "this address just happens
to be on the bus" — `dmem_addr` is driven combinationally from EX every
cycle regardless of instruction type, so an unqualified address match
would spuriously claim on unrelated instructions.

## 10. `top.v` and `fpga/top_fpga.v` — integration

Same role as before: wire `cpu_core`, `imem`, and `dmem` together, plus
`clint` and `plic` and the address decode in front of them, both MMU
walkers' ports to `dmem`'s 2nd/3rd ports, and `irq_sources[7:0]` (was a
single `irq_ext` pin). `fpga/top_fpga.v` ties `irq_sources` low by default
(documented as a hook for board buttons/peripherals). The CPU's status
output, `trap`, still pulses for exactly one cycle whenever *any* trap or
interrupt redirect is taken.

## 11. Where this design stops (by design)

- **Single-issue, in-order** — one instruction fetched per cycle, no
  superscalar issue, no out-of-order execution, no register renaming, no
  reorder buffer/reservation stations/scoreboard. This is the natural
  next step, but it's a full microarchitecture redesign rather than an
  additive change like everything above — worth its own dedicated effort
  rather than bolting onto this pipeline.
- **A single external PLIC context** — M-mode only; no S-mode external
  interrupt delivery (`SEIP`).
- **No hypervisor extension** — only M/S/U, no virtualization.
- **No hardware PTE A/D auto-update** — a PTE missing Accessed (or Dirty,
  for a store) faults rather than being set automatically by the walker.
- **`MXR`/`SUM`/`TVM`/`TW`/`TSR`** in `mstatus` are hardwired 0 — real
  spec fields this core doesn't implement the semantics of yet.

These are exactly the gaps discussed in `README.md`'s section on what it
would take to run Linux — worth reading that section if you're wondering
"what's the next thing to add."
