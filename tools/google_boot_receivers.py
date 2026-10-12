#!/usr/bin/env python3
"""List (and optionally re-enable) Google BOOT_COMPLETED receivers that are disabled.

On first boot the vendor script /system/bin/appsdisable runs `pm disable` on every Google
component that receives BOOT_COMPLETED (Play Protect among them). Google also disables many
of its own components on TVs, so this only touches components that are BOTH disabled AND
registered for BOOT_COMPLETED.

Usage: python3 -I tools/google_boot_receivers.py           (list)
       python3 -I tools/google_boot_receivers.py --apply   (pm enable each one; needs root, since
                                                            Android refuses this to the adb shell)
"""
import re
import subprocess
import sys


def adb(*args):
    return subprocess.run(["adb", "shell", *args], capture_output=True, text=True, check=True).stdout


def root(cmd):
    r = subprocess.run(["adb", "shell", "su", "-c", cmd], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"failed (is the device rooted and adb granted su?): {cmd}\n{r.stdout}{r.stderr}")


def section(text, header):
    """Lines of an indented dumpsys block that starts with `header`."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip() == header:
            indent = len(line) - len(line.lstrip())
            out = []
            for nxt in lines[i + 1:]:
                if nxt.strip() and len(nxt) - len(nxt.lstrip()) <= indent:
                    break
                out.append(nxt)
            return out
    return []


def boot_receivers(text, pkg):
    """Components listed under BOOT_COMPLETED in the package's Receiver Resolver Table."""
    table = section(text, "Receiver Resolver Table:")
    found, inside = set(), False
    for line in table:
        stripped = line.strip()
        if re.fullmatch(r"[\w.]+:", stripped):  # an action header such as android.intent.action.X:
            inside = stripped == "android.intent.action.BOOT_COMPLETED:"
            continue
        if inside:
            m = re.search(re.escape(pkg) + r"/(\S+)", stripped)
            if m:
                cls = m.group(1)
                found.add(pkg + "." + cls[1:] if cls.startswith(".") else cls)
    return found


def main():
    apply = "--apply" in sys.argv
    pkgs = [l.split(":", 1)[1].strip() for l in adb("pm", "list", "packages").splitlines() if "google" in l]
    targets = []
    for pkg in pkgs:
        text = adb("dumpsys", "package", pkg)
        disabled = {l.strip() for l in section(text, "disabledComponents:") if l.strip()}
        for cls in sorted(boot_receivers(text, pkg) & disabled):
            targets.append(f"{pkg}/{cls}")
    for comp in targets:
        print(comp)
        if apply:
            root(f"pm enable '{comp}'")
    print(f"{len(targets)} disabled Google BOOT_COMPLETED receiver(s)" + (" re-enabled" if apply else ""))
    if apply:
        root("settings delete global start_disable")


if __name__ == "__main__":
    main()
