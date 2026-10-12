#!/usr/bin/env python3
"""Print SHA-256 of each signer certificate in an APK's v2/v3 signing block.

Usage: python -I apkcert.py <file.apk> [...]
Parses the block directly (no signature verification: Android does that at install);
the point is to see WHICH certificate signed the APK.
"""
import hashlib
import struct
import sys

V2, V3 = 0x7109871A, 0xF05368C0


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def lp(b, o):  # length-prefixed (uint32) slice -> (bytes, next offset)
    n = u32(b, o)
    return b[o + 4:o + 4 + n], o + 4 + n


def signing_block(data):
    eocd = data.rfind(b"PK\x05\x06")
    cd_off = u32(data, eocd + 16)
    if data[cd_off - 16:cd_off] != b"APK Sig Block 42":
        raise SystemExit("no APK Signing Block (v1-only APK?)")
    size = struct.unpack_from("<Q", data, cd_off - 24)[0]
    start = cd_off - size - 8
    return data[start + 8:cd_off - 24]


def certs(scheme_block):
    signers, _ = lp(scheme_block, 0)
    o = 0
    while o < len(signers):
        signer, o = lp(signers, o)
        signed_data, _ = lp(signer, 0)
        _digests, p = lp(signed_data, 0)
        cert_seq, _ = lp(signed_data, p)
        q = 0
        while q < len(cert_seq):
            cert, q = lp(cert_seq, q)
            yield cert


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: apkcert.py <file.apk> [...]")
    for path in sys.argv[1:]:
        try:
            block = signing_block(open(path, "rb").read())
        except (OSError, struct.error, IndexError) as e:
            print(f"{path}: not a readable APK ({e})"); continue
        except SystemExit as e:
            print(f"{path}: {e}"); continue
        o = 0
        while o < len(block):
            n = struct.unpack_from("<Q", block, o)[0]
            pid = u32(block, o + 8)
            value = block[o + 12:o + 8 + n]
            if pid in (V2, V3):
                for c in certs(value):
                    print(f"{path}: v{2 if pid == V2 else 3} cert sha256 {hashlib.sha256(c).hexdigest()}")
            o += 8 + n


if __name__ == "__main__":
    main()
