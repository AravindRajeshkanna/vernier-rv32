/* PID 1 for the initramfs, with no libc.
 *
 * This is the last link in the chain the rest of this repository exists to
 * build: reset vector -> stub -> OpenSBI -> Linux -> here. Reaching this
 * file's first `write` means the core took a userspace ELF through Sv32
 * translation, an S-mode trap, and back, on hardware this project wrote.
 *
 * Why no libc: there is no rv32 *Linux* userspace toolchain on this machine.
 * The one cross compiler here is riscv64-unknown-elf, which is bare metal -
 * its newlib knows nothing about Linux system calls. Building a musl or
 * glibc for riscv32 means building a second toolchain, which is hours of
 * work and a large dependency for a program whose entire job is to prove the
 * kernel got here. `ecall` is a two-line inline asm and it is the same
 * instruction a libc would emit; see docs/practices.md section 22 for the
 * general form of this argument, and software/soc/console.c for the same
 * decision taken one privilege level down.
 *
 * The system call numbers are the asm-generic set, which is what rv32 uses.
 * They are written out rather than included from <asm/unistd.h> so this file
 * has no include path into the kernel tree.
 */

#define SYS_mount        40
#define SYS_openat       56
#define SYS_close        57
#define SYS_read         63
#define SYS_write        64
#define SYS_exit_group   94
#define SYS_reboot      142
#define SYS_uname       160
#define SYS_getpid      172

#define AT_FDCWD        (-100)
#define O_RDONLY        0

#define STDOUT          1

/* reboot(2)'s magic numbers. The second one is Linus' daughter's birthday,
 * which is not a joke and is load-bearing: the kernel rejects any other. */
#define RB_MAGIC1       0xfee1deadU
#define RB_MAGIC2       672274793U
#define RB_POWER_OFF    0x4321fedcU

typedef unsigned int u32;

static inline long syscall5(long n, long a, long b, long c, long d, long e)
{
    register long a7 __asm__("a7") = n;
    register long a0 __asm__("a0") = a;
    register long a1 __asm__("a1") = b;
    register long a2 __asm__("a2") = c;
    register long a3 __asm__("a3") = d;
    register long a4 __asm__("a4") = e;
    __asm__ volatile ("ecall"
                      : "+r"(a0)
                      : "r"(a1), "r"(a2), "r"(a3), "r"(a4), "r"(a7)
                      : "memory");
    return a0;
}

static long syscall0(long n)                        { return syscall5(n, 0, 0, 0, 0, 0); }
static long syscall1(long n, long a)                { return syscall5(n, a, 0, 0, 0, 0); }
static long syscall3(long n, long a, long b, long c) { return syscall5(n, a, b, c, 0, 0); }
static long syscall4(long n, long a, long b, long c, long d)
                                                    { return syscall5(n, a, b, c, d, 0); }

static unsigned slen(const char *s)
{
    unsigned n = 0;
    while (s[n])
        n++;
    return n;
}

static void put(const char *s)
{
    unsigned n = slen(s), done = 0;
    while (done < n) {
        long w = syscall3(SYS_write, STDOUT, (long)(s + done), (long)(n - done));
        if (w <= 0)                 /* nothing useful to do about it here */
            return;
        done += (unsigned)w;
    }
}

static void putdec(long v)
{
    char buf[12];
    int i = (int)sizeof(buf);

    buf[--i] = '\0';
    if (v == 0)
        buf[--i] = '0';
    while (v > 0) {
        buf[--i] = (char)('0' + (v % 10));
        v /= 10;
    }
    put(&buf[i]);
}

/* struct new_utsname: six NUL-terminated fields of exactly 65 bytes. */
#define UTS_LEN 65

static void banner(void)
{
    char uts[6 * UTS_LEN];

    put("\n");
    put("=== VERNIER-RV32: USERSPACE ===\n");

    if (syscall1(SYS_uname, (long)uts) == 0) {
        put("kernel  : ");
        put(&uts[0 * UTS_LEN]);         /* sysname */
        put(" ");
        put(&uts[2 * UTS_LEN]);         /* release */
        put("\n");
        put("machine : ");
        put(&uts[4 * UTS_LEN]);         /* machine */
        put("\n");
    } else {
        put("uname failed\n");
    }

    put("pid     : ");
    putdec(syscall0(SYS_getpid));
    put("\n");
}

/* Copy a whole procfs file to the console.
 *
 * /proc/cpuinfo is worth the CONFIG_PROC_FS this costs: it prints the ISA
 * string the kernel parsed out of dts/soc.dts and the mmu it decided it has,
 * so a boot that gets here has demonstrated the device tree was believed as
 * well as read. A procfs file also has no size until it is read, which
 * exercises a path a regular file would not.
 */
static void cat(const char *path)
{
    char buf[512];
    long fd = syscall4(SYS_openat, AT_FDCWD, (long)path, O_RDONLY, 0);

    if (fd < 0) {
        put("cannot open ");
        put(path);
        put("\n");
        return;
    }
    for (;;) {
        long n = syscall3(SYS_read, fd, (long)buf, (long)sizeof(buf));
        if (n <= 0)
            break;
        syscall3(SYS_write, STDOUT, (long)buf, n);
    }
    syscall1(SYS_close, fd);
}

void init_main(void)
{
    banner();

    if (syscall5(SYS_mount, (long)"proc", (long)"/proc", (long)"proc", 0, 0) == 0) {
        put("\n--- /proc/cpuinfo ---\n");
        cat("/proc/cpuinfo");
    } else {
        put("mount /proc failed\n");
    }

    /* The line the simulation gate greps for, and the one the Verilator
     * harness' +stopon watches for so a passing run ends in a minute instead
     * of running out +maxcycles. Last, so that seeing it means everything
     * above it also ran.
     *
     * Hyphenated because a plusarg is a single shell word: +stopon= cannot
     * carry a space. */
    put("\n=== VERNIER-RV32-LINUX-BOOT-OK ===\n");

    /* Ask the firmware to stop the machine. Whether this works depends on
     * OpenSBI advertising SRST, which the generic platform only does when
     * the device tree describes a reset device - ours does not, so expect
     * this to return. It is still worth trying: on a build that does have
     * one, it turns a simulation that runs to +maxcycles into one that ends.
     */
    syscall4(SYS_reboot, (long)RB_MAGIC1, (long)RB_MAGIC2, (long)RB_POWER_OFF, 0);

    /* PID 1 exiting is a kernel panic, and a panic here would overwrite the
     * result above with a failure that is not one. Spin instead.
     *
     * Not `wfi`: the spec permits an implementation to trap that in U-mode,
     * and taking an illegal-instruction fault one line after declaring
     * success is precisely the sort of ending that gets misread. */
    for (;;)
        __asm__ volatile ("" ::: "memory");
}
