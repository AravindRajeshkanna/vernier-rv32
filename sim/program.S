/* The hand-assembled RV32IMA regression program for sim/tb_top.v.
 *
 * This is the source of truth for sim/program.hex, which rtl/imem.v loads at
 * elaboration time. The hex is committed as well, so `make sim` needs no
 * RISC-V toolchain - that is the whole point of the hand-assembled test, and
 * it is why the `rtl` CI job can run with nothing but Icarus Verilog.
 *
 * `make check-program` reassembles this file and fails if the result differs
 * from the committed hex by a single byte. `make regen-program` rewrites the
 * hex from this file. Neither runs as part of a normal build.
 *
 * Provenance, stated plainly: this file was recovered by disassembling the
 * committed program.hex. The original was produced by a throwaway Python
 * encoder that was never in the repository, which left the program
 * unmodifiable - a 440-instruction binary with no source. The recovery is
 * verified the only way that means anything: reassembling it reproduces the
 * committed hex exactly.
 *
 * Labels are named for their byte offset, because the original had no symbol
 * names to recover.
 */
    .section .text
    .globl _start
_start:
    addi         ra,zero,5
    addi         sp,zero,10
    add          gp,ra,sp
    sw           gp,0(zero)
    lw           tp,0(zero)
    beq          gp, tp, L_0020
    addi         t0,zero,1
    jal          zero, L_0024
L_0020:
    addi         t0,zero,0
L_0024:
    addi         t1,zero,42
    sw           t1,8(zero)
    lw           t2,8(zero)
    addi         s0,t2,1
    addi         s1,zero,43
    beq          s0, s1, L_0040
    ori          t0,t0,2
L_0040:
    lui          a0,0x0
    addi         a0,a0,1400
    csrrw        zero,mtvec,a0
    lui          a4,0x0
    addi         a4,a4,11
    ecall
    lui          a4,0x0
    addi         a4,a4,2
    .word 0x042081b3    /* deliberately illegal: tests the trap */
    lui          a5,0x0
    addi         a5,a5,-1
    lui          a6,0x80000
    addi         a6,a6,0
    mul          s4,a5,a6
    mulh         s5,a5,a6
    mulhsu       s6,a5,a6
    mulhu        s7,a5,a6
    lui          a7,0x80000
    addi         a7,a7,0
    beq          s4, a7, L_0094
    ori          t0,t0,16
L_0094:
    lui          a7,0x0
    addi         a7,a7,0
    beq          s5, a7, L_00a4
    ori          t0,t0,16
L_00a4:
    lui          a7,0x0
    addi         a7,a7,-1
    beq          s6, a7, L_00b4
    ori          t0,t0,16
L_00b4:
    lui          a7,0x80000
    addi         a7,a7,-1
    beq          s7, a7, L_00c4
    ori          t0,t0,16
L_00c4:
    lui          a5,0x0
    addi         a5,a5,-7
    lui          a6,0x0
    addi         a6,a6,2
    div          s4,a5,a6
    divu         s5,a5,a6
    rem          s6,a5,a6
    remu         s7,a5,a6
    lui          a7,0x0
    addi         a7,a7,-3
    beq          s4, a7, L_00f4
    ori          t0,t0,32
L_00f4:
    lui          a7,0x80000
    addi         a7,a7,-4
    beq          s5, a7, L_0104
    ori          t0,t0,32
L_0104:
    lui          a7,0x0
    addi         a7,a7,-1
    beq          s6, a7, L_0114
    ori          t0,t0,32
L_0114:
    lui          a7,0x0
    addi         a7,a7,1
    beq          s7, a7, L_0124
    ori          t0,t0,32
L_0124:
    div          s8,a5,zero
    rem          s9,a5,zero
    lui          a7,0x0
    addi         a7,a7,-1
    beq          s8, a7, L_013c
    ori          t0,t0,32
L_013c:
    beq          s9, a5, L_0144
    ori          t0,t0,32
