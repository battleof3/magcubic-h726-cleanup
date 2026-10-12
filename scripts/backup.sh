#!/usr/bin/env bash
# Full eMMC backup over USB ADB. On a stock 2026 H726 unit /dev/block/mmcblk0 is readable by
# the shell user (mode 666, SELinux permissive), so no root is needed; once SELinux is enforcing
# (after Step 7) the shell user is denied and the script reads through su instead. Streams the whole disk once, carves
# every partition out using the image's own GPT, and checks each static partition against a
# SHA-256 of the same byte range computed on the projector.
#
# Usage: bash scripts/backup.sh [output-dir] [adb-serial]      (default output: ./backup)
set -euo pipefail

OUT=${1:-backup}
S=${2:-$(adb get-serialno 2>/dev/null || true)}
[[ -n $S && $S != unknown ]] || { echo "error: no adb device (see README Step 2)" >&2; exit 1; }
a() { adb -s "$S" "$@" </dev/null; }  # adb reads stdin; keep it off the while-read loop

# Partitions that change while Android runs can't match a hash taken a moment later.
LIVE='^(userdata|metadata|misc|media_data)$'

# Read the disk as the shell user if allowed, otherwise through su (root).
if [[ $(a shell 'dd if=/dev/block/mmcblk0 bs=512 count=1 2>/dev/null | wc -c' | tr -d '\r ') == 512 ]]; then
  R() { a shell "$1"; }; RX() { a exec-out "$1"; }
elif [[ $(a shell "su -c 'dd if=/dev/block/mmcblk0 bs=512 count=1 2>/dev/null | wc -c'" | tr -d '\r ') == 512 ]]; then
  echo "reading through su (shell user is denied)"
  R() { a shell "su -c '$1'"; }; RX() { a exec-out "su -c '$1'"; }
else
  echo "mmcblk0 is not readable by the shell user and su is unavailable: see README Step 4." >&2; exit 1
fi
SECTORS=$(R 'cat /sys/block/mmcblk0/size' | tr -d '\r ')
[[ $SECTORS =~ ^[0-9]+$ ]] || { echo "could not read the eMMC size (got: $SECTORS)" >&2; exit 1; }
EXPECTED=$(( SECTORS * 512 ))

mkdir -p "$OUT/parts"
cd "$OUT"
a shell 'getprop ro.build.fingerprint' | tr -d '\r' >fingerprint.txt

if [[ ! -f emmc_full.img || $(stat -c%s emmc_full.img) != "$EXPECTED" ]]; then
  echo "== streaming full eMMC ($EXPECTED bytes)"
  RX 'dd if=/dev/block/mmcblk0 bs=1M 2>/dev/null' >emmc_full.img
fi
[[ $(stat -c%s emmc_full.img) == "$EXPECTED" ]] || { echo "SIZE MISMATCH (expected $EXPECTED)"; exit 1; }

echo "== GPT"
sfdisk -d emmc_full.img >gpt.txt
dev=$(R 'dd if=/dev/block/mmcblk0 bs=512 count=34 2>/dev/null | sha256sum' | cut -d' ' -f1)
pc=$(head -c $((512 * 34)) emmc_full.img | sha256sum | cut -d' ' -f1)
[[ $dev == "$pc" ]] && echo "primary GPT region OK" || { echo "GPT MISMATCH"; exit 1; }

echo "== partitions (name, bytes, sha256, check)"
# Largest block size that divides both offset and length keeps device-side dd fast.
pick_bs() { for b in 1048576 65536 4096 512; do (( $1 % b == 0 && $2 % b == 0 )) && { echo $b; return; }; done; }

sfdisk --json emmc_full.img |
  python3 -I -c 'import json,sys
for p in json.load(sys.stdin)["partitiontable"]["partitions"]:
    print(p["name"], p["start"], p["size"])' |
  while read -r name start sectors; do
    off=$((start * 512)); len=$((sectors * 512)); bs=$(pick_bs $off $len)
    file=parts/$name.img
    dd if=emmc_full.img of="$file" bs=$bs skip=$((off / bs)) count=$((len / bs)) status=none
    pc=$(sha256sum "$file" | cut -d' ' -f1)
    if [[ $name =~ $LIVE ]]; then
      printf '%-18s %12s  %s  live, not cross-checked\n' "$name" "$len" "$pc"
      continue
    fi
    dev=$(R "dd if=/dev/block/mmcblk0 bs=$bs skip=$((off / bs)) count=$((len / bs)) 2>/dev/null | sha256sum" | cut -d' ' -f1)
    if [[ $dev == "$pc" ]]; then
      printf '%-18s %12s  %s  OK\n' "$name" "$len" "$pc"
    else
      printf '%-18s %12s  MISMATCH device=%s pc=%s\n' "$name" "$len" "$dev" "$pc"
      exit 1
    fi
  done

sha256sum emmc_full.img parts/*.img >SHA256SUMS
echo "== done; checksums in $OUT/SHA256SUMS. Copy $OUT to two places off this PC."
