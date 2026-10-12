#!/usr/bin/env bash
# Builds NetworkStackConfigHy300.apk: a static overlay that points NetworkStack's connectivity
# checks at Google's standard endpoints instead of the vendor's compiled-in www.google.cn,
# and copies it into the hy300-clean module.
#
# Needs: java (17+), python3, curl, adb with the projector connected (for framework-res.apk).
# Tools come from Google's Maven and are checked against the .sha256 files published there.
# Usage: bash overlay/build.sh
set -euo pipefail
cd "$(dirname "$0")"

VER=9.4.1                     # aapt2 build: 9.4.1-15978811
AAPT2_VER=9.4.1-15978811
MAVEN=https://dl.google.com/android/maven2/com/android/tools/build
TOOLS=.tools BUILD=build KEY=.key.p12 PASS=hy300local
mkdir -p "$TOOLS" "$BUILD"

fetch() {  # fetch <url> <dest>: download once, verify against Maven's published sha256 (kept as <dest>.sha256)
  [[ -f $2 ]] || curl -sfL -o "$2" "$1" || { echo "download failed: $1" >&2; exit 1; }
  [[ -s $2.sha256 ]] || curl -sfL -o "$2.sha256" "$1.sha256" ||
    { echo "checksum download failed: $1.sha256" >&2; rm -f "$2.sha256"; exit 1; }
  [[ $(cat "$2.sha256") == "$(sha256sum "$2" | cut -d' ' -f1)" ]] ||
    { echo "CHECKSUM MISMATCH for $1" >&2; rm -f "$2" "$2.sha256"; exit 1; }
}
fetch "$MAVEN/aapt2/$AAPT2_VER/aapt2-$AAPT2_VER-linux.jar" "$TOOLS/aapt2.jar"
fetch "$MAVEN/apksig/$VER/apksig-$VER.jar" "$TOOLS/apksig.jar"
[[ -x $TOOLS/aapt2 ]] || { unzip -o -q "$TOOLS/aapt2.jar" aapt2 -d "$TOOLS"; chmod +x "$TOOLS/aapt2"; }

[[ -f $BUILD/framework-res.apk ]] || adb pull /system/framework/framework-res.apk "$BUILD/" >/dev/null ||
  { echo "adb pull of framework-res.apk failed: is the projector connected?" >&2; exit 1; }
[[ -f $KEY ]] || keytool -genkeypair -keystore "$KEY" -storetype PKCS12 -storepass "$PASS" \
  -alias hy300 -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=hy300-clean local overlay" >/dev/null

"$TOOLS/aapt2" compile --dir networkstack/res -o "$BUILD/compiled.zip"
"$TOOLS/aapt2" link -o "$BUILD/unsigned.apk" --manifest networkstack/AndroidManifest.xml \
  -I "$BUILD/framework-res.apk" "$BUILD/compiled.zip" --min-sdk-version 34 --target-sdk-version 34

# Android 11+ requires resources.arsc stored uncompressed and 4-byte aligned.
python3 -I - "$BUILD/unsigned.apk" "$BUILD/aligned.apk" <<'EOF'
import sys, zipfile
src, out = sys.argv[1:3]
with zipfile.ZipFile(src) as zi, open(out, "wb") as fo:
    zo = zipfile.ZipFile(fo, "w")
    for info in zi.infolist():
        ni = zipfile.ZipInfo(info.filename, date_time=info.date_time)
        ni.compress_type = info.compress_type
        if ni.compress_type == zipfile.ZIP_STORED:
            ni.extra = b"\0" * ((4 - (fo.tell() + 30 + len(info.filename.encode())) % 4) % 4)
        zo.writestr(ni, zi.read(info))
    zo.close()
EOF

java -cp "$TOOLS/apksig.jar" Sign.java "$KEY" "$PASS" "$BUILD/aligned.apk" "$BUILD/NetworkStackConfigHy300.apk" 2>/dev/null
cp "$BUILD/NetworkStackConfigHy300.apk" ../magisk/hy300-clean/system/product/overlay/
echo "built: $(sha256sum "$BUILD/NetworkStackConfigHy300.apk")"