L_0144:
    lui          a5,0x80000
    addi         a5,a5,0
    lui          a6,0x0
    addi         a6,a6,-1
    div          s8,a5,a6
    rem          s9,a5,a6
    beq          s8, a5, L_0164
    ori          t0,t0,32
L_0164:
    beq          s9, zero, L_016c
    ori          t0,t0,32
L_016c:
    lui          a0,0x200c
    addi         a0,a0,-8
    lw           s2,0(a0)
    addi         s2,s2,40
    lui          a0,0x2004
    addi         a0,a0,0
    sw           s2,0(a0)
    lui          a0,0x2004
    addi         a0,a0,4
    sw           zero,0(a0)
    lui          s2,0x0
    addi         s2,s2,128
    csrrs        zero,mie,s2
    lui          s2,0x0
    addi         s2,s2,8
    csrrs        zero,mstatus,s2
    lui          t5,0x0
    addi         t5,t5,200
L_01b4:
    addi         t5,t5,-1
    bne          t5, zero, L_01b4
    lui          a0,0x4
    addi         a0,a0,0
    lui          a1,0x0
    addi         a1,a1,75
    sw           a1,0(a0)
    lui          a0,0x4
    addi         a0,a0,4
    lui          a1,0x1
    addi         a1,a1,1025
    sw           a1,0(a0)
    lui          a0,0x5
    addi         a0,a0,0
    lui          a1,0x2
    addi         a1,a1,-1849
    sw           a1,0(a0)
    lui          a0,0x5
    addi         a0,a0,4
    lui          a1,0x2
    addi         a1,a1,-957
    sw           a1,0(a0)
    lui          tp,0x0
    addi         tp,tp,740
    lui          a0,0x0
    addi         a0,a0,572
    csrrw        zero,mepc,a0
    lui          a0,0x2
    addi         a0,a0,-2048
    csrrc        zero,mstatus,a0
    lui          a0,0x1
    addi         a0,a0,-2048
    csrrs        zero,mstatus,a0
    mret
    lui          a0,0x80000
    addi         a0,a0,4
    csrrw        zero,satp,a0
    lui          s4,0x400
    addi         s4,s4,0
    lui          s5,0xabcd1
    addi         s5,s5,564
    sw           s5,0(s4)
    lw           s6,0(s4)
    beq          s6, s5, L_0268
    ori          t0,t0,64
L_0268:
    lui          a4,0x0
    addi         a4,a4,13
    lui          s7,0x800
    addi         s7,s7,0
    lw           s8,0(s7)
    lui          s9,0x401
    addi         s9,s9,0
    lw           s10,0(s9)
    csrrw        zero,satp,zero
    lui          a0,0x5
    addi         a0,a0,4
    lui          s11,0x2
    addi         s11,s11,-825
    sw           s11,0(a0)
    lui          a0,0x80000
    addi         a0,a0,4
    csrrw        zero,satp,a0
    lui          a4,0x0
    addi         a4,a4,15
    lui          t3,0x5a5a6
    addi         t3,t3,-1446
    sw           t3,0(s9)
    sfence.vma   zero,zero
    sw           t3,0(s9)
    lw           t4,0(s9)
    beq          t4, t3, L_02d4
    ori          t0,t0,128
L_02d4:
    csrrw        zero,satp,zero
    lui          a4,0x0
    addi         a4,a4,3
    ebreak
    lui          a0,0x0
    addi         a0,a0,256
    lui          a1,0x0
    addi         a1,a1,100
    sw           a1,0(a0)
    lui          a2,0x0
    addi         a2,a2,23
    amoadd.w     a3,a2,(a0)
    lui          a7,0x0
    addi         a7,a7,100
    beq          a3, a7, L_0314
    ori          t0,t0,512
L_0314:
    lw           s2,0(a0)
    lui          a7,0x0
    addi         a7,a7,123
    beq          s2, a7, L_0328
    ori          t0,t0,512
