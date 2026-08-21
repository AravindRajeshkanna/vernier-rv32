#!/usr/bin/env python3
"""Build a newc cpio archive from a gen_init_cpio(1) spec.

This replaces the kernel's own usr/gen_init_cpio, which does not compile on
macOS: it calls copy_file_range(2) and opens with O_LARGEFILE, both of which
are Linux-only. usr/Makefile passes a `.cpio` file straight through to the
initramfs without building that host tool at all, so producing the archive
here removes the dependency rather than working around it.

The format is small and frozen - it is what the kernel's own
init/initramfs.c parses, and it has not changed in twenty years - so this is
about sixty lines rather than a library:

    070701 <13 x 8-hex-digit fields> <name>\\0 [pad to 4] <data> [pad to 4]

and a final entry named TRAILER!!! with every field zero.

The spec dialect is gen_init_cpio's, restricted to what an initramfs for this
SoC needs:

    dir   <name> <mode> <uid> <gid>
    file  <name> <source> <mode> <uid> <gid>
    nod   <name> <mode> <uid> <gid> <type c|b> <major> <minor>
    slink <name> <target> <mode> <uid> <gid>

Blank lines and # comments are ignored. Modes are octal, as they are there.

Needs nothing but the standard library, for the same reason
software/soc/uartload.py does.
"""
import sys

S_IFDIR  = 0o040000
S_IFREG  = 0o100000
S_IFCHR  = 0o020000
S_IFBLK  = 0o060000
S_IFLNK  = 0o120000

MAGIC = b"070701"


class Cpio:
    def __init__(self):
        self.out = bytearray()
        # Inode numbers only have to be distinct within the archive; the
        # kernel uses them to spot hard links, and nothing here has any.
        self.ino = 721

    def _pad(self):
        while len(self.out) % 4:
            self.out.append(0)

    def entry(self, name, mode, uid, gid, data=b"", rdev=(0, 0), nlink=1):
        # Leading slashes must go: initramfs unpacks relative to the root it
        # is creating, and a name of "/init" would be looked up as "init"
        # under a directory called "" on some readers. gen_init_cpio strips
        # them too.
        name = name.lstrip("/")
        raw  = name.encode() + b"\0"

        self.ino += 1
        fields = [
            self.ino, mode, uid, gid, nlink,
            0,                       # mtime: zero, so the archive is
                                     # reproducible - see practices.md 20
            len(data),
            0, 0,                    # devmajor, devminor
            rdev[0], rdev[1],
            len(raw),
            0,                       # check: unused for newc
        ]
        self.out += MAGIC + b"".join(b"%08X" % f for f in fields)
        self.out += raw
        self._pad()
        self.out += data
        self._pad()

    def finish(self):
        # The trailer's nlink must be 1: init/initramfs.c treats a zero
        # nlink as a malformed header rather than as the end of the archive.
        self.entry("TRAILER!!!", 0, 0, 0)
        return bytes(self.out)


def parse(spec_path, cpio):
    with open(spec_path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            kind = parts[0]

            def die(msg):
                sys.exit(f"{spec_path}:{lineno}: {msg}\n  {line}")

            try:
                if kind == "dir":
                    name, mode, uid, gid = parts[1], int(parts[2], 8), \
                                           int(parts[3]), int(parts[4])
                    cpio.entry(name, S_IFDIR | mode, uid, gid, nlink=2)

                elif kind == "file":
                    name, src, mode, uid, gid = parts[1], parts[2], \
                        int(parts[3], 8), int(parts[4]), int(parts[5])
                    with open(src, "rb") as fh:
                        data = fh.read()
                    cpio.entry(name, S_IFREG | mode, uid, gid, data)

                elif kind == "nod":
                    name, mode, uid, gid = parts[1], int(parts[2], 8), \
                                           int(parts[3]), int(parts[4])
                    dtype, major, minor = parts[5], int(parts[6]), int(parts[7])
                    if dtype not in ("c", "b"):
                        die(f"device type must be c or b, not {dtype!r}")
                    fmt = S_IFCHR if dtype == "c" else S_IFBLK
                    cpio.entry(name, fmt | mode, uid, gid, rdev=(major, minor))

                elif kind == "slink":
                    name, target, mode, uid, gid = parts[1], parts[2], \
                        int(parts[3], 8), int(parts[4]), int(parts[5])
                    cpio.entry(name, S_IFLNK | mode, uid, gid, target.encode())

                else:
                    die(f"unknown entry type {kind!r}")
            except (IndexError, ValueError) as exc:
                die(f"malformed {kind} entry: {exc}")
            except OSError as exc:
                die(f"{exc}")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: mkcpio.py <spec> <out.cpio>")

    cpio = Cpio()
    parse(sys.argv[1], cpio)
    blob = cpio.finish()

    with open(sys.argv[2], "wb") as f:
        f.write(blob)
    print(f"  initramfs: {len(blob)} bytes ({len(blob) // 1024} KB)",
          file=sys.stderr)


if __name__ == "__main__":
    main()
