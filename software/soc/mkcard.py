#!/usr/bin/env python3
"""Build the SD card image the boot ROM loads a program from.

Layout (see software/soc/soc.h, which the boot ROM reads it with):
  block 0        header: magic 'SOC1' then the image length, little-endian
  block 1..N     the program image, zero-padded to a block boundary

Two output formats, because simulation and hardware want different things:

  mkcard.py <image.bin> <blocks> > card.hex
      One hex byte per line, which is what $readmemh into a byte array wants.
      This is what sim/sd_card_model.v loads.

  mkcard.py --binary <image.bin> <blocks> card.img
      Raw bytes, to be written to a real card's first blocks with dd. The hex
      form cannot be used for this - it is ASCII, three bytes per byte - and
      writing it to a card produces one that the boot ROM will reject for a
      bad magic, which is a confusing way to discover a format mismatch.

  <blocks> is the total card size in 512-byte blocks. The hex output is padded
  out to fill it, because $readmemh warns when the file is shorter than the
  array it is loading into. The binary output is *not* padded: it is written
  to the front of a real card that is already however large it is, and padding
  would mean pointlessly writing megabytes of zeros.
"""
import sys

BLOCK = 512
MAGIC = 0x31434F53  # 'S','O','C','1' little-endian


def main() -> int:
    args = sys.argv[1:]
    binary_out = None
    if args and args[0] == "--binary":
        args = args[1:]
        if len(args) != 3:
            sys.stderr.write(__doc__)
            return 1
        binary_out = args[2]
        args = args[:2]

    if len(args) != 2:
        sys.stderr.write(__doc__)
        return 1

    image = open(args[0], "rb").read()
    total_blocks = int(args[1], 0)

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
    if binary_out is not None:
        # Unpadded: only the blocks that carry something.
        with open(binary_out, "wb") as f:
            f.write(card)
        sys.stderr.write(
            f"; {binary_out}: {len(card)} bytes "
            f"({len(card) // BLOCK} blocks), image {len(image)} bytes\n")
        return 0

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
