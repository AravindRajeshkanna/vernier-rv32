#!/usr/bin/env python3
"""Pack a stub, a device tree and OpenSBI into one SDRAM image.

The layout is fixed here and mirrored in software/opensbi/sbi_stub.S, which
has to know where the DTB and the firmware ended up:

    0x9000_0000   the stub, entered from reset
    0x9000_8000   the device tree blob
    0x9001_0000   OpenSBI, linked to run at exactly this address

Emits the $readmemh form sim/sdram_model.v and the Verilator harness both
load: one 16-bit little-endian word per line, because the part is 16 bits
wide.  Gaps are zero-filled, which is what an unwritten SDRAM word reads as
in the model anyway.

Usage: mkimage.py <stub.bin> <soc.dtb> <fw_jump.bin> > image.hex
"""
import sys

BASE      = 0x90000000
DTB_OFF   = 0x00008000
FW_OFF    = 0x00010000


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    stub, dtb, fw = (open(p, "rb").read() for p in sys.argv[1:4])

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
