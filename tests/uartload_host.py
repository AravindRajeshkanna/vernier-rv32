#!/usr/bin/env python3
"""Run software/soc/uartload.py against a fake board, over a real pty.

The boot ROM's half of this protocol is tested by sim/tb_uartload.v, against
the actual RTL. The *host's* half had nothing at all - which is how it shipped
depending on a third-party package that turned out not to be importable on the
machine it was written for, and how the knock could sit at a rate that misses
the ROM's window half the time. Neither is visible without running it.

So this is the other side of the same protocol, in Python, on a pty: the script
under test cannot tell the difference between this and an FTDI cable, because
it is talking to a real terminal device through real termios.

    python3 tests/uartload_host.py

No board, no toolchain, no simulator - it is the fastest thing in this
repository that can catch a loader bug.
"""
import binascii
import os
import selectors
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPT = os.path.join(ROOT, "software", "soc", "uartload.py")

MAGIC = 0x55434F53
PROBE, ACK, NAK = 0x55, 0x4B, 0x45
LOAD_ADDR = 0x90000000

failures = []


def check(name, ok, detail=""):
    print(f"  {name:<44}{'ok' if ok else 'FAILED'}")
    if not ok:
        failures.append(f"{name}: {detail}")


class FakeBoard:
    """The ROM's side of the protocol, as software/soc/bootrom.c implements it.

    Written from soc.h rather than from uartload.py on purpose: if the two
    drift apart, this is meant to notice.
    """

    def __init__(self, fd, window_s=0.25):
        self.fd = fd
        self.window_s = window_s
        self.sel = selectors.DefaultSelector()
        self.sel.register(fd, selectors.EVENT_READ)

    def _read(self, n, timeout):
        out = b""
        end = time.monotonic() + timeout
        while len(out) < n:
            left = end - time.monotonic()
            if left <= 0 or not self.sel.select(left):
                break
            out += os.read(self.fd, n - len(out))
        return out

    def _write(self, b):
        os.write(self.fd, bytes((b,)))

    def run(self, expect_payload, corrupt_at=None, nak_header=False):
        """Answer a knock, take an image, and return what arrived."""
        # 1. the knock. The ROM answers the first probe inside its window.
        end = time.monotonic() + self.window_s
        while time.monotonic() < end:
            b = self._read(1, 0.05)
            if b and b[0] == PROBE:
                self._write(ACK)
                break
        else:
            return None

        # 2. the header, skipping any probe that was already in flight
        while True:
            b = self._read(1, 1.0)
            if not b:
                return None
            if b[0] != PROBE:
                break
        hdr = b + self._read(15, 1.0)
        if len(hdr) != 16:
            return None
        magic, addr, length, crc = struct.unpack("<IIII", hdr)
        if magic != MAGIC or nak_header:
            self._write(NAK)
            return "NAK"
        self._write(ACK)

        # 3. the image, stop-and-wait
        got = bytearray()
        for _ in range(length):
            b = self._read(1, 1.0)
            if not b:
                return None
            got += b
            self._write(ACK)

        # 4. the CRC
        seen = binascii.crc32(bytes(got)) & 0xFFFFFFFF
        if corrupt_at is not None:
            seen ^= 1
        self._write(ACK if seen == crc else NAK)
        if seen != crc:
            return "CRCFAIL"
        os.write(self.fd, b"\r\nfake board running\r\n")
        return bytes(got)


def run_case(name, payload, extra_args=(), **board_kwargs):
    master, slave = os.openpty()
    image = os.path.join(HERE, "build", "uartload_case.bin")
    os.makedirs(os.path.dirname(image), exist_ok=True)
    with open(image, "wb") as f:
        f.write(payload)

    proc = subprocess.Popen(
        [sys.executable, SCRIPT, os.ttyname(slave), image,
         "--knock-timeout", "5", *extra_args],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        got = FakeBoard(master).run(payload, **board_kwargs)
        # Closing our end ends the script's console passthrough.
        time.sleep(0.05)
        os.close(master)
        out = proc.communicate(timeout=30)[0]
    except subprocess.TimeoutExpired:
        proc.kill()
        return None, "the host script never exited"
    finally:
        os.close(slave)
    return got, out


def main():
    print("\n=== uartload.py against a fake board ===")

    # 1. an ordinary transfer
    payload = bytes((i * 7 + 3) & 0xFF for i in range(2048))
    got, out = run_case("ordinary", payload)
    check("2048 bytes arrive intact", got == payload,
          f"got {type(got)} {len(got) if isinstance(got, bytes) else got}")
    check("host reports success", "accepted" in (out or ""), (out or "")[-200:])

    # 2. the board rejects the header - the host must say so and stop
    got, out = run_case("nak", payload, nak_header=True)
    check("a rejected header is reported", got == "NAK" and "rejected" in (out or ""),
          (out or "")[-200:])

    # 3. the board reports a CRC mismatch
    got, out = run_case("crc", payload, corrupt_at=0)
    check("a CRC mismatch is reported", got == "CRCFAIL" and "rejected" in (out or ""),
          (out or "")[-200:])

    # 4. an address the ROM would refuse must be caught before a board is
    #    reset, not after
    got, out = run_case("addr", payload, extra_args=("--addr", "0x04000000"))
    check("a bad load address is refused up front",
          "not inside any region" in (out or ""), (out or "")[-200:])

    print()
    if failures:
        print("UARTLOAD HOST TEST FAILED")
        for f in failures:
            print("   ", f)
        sys.exit(1)
    print("UARTLOAD HOST TEST PASSED\n")


if __name__ == "__main__":
    main()
