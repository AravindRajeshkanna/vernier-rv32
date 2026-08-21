#!/usr/bin/env python3
"""Check a built kernel against the ISA this core actually implements.

The configuration is not enough on its own, and this project has already
been bitten twice by assuming it was:

  - CONFIG_EFI is `default y` on riscv and `select RISCV_ISA_C`, so turning
    the C extension off in a fragment silently gets you compressed
    instructions anyway. software/linux/kconfig-merge.py catches that one.
  - arch/riscv/Makefile appends `_zacas` and `_zabha` to -march whenever the
    *toolchain* supports them, keyed on symbols with no prompt. The compiler
    is then free to emit `amocas` for an atomic builtin, and no Kconfig
    option would stop it.

Either produces a kernel that traps on an instruction rtl/ does not decode,
in S-mode, before the console driver has probed - which is the failure mode
this whole SoC is worst at diagnosing. So the finished binary is read back
and every mnemonic in it checked against a list of what the hardware has.

Usage: isacheck.py --objdump=PREFIX-objdump <vmlinux>
"""
import re
import subprocess
import sys

# rv32i, as implemented by rtl/cpu_core.v and rtl/ooo/core_ooo.v, plus every
# pseudo-instruction spelling objdump uses for one. The pseudo-ops are not
# separate hardware - `mv` is `addi rd,rs,0` - but the disassembler prints
# them, so the list has to.
RV32I = """
lui auipc jal jalr beq bne blt bge bltu bgeu lb lh lw lbu lhu sb sh sw
addi slti sltiu xori ori andi slli srli srai add sub sll slt sltu xor srl
sra or and fence ecall ebreak
nop mv not neg seqz snez sltz sgtz beqz bnez blez bgez bltz bgtz bgt ble
bgtu bleu j jr ret call tail li la zext.b unimp
"""

# rv32m and rv32a.
RV32M = "mul mulh mulhsu mulhu div divu rem remu"
RV32A = """
lr.w sc.w amoswap.w amoadd.w amoxor.w amoand.w amoor.w amomin.w amomax.w
amominu.w amomaxu.w
"""

# Zicsr and Zifencei. rdtime/rdtimeh are csrr of the time CSR, which
# rtl/csr_file.v implements directly from the CLINT's mtime rather than
# leaving to be trapped and emulated by M-mode.
ZICSR = """
csrrw csrrs csrrc csrrwi csrrsi csrrci csrr csrw csrs csrc csrwi csrsi csrci
rdcycle rdcycleh rdtime rdtimeh rdinstret rdinstreth
"""
ZIFENCEI = "fence.i"

# The privileged instructions the core implements: M/S/U with Sv32.
PRIV = "mret sret wfi sfence.vma"

# The A extension's ordering suffixes are part of the mnemonic as objdump
# prints them, so every amo* and lr/sc above also appears as .aq, .rl and
# .aqrl. Generated rather than listed.
AMO_SUFFIXES = ("", ".aq", ".rl", ".aqrl")

# Encodings that are in the image but can never execute on this hart, with
# the reason. Anything here is reported and counted, but does not fail:
# a *change* in the count is what would be worth looking at.
#
# Svinval has no CONFIG_ symbol - unlike Zacas or Zbb, it cannot be
# configured out - so arch/riscv/mm/tlbflush.c always compiles the
# sinval.vma path in and selects it at run time with has_svinval(). That
# reads riscv_isa_extension_available(), which is populated from
# `riscv,isa-extensions` in the device tree; dts/soc.dts does not list
# svinval, so the branch is never taken.
INERT = {
    0x18000073: "sfence.w.inval (Svinval, unreachable: not in riscv,isa-extensions)",
    0x18100073: "sfence.inval.ir (Svinval, unreachable: not in riscv,isa-extensions)",
}
INERT_MASKED = [
    # sinval.vma rs1, rs2 - funct7 0x0B, opcode SYSTEM, rd and funct3 zero.
    (0xFE007FFF, 0x16000073,
     "sinval.vma (Svinval, unreachable: not in riscv,isa-extensions)"),
]

# The 64-byte RISC-V Image header sits immediately after the entry branch in
# .head.text and is data, not code. objdump disassembles it anyway.
IMAGE_HEADER_BYTES = 0x40

LINE = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(.*)$")
SYMBOL = re.compile(r"^([0-9a-f]+)\s+<(.+)>:$")


def allowed():
    words = set()
    for group in (RV32I, RV32M, ZICSR, ZIFENCEI, PRIV):
        words |= set(group.split())
    for mnemonic in RV32A.split():
        for suffix in AMO_SUFFIXES:
            words.add(mnemonic + suffix)
    return words


def main():
    objdump = "riscv64-unknown-elf-objdump"
    args = []
    for a in sys.argv[1:]:
        if a.startswith("--objdump="):
            objdump = a[len("--objdump="):]
        else:
            args.append(a)
    if len(args) != 1:
        sys.exit(__doc__)
    vmlinux = args[0]

    try:
        dis = subprocess.check_output([objdump, "-d", vmlinux], text=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        sys.exit(f"could not disassemble {vmlinux}: {exc}")

    ok = allowed()
    entry = None
    sym = "?"
    bad = []
    inert = {}
    total = 0

    for line in dis.splitlines():
        m = SYMBOL.match(line.strip())
        if m:
            sym = m.group(2)
            if entry is None:
                entry = int(m.group(1), 16)
            continue

        m = LINE.match(line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        enc  = int(m.group(2), 16)
        text = m.group(3).split()
        if not text:
            continue
        mnemonic = text[0]
        total += 1

        # The Image header, which is data.
        if entry is not None and entry < addr < entry + IMAGE_HEADER_BYTES:
            continue

        if mnemonic in ok:
            continue

        reason = INERT.get(enc)
        if reason is None:
            for mask, value, why in INERT_MASKED:
                if enc & mask == value:
                    reason = why
                    break
        if reason is not None:
            inert[reason] = inert.get(reason, 0) + 1
            continue

        bad.append((addr, enc, " ".join(text), sym))

    print(f"  {total} instructions checked against rv32ima_zicsr_zifencei "
          f"+ the privileged set", file=sys.stderr)
    for reason, count in sorted(inert.items()):
        print(f"  {count:>4} x {reason}", file=sys.stderr)

    if not bad:
        print("  no instruction outside what rtl/ implements", file=sys.stderr)
        return 0

    print(f"\n{len(bad)} instruction(s) this core cannot execute:\n",
          file=sys.stderr)
    for addr, enc, text, sym in bad[:40]:
        print(f"  {addr:08x}  {enc:08x}  {text:<28} in <{sym}>",
              file=sys.stderr)
    if len(bad) > 40:
        print(f"  ... and {len(bad) - 40} more", file=sys.stderr)
    print("\nThis kernel would take an illegal-instruction trap in S-mode, "
          "most likely\nbefore the console driver has probed. Check the ISA "
          "string arch/riscv/Makefile\nbuilt (make ... V=1) rather than the "
          "Kconfig options - they are not the same.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
