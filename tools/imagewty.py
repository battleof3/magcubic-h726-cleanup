#!/usr/bin/env python3
"""List or extract entries of an Allwinner IMAGEWTY (PhoenixSuit update.img), v3 layout.

Usage: python -I imagewty.py <update.img> [outdir [name ...]]
With only the image it lists entries; with outdir it extracts all (or just the named) entries.
"""
import os
import struct
import sys

ITEM = 1024


def entries(f):
    hdr = f.read(ITEM)
    if hdr[:8] != b"IMAGEWTY":
        sys.exit("not an IMAGEWTY image (encrypted or wrong file)")
    num = struct.unpack_from("<I", hdr, 60)[0]
    for i in range(num):
        f.seek(ITEM * (1 + i))
        e = f.read(ITEM)
        maintype = e[8:16].rstrip(b"\0 ").decode(errors="replace")
        subtype = e[16:32].rstrip(b"\0 ").decode(errors="replace")
        name = e[36:292].split(b"\0", 1)[0].decode(errors="replace")
        stored, _, orig, _, off = struct.unpack_from("<5I", e, 292)
        yield maintype, subtype, name, stored, orig, off


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    img, out, wanted = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None), set(sys.argv[3:])
    found = set()
    with open(img, "rb") as f:
        for maintype, subtype, name, stored, orig, off in entries(f):
            if out is None:
                print(f"{maintype:8} {subtype:16} {orig:>11} @{off:<11} {name}")
                continue
            base = os.path.basename(name)
            if wanted and base not in wanted:
                continue
            found.add(base)
            f.seek(off)
            with open(os.path.join(out, base), "wb") as o:
                o.write(f.read(orig))
    missing = wanted - found
    if out is not None and missing:
        sys.exit("not in image: " + ", ".join(sorted(missing)))


if __name__ == "__main__":
    main()
