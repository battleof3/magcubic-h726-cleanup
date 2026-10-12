#!/usr/bin/env bash
# Zips the hy300-clean Magisk module (entries without a ./ prefix, as Magisk's installer needs).
# Build the overlay and the keystone helper first (bash overlay/build.sh; bash keystone/build.sh)
# so the module carries them.
# Usage: bash magisk/build.sh               (full module; fails if the overlay or keystone.dex is missing)
#        ALLOW_MISSING=1 bash magisk/build.sh   (build without them anyway)
#        NO_ENFORCE=1 bash magisk/build.sh  (without post-fs-data.sh: SELinux stays permissive,
#                                            for adapting sepolicy.rule to another build)
set -euo pipefail

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
cd "$(dirname "$0")/hy300-clean"
missing=()
[[ -f system/product/overlay/NetworkStackConfigHy300.apk ]] ||
  missing+=("overlay (bash overlay/build.sh): connectivity checks would stay on the vendor's www.google.cn")
[[ -f keystone.dex ]] ||
  missing+=("keystone helper (bash keystone/build.sh): holding the mouse button wouldn't open keystone mode")
if (( ${#missing[@]} )); then
  printf 'not built: %s\n' "${missing[@]}" >&2
  [[ ${ALLOW_MISSING:-0} = 1 ]] || { echo "build those first, or set ALLOW_MISSING=1" >&2; exit 1; }
fi
rm -f ../hy300-clean.zip
files=(module.prop customize.sh service.sh remote-buttons.sh sepolicy.rule META-INF system)
[[ -f keystone.dex ]] && files+=(keystone.dex)
[[ ${NO_ENFORCE:-0} = 1 ]] && echo "building without post-fs-data.sh (SELinux stays permissive)" || files+=(post-fs-data.sh)
mkzip ../hy300-clean.zip "${files[@]}"
echo "module: $(sha256sum ../hy300-clean.zip)"
