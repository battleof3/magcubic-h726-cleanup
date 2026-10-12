#!/usr/bin/env bash
# Builds the hy300-a11yfix Magisk module from YOUR projector's own services.jar.
# The vendor's DisplayContent.enableNfxAccessibility / enableYtbAccessibility wipe every
# accessibility service on each focus change; this turns both methods into no-ops,
# proves nothing else in the dex changed, and rebuilds the jar (dex stored, 4-byte aligned).
#
# Needs: java, python3, curl, adb with the projector connected.
# Tools: smali/baksmali 2.5.2 from JesusFreke's official downloads (no published hash: the
# script prints their SHA-256; they only run on this PC). Never use someone else's services.jar.
# Usage: bash a11yfix/patch_services.sh [stock-services.jar]
set -euo pipefail
STOCK_ARG=${1:+$(realpath "$1")}

mkzip() {  # mkzip <out.zip> <files/dirs...>: entries without a ./ prefix
python3 -I - "$1" "${@:2}" <<'PY'
import os, sys, zipfile
out, items = sys.argv[1], sys.argv[2:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for it in items:
        paths = [it] if os.path.isfile(it) else [os.path.join(r, f) for r, _, fs in os.walk(it) for f in fs]
        for p in sorted(paths):
            z.write(p, os.path.normpath(p))
PY
}
cd "$(dirname "$0")"

TOOLS=.tools BUILD=build MOD=module
SMALI_URL=https://bitbucket.org/JesusFreke/smali/downloads
mkdir -p "$TOOLS" "$BUILD"
for j in smali-2.5.2.jar baksmali-2.5.2.jar; do
  [[ -f $TOOLS/$j ]] || curl -sfL -o "$TOOLS/$j" "$SMALI_URL/$j"
done
sha256sum "$TOOLS"/*.jar

# Optional argument: path to a stock services.jar (needed if hy300-a11yfix is already active,
# because the device then serves the patched jar).
# The stock copy is kept as build/services.stock.jar and never overwritten; copy it to your
# backup after the first run, because once the module is active the device serves the patched jar.
if [[ -n $STOCK_ARG ]]; then cp "$STOCK_ARG" "$BUILD/services.stock.jar"
elif [[ ! -f $BUILD/services.stock.jar ]]; then
  adb pull /system/framework/services.jar "$BUILD/services.stock.jar" >/dev/null ||
    { echo "adb pull failed: is the projector connected?" >&2; exit 1; }
fi
cp "$BUILD/services.stock.jar" "$BUILD/services.jar"
API=$(adb shell getprop ro.build.version.sdk | tr -d '\r')

# Find the dex holding the hook. The vendor's helper component name only exists in unpatched code.
DEX="" PATCHED=""
for d in $(unzip -Z1 "$BUILD/services.jar" | grep -E '^classes[0-9]*\.dex$'); do
  unzip -p "$BUILD/services.jar" "$d" >"$BUILD/probe.dex"
  if grep -aq 'com.android.nfx/com.android.nfx.NfxAccessibilityService' "$BUILD/probe.dex"; then DEX=$d
  elif grep -aq enableNfxAccessibility "$BUILD/probe.dex"; then PATCHED=$d; fi
done
rm -f "$BUILD/probe.dex"
if [[ -z $DEX && -n $PATCHED ]]; then
  rm -f "$BUILD/services.stock.jar"   # not stock after all; don't cache it
  echo "services.jar is already patched (hy300-a11yfix active?): pass a stock jar as the argument" >&2; exit 1
fi
[[ -n $DEX ]] || { echo "hook not found: this build may not have it" >&2; exit 1; }
echo "hook is in $DEX (API $API)"

rm -rf "$BUILD"/smali_*
unzip -p "$BUILD/services.jar" "$DEX" >"$BUILD/orig.dex"
java -jar "$TOOLS/baksmali-2.5.2.jar" d -a "$API" "$BUILD/orig.dex" -o "$BUILD/smali_orig"
cp -r "$BUILD/smali_orig" "$BUILD/smali_patched"

python3 -I - "$BUILD/smali_patched/com/android/server/wm/DisplayContent.smali" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
for m in ("enableNfxAccessibility", "enableYtbAccessibility"):
    s, n = re.subn(r"(\.method (?:[a-z-]+ )*" + m + r"\(Z\)V\n).*?(\.end method)",
                   r"\1    .registers 2\n\n    # hy300-clean: vendor hook wiped every accessibility service on each focus change.\n    return-void\n\2",
                   s, flags=re.S)
    assert n == 1, f"{m}: expected 1 method, found {n}"
open(p, "w").write(s)
EOF

java -jar "$TOOLS/smali-2.5.2.jar" a -a "$API" "$BUILD/smali_patched" -o "$BUILD/patched.dex"
java -jar "$TOOLS/baksmali-2.5.2.jar" d -a "$API" "$BUILD/patched.dex" -o "$BUILD/smali_check"

# Proof: ignoring smali's dropped default static initialisers, only DisplayContent may differ.
python3 -I - "$BUILD/smali_orig" "$BUILD/smali_check" <<'EOF'
import os, re, sys
a, b = sys.argv[1:3]
dflt = re.compile(r"^(\.field .*?) = (?:false|0x0|0x0t|0x0s|0x0L|0\.0f|0\.0|null)$")
norm = lambda p: [dflt.sub(r"\1", l.rstrip("\n")) for l in open(p)]
changed = []
for root, _, files in os.walk(a):
    for f in files:
        pa = os.path.join(root, f); pb = os.path.join(b, os.path.relpath(pa, a))
        if not os.path.exists(pb) or norm(pa) != norm(pb):
            changed.append(os.path.relpath(pa, a))
print("semantically changed:", changed)
assert changed == ["com/android/server/wm/DisplayContent.smali"], "unexpected changes: aborting"
EOF

python3 -I - "$BUILD/services.jar" "$DEX" "$BUILD/patched.dex" "$BUILD/services.patched.jar" <<'EOF'
import sys, zipfile
src, name, newdex, out = sys.argv[1:5]
new = open(newdex, "rb").read()
with zipfile.ZipFile(src) as zi, open(out, "wb") as fo:
    zo = zipfile.ZipFile(fo, "w")
    for info in zi.infolist():
        data = new if info.filename == name else zi.read(info)
        ni = zipfile.ZipInfo(info.filename, date_time=info.date_time)
        ni.compress_type, ni.external_attr, ni.create_system = info.compress_type, info.external_attr, info.create_system
        if ni.compress_type == zipfile.ZIP_STORED:
            ni.extra = b"\0" * ((4 - (fo.tell() + 30 + len(info.filename.encode())) % 4) % 4)
        zo.writestr(ni, data)
    zo.close()
EOF

mkdir -p "$MOD/system/framework"
cp "$BUILD/services.patched.jar" "$MOD/system/framework/services.jar"
for app in $(adb shell 'ls -d /product/app/NFXAccessibility* /product/app/YTAccessibility* 2>/dev/null' | tr -d '\r'); do
  mkdir -p "$MOD/system$app" && : >"$MOD/system$app/.replace"
done
(cd "$MOD" && rm -f ../hy300-a11yfix.zip && mkzip ../hy300-a11yfix.zip module.prop customize.sh META-INF system)
echo "module: $(sha256sum hy300-a11yfix.zip)"
