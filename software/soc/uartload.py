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

Needs nothing but the standard library, deliberately.

It used to `import serial`, which cost a bench session: `pip` is not always on
PATH, `pipx install pyserial` puts the library in an isolated virtualenv where
nothing can import it, and `#!/usr/bin/env python3` can pick a different
interpreter from the one the package landed in. The failure then reads
"pyserial is not installed" on a machine where it demonstrably is, at the exact
moment somebody is trying to find out whether a *hardware* loader works.

Nothing else in this repo needs a third-party Python package and this does not
either: a serial port on macOS or Linux is `termios` plus `os.read`, both of
which have been in the standard library for thirty years.
"""
import argparse
import binascii
import os
import select
import struct
import sys
import termios
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
    # 32 MB, the whole part. This said 16 MB until a kernel image needed the
    # upper half: wb_interconnect.v decoded addr[31:24] by equality then, so
    # one base byte bought one 16 MB slave. It decodes through a per-slave
    # mask now and dts/soc.dts declares the full 0x02000000.
    "SDRAM":     (0x90000000, 0x02000000),
}


def region_of(addr, length):
    for name, (base, size) in REGIONS.items():
        if addr >= base and addr + length <= base + size:
            return name
    return None


class Serial:
    """A raw 8N1 serial port, from the standard library.

    Deliberately small: open, configure, read with a timeout, write. That is
    the whole of what this script needs from a UART.
    """

    def __init__(self, device, baud):
        self.eof = False
        try:
            self.fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        except OSError as e:
            sys.exit(f"error: cannot open {device}: {e.strerror}")

        try:
            speed = getattr(termios, f"B{baud}")
        except AttributeError:
            sys.exit(f"error: {baud} is not a baud rate termios knows about")

        # Raw 8N1, no flow control, no modem-control lines, no echo, and no
        # translation of any kind - CR and NUL are data here, not line
        # discipline. CLOCAL because the FTDI's DCD is not wired to anything.
        iflag = oflag = lflag = 0
        cflag = termios.CS8 | termios.CREAD | termios.CLOCAL

        # The control-character array has to be exactly NCCS entries, and NCCS
        # is not the same everywhere - 20 on macOS, 32 on Linux. Take the
        # port's own and change the two that matter, rather than building one
        # from a guessed length: tests/uartload_host.py caught that guess on
        # its first run, which is a better place to find it than a bench.
        cc = list(termios.tcgetattr(self.fd)[6])
        cc[termios.VMIN] = 0
        cc[termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW,
                          [iflag, oflag, cflag, lflag, speed, speed, cc])
        termios.tcflush(self.fd, termios.TCIOFLUSH)

    def write(self, data):
        while data:
            n = os.write(self.fd, data)
            data = data[n:]

    def read(self, n, timeout):
        """Up to `n` bytes, or fewer if `timeout` seconds pass first."""
        out = b""
        deadline = time.monotonic() + timeout
        while len(out) < n:
            left = deadline - time.monotonic()
            if left <= 0:
                break
            if not select.select([self.fd], [], [], left)[0]:
                break
            try:
                chunk = os.read(self.fd, n - len(out))
            except OSError:
                self.eof = True          # the far end went away
                break
            if not chunk:
                self.eof = True          # readable but empty is end-of-file
                break
            out += chunk
        return out


def knock(port, timeout_s):
    """Bang on the door until the ROM answers, or give up.

    The ROM's window is short and opens at reset, so this cannot be a single
    attempt with a long read timeout: it has to be *in flight* at the moment
    the window opens.
    """
    # Knock *fast*. The ROM listens for about 23 ms after reset - a 3 ms
    # banner plus its 20 ms window - so the probe interval is what decides
    # whether a reset is caught. This waited 50 ms for a reply between
    # probes, which made it roughly a coin toss per reset; 2 ms makes missing
    # the window essentially impossible, and costs nothing because the reply
    # arrives in well under a millisecond when it arrives at all.
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        port.write(PROBE)
        r = port.read(1, 0.002)
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
    r = port.read(1, 1.0)
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

    # Stop-and-wait costs a round trip per byte: one frame out, one frame
    # back, ten bits each. Worth printing for anything large, because a
    # multi-megabyte image is twenty minutes and a progress bar that has not
    # moved for a while is otherwise indistinguishable from a hang.
    secs = len(payload) * 20.0 / args.baud
    if secs > 60:
        print(f"  at {args.baud} baud that is about {secs / 60:.0f} minutes - "
              f"it is stop-and-wait,\n  a round trip per byte (see below)")

    port = Serial(args.port, args.baud)

    print("knocking - press reset on the board", flush=True)
    if not knock(port, args.knock_timeout):
        sys.exit("error: the ROM never answered. Press reset while this is "
                 "running; the listening window is only a few milliseconds "
                 "wide and it opens at reset.")
    print("  ROM answered")

    port.write(struct.pack("<IIII", MAGIC, args.addr, len(payload), crc))
    expect_ack(port, "header")

    # Stop-and-wait, a byte at a time. The board's UART receiver is one byte
    # deep (no FIFO), so this is what stops the host overwriting a byte the
    # ROM has not read yet - see the note in software/soc/soc.h. It costs a
    # round trip per byte: about 87 seconds for a 500 KB image at 115200
    # rather than 43, which is a fair price for not having to be right about
    # relative clock rates.
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
    try:
        while not port.eof:
            data = port.read(1, 60.0)
            if data:
                sys.stdout.write(data.decode("latin-1"))
                sys.stdout.flush()
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
