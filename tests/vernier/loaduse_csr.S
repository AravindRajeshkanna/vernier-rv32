# See LICENSE for license details.

#*****************************************************************************
# loaduse_csr.S
#-----------------------------------------------------------------------------
#
# A store whose base register is written by the load right before it, with a
# CSR write in front of that.
#
# This is Linux's put_user(), reduced to the four instructions that matter.
# `software/linux/README.md` has how it was found; the shape is:
#
#     lui   a5, 0x40          # a5 = 0x00040000, the sstatus.SUM bit
#     csrs  sstatus, a5       # let the kernel touch user memory
#     lw    a5, 16(sp)        # a5 = the user pointer
#     sw    s5, 0(a5)         # the store
#
# The wide core faulted on that `sw` with stval = 0x00040000 - which is the
# value `lui` put in a5, not the value `lw` put there. The store used the
# register as it was two instructions earlier.
#
# What makes it worth a test of its own rather than a note: the load-use
# hazard between the `lw` and the `sw` is the ordinary one, and riscv-tests
# covers ordinary load-use thoroughly. What it does not cover is a load-use
# pair *behind a CSR write*, and CSR writes redirect on this design. So the
# case is the interaction, not either half.
#
# The check is on the address the store actually used, which no probe in this
# project sees: co-simulation compares (pc, instruction, rd, value) per
# retired instruction, and a store writes no register. A store to the wrong
# address is invisible to it. Reading the destination back is what catches it.
#

#include "riscv_test.h"
#include "test_macros.h"

# RVTEST_RV32M, not RVTEST_RV32U: the `p` environment's U variant leaves the
# test in user mode, where `csrs sstatus` is an illegal instruction and this
# file traps before reaching any case. That is not a subtlety about the core -
# it is what the environment is for - but it cost a build to notice, because
# the failure reports as `ISA-FAIL subtest=669` and 669 is the trap handler's
# `TESTNUM | 1337`, not a case number.
RVTEST_RV32M
RVTEST_CODE_BEGIN

  # The p environment does not initialise `sp`, so the spill slots the kernel
  # sequence reads from are a data label here rather than the stack. That is
  # the only difference from the code in the header, and it does not touch the
  # hazard: what matters is that the store's base comes from a load.
  la      t1, scratch
  la      t0, slots

  # ---- 1: the sequence as the kernel has it -------------------------------
  li      TESTNUM, 2
  sw      t1, 0(t0)               # the "user pointer", in a spill slot
  li      s5, 0xABCD1234          # the value to store
  li      a5, 0                   # scrub, so a stale a5 cannot be a pass
  sw      zero, 0(t1)

  lui     a5, 0x40                # a5 = 0x00040000  (sstatus.SUM)
  csrs    sstatus, a5             # the CSR write that precedes the load
  lw      a5, 0(t0)               # a5 = the pointer
  sw      s5, 0(a5)               # <- the store under test
  lui     a5, 0x40
  csrc    sstatus, a5

  lw      t2, 0(t1)
  li      t3, 0xABCD1234
  bne     t2, t3, fail

  # ---- 2: the same, with the load feeding the store's data --------------
  # rs2 rather than rs1, because the hazard check has to cover both source
  # fields and only one of them is exercised above.
  li      TESTNUM, 3
  li      s5, 0x5A5A0F0F
  sw      s5, 4(t0)
  sw      zero, 0(t1)

  lui     a5, 0x40
  csrs    sstatus, a5
  lw      a5, 4(t0)               # a5 = the value
  sw      a5, 0(t1)               # <- store whose *data* is the load result
  lui     a5, 0x40
  csrc    sstatus, a5

  lw      t2, 0(t1)
  li      t3, 0x5A5A0F0F
  bne     t2, t3, fail

  # ---- 3: no CSR write, the plain load-use case ---------------------------
  # Here so a failure says which of the two ingredients matters. If this one
  # fails too, the CSR write is incidental and the defect is plain load-use.
  li      TESTNUM, 4
  li      s5, 0x0BADF00D
  sw      t1, 8(t0)
  sw      zero, 0(t1)

  li      a5, 0x00040000          # the same stale value, no CSR involved
  lw      a5, 8(t0)
  sw      s5, 0(a5)

  lw      t2, 0(t1)
  li      t3, 0x0BADF00D
  bne     t2, t3, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
  .align 3
scratch:
  .word 0
  .word 0
slots:
  .word 0
  .word 0
  .word 0
  .word 0

RVTEST_DATA_END
