#!/usr/bin/env bash
# Builds keystone.dex (hy300.Keystone, the launcher-free keystone helper) and copies it into the
# hy300-clean module. stubs/ holds compile-only declarations of the Android APIs it calls; the
# real classes come from the projector's framework at run time, so the stubs are not packaged.
#
# Needs: java (17+), curl. D8 comes from Google's Maven, checked against its published .sha256.
# Usage: bash keystone/build.sh
set -euo pipefail
cd "$(dirname "$0")"

R8_VER=9.4.28
URL=https://dl.google.com/android/maven2/com/android/tools/r8/$R8_VER/r8-$R8_VER.jar
TOOLS=.tools BUILD=build
mkdir -p "$TOOLS"
rm -rf "$BUILD" && mkdir -p "$BUILD/stubs" "$BUILD/classes" "$BUILD/dex"

[[ -f $TOOLS/r8.jar ]] || curl -sfL -o "$TOOLS/r8.jar" "$URL" || { echo "download failed: $URL" >&2; exit 1; }
# The published checksum is kept next to the jar, so later builds work offline.
[[ -s $TOOLS/r8.jar.sha256 ]] || curl -sfL -o "$TOOLS/r8.jar.sha256" "$URL.sha256" ||
  { echo "checksum download failed: $URL.sha256" >&2; rm -f "$TOOLS/r8.jar.sha256"; exit 1; }
[[ $(cat "$TOOLS/r8.jar.sha256") == "$(sha256sum "$TOOLS/r8.jar" | cut -d' ' -f1)" ]] ||
  { echo "CHECKSUM MISMATCH for $URL" >&2; rm -f "$TOOLS/r8.jar" "$TOOLS/r8.jar.sha256"; exit 1; }

javac --release 11 -d "$BUILD/stubs" $(find stubs -name '*.java')
javac --release 11 -cp "$BUILD/stubs" -d "$BUILD/classes" src/hy300/Keystone.java
java -cp "$TOOLS/r8.jar" com.android.tools.r8.D8 --release --min-api 34 --output "$BUILD/dex" \
  $(find "$BUILD/classes" -name '*.class')
cp "$BUILD/dex/classes.dex" ../magisk/hy300-clean/keystone.dex
echo "built: $(sha256sum ../magisk/hy300-clean/keystone.dex)"
