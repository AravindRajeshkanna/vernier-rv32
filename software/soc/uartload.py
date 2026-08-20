#!/usr/bin/env python3
"""Send a program to the board's boot ROM over the serial console.

This is the host half of the protocol in software/soc/soc.h, and it exists
because it is the only way to get a program into external SDRAM on a board: a
bitstream initialises block RAM at FPGA configuration time, and SDRAM comes up
holding nothing.

    ./software/soc/uartload.py /dev/cu.usbserial-XXXX software/soc/sdramtest.bin
    # then press reset on the board

The order matters. The ROM listens for a knock only briefly after reset (see
UARTLOAD_WINDOW_MS), so this script knocks continuously and you press reset
into it. If you miss the window, press reset again - nothing here has to be
restarted.

Needs pyserial. It is not vendored and not in requirements anywhere, because
nothing else in this repo needs a serial port; `pip install pyserial`.
"""
import argparse
import binascii
import struct
import sys
import time

MAGIC = 0x55434F53          # 'S','O','C','U' little-endian
PROBE = b"\x55"             # 'U'
ACK   = 0x4B                # 'K'
NAK   = 0x45                # 'E'

# Must match soc.h. A load address outside these is refused by the ROM, which
# is the safe direction - but saying so here means the mistake is caught
# before a board has been reset, with a message that names both.
REGIONS = {
    "block RAM": (0x80000000, 0x00010000),
    "SDRAM":     (0x90000000, 0x01000000),
}


def region_of(addr, length):
    for name, (base, size) in REGIONS.items():
        if addr >= base and addr + length <= base + size:
            return name
    return None


def knock(port, timeout_s):
    """Bang on the door until the ROM answers, or give up.

    The ROM's window is short and opens at reset, so this cannot be a single
    attempt with a long read timeout: it has to be *in flight* at the moment
    the window opens.
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        port.write(PROBE)
        port.flush()
        r = port.read(1)
        if r and r[0] == ACK:
            return True
        # Anything else is the ROM's console output from a previous boot, or
        # line noise. Both are worth ignoring rather than reporting - the
        # board prints a banner every time it resets.
    return False


def expect_ack(port, what):
    """Read exactly one byte and require it to be an acknowledgement.

    Deliberately not "skip anything that isn't an ACK". The ROM prints nothing
    between the first acknowledgement and the last precisely so this can be
    strict - see the comment in software/soc/bootrom.c. Filtering by value
    would not work anyway: 'E' is the NAK byte and "UART LOAD FAILED" contains
    one, so a permissive reader would turn a progress message into a rejection.
    """
    r = port.read(1)
    if not r:
        sys.exit(f"error: no reply after {what} - is the board still running?")
    if r[0] == NAK:
        sys.exit(f"error: board rejected {what}; its console says why")
    if r[0] != ACK:
        sys.exit(f"error: unexpected reply 0x{r[0]:02X} ({chr(r[0])!r}) after "
                 f"{what} - the ROM should send nothing but acknowledgements "
                 f"during a transfer")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", help="serial device, e.g. /dev/cu.usbserial-XXXX")
    ap.add_argument("image", help="raw binary (objcopy -O binary), not an ELF")
    ap.add_argument("--addr", type=lambda v: int(v, 0), default=0x90000000,
                    help="load address (default 0x90000000, external SDRAM)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--knock-timeout", type=float, default=30.0,
                    help="how long to keep knocking, in seconds")
    args = ap.parse_args()

    try:
        import serial
    except ImportError:
        sys.exit("error: pyserial is not installed - `pip install pyserial`")

    with open(args.image, "rb") as f:
        payload = f.read()
    if not payload:
        sys.exit(f"error: {args.image} is empty")
    if payload[:4] == b"\x7fELF":
        sys.exit(f"error: {args.image} is an ELF; the ROM wants a raw binary "
                 f"(riscv64-unknown-elf-objcopy -O binary)")

    where = region_of(args.addr, len(payload))
    if where is None:
        sys.exit(f"error: {len(payload)} bytes at 0x{args.addr:08X} is not "
                 f"inside any region the ROM will accept "
                 f"({', '.join(REGIONS)}) - the board would refuse it")

    crc = binascii.crc32(payload) & 0xFFFFFFFF
    print(f"{len(payload)} bytes -> 0x{args.addr:08X} ({where}), "
          f"CRC32 {crc:08X}")

    port = __import__("serial").Serial(args.port, args.baud, timeout=0.05)

    print("knocking - press reset on the board", flush=True)
    if not knock(port, args.knock_timeout):
        sys.exit("error: the ROM never answered. Press reset while this is "
                 "running; the listening window is only a few milliseconds "
                 "wide and it opens at reset.")
    print("  ROM answered")

    port.write(struct.pack("<IIII", MAGIC, args.addr, len(payload), crc))
    port.flush()
    expect_ack(port, "header")

    # Stop-and-wait, a byte at a time. The board's UART receiver is one byte
    # deep (no FIFO), so this is what stops the host overwriting a byte the
    # ROM has not read yet - see the note in software/soc/soc.h. It costs a
    # round trip per byte: about 87 seconds for a 500 KB image at 115200
    # rather than 43, which is a fair price for not having to be right about
    # relative clock rates.
    port.timeout = 1.0
    sent = 0
    total = len(payload)
    for b in payload:
        port.write(bytes((b,)))
        expect_ack(port, f"the byte at offset {sent}")
        sent += 1
        if sent % 4096 == 0 or sent == total:
            pct = 100 * sent // total
            print(f"\r  sent {sent}/{total} ({pct}%)", end="", flush=True)
    print()

    expect_ack(port, "CRC check")
    print("  accepted; the board is running it\n")

    # From here the board is the program's console. Stream it until
    # interrupted, so a load and its output are one command rather than two.
    port.timeout = None
    try:
        while True:
            data = port.read(1)
            if data:
                sys.stdout.write(data.decode("latin-1"))
                sys.stdout.flush()
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