L_0328:
    lui          a2,0x0
    addi         a2,a2,999
    amoswap.w    a3,a2,(a0)
    lui          a7,0x0
    addi         a7,a7,123
    beq          a3, a7, L_0344
    ori          t0,t0,512
L_0344:
    lw           s2,0(a0)
    lui          a7,0x0
    addi         a7,a7,999
    beq          s2, a7, L_0358
    ori          t0,t0,512
L_0358:
    lr.w         s3,(a0)
    lui          a2,0x0
    addi         a2,a2,42
    sc.w         s4,a2,(a0)
    beq          s4, zero, L_0370
    ori          t0,t0,512
L_0370:
    lw           s2,0(a0)
    lui          a7,0x0
    addi         a7,a7,42
    beq          s2, a7, L_0384
    ori          t0,t0,512
L_0384:
    lr.w         s3,(a0)
    lui          a2,0x2
    addi         a2,a2,-415
    sw           a2,0(a0)
    lui          a2,0x0
    addi         a2,a2,55
    sc.w         s4,a2,(a0)
    lui          a7,0x0
    addi         a7,a7,1
    beq          s4, a7, L_03b0
    ori          t0,t0,512
L_03b0:
    lw           s2,0(a0)
    lui          a7,0x2
    addi         a7,a7,-415
    beq          s2, a7, L_03c4
    ori          t0,t0,512
L_03c4:
    lui          a0,0x0
    addi         a0,a0,1708
    csrrw        zero,stvec,a0
    lui          a0,0x0
    addi         a0,a0,256
    csrrw        zero,medeleg,a0
    lui          t1,0x0
    addi         t1,t1,0
    lui          s1,0x0
    addi         s1,s1,0
    lui          tp,0x0
    addi         tp,tp,1072
    lui          a0,0x0
    addi         a0,a0,1040
    csrrw        zero,mepc,a0
    lui          a0,0x2
    addi         a0,a0,-2048
    csrrc        zero,mstatus,a0
    mret
    lui          a4,0x0
    addi         a4,a4,8
    ecall
    lui          s1,0x7
    addi         s1,s1,1911
    lui          a4,0x0
    addi         a4,a4,3
    ebreak
    lui          t5,0x0
    addi         t5,t5,20
L_0438:
    addi         t5,t5,-1
    bne          t5, zero, L_0438
    lui          a0,0x3000
    addi         a0,a0,4
    lui          a1,0x0
    addi         a1,a1,3
    sw           a1,0(a0)
    lui          a0,0x3000
    addi         a0,a0,8
    lui          a1,0x0
    addi         a1,a1,5
    sw           a1,0(a0)
    lui          a0,0x3000
    addi         a0,a0,12
    lui          a1,0x0
    addi         a1,a1,1
    sw           a1,0(a0)
    lui          a0,0x3003
    addi         a0,a0,0
    lui          a1,0x0
    addi         a1,a1,2
    sw           a1,0(a0)
    lui          a0,0x3002
    addi         a0,a0,0
    lui          a1,0x0
    addi         a1,a1,14
    sw           a1,0(a0)
    lui          s9,0x0
    addi         s9,s9,0
    lui          s2,0x1
    addi         s2,s2,-2048
    csrrs        zero,mie,s2
    lui          t5,0x0
    addi         t5,t5,50
L_04c0:
    addi         t5,t5,-1
    bne          t5, zero, L_04c0
    lui          a0,0x4
    addi         a0,a0,12
    lui          a1,0x1
    addi         a1,a1,-2047
    sw           a1,0(a0)
    lui          a0,0x2
    addi         a0,a0,0
    lui          a1,0x1
    addi         a1,a1,-957
    sw           a1,0(a0)
    lui          a0,0x80000
    addi         a0,a0,4
    csrrw        zero,satp,a0
    lui          a4,0x0
    addi         a4,a4,12
    lui          tp,0x0
    addi         tp,tp,1332
    lui          a0,0x0
    addi         a0,a0,1320
    csrrw        zero,mepc,a0
    lui          a0,0x2
    addi         a0,a0,-2048
    csrrc        zero,mstatus,a0
    mret
    lui          a0,0xc00
    addi         a0,a0,0
    jalr         zero,0(a0)
    lui          t5,0x0
    addi         t5,t5,11
    beq          t6, t5, L_0544
    ori          t0,t0,256
