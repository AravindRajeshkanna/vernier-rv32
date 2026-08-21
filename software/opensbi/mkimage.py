#!/usr/bin/env python3
"""Pack a stub, a device tree, OpenSBI and optionally Linux into one image.

The layout is fixed here and mirrored in software/opensbi/sbi_stub.S, which
has to know where the DTB and the firmware ended up:

    0x9000_0000   the stub, entered from reset
    0x9000_8000   the device tree blob
    0x9008_0000   OpenSBI, linked to run at exactly this address
    0x9040_0000   the Linux Image, if --kernel was given
    0x91E0_0000   where fw_jump relocates the device tree for the next stage

and checks that OpenSBI's own preconditions hold before writing anything.

One image rather than several is the point. software/soc/uartload.py sends a
single blob to a single address, so a kernel packed here needs no second
transfer, no second load address to get right, and no `linux,initrd-*` in the
device tree - the initramfs is inside the Image (CONFIG_INITRAMFS_SOURCE).
That check is the point of passing the ELF in as well as the binary: get the
load address wrong and OpenSBI does not complain, it calls sbi_hart_hang()
in a `wfi` loop *before* the console exists, which is indistinguishable from
the firmware never having started. Failing here, at build time, with the
numbers in the message, is worth the twenty lines.

Emits the $readmemh form sim/sdram_model.v and the Verilator harness both
load: one 16-bit little-endian word per line, because the part is 16 bits
wide.  Gaps are zero-filled, which is what an unwritten SDRAM word reads as
in the model anyway.

`--bin=PATH` additionally writes the flat image, which is what
software/soc/uartload.py sends to a board: the hex form is for simulation
and the binary is for hardware, and they must be the same bytes, so one
script emits both rather than two agreeing by inspection.

Usage: mkimage.py [--nm=PREFIX-nm] [--kernel=Image] [--bin=PATH] \
                  <stub.bin> <soc.dtb> <fw_jump.bin> <fw_jump.elf> > image.hex
"""
import subprocess
import sys

BASE      = 0x90000000
DTB_OFF   = 0x00008000
FW_OFF    = 0x00080000
KERN_OFF  = 0x00400000     # FW_JUMP_ADDR
FDT_OFF   = 0x01E00000     # FW_JUMP_FDT_ADDR: written by OpenSBI, not by us,
                           # and above the kernel because arch/riscv drops
                           # every memory range below the kernel's own load
                           # address. See build-opensbi.sh.
SDRAM_SZ  = 0x02000000     # the whole part; see dts/soc.dts memory@90000000

# arch/riscv/include/asm/image.h. The second magic is the current one; the
# first was deprecated in v5.11 and is zero on new kernels.
IMAGE_MAGIC2 = 0x05435352  # "RSC\x05"


def symbols(elf, nm):
    """{name: address} for the handful of symbols the checks below need."""
    out = {}
    try:
        listing = subprocess.check_output([nm, elf], text=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        sys.exit(f"could not read symbols from {elf}: {exc}")
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) == 3:
            out[parts[2]] = int(parts[0], 16)
    return out


def check_opensbi_layout(elf, nm):
    """Refuse a layout sbi_domain_init() would reject.

    OpenSBI's linker script puts the read-write sections at the next power-of-2
    boundary above the read-only ones, and sbi_domain_init() then requires that
    (_fw_rw_start - _fw_start) is a power of two *and* that _fw_start is
    aligned to it. Both only hold when FW_TEXT_START is itself aligned to that
    rounded size, which is not obvious and is not checked anywhere in the
    OpenSBI build - it is checked at run time, on a machine with no console.
    """
    sym = symbols(elf, nm)
    try:
        fw_start = sym["_fw_start"]
        fw_rw    = sym["_fw_rw_start"]
    except KeyError as missing:
        sys.exit(f"{elf}: no {missing} symbol - is this an OpenSBI firmware ELF?")

    want = BASE + FW_OFF
    if fw_start != want:
        sys.exit(f"OpenSBI is linked at 0x{fw_start:08x} but this image packs "
                 f"it at 0x{want:08x}.\n"
                 f"Rebuild it with FW_TEXT_START=0x{want:08x}.")

    rw_offset = fw_rw - fw_start
    if rw_offset == 0 or (rw_offset & (rw_offset - 1)) != 0:
        sys.exit(f"_fw_rw_start - _fw_start is 0x{rw_offset:x}, which is not a "
                 f"power of two.\n"
                 f"sbi_domain_init() rejects that and hangs with no console. "
                 f"FW_TEXT_START must be\naligned to the power-of-2 size of "
                 f"OpenSBI's read-only sections.")
    if fw_start & (rw_offset - 1):
        sys.exit(f"_fw_start 0x{fw_start:08x} is not aligned to the "
                 f"read-write offset 0x{rw_offset:x}.\n"
                 f"sbi_domain_init() rejects that and hangs with no console.")

    print(f"; opensbi _fw_start 0x{fw_start:08x}, rw offset 0x{rw_offset:x} "
          f"(power of two, aligned)", file=sys.stderr)


