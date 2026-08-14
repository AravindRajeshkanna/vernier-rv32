# Vernier-RV32 — Architecture

This document explains the Verilog source in `rtl/`, module by module, and
how it fits together into a complete RV32IMA CPU and the Wishbone SoC around
it. For setup and simulation instructions see `README.md`; for what has been
verified and how, see `tests/README.md`. This file is about the design
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
2-bit saturating-counter branch predictor**, and a **UART** peripheral —
which, together with a real `software/` build using
`riscv64-unknown-elf-gcc`, means this core now runs actual compiled C, not
just hand-assembled test programs (section 12). It's still single-issue
and in-order — no superscalar issue, no out-of-order execution/speculation
— see `README.md` for what that next step would look like.

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
 ├── plic.v                    (prioritized/claimable external interrupt controller)
 └── uart.v                    (TX+RX serial console)
```

`fpga/top_fpga.v` mirrors `top.v` but for real hardware — same modules,
wired to physical clock/reset/LED pins instead of a testbench. For the SoC
the equivalent is `fpga/soc_fpga.v`, with `fpga/ulx3s_top.v` adapting it to
one specific board's pin names, polarities and tie-offs.

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
load/store exactly as before. **AMO/LR/SC add a second write path in MEM
itself, split across two phases.** In the read phase the old value is
captured into `amo_rdata_q`; in the write phase an ALU
(`amoswap`/`amoadd`/`amoxor`/`amoand`/`amoor`/`amomin(u)`/`amomax(u)`)
computes from that register and its result becomes `dmem_wdata`. The old
value also reaches `rd` via `mem_result` — from `dmem_rdata` directly for
`LR.W`, which finishes in the read phase, and from `amo_rdata_q` for an RMW,
which finishes in the write phase and by then can no longer read it off
memory.

The split is a timing fix, not a functional necessity. Doing the whole
read-modify-write in one cycle works — `dmem.v`'s port is
combinational-read/synchronous-write, so the old value is visible before the
edge, exactly like an ordinary load — and that is what this stage used to do.
But it puts the memory's read port, the AMO comparators and the memory's
write-data port on one combinational chain, and that chain measured as the
whole design's critical path on an ECP5. `fpga/README.md` has the numbers.
The core owns the phase state (`amo_wr_phase`) because it is the only place
that knows what an AMO is; `rtl/soc/cpu_wb.v` used to run a second copy of
the same state machine and no longer does. A memory system reports back
through `dmem_rvalid` which cycle carried read data — tied high for
zero-latency memory, driven from the read acknowledgement on the bus.

`LR.W` sets a
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

Both now take an `INIT_FILE` parameter for `$readmemh`-preloading their
array — `imem`'s has existed since the beginning (the hand-assembled test
program); `dmem`'s (`INIT_FILE`, defaulting to `""` — empty, meaning
"unchanged, all-zero") is new, and exists specifically to preload a
compiled C program's `.rodata`/`.data` segment (section 12) without
needing runtime `sw` instructions to populate it, the way the
hand-assembled test's MMU page tables already do.

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

## 9a. `uart.v` — TX + RX serial console

A minimal memory-mapped UART, polled rather than interrupt-driven (same
"software checks a status bit" convention as the CLINT, rather than
adding another interrupt source): `TXDATA` (write starts a send if not
busy), `RXDATA` (read returns the last received byte, clearing
`STATUS.rx_valid`), `STATUS` (`tx_busy`/`rx_valid`). `CLKS_PER_BIT` is a
fixed module parameter (not a runtime baud-rate register — nothing here
needs to reconfigure it) — `top.v` uses a small value for fast
simulation, `fpga/top_fpga.v` a realistic one for an assumed board clock.

TX and RX are independent shift-register state machines (`IDLE → START →
8×DATA → STOP` and its mirror); RX runs the async `rx` pin through a 2-FF
synchronizer first. Reading `RXDATA` has a side effect (clearing
`rx_valid`), so — the same pitfall `plic.v`'s claim register has to avoid
— it needs a genuine "this cycle is a real load" signal (`re`, from
`cpu_core.v`'s `dmem_re`), not just an address match, since `dmem_addr` is
driven combinationally from EX every cycle regardless of instruction
type. When a same-cycle read-clear and a new-byte-arrival collide, the
arrival wins (scheduled last in the always block) — the other order would
silently drop the new byte's `rx_valid` flag while still overwriting its
data register, a real, if rare, data-loss bug worth avoiding deliberately
rather than by accident of statement order.

Documented simplification: no minimum idle-high gap is enforced before
re-arming for a new start bit, so a transmitter sending frames back-to-back
with *zero* gap between the stop bit and the next start bit could shift
the sampling point within that next byte. This core's own TX never does
that (always at least one idle cycle, and in practice many more from
software's own poll-loop overhead).

## 10. `top.v` and `fpga/top_fpga.v` — integration

Same role as before: wire `cpu_core`, `imem`, and `dmem` together, plus
`clint`/`plic`/`uart` and the address decode in front of them (`0x0200_
0000`/`0x0300_0000`/`0x0400_0000` respectively), both MMU walkers' ports
to `dmem`'s 2nd/3rd ports, `irq_sources[7:0]` (was a single `irq_ext`
pin), and `uart_tx`/`uart_rx`. `fpga/top_fpga.v` ties `irq_sources` low by
default (documented as a hook for board buttons/peripherals) and exposes
real `uart_tx`/`uart_rx` pins for a USB-serial adapter. `top.v` also
gained a `DMEM_INIT_FILE` parameter (default empty, unused by the
hand-assembled test) and bumped its default `IMEM_WORDS` from 1024 to
8192 — headroom for compiled programs (section 12), harmless to the
hand-assembled test, which uses well under either size. The CPU's status
output, `trap`, still pulses for exactly one cycle whenever *any* trap or
interrupt redirect is taken.

## 12. `software/` — a real `riscv64-unknown-elf-gcc` build

Every program before this update was hand-assembled by a throwaway Python
script directly into `sim/program.hex`. `software/` is a real, permanent
build flow alongside it (`sim/tb_top.v` and `sim/program.hex` are
untouched — see `README.md` for how the two coexist): `crt0.S` (startup:
set `gp`/`sp`, zero `.bss`, call `main`, spin forever), `link.ld`, a
`uart.c`/`.h` driver, `syscalls.c` (newlib stubs), and `main.c`, built
with `riscv64-unknown-elf-gcc` and turned into the two hex files `top.v`
preloads `imem`/`dmem` from.

Two real, non-obvious things came up getting this working, both worth
recording so they don't have to be rediscovered:

- **No exact `rv32ima` multilib exists** in this toolchain build — the
  precompiled variants are `rv32i`/`rv32im`/`rv32iac`/`rv32imac`/
  `rv32imafc`. Asking for `-march=rv32ima` directly doesn't fail loudly;
  it makes the linker silently fall back to a 64-bit libc and fail with a
  confusing "ABI is incompatible with... target emulation" error. The fix
  is `-march=rv32im -mabi=ilp32` — a strict subset of what this core
  implements, so nothing GCC emits can be an instruction this CPU doesn't
  support (the A extension just goes unexercised by compiled code; it's
  still covered by the hand-assembled test).
- **Full newlib printf is surprisingly large.** A trivial
  `printf("hi %d\n", 42)` program links to **~69KB** with the default
  (full) newlib — mostly `vfprintf`/float-formatting machinery — against
  this core's 4KB-by-default `imem`. `-specs=nano.specs` (newlib-nano,
  already bundled with this toolchain) gives the same real `printf` at
  **~9KB**. This is why `IMEM_WORDS` defaults to 8192 (32KB, ~3x headroom
  over that) rather than something enormous: this project uses
  newlib-nano, not full newlib.

**The Harvard linker script has one more real gotcha beyond "two `MEMORY`
regions both based at `ORIGIN = 0`"**: the linker's own load-address
(LMA) overlap check doesn't know these are two separate physical
memories — by default a section's LMA equals its VMA, so `.text` (ROM,
VMA/LMA both 0) and `.data` (RAM, VMA 0 too) collide in *LMA* space even
though they're going to entirely different arrays at runtime, and `ld`
refuses to link ("section .data LMA … overlaps section .text LMA …").
The fix is a third, fictitious, never-actually-loaded-from `MEMORY`
region (`RAM_LMA`, based at an arbitrary non-overlapping address) that
`.data` is told to use for its *LMA* only (`> RAM AT> RAM_LMA`), leaving
its *VMA* — the address that actually matters, since `dmem` is preloaded
directly rather than copied at boot — at 0. A related consequence: GNU
`objcopy -O verilog`'s `@address` output uses **LMA, not VMA** — feeding
that straight to `dmem`'s preload would produce addresses like
`@10000000`, nonsensical for a 32KB array based at 0. `software/Makefile`
rule instead uses `objcopy -O binary` (raw bytes, no address baked in) and
`software/bin2hex.py` to produce a plain sequential hex file, sidestepping
LMA/VMA entirely by relying on the fact that both `imem`'s and `dmem`'s
preloaded content is already known, by construction, to start at address
0.

## 12a. `rtl/soc/` — the Wishbone SoC

> For a **reference** rather than a rationale — every block's register map,
> the address map, and the traps waiting for firmware — see `docs/soc.md`.
> This section explains why the SoC is shaped the way it is; that one
> explains how to use it.

`rtl/top.v` (section 10) is a flat address decoder in front of two
zero-latency memories. `rtl/soc/soc_top.v` is the same CPU wired as an
actual system-on-chip: one unified address space, a real bus, a boot ROM
and storage. **Both exist**; the SoC did not replace the older top level,
because `sim/tb_top.v`'s hand-assembled regression test runs against
`rtl/top.v` and is worth keeping exactly as it is.

### The address map

| Base | Slave |
|---|---|
| `0x0000_0000` | Boot ROM (reset vector) |
| `0x0200_0000` | CLINT |
| `0x0300_0000` | PLIC |
| `0x0400_0000` | UART |
| `0x0500_0000` | GPIO |
| `0x0600_0000` | SPI |
| `0x0700_0000` | Framebuffer |
| `0x8000_0000` | Main RAM |

Decoded on `addr[31:24]`. CLINT/PLIC/UART keep the bases they already had,
so the drivers in `software/` work unchanged; RAM sits at `0x8000_0000`
where essentially every real RISC-V platform puts it, which is also what
makes `dts/soc.dts` look like an ordinary device tree.

### The framebuffer

`rtl/soc/wb_framebuffer.v` is a 320x240, 8-bit-per-pixel buffer in block RAM,
scanned out in raster order by `rtl/soc/video_timing.v`. A pixel is one byte
in **RRRGGGBB** direct colour, so there is no palette to program and no second
memory; the buffer is linear, so `(x,y)` is at `FB_BASE + y*320 + x` and a
single pixel is a plain `sb`.

It is a **display controller, not a GPU**: the CPU draws, this reads out.
There is no blitter and no second core. That matters for the bus - scan-out
uses the block RAM's *second port*, so the framebuffer adds no bus master and
the interconnect's two-master arbitration (section 11) is untouched.

Two details worth knowing:

- **The pixel path is two registers deep**, not one: raster position to
  address is combinational, the block RAM read costs a register, and the
  colour expansion costs another. The syncs are delayed to match. Getting
  that wrong shifts the whole image one pixel against the syncs, which is
  invisible on a monitor and was caught only because `sim/tb_video.v`
  compares captured pixels against what was written.
- **Nothing drives a display yet.** Scan-out runs in the CPU's own clock
  domain, so there is no clock-domain crossing anywhere in the video path.
  A real monitor needs a 25.175 MHz pixel clock from a PLL and a TMDS
  serializer above this; until then the video outputs leave `soc_fpga.v`
  unconnected and synthesis strips the scan-out logic, leaving only the
  buffer's block RAM. See `fpga/README.md`.

**This retires the Harvard wart.** Section 6 documented an awkward
consequence of `imem`/`dmem` being separate arrays both based at zero: a
PTE's PPN meant different things depending on which walker resolved it.
In the SoC there is one physical address space, and instruction fetch and
data access are separate *bus masters* rather than separate address
spaces, so a PPN now means exactly one thing.

### Teaching the pipeline to wait

The core assumed memory answered in the same cycle it was asked. A bus
doesn't, so `cpu_core.v` gained two inputs — `ibus_wait` and `dbus_wait` —
both of which `rtl/top.v` ties low, leaving that path bit-identical to
before (`make sim` still reports the same mispredict count, 54, which is a
usefully sensitive canary for accidental timing changes).

`ibus_wait` was easy: it folds into `if_stall`, which is exactly the shape
an ITLB-miss stall already had.

`dbus_wait` is a genuinely new stall shape and needed care in three places:

- **EX/MEM must *hold*, not bubble.** The request signals are driven
  straight off those registers, so bubbling would retract an in-flight bus
  request. It is checked ahead of `ex_busy_stall`, which it is otherwise a
  member of.
- **MEM/WB must also hold, not bubble.** This one is subtle: bubbling
  MEM/WB would tear down the MEM/WB *forwarding* path mid-stall, and
  whatever is sitting in EX may still depend on it. Re-writing the same
  register with the same data for a few extra cycles is idempotent; losing
  a forwarded operand is not. This is the same class of bug the
  `store_data_latched` snapshot (section 2c) exists to prevent.
- **Every EX-stage architectural side effect must be suppressed**
  (`ex_commit`). ID/EX is being held and will re-present the same
  instruction next cycle, so letting it redirect, write a CSR, take a trap,
  return from one, flush the TLB or train the predictor would do all of
  that twice. The pre-existing stalls never needed this, because the only
  instructions that could cause them were divides and memory accesses —
  neither of which writes a CSR or redirects. Under `dbus_wait` the
  instruction in EX can be anything.

The page-table walkers deliberately stayed *off* the bus, on a dedicated
read port into `wb_ram.v`. Page tables were already documented as living in
plain RAM, so bussing them would have bought nothing and cost bus
arbitration on top of the read-port arbitration they need anyway.

### The interconnect

`wb_interconnect.v` is a shared bus, not a crossbar: one master at a time,
so address/data/`we`/`sel` are a single broadcast copy and only `stb` is
decoded per slave. A load or store therefore costs the fetch behind it a
cycle — the classic single-port-memory tradeoff, taken deliberately for a
much smaller and more obviously-correct interconnect.

Arbitration is fixed priority, data over instruction — combinational while
the bus is idle, and **latched for the duration of a transfer**. Both halves
matter:

- **Combinational when idle** means starting a transfer costs nothing. A
  registered "go to GRANT state" arbiter would add a cycle to every access,
  fetches included.
- **Latched once under way** is what makes a multi-cycle slave safe. The
  memories are now synchronous block RAMs with a wait state (below), so a
  purely combinational grant would let the data master take the bus in the
  middle of the fetch master's read — and then the RAM's `ack`, which
  belongs to the fetch master's address, would be delivered to the data
  master along with the fetch master's data. Silent corruption, not a hang.

An earlier version of this design argued the lock was unimplementable
because stickiness plus combinational re-arbitration on `ack` forms a
combinational loop (`ack` → grant → `stb` → `ack`). That is true only if the
lock itself is combinational. **Registering it breaks the loop**: the grant
depends on `lock`, a flip-flop, and `lock`'s next value depends on `ack`, so
nothing goes round without passing through the register.

Atomics were previously safe purely because the data master always wins, and
still are — `cpu_wb.v` holds `cyc` across both phases of an AMO's
read-modify-write, so priority alone keeps anything else out of the gap. The
lock does not weaken it: when the read phase's ack releases the lock,
`m1_cyc` is still asserted, so the data master immediately wins
re-arbitration for the write phase.

One requirement the arbiter now depends on: **both masters must tie `stb` to
`cyc`.** It grants on `cyc` alone, so a master asserting `cyc` without `stb`
— legal Wishbone, a master holding the bus between transfers — would take
the bus and never strobe. `cpu_wb.v` drives each pair from one expression, so
this holds by construction, and `formal/fv_interconnect.v` assumes it
explicitly rather than leaving it as folklore.

Starvation isn't possible despite the fetch master always losing: a data
access is one transaction that then completes, and while it is outstanding
the whole pipeline is frozen, so nothing can queue behind it.

An access decoding to no slave is acked immediately with zero data rather
than left hanging — a bus that never acks would wedge the CPU permanently,
turning a stray pointer into a silent hang.

### The memories, and why they take a wait state

`wb_ram.v` and `wb_rom.v` are **synchronous, word-organized** memories: the
address goes in one cycle and the data comes out the next. This is not a
performance choice, it is what a block RAM is, and it is what makes the
design synthesizable at all — see `fpga/README.md` for the measurements. The
previous version was a byte array with *asynchronous* reads on three separate
ports, which is a fine simulation model and an impossible piece of hardware:
yosys cannot map an async read to a block RAM, so it built the array out of
flip-flops instead and full-SoC synthesis never terminated.

Three consequences ripple outward from that one change, and they are the
reason it was not a five-line edit:

1. **One wait state on every RAM and ROM access**, absorbed by the
   `ibus_wait`/`dbus_wait` machinery that already existed.
2. **The bus arbiter needed the lock** described above.
3. **`mmu.v`'s walker had to become a handshake.** It previously read a PTE
   combinationally and assumed the data was simply there. It now asserts
   `ptw_req` with an address, waits for `ptw_gnt`, and reads `ptw_rdata` in
   the following cycle — which also handles the fact that the two walkers now
   *share* one physical read port (block RAMs have two ports, and the bus
   takes one), arbitrated fixed-priority with the data walker first.
   `satp` is latched with the request for the same reason `va` always was: a
   walk now spans more cycles, and the instruction that writes `satp`
   executes in EX while a fetch-side walk may be in flight. An `SFENCE.VMA`
   during a walk now abandons it rather than installing an entry derived from
   page tables the fence has just declared stale.

The walk costs two extra cycles as a result. Walks only happen on a TLB miss,
so this is a good trade for main memory that can exist.

### `cpu_wb.v` — the adapter

Requests are issued *combinationally* rather than out of a state register, so
a transfer starts in the cycle it is requested; a registered "go to REQUEST
state" FSM would have added a cycle on top of the one the memories now cost.

**The fetch address is frozen for the duration of a transfer.** This became
necessary with the wait state: a branch resolving in EX asserts
`redirect_valid`, which overrides the PC freeze that `ibus_wait` would
otherwise hold, so `imem_addr` can change *underneath an in-flight fetch*.
The slave has already latched the old address, so its ack carries the old
word. `f_busy`/`f_addr` hold the bus address steady and tag the fetch buffer
with the address that was actually requested; `ack_for_current` is what stops
the core consuming a word that answers a question it is no longer asking. A
`FENCE.I` landing mid-fetch additionally poisons the in-flight result, so a
word that predates the writes the fence exists to publish is never cached
under a valid tag.

Two more pieces of real work happen here:

- **Byte lanes.** The core's native convention puts sub-word data in the
  *low* lanes with the exact byte address on the bus (what `dmem.v`
  implemented). Wishbone wants a word-aligned address plus `sel`, so the
  adapter shifts store data up into the addressed lane and load data back
  down. This assumes naturally-aligned accesses — true here, but an
  assumption.
- **Two-phase AMO.** `dmem_re` is *not* asserted for AMO/LR/SC (the core
  doesn't classify them as loads), so a new `dmem_is_amo` output is what
  says a read is needed at all. The read data is latched so it stays stable
  for the write phase, because the core recomputes `dmem_wdata`
  combinationally from whatever `dmem_rdata` currently shows.

There is also a one-entry fetch buffer, tagged with the full address. Its
real job isn't caching — it's to stop the fetch master re-requesting the
same word every cycle while the pipeline is held up by something else, and
in particular to stop it holding `cyc` permanently asserted.

### A real bug this found

The SoC's first full run passed every test except atomics, and the cause
was a latent ordering assumption rather than anything in the new code. An
SC both *reads* the reservation (to decide success) and *clears* it. With
zero-latency memory those happen in the same single cycle and the order
never mattered. Over a bus, an SC occupies MEM for several cycles, so
clearing it on the first pulled `sc_match` out from under the write phase:
the store was still issued, but reported failure. The fix is that the
reservation now holds across `dbus_stall`. Every other update in that
block is idempotent across a stall; that one is not — which is precisely
why it survived until a multi-cycle memory existed to expose it.

### Peripherals

`clint.v`, `plic.v` and `uart.v` needed **no changes** to join the bus —
`wb_periph_bridge.v` adapts their existing `addr/wdata/we/re/rdata`
convention, instantiated once each. The bridge is also where a real hazard
gets handled: the PLIC's claim register and the UART's RXDATA have *read
side effects*, so `re` is gated on the interconnect's `s_data_master`,
ensuring a stray instruction fetch into MMIO space can't claim an interrupt
or eat a received byte. MMIO registers are word-accessed by convention;
a sub-word access to one would go through the adapter's lane shifting and
is not something the peripherals model.

`wb_gpio.v` and `wb_spi.v` are native Wishbone. The SPI master is
deliberately the one slave with **real multi-cycle wait states** — a DATA
write withholds `ack` until all 8 bits have shifted. That makes the driver
trivial (a byte exchange is one store plus one load, no polling), and more
importantly it is what actually exercises `dbus_wait` end to end; every
other slave acks combinationally and would have left that logic unverified.

### Boot flow

`software/soc/bootrom.c` runs from ROM at the reset vector: bring up the
console, initialize the SD card over SPI, read a header block, pull the
program image into RAM and jump to it. It is freestanding — no libc, no
`.data` — so it can't be broken by an image that hasn't been copied in yet.
`link_rom.ld` asserts `.data` is empty rather than silently producing a
broken image, since `crt0_rom.S` has no ROM-to-RAM copy loop.

`sim/tb_soc.v` runs the whole thing with a simulated SD card
(`sim/sd_card_model.v`, implementing CMD0/8/55/58, ACMD41 and CMD17) and
decodes the UART line back into console text. Nothing is preloaded into
RAM, so the output is real evidence the entire chain works.

## 12b. Platform features for supervisor firmware

Bringing OpenSBI into scope exposed a set of things this core either lacked
or reported incorrectly. All are now implemented and covered by
`make sim_soc`; `software/opensbi/README.md` has the firmware-side view.

- **`misa` now advertises `I`+`M`+`A`** (`0x4000_1101`). It previously
  claimed `I` alone, which was simply wrong - the M and A extensions have
  been implemented for several revisions. It isn't cosmetic: firmware and
  operating systems read `misa` to decide what the hart can do, so
  under-reporting makes them disable working hardware.
- **Counter CSRs.** `cycle`/`time`/`instret`, their RV32 `h` halves, the
  machine-level `mcycle`/`minstret` they are views of, and
  `mcounteren`/`scounteren` to gate access from lower privilege. `time` is
  wired to the **CLINT's `mtime`** rather than being a private counter,
  because SBI timer code reads `time` and programs `mtimecmp` from it - two
  unrelated clocks there would produce timer interrupts at nonsense
  intervals.
- **Misaligned-access traps** (cause 4 load, cause 6 store/AMO, `mtval` =
  the faulting address). This core has never supported misaligned accesses -
  `cpu_wb.v`'s byte-lane shifting assumes natural alignment - but until now
  it *silently mis-executed* them rather than trapping. Trapping is what the
  spec requires of an implementation that doesn't support them, and it is
  the mechanism by which M-mode firmware emulates them.
- **`FENCE.I` is no longer a no-op.** `cpu_wb.v`'s one-entry fetch buffer is
  not coherent with writes, so a loader that copies code into RAM and jumps
  to it could fetch a stale word. `FENCE.I` now invalidates the buffer and
  redirects to PC+4 so anything already fetched behind it is re-fetched.

### The operand-drift trap, found again

Adding the misalignment check reintroduced a bug this project had already
met once, in a new place, and it is worth recording because the shape
recurs.

`mem_addr_ex` is `op1 + id_ex_imm`, and `op1` comes from *live forwarding*.
During a multi-cycle MMU walk the rest of the pipeline keeps draining
underneath the stalled instruction, so those forwarding sources go away and
the computed address decays to a stale value. `mmu.v` is immune because it
snapshots `va_r` on the walk's first cycle, and store data is immune because
of `store_data_latched` - both existing defenses against exactly this.

The new alignment check had no such defense, so several cycles into a walk
it re-evaluated a decayed address and invented a misalignment fault for a
perfectly aligned load. The regression caught it: a load that should have
page-faulted (cause 13) instead reported cause 4 with an effective address
of `1` while the register file plainly held `0x00800000`.

The fix is `!mmu_busy` in the condition - a misaligned access never starts a
walk, so a walk in progress always implies the address was already judged
aligned on cycle one, making "not mid-walk" exactly the right window to
decide this in.

## 12c. Verification

Four layers, each answering something the one before it cannot. `make verify`
runs all of them; `tests/README.md` is the detailed writeup.

| Layer | Question | Result |
|---|---|---|
| Directed tests | Does the feature I just wrote work? | `make sim`, `make sim_soc` pass |
| riscv-tests | Does this implement *RISC-V*, judged by somebody else's suite? | 79 pass, 3 xfail |
| Spike co-simulation | Did it execute the *same instructions* as the reference model? | 82/82 traces match |
| Formal (yosys + z3) | Does this module hold for *every* input? | 4 proved, bound 12 cycles |

The layering is not redundancy. A directed test only catches what its author
thought to assert. An architectural test catches what the ISA requires but
still only checks an end-of-program verdict — a core can reach the right
answer through a wrong sequence. Co-simulation closes that by diffing every
retired instruction `(pc, insn, rd, value)` against Spike. And formal closes
what neither can: the PLIC's arbitration is a function of 8 priorities, 8
enables, 8 pending bits and a threshold, and no test suite is going to
enumerate 2^30 configurations.

### The retire trace

`cpu_core.v` carries shadow PC/instruction registers down the pipeline and
exposes a one-line-per-retired-instruction trace, printed by `sim/tracer.v`
and diffed by `tests/cosim.py`. Two decisions in it are load-bearing:

- The shadow registers ride **inside the existing pipeline-register `always`
  blocks**. A parallel block would have to restate every stall and flush
  condition and would drift the first time one changed — precisely the shape
  of the operand-drift bug in §12b. Riding along makes the trace incapable of
  disagreeing with the pipeline.
- A **trapping instruction is not traced**, because it does not retire. Spike
  draws the same line (an exception line instead of a commit line), and
  matching that definition is what makes the two traces comparable at all.

`instret_retire` — the same signal — also feeds `minstret`, which is now
counted at the *end of EX* rather than at MEM. Every exception this core can
raise is resolved by then, so nothing downstream can cancel an instruction
that gets that far; the old MEM-based count included trapping instructions,
which by definition do not retire.

### What it found

Fifteen real bugs, listed in full in `tests/README.md`. The three worth
repeating here because they are architectural rather than cosmetic:

**The MMU never checked the PTE's `U` bit.** `mmu.v` checked V/R/W/X/A/D and
simply ignored U, so U-mode could read *and execute* supervisor pages, and
S-mode could freely touch user pages. The entire user/supervisor isolation
boundary — the reason U mode exists — was absent. Fixing it required adding
`mstatus.SUM` and `MXR` too, since S-mode's legitimate access to user memory
is gated on SUM.

That fix broke the legacy hand-assembled test, in an instructive way: its
page table maps everything as one supervisor superpage (`U=0`) and then drops
to U-mode and keeps executing, which is architecturally impossible once the
check exists. The test had been depending on the missing check. Its U-mode
and S-mode code are interleaved in the same 4 KB pages, so it cannot be fixed
without regenerating the program; the Part 13 note in `sim/tb_top.v` records
exactly what it now does and does not demonstrate.

**`mcycle` and `minstret` were driven from two `always` blocks at once** —
the free-running increment in one, the CSR write in another. That is a
multiple-driver conflict: undefined in simulation (whichever block the
simulator evaluates last wins) and rejected outright by synthesis. They are
now one block each, with the spec's priority made explicit — a write wins
over the tick and suppresses it on *both* halves of the 64-bit counter.

**An AMO was permission-checked as a load.** The data MMU's `is_store` input
was `id_ex_is_store`, which excludes AMOs, so an atomic read-modify-write
against a read-only page would translate successfully and then write it. LR
is correctly still a read, which is also how Spike models it.

## 13. Where this design stops (by design)

- **Single-issue, in-order** — one instruction fetched per cycle, no
  superscalar issue, no out-of-order execution, no register renaming, no
  reorder buffer/reservation stations/scoreboard. This is the natural
  next step, but it's a full microarchitecture redesign rather than an
  additive change like everything above — worth its own dedicated effort
  rather than bolting onto this pipeline.
- **A single external PLIC context** — M-mode only; no S-mode external
  interrupt delivery (`SEIP`).
- **No hypervisor extension** — only M/S/U, no virtualization.
- **The UART is polled, not interrupt-driven**, and `software/`'s libc is
  newlib-nano, not full newlib — `printf`'s float formatting is disabled
  by default under nano (`-u _printf_float` at the link line re-enables
  it, at a size cost) and no compiled program uses the A extension
  (`-march=rv32im`, a strict subset of what this core implements).
- **No hardware PTE A/D auto-update** — a PTE missing Accessed (or Dirty,
  for a store) faults rather than being set automatically by the walker.
- **No PMP** (`pmpcfg`/`pmpaddr`) and **no debug-spec triggers**
  (`tselect`/`tdata`). These are the only two features the RISC-V
  architectural test suite fails this core on — see
  `tests/expected-failures.txt`.
- **The SoC is memory-limited.** 64 KB of
  on-chip RAM in the FPGA configuration (256 KB in simulation), no external
  DRAM controller (`wb_ram.v`'s header marks the seam where one would go),
  no JTAG debug module (`docs/debug.md` sets out exactly what one would
  take), no Ethernet. The design builds to a **bitstream** on an
  ULX3S, closes timing at 25 MHz against that board's real pinout —
  30.77 MHz measured post-route on an LFE5U-85F, 28.78 MHz on a 45F — and
  **runs on an 85F**, where it boots and passes its acceptance test. The SD
  card and the video pins are the parts a board has not yet settled; see
  `fpga/README.md`. The measured critical path is **75% routing** and
  only 8 ns of logic — the design is wire-bound rather than logic-bound, so
  floorplanning is worth more than shortening logic. Where exactly that path
  lands moves from build to build: `fpga/README.md` records three consecutive
  builds, two of them differing by changes that altered no CPU logic at all,
  landing in three different places. Read that before attributing any Fmax
  change to anything.
- **No caches.** Every fetch and every load goes to the bus. With a
  shared-bus interconnect that also means a load or store costs the fetch
  behind it a cycle.

These are exactly the gaps discussed in `README.md`'s section on what it
would take to run Linux — worth reading that section if you're wondering
"what's the next thing to add."
