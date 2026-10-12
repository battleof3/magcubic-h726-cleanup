#!/usr/bin/env python3
"""Group SELinux avc denials into candidate allow rules.

Usage: python -I avc2rules.py <log>...
Prints one line per (source, target, class) with the union of permissions, the hit count,
and a few example process/object names, sorted by source domain.
"""
import collections
import re
import sys

AVC = re.compile(r"avc:\s+denied\s+\{ ([^}]+) \}(.*)")
FIELD = re.compile(r'(\w+)=("[^"]*"|\S+)')


def ctx_type(ctx):
    parts = ctx.split(":")
    return parts[2] if len(parts) > 2 else ctx


def main():
    rules = collections.defaultdict(lambda: {"perms": set(), "n": 0, "who": set(), "what": set()})
    seen = set()
    for path in sys.argv[1:]:
        for line in open(path, errors="replace"):
            m = AVC.search(line)
            if not m:
                continue
            perms, rest = m.group(1).split(), m.group(2)
            f = dict(FIELD.findall(rest))
            if "scontext" not in f or "tcontext" not in f:
                continue
            # dmesg and logcat both carry kernel audit events: count each audit serial once.
            serial = re.search(r"audit\(([\d.]+:\d+)\)", line)
            key = serial.group(1) if serial else (path, m.group(0))
            if key in seen:
                continue
            seen.add(key)
            k = (ctx_type(f["scontext"]), ctx_type(f["tcontext"]), f.get("tclass", "?"))
            r = rules[k]
            r["perms"].update(perms)
            r["n"] += 1
            for name in ("comm", "app"):
                if name in f:
                    r["who"].add(f[name].strip('"'))
            for name in ("name", "path", "property"):
                if name in f:
                    r["what"].add(f[name].strip('"'))
    for (s, t, c), r in sorted(rules.items()):
        who = ",".join(sorted(r["who"]))[:40]
        what = ",".join(sorted(r["what"]))[:60]
        print(f"{r['n']:5d}  allow {s} {t} {c} {{ {' '.join(sorted(r['perms']))} }}   # {who} -> {what}")


if __name__ == "__main__":
    main()
