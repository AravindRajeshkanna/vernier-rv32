#!/usr/bin/env python3
"""Program for sim/tb_soc_2hart_coherence.v: two harts, each polling a word the
other writes, so a stale cached copy shows up as a hang or an old value.

Words are at RAM base + 0x200: X (+0), flag (+4), done (+8), result (+12),
Z (+16), go2 (+20), result2 (+24).
  hart 0: X = OLD; read X (cached); flag = 1; poll done until nonzero;
          read X; result = X; then Z = NEW2; go2 = 1
  hart 1: read Z (cached, still 0); poll flag until nonzero; X = NEW;
          done = 1; poll go2 until nonzero; read Z; result2 = Z
Round one has hart 0 holding words hart 1 writes (X, done); round two has
hart 1 holding words hart 0 writes (Z, go2), so each hart's cache is the one
that has to drop a line. A cache that does not leaves hart 0 spinning on
done or reading OLD, or hart 1 spinning on go2 or reading Z as 0.
"""
import sys

def i_type(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 7) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F)
def u_type(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F)
def s_type(imm, rs1, rs2, f3, op):
    return (((imm >> 5) & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 7) << 12) | ((imm & 0x1F) << 7) | (op & 0x7F)
def b_type(imm, rs1, rs2, f3, op):
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((f3 & 7) << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | (op & 0x7F)
def j_type(imm, rd, op):
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | ((rd & 0x1F) << 7) | (op & 0x7F)

def LW(rd, off, rs1):
    return i_type(off, rs1, 2, rd, 0x03)


def SW(rs2, off, rs1):
    return s_type(off, rs1, rs2, 2, 0x23)


def ADDI(rd, rs1, imm):
    return i_type(imm, rs1, 0, rd, 0x13)


def LUI(rd, imm20):
    return u_type(imm20, rd, 0x37)


def BEQ(rs1, rs2, off):
    return b_type(off, rs1, rs2, 0, 0x63)


def BNE(rs1, rs2, off):
    return b_type(off, rs1, rs2, 1, 0x63)


SPIN = j_type(0, 0, 0x6F)

hart0 = [
    ADDI(2, 2, 0x200),     # x2 = &X
    LUI(3, 0x11111),       # OLD = 0x11111000
    SW(3, 0, 2),           # X = OLD (a full-word store allocates the line)
    LW(4, 0, 2),           # read X: hit, X is resident
    ADDI(6, 0, 1),
    SW(6, 4, 2),           # flag = 1
    LW(7, 8, 2),           # L: poll done
    BEQ(7, 0, -4),         #    until nonzero
    LW(8, 0, 2),           # read X again: must be NEW
    SW(8, 12, 2),          # result = X
    LUI(9, 0x33333),       # NEW2 = 0x33333000
    SW(9, 16, 2),          # Z = NEW2
    SW(6, 20, 2),          # go2 = 1
    SPIN,
]
hart1 = [
    ADDI(2, 2, 0x200),     # x2 = &X
    LW(9, 16, 2),          # read Z: now cached, and 0
    LW(7, 4, 2),           # L: poll flag
    BEQ(7, 0, -4),         #    until nonzero
    LUI(3, 0x22222),       # NEW = 0x22222000
    SW(3, 0, 2),           # X = NEW
    ADDI(6, 0, 1),
    SW(6, 8, 2),           # done = 1
    LW(7, 20, 2),          # L: poll go2
    BEQ(7, 0, -4),         #    until nonzero
    LW(10, 16, 2),         # read Z again: must be NEW2
    SW(10, 24, 2),         # result2 = Z
    SPIN,
]
head = [
    i_type(0xF14, 0, 2, 1, 0x73),  # csrrs x1, mhartid, x0
    LUI(2, 0x80000),               # x2 = RAM base
]
bne_at = len(head)
words = head + [None] + hart0
hart1_at = len(words)
words[bne_at] = BNE(1, 0, 4 * (hart1_at - bne_at))
words += hart1
for w in words:
    sys.stdout.write('%08X\n' % (w & 0xFFFFFFFF))
