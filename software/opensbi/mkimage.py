#!/usr/bin/env python3
"""Pack a stub, a device tree and OpenSBI into one SDRAM image.

The layout is fixed here and mirrored in software/opensbi/sbi_stub.S, which
has to know where the DTB and the firmware ended up:

    0x9000_0000   the stub, entered from reset
    0x9000_8000   the device tree blob
    0x9008_0000   OpenSBI, linked to run at exactly this address

and checks that OpenSBI's own preconditions hold before writing anything.
That check is the point of passing the ELF in as well as the binary: get the
load address wrong and OpenSBI does not complain, it calls sbi_hart_hang()
in a `wfi` loop *before* the console exists, which is indistinguishable from
the firmware never having started. Failing here, at build time, with the
numbers in the message, is worth the twenty lines.

Emits the $readmemh form sim/sdram_model.v and the Verilator harness both
load: one 16-bit little-endian word per line, because the part is 16 bits
wide.  Gaps are zero-filled, which is what an unwritten SDRAM word reads as
in the model anyway.

Usage: mkimage.py [--nm=PREFIX-nm] <stub.bin> <soc.dtb> <fw_jump.bin> \
                  <fw_jump.elf> > image.hex
"""
import subprocess
import sys

BASE      = 0x90000000
DTB_OFF   = 0x00008000
FW_OFF    = 0x00080000


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


def main():
    nm = "riscv64-unknown-elf-nm"
    args = []
    for a in sys.argv[1:]:
        if a.startswith("--nm="):
            nm = a[5:]
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

    image = bytearray(FW_OFF + len(fw))
    image[0:len(stub)] = stub
    image[DTB_OFF:DTB_OFF + len(dtb)] = dtb
    image[FW_OFF:FW_OFF + len(fw)] = fw

    if len(image) % 2:
        image.append(0)
    for i in range(0, len(image), 2):
        sys.stdout.write("%04x\n" % (image[i] | (image[i + 1] << 8)))

    print(f"; stub {len(stub)}B, dtb {len(dtb)}B, opensbi {len(fw)}B, "
          f"image {len(image)}B ({len(image)//1024} KB)", file=sys.stderr)


if __name__ == "__main__":
    main()
