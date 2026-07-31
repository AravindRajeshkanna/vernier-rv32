#include <stdio.h>

int main(void) {
    printf("Hello from RV32IMA!\n");
    printf("This is real C, compiled with riscv64-unknown-elf-gcc,\n");
    printf("running on a from-scratch RISC-V core, printing over a\n");
    printf("simulated UART.\n");

    for (int i = 0; i < 5; i++) {
        printf("i = %d\n", i);
    }

    printf("done.\n");

    while (1) {
        /* nothing left to do - spin forever */
    }
    return 0;
}