L_0544:
    lui          a7,0x0
    addi         a7,a7,1
    beq          t1, a7, L_055c
    lui          s2,0x1
    addi         s2,s2,0
    or           t0,t0,s2
L_055c:
    lui          a7,0x7
    addi         a7,a7,1911
    beq          s1, a7, L_056c
    ori          t0,t0,1024
L_056c:
    csrrw        zero,satp,zero
    sw           t0,4(zero)
L_0574:
    jal          zero, L_0574
    addi         t6,t6,1
    csrrs        a1,mcause,zero
    blt          a1, zero, L_05c8
    lui          t4,0x0
    addi         t4,t4,3
    beq          a1, t4, L_05b4
    lui          t4,0x0
    addi         t4,t4,12
    beq          a1, t4, L_05b4
    beq          a1, a4, L_05a4
    ori          t0,t0,4
L_05a4:
    csrrs        a3,mepc,zero
    addi         a3,a3,4
    csrrw        zero,mepc,a3
    mret
L_05b4:
    csrrw        zero,mepc,tp
    lui          a0,0x2
    addi         a0,a0,-2048
    csrrs        zero,mstatus,a0
    mret
L_05c8:
    lui          t4,0x80000
    addi         t4,t4,7
    beq          a1, t4, L_05e8
    lui          t4,0x80000
    addi         t4,t4,11
    beq          a1, t4, L_060c
    ori          t0,t0,8
    jal          zero, L_06a8
L_05e8:
    lui          a0,0x2004
    addi         a0,a0,0
    lui          t4,0x0
    addi         t4,t4,-1
    sw           t4,0(a0)
    lui          a0,0x2004
    addi         a0,a0,4
    sw           t4,0(a0)
    jal          zero, L_06a8
L_060c:
    lui          a0,0x3003
    addi         a0,a0,4
    lw           s8,0(a0)
    addi         s9,s9,1
    lui          a7,0x0
    addi         a7,a7,1
    beq          s9, a7, L_0644
    lui          a7,0x0
    addi         a7,a7,2
    beq          s9, a7, L_0660
    lui          s2,0x1
    addi         s2,s2,-2048
    or           t0,t0,s2
    jal          zero, L_06a8
L_0644:
    lui          a7,0x0
    addi         a7,a7,2
    beq          s8, a7, L_06a8
    lui          s2,0x1
    addi         s2,s2,-2048
    or           t0,t0,s2
    jal          zero, L_06a8
L_0660:
    lui          a7,0x0
    addi         a7,a7,1
    beq          s8, a7, L_067c
    lui          s2,0x1
    addi         s2,s2,-2048
    or           t0,t0,s2
    jal          zero, L_06a8
L_067c:
    lui          s2,0x1
    addi         s2,s2,-2048
    csrrc        zero,mie,s2
    lui          a0,0x3003
    addi         a0,a0,4
    lui          a1,0x0
    addi         a1,a1,2
    sw           a1,0(a0)
    lui          a1,0x0
    addi         a1,a1,1
    sw           a1,0(a0)
L_06a8:
    mret
    addi         t1,t1,1
    csrrs        a1,scause,zero
    lui          t4,0x0
    addi         t4,t4,8
    beq          a1, t4, L_06c4
    ori          t0,t0,1024
L_06c4:
    csrrs        a3,sepc,zero
    addi         a3,a3,4
    csrrw        zero,sepc,a3
    lui          a4,0x0
    addi         a4,a4,9
    ecall
    sret
