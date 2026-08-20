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
# --word-size=2 matches sim/sdram_model.v, which is a 16-bit part: one
# entry per SDRAM word, little-endian, so entry N holds bytes 2N and 2N+1.
#
# Every size here is little-endian, which is the same choice made three
# times rather than one convention: RISC-V is little-endian, the packing
# below is little-endian, and rtl/soc/wb_sdram.v puts the low halfword in
# the lower column. A byte-lane test in sim/tb_sdram.v is what holds the
# third of those to the other two.
#
# --skip-words N emits N zero entries first, so the payload lands at a
# non-zero offset in the target array. That is how a program linked to run
# part-way into RAM gets preloaded into a bitstream: rtl/soc/wb_ram.v's
# $readmemh always starts at index 0, so the offset has to be in the file.
import argparse
import struct


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("--word-size", type=int, default=4, choices=(1, 2, 4))
    ap.add_argument("--skip-words", type=int, default=0,
                    help="emit this many zero entries before the payload")
    args = ap.parse_args()

    with open(args.input, "rb") as f:
        data = f.read()

    for _ in range(args.skip_words):
        print({1: "00", 2: "0000", 4: "00000000"}[args.word_size])

    if args.word_size == 1:
        for b in data:
            print(f"{b:02X}")
    elif args.word_size == 2:
        pad = (-len(data)) % 2
        data += b"\x00" * pad
        for i in range(0, len(data), 2):
            print(f"{struct.unpack_from('<H', data, i)[0]:04X}")
    else:
        pad = (-len(data)) % 4
        data += b"\x00" * pad
        for i in range(0, len(data), 4):
            word = struct.unpack_from("<I", data, i)[0]
            print(f"{word:08X}")


if __name__ == "__main__":
    main()