def check_kernel(image):
    """Refuse a kernel that does not want to be where we are putting it.

    The RISC-V Image header carries `text_offset`, the offset from the start
    of usable RAM the kernel is built to run at - 4 MB on rv32, because
    setup_vm() maps the kernel with Sv32 megapages. OpenSBI enters at
    FW_JUMP_ADDR, which this script has to place it at, and nothing connects
    the two: get it wrong and the kernel relocates itself onto its own page
    tables and dies in S-mode before any console exists.
    """
    if len(image) < 64:
        sys.exit(f"kernel image is {len(image)} bytes, too short to hold a "
                 f"RISC-V Image header")

    magic2      = int.from_bytes(image[56:60], "little")
    text_offset = int.from_bytes(image[8:16],  "little")
    image_size  = int.from_bytes(image[16:24], "little")

    if magic2 != IMAGE_MAGIC2:
        sys.exit(f"kernel magic is 0x{magic2:08x}, not 0x{IMAGE_MAGIC2:08x} "
                 f'("RSC\\x05").\n'
                 f"That is not an arch/riscv/boot/Image - a vmlinux ELF and a "
                 f"compressed\nImage.gz both fail this check, and both look "
                 f"plausible in a file listing.")

    if text_offset != KERN_OFF:
        sys.exit(f"kernel wants to run at RAM + 0x{text_offset:x} but this "
                 f"image packs it at RAM + 0x{KERN_OFF:x}.\n"
                 f"Change KERN_OFF here and FW_JUMP_ADDR in "
                 f"software/opensbi/build-opensbi.sh together.")

    # image_size is the runtime footprint including .bss, which is bigger
    # than the file. It is what has to fit, not len(image).
    end = KERN_OFF + image_size
    if end > FDT_OFF:
        sys.exit(f"kernel needs 0x{image_size:x} bytes at 0x{BASE+KERN_OFF:08x}, "
                 f"ending at 0x{BASE+end:08x},\nwhich runs into the device tree "
                 f"OpenSBI relocates to 0x{BASE+FDT_OFF:08x} (FW_JUMP_FDT_ADDR).")
    if end > SDRAM_SZ:
        sys.exit(f"kernel needs 0x{image_size:x} bytes at 0x{BASE+KERN_OFF:08x}, "
                 f"ending at 0x{BASE+end:08x},\nwhich is past the "
                 f"{SDRAM_SZ // (1024*1024)} MB this SoC decodes.")

    print(f"; kernel text_offset 0x{text_offset:x}, runtime size "
          f"0x{image_size:x} ({image_size // 1024} KB)", file=sys.stderr)
    return image_size


def main():
    nm = "riscv64-unknown-elf-nm"
    kernel_path = None
    bin_path = None
    args = []
    for a in sys.argv[1:]:
        if a.startswith("--nm="):
            nm = a[5:]
        elif a.startswith("--kernel="):
            kernel_path = a[len("--kernel="):]
        elif a.startswith("--bin="):
            bin_path = a[len("--bin="):]
        else:
            args.append(a)
    if len(args) != 4:
        sys.exit(__doc__)

    check_opensbi_layout(args[3], nm)
    stub, dtb, fw = (open(p, "rb").read() for p in args[:3])

    if len(stub) > DTB_OFF:
        sys.exit(f"stub is {len(stub)} bytes, which runs into the DTB at "
                 f"0x{DTB_OFF:x}")
    if len(dtb) > FW_OFF - DTB_OFF:
        sys.exit(f"device tree is {len(dtb)} bytes, which runs into OpenSBI "
                 f"at 0x{FW_OFF:x}")

    kernel = b""
    if kernel_path is not None:
        kernel = open(kernel_path, "rb").read()
        check_kernel(kernel)
        if FW_OFF + len(fw) > KERN_OFF:
            sys.exit(f"OpenSBI is {len(fw)} bytes at 0x{FW_OFF:x}, which runs "
                     f"into the kernel at 0x{KERN_OFF:x}")

    size = FW_OFF + len(fw) if not kernel else KERN_OFF + len(kernel)
    image = bytearray(size)
    image[0:len(stub)] = stub
    image[DTB_OFF:DTB_OFF + len(dtb)] = dtb
    image[FW_OFF:FW_OFF + len(fw)] = fw
    if kernel:
        image[KERN_OFF:KERN_OFF + len(kernel)] = kernel

    if bin_path is not None:
        with open(bin_path, "wb") as f:
            f.write(image)

    if len(image) % 2:
        image.append(0)
    for i in range(0, len(image), 2):
        sys.stdout.write("%04x\n" % (image[i] | (image[i + 1] << 8)))

    parts = (f"; stub {len(stub)}B, dtb {len(dtb)}B, opensbi {len(fw)}B"
             + (f", kernel {len(kernel)}B" if kernel else ""))
    print(f"{parts}, image {len(image)}B ({len(image)//1024} KB)",
          file=sys.stderr)


if __name__ == "__main__":
    main()
