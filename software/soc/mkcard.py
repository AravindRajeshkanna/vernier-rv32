#!/usr/bin/env python3
"""Build the SD card image that sim/sd_card_model.v loads.

Layout (see software/soc/soc.h, which the boot ROM reads it with):
  block 0        header: magic 'SOC1' then the image length, little-endian
  block 1..N     the program image, zero-padded to a block boundary

Emits one hex byte per line, which is what $readmemh into a byte array wants.

Usage: mkcard.py <image.bin> <blocks> > card.hex
  <blocks> is the total card size in 512-byte blocks; the card model's array
  is that size, and $readmemh warns if the file is shorter than the array, so
  the output is padded out to fill it.
"""
import sys

BLOCK = 512
MAGIC = 0x31434F53  # 'S','O','C','1' little-endian


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write(__doc__)
        return 1

    image = open(sys.argv[1], "rb").read()
    total_blocks = int(sys.argv[2], 0)

    header = bytearray(BLOCK)
    header[0:4] = MAGIC.to_bytes(4, "little")
    header[4:8] = len(image).to_bytes(4, "little")

    payload = bytearray(image)
    if len(payload) % BLOCK:
        payload += bytes(BLOCK - (len(payload) % BLOCK))

    card = bytes(header) + bytes(payload)
    if len(card) > total_blocks * BLOCK:
        sys.stderr.write(
            f"error: image needs {len(card)} bytes but the card is only "
            f"{total_blocks * BLOCK}\n")
        return 1
    card += bytes(total_blocks * BLOCK - len(card))

    out = sys.stdout
    for b in card:
        out.write(f"{b:02X}\n")

    sys.stderr.write(
        f"; card: {total_blocks} blocks, image {len(image)} bytes "
        f"({(len(image) + BLOCK - 1) // BLOCK} blocks)\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
