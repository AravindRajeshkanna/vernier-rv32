#!/usr/bin/env python3
# Packs a raw binary (from `objcopy -O binary --only-section=...`) into a
# plain $readmemh-compatible hex file: one value per line, loaded
# sequentially starting at index 0 (no @address directives needed, since
# both rtl/imem.v's and rtl/dmem.v's preloaded content starts at address
# 0 by construction - see software/link.ld).
#
# --word-size=4 (default) matches rtl/imem.v's 32-bit-word array (used
# for the .text segment, imem being fetch-only and word-addressed).
# --word-size=1 matches rtl/dmem.v's byte array (used for the
# .rodata/.data segment, dmem being byte-addressable).
import argparse
import struct


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("--word-size", type=int, default=4, choices=(1, 4))
    args = ap.parse_args()

    with open(args.input, "rb") as f:
        data = f.read()

    if args.word_size == 1:
        for b in data:
            print(f"{b:02X}")
    else:
        pad = (-len(data)) % 4
        data += b"\x00" * pad
        for i in range(0, len(data), 4):
            word = struct.unpack_from("<I", data, i)[0]
            print(f"{word:08X}")


if __name__ == "__main__":
    main()
