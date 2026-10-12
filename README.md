# HY300 Pro Cleanup

> Also available as a [Claude doc](https://claude.ai/artifact/WCCGjTeqWXCA1S1AjF6KHz).

Magcubic HY300 Pro projectors ship with factory malware signed into the firmware. This repository takes a new unit from quarantined to backed up, rooted, stripped and SELinux-enforcing, without flashing anyone's "clean" image.

Run every command from the root of this repository, in **bash** (in fish or another shell, run `bash` first). Everything here was worked through end to end on a **2026 HY300 Pro (Allwinner H726, Android 14, build `Projector.20260318.111759`)**. Notes call out where earlier H713 units differ. Other builds will differ in places: read each step, check your own unit, and adapt.

> [!WARNING]
> This involves raw writes to the device's storage. Follow the backup and rescue steps before any write. You do this at your own risk. The goal is a projector that is **contained and stripped, not trusted**: nobody can guarantee every vendor component has been found.

## Contents

- [Repository layout](#repository-layout)
- [Before you start](#before-you-start)
- [What you need](#what-you-need)
- [Step 1 — Quarantine the network](#step-1--quarantine-the-network)
- [Step 2 — ADB over USB and identifying your unit](#step-2--adb-over-usb-and-identifying-your-unit)
- [Step 3 — Contain the malware without root](#step-3--contain-the-malware-without-root)
- [Step 4 — Back up the whole eMMC](#step-4--back-up-the-whole-emmc)
- [Step 5 — Prepare and test the FEL rescue path](#step-5--prepare-and-test-the-fel-rescue-path)
- [Step 6 — Root with Magisk by patching init_boot](#step-6--root-with-magisk-by-patching-init_boot)
- [Step 7 — Install the hy300-clean Magisk module](#step-7--install-the-hy300-clean-magisk-module)
- [Step 8 — Fix the vendor accessibility wipe](#step-8--fix-the-vendor-accessibility-wipe)
- [Step 9 — Launcher, HDMI and remote buttons](#step-9--launcher-hdmi-and-remote-buttons)
- [Step 10 — Vendor apps and network endpoints](#step-10--vendor-apps-and-network-endpoints)
- [Step 11 — Verify, keep it contained, and maintain](#step-11--verify-keep-it-contained-and-maintain)
- [Proof it worked: DNS log analysis](#proof-it-worked-dns-log-analysis)
- [What's on these units](#whats-on-these-units)
- [Troubleshooting](#troubleshooting)
- [Software and sources](#software-and-sources)

## Repository layout

<details>
<summary>Repository layout (table)</summary>

| Path | What it is |
| --- | --- |
| [`scripts/quarantine.sh`](scripts/quarantine.sh) | PC-hosted quarantine Wi-Fi: no route anywhere, DNS sinkhole with logging |
| [`scripts/backup.sh`](scripts/backup.sh) | Full eMMC backup over ADB, every partition verified against the device |
| [`tools/imagewty.py`](tools/imagewty.py) | Lists and extracts Allwinner `update.img` (IMAGEWTY) firmware |
| [`tools/apkcert.py`](tools/apkcert.py) | Prints the v2/v3 signing certificate of an APK |
| [`tools/avc2rules.py`](tools/avc2rules.py) | Groups SELinux denials into candidate policy rules |
| [`tools/google_boot_receivers.py`](tools/google_boot_receivers.py) | Lists and re-enables the Google boot receivers the vendor scripts disabled |
| [`magisk/hy300-clean/`](magisk/hy300-clean/) | The cleanup Magisk module (source) |
| [`magisk/build.sh`](magisk/build.sh) | Zips the module |
| [`overlay/`](overlay/) | Source and build script for the connectivity-check overlay |
| [`keystone/`](keystone/) | Source and build script for the remote-driven keystone helper (`keystone.dex`) |
| [`a11yfix/`](a11yfix/) | Script that builds the accessibility-fix module from **your own** `services.jar` |

</details>

Nothing from a projector is included: no backups, malware samples, vendor jars or signing keys. Build outputs, downloaded tools and keys are covered by [`.gitignore`](.gitignore).

## Before you start

The malware is part of the firmware, signed with the vendor's own platform key, so neither a factory reset nor the official firmware removes it.

**What a 2026 H726 unit ships with** (details in [What's on these units](#whats-on-these-units)):

- A system-UID payload app (`com.hotack.screensaversdk`; `com.hotack.silentsdk` on H713) that can silently install apps and change protected settings.
- A silent installer (`com.htc.storeos`) polling its server every 5 seconds, and an OTA updater that can reinstall everything.
- A root shell daemon (`/system/bin/qw`) started on every boot, and a factory test script (`runin.sh`) that runs `eval` as root on a config file anyone can write to shared storage.
- SELinux set to permissive, the raw eMMC and the `/oem` partition world-writable, and a framework hook that wipes every accessibility service on each app switch.
- A casting stack (Feitu/mphotool) with its own update checker and log uploader.

<details>
<summary>Cleanup levels (table)</summary>

| Level | What you do | Effort | Result |
| --- | --- | --- | --- |
| 0 · Display only | Never connect it to Wi-Fi; feed it HDMI from a trusted device | None | The malware has nothing to reach |
| 1 · Contain | Steps 1–3 | About an hour, no root | Quiet, but still installed; a factory reset undoes it |
| 2 · Strip | All steps | An afternoon or more; comfort with a Linux shell | Malware neutered systemlessly, SELinux enforcing, everything reversible |

</details>

**Rules for every level:**

- Never flash anyone's "clean" image, the vendor's included. Magcubic's official image for this build is byte-identical to the infected unit.
- Nothing gets written to the device until your own full backup exists in two places.
- Keep it off any network that can reach your LAN, and never sign it into a Google account.

> [!NOTE]
> **Keystone.** On the 2026 H726 build the keystone screen exists only in the Magcubic launcher (`com.htc.magcubicos`), which Step 9 disables. The Step 7 module replaces it: **hold the remote's mouse button for about a second** to adjust keystone with the arrows (Step 9). It talks to this build's display service, so the module enables it only on `Projector.20260318.111759`.

## What you need

<details>
<summary>Hardware and software needed (table)</summary>

| Item | Why | Notes |
| --- | --- | --- |
| USB-A male to USB-A male **data** cable | USB ADB and FEL recovery | It backfeeds 5 V: to truly power-cycle the projector, unplug power **and** this cable |
| Linux PC | Quarantine, ADB, patching, image tools | [Android platform tools](https://developer.android.com/tools/releases/platform-tools), Android udev rules (Arch: [`android-udev`](https://archlinux.org/packages/extra/any/android-udev/)), `sfdisk` (util-linux), `python3`, `curl`, `unzip`, a full JDK 17+ (`java`, `javac`, `keytool`; a JRE-only package is not enough), `unpack_bootimg` (Arch `android-tools`; Debian/Ubuntu `mkbootimg`), and for the hotspot NetworkManager with `dnsmasq`, `iw` and `nft` |
| Windows VM | [PhoenixSuit](#step-5--prepare-and-test-the-fel-rescue-path) FEL rescue | [VirtualBox](https://www.virtualbox.org/) or QEMU with USB 2.0/3.0 passthrough; Windows 7 or later |
| Paperclip | Flash button next to the HDMI port | Only for FEL |
| About 20 GB free disk | Full eMMC backup (7.3 GB) plus every partition carved out (another ~7.3 GB), the official image (2.2 GB) and build files | Keep a second copy of the backup off the PC |
| `mkisofs` or `xorriso` | Getting files into the rescue VM | Only for Step 5 |

</details>

## Step 1 — Quarantine the network

The projector must never reach the internet or your LAN while it's infected. Give it a network where it can only talk to your PC, and let DNS log what it tries to reach.

- **Router with VLANs** (UniFi, OpenWrt, pfSense): a dedicated VLAN and SSID with client isolation, all egress dropped, only your PC allowed in, and DNS pointed at a sinkhole such as Pi-hole with the [domains below](#whats-on-these-units) blocked.
- **ISP gateway with no VLANs:** host the network from the PC with [`scripts/quarantine.sh`](scripts/quarantine.sh). It creates an access point sharing the PC's Wi-Fi radio (the PC stays online). dnsmasq answers every lookup with "no such domain" and logs it, and nftables logs and drops anything the projector tries to send onward.
- If the projector has already been on your main network with internet, assume your IP was enrolled as a proxy exit and change any password typed into it.

<details>
<summary>Quarantine commands</summary>

```bash
sudo bash scripts/quarantine.sh up       # prints the Wi-Fi password
sudo bash scripts/quarantine.sh status   # leases, last DNS lookups, dropped packets
sudo bash scripts/quarantine.sh down
```

</details>

On the projector, join the `hy300-quarantine` network with the password the script prints. The script needs NetworkManager (with `dnsmasq`), `iw` and nftables, and opens DHCP/DNS in ufw only if ufw is active (with firewalld, allow DHCP and DNS on `ap0` yourself). It uses the Wi-Fi interface currently connected as a client; override it with `sudo PARENT=<iface> bash scripts/quarantine.sh up`. Its firewall also blocks the projector from every service on the PC except DHCP and DNS. The card must support an access point alongside a client connection (see `iw list` → "valid interface combinations"); single-radio cards only manage it on the channel the client already uses. Android won't automatically rejoin a saved network that has no internet, so reconnect the projector by hand after a reboot.

## Step 2 — ADB over USB and identifying your unit

1. **Developer options** live in the projector's own settings skin: Settings → About, then press OK on the model name 7–10 times.
2. Turn on **ADB debugging** and **USB debugging**. USB debugging switches the USB port to device mode, so USB drives and keyboards stop working while it's on.
3. Connect the projector's USB-A port to the PC and run `adb devices`. Accept the prompt with "Always allow from this computer". `no permissions` means the udev rules are missing.
4. On H726 units network ADB fails with a TLS `CERTIFICATE_UNKNOWN` error: the firmware forces wireless-debugging TLS but has no pairing screen. Use the cable.

<details>
<summary>Identify the unit (command)</summary>

```bash
adb shell 'for p in ro.board.platform ro.hardware ro.build.version.release ro.build.display.id ro.build.flavor ro.boot.slot_suffix ro.boot.flash.locked ro.boot.verifiedbootstate ro.product.cpu.abilist; do echo "$p=$(getprop $p)"; done; uname -a; tr "\0" " " < /proc/device-tree/compatible; echo; ls -l /dev/block/mmcblk0; ls /dev/block/by-name'
```

</details>

<details>
<summary>H726 vs H713: how to tell them apart</summary>

| Tell | H726 (2026 HY300 Pro, this guide) | H713 (earlier HY300 Pro/Pro+) |
| --- | --- | --- |
| `ro.board.platform` / device tree | `hermes`, `allwinner,h726 arm,sun50iw15p1`, flavor `h726_p2` | `h713_tuna_p3` |
| Android / kernel | 14 / 5.15, 32-bit (`armv7l`, `armeabi-v7a` only) | 11 / 5.4.99 |
| Ramdisk | In `init_boot` (patch this) | In `boot` |
| Fastboot | None: `adb reboot bootloader` lands in a recovery with no UI and no USB | Present |
| Slot B | All zeros: no fallback slot | Usable fallback |
| Network ADB | TLS only, no pairing UI | Plain `adb connect` works |
| Payload | `com.hotack.screensaversdk` in `/data` | `com.hotack.silentsdk` in `/system` |

</details>

On an H713 unit, use the [H713 root guide](https://xdaforums.com/t/beta-android-tv-and-root-tutorial-for-allwinner-h713-based-projectors.4744020/) (fastboot and a patched `boot`) for Steps 5–6, then adapt the module's package and file lists to your own inventory. If `adb reboot bootloader` leaves an H726 on a robot screen, unplug power **and** the USB cable, then power on.

## Step 3 — Contain the malware without root

Disable the reinstall paths first, then remove the payload. This is reversible and needs no root, but the root daemon and boot scripts keep running until Step 7, and a factory reset re-enables everything.

<details>
<summary>Inventory and evidence</summary>

```bash
adb shell pm list packages -f | sort > packages.txt
adb shell pm list packages -3 -i        # the payload shows installer=null
adb shell dumpsys activity services | grep -oE 'u0 [^ }]+' | grep -iE 'hotack|htc|storeos|ota'
adb shell ls -l /system/bin/qw /system/bin/appsdisable /system/bin/preinstall /system/bin/runin.sh
adb pull "$(adb shell pm path com.hotack.screensaversdk | sed 's/package://' | tr -d '\r')" payload.apk
```

</details>

<details>
<summary>Containment commands</summary>

```bash
adb shell pm disable-user --user 0 com.htc.storeos
adb shell pm disable-user --user 0 com.htc.htcotaupdate
adb shell pm disable-user --user 0 com.htc.screensaver
adb shell pm uninstall com.hotack.screensaversdk     # H726: it lives in /data
# H713: com.hotack.silentsdk lives in /system, so use pm disable-user instead
```

</details>

Check after a cold reboot: the three packages show in `pm list packages -d`, the payload is gone, and the quarantine DNS log stops showing `aodintech` lookups. Level 1 stops here.

## Step 4 — Back up the whole eMMC

Your own dump is the only trustworthy recovery source: it holds per-unit calibration (`Reserve0`, `private`, `env`) that no vendor image has. On H726 no root is needed, because `/dev/block/mmcblk0` is world-readable (mode 666; partition nodes are root-only).

<details>
<summary>Backup command</summary>

```bash
bash scripts/backup.sh backup          # ~10 minutes over USB 2.0
```

</details>

[`scripts/backup.sh`](scripts/backup.sh) streams the whole disk, carves every partition out using the image's own GPT, and checks each static partition against a SHA-256 of the same byte range computed on the projector. Every static partition must report `OK`. Then copy `backup/` to two places off the PC.

- `unpack_bootimg --boot_img backup/parts/init_boot_a.img --out x --format info` shows whether the ramdisk is in `init_boot` (non-zero ramdisk size) or `boot`.
- If `mmcblk0` isn't readable on your unit, the script stops, and this guide's backup-before-write order can't be followed as written. Rooting without a prior backup is out of scope here; see the [H726 XDA guide](https://xdaforums.com/t/guide-rooting-tutorial-for-a-magcubic-hy300-pro-with-an-allwinner-h726-and-android-14.4776519/), and back up immediately after rooting.

## Step 5 — Prepare and test the FEL rescue path

On H726 there is no fastboot and no usable slot B, so a unit that won't boot can only be recovered through the chip's FEL mode with Allwinner's PhoenixSuit on Windows. Set it up and prove the projector is detected **before** writing anything in Step 6.

**1. Get an official image of your build and check it.** Magcubic's support article "[How to Update the Firmware on the HY300PRO Projector via a USB Drive (H726 Chip)](https://www.magcubic-support.com/newsinfo/3145157.html)" links a [Google Drive folder](https://drive.google.com/drive/folders/1Teaoyh3RsPWyENtORIcWdAviP6Jyi_SE) with `update.img`, an unencrypted Allwinner IMAGEWTY file of about 2.2 GB. Save it as `update.img` in the repository root. The bootloader is reported to refuse images older than the installed build, so compare it with your dump using [`tools/imagewty.py`](tools/imagewty.py):

<details>
<summary>Check the official image against your dump (commands)</summary>

```bash
mkdir -p fex && python3 -I tools/imagewty.py update.img fex sunxi_version.fex init_boot.fex boot.fex vbmeta.fex
cat fex/sunxi_version.fex                      # build date, e.g. 2026-03-18 11:26:01
cmp -n "$(stat -c%s fex/init_boot.fex)" fex/init_boot.fex backup/parts/init_boot_a.img && echo "same build"
```

</details>

On the reference unit the March 2026 image matched byte for byte (boot, init_boot, vendor_boot, dtbo, vbmeta), which also proves the official firmware is the infected build.

**2. Build a rescue VM.**

- Windows 10 IoT Enterprise LTSC 2021 was used. Verify the ISO's SHA-256 against Microsoft's published value; the [MVS dump](https://github.com/awuctl/mvs) lists them.
- VirtualBox: USB 3.0 (xHCI) controller, no network adapter, and a USB filter for vendor ID `1f3a` with **no product ID** (FEL reconnects as a different product mid-flash).
- **Keep that filter inactive except during a rescue:** the projector's normal ADB device is also vendor `1f3a` (`1f3a:4ee7`), and an active filter steals it from the host.
- Get files into the VM with a read-only ISO (`mkisofs -J -R -iso-level 3 -o transfer.iso <dir>`) instead of shared folders.
- PhoenixSuit v1.10 as distributed on [Creality's wiki](https://wiki.creality.com/) (search for PhoenixSuit), with its Allwinner USB driver v1.0.0.3. The driver catalog is WHQL-signed, so no signature-enforcement workaround is needed. Avoid repacked v1.19 bundles.

**3. Test detection, without flashing:**

1. Unplug the projector's power **and** the A-to-A cable.
2. Hold the recessed flash button next to the HDMI port, connect the cable, then plug in power. Keep holding for 3 seconds. The screen stays dark.
3. The PC sees `1f3a:efe8`. In the VM, install the driver from Device Manager on the unknown device. Success shows as "USB Device(VID_1f3a_PID_efe8)".
4. PhoenixSuit's Home tab says "No Device Attached" in FEL mode. That's normal; it only talks to FEL devices during a firmware flash.
5. Unplug both cables and power on normally.

**If you ever flash:** Firmware tab → select `update.img` → enter FEL. Answer **NO** to any format prompt. The official image carries a generic `Reserve0` that differs from your unit's, so after flashing compare `Reserve0` and `private` against `backup/parts/` (Step 4's script will show the hashes) and, once rooted again, write your own copies back with Step 6's guarded write (sub-step 3), using that partition's name, your backup image as the source, and the guard and readback hashes swapped accordingly.

## Step 6 — Root with Magisk by patching init_boot

Magisk patches your own `init_boot_a`, and the result is written straight into that partition's byte range on the raw disk. This needs neither fastboot nor root, because `mmcblk0` is world-writable on H726. A guard refuses to write unless the target holds your stock image.

**Why Magisk:** these units run a 32-bit ARM kernel. KernelSU and APatch need arm64; Magisk only touches the ramdisk and still ships `armeabi-v7a` binaries.

**Check first:** `ro.boot.flash.locked` must be `0` and `ro.boot.verifiedbootstate` must be `orange`. The patched image fails its AVB hash and only boots on an unlocked bootloader. If yours is locked, stop.

1. Get [Magisk](https://github.com/topjohnwu/Magisk/releases) only from topjohnwu's GitHub releases, and compare the APK's SHA-256 with the digest listed on the release (v30.7 was used).
2. Patch on the device as the shell user: Android TV has no file picker for the app's "select and patch" flow, so run Magisk's own script. Use the ABI from `ro.product.cpu.abi`. Run this block and the next in **one bash session** (they share `$MAGISK`, `$ABI` and `$T`; in fish, start `bash` first).

<details>
<summary>Patch commands</summary>

```bash
MAGISK=Magisk-v30.7.apk                                   # the APK you downloaded, saved in the repo root
ABI=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')    # armeabi-v7a on H726
unzip -o "$MAGISK" "lib/$ABI/*" 'assets/*' -d mk
T=/data/local/tmp/mp; adb shell mkdir -p $T
for f in magiskboot magiskinit magisk init-ld busybox; do adb push mk/lib/$ABI/lib$f.so $T/$f; done
adb push mk/assets/boot_patch.sh mk/assets/util_functions.sh mk/assets/stub.apk backup/parts/init_boot_a.img $T/
adb shell "cd $T && chmod 755 magiskboot magiskinit magisk init-ld busybox && ./busybox sh boot_patch.sh $T/init_boot_a.img"
adb pull $T/new-boot.img magisk_init_boot_a.img
unpack_bootimg --boot_img magisk_init_boot_a.img --out chk --format info   # same size as the partition
```

The log should say "Stock boot image detected", add `magiskinit` as `init`, and back up the original to `.backup/init.xz`.

</details>

3. Guarded write: compute the range from your own GPT, then write and verify on the device. First confirm that `magisk_init_boot_a.img` is exactly as large as `backup/parts/init_boot_a.img` (`stat -c%s` on both); if it isn't, stop.

<details>
<summary>Guarded write commands</summary>

```bash
read start sectors < <(sfdisk --json backup/emmc_full.img | python3 -I -c 'import json,sys
for p in json.load(sys.stdin)["partitiontable"]["partitions"]:
    p["name"]=="init_boot_a" and print(p["start"], p["size"])')
(( start % 8 == 0 && sectors % 8 == 0 )) || echo 'NOT 4K-ALIGNED: stop here'
SKIP=$((start * 512 / 4096)); COUNT=$((sectors * 512 / 4096))
STOCK=$(sha256sum < backup/parts/init_boot_a.img | cut -d' ' -f1)
PATCH=$(sha256sum < magisk_init_boot_a.img | cut -d' ' -f1)
adb shell "pre=\$(dd if=/dev/block/mmcblk0 bs=4096 skip=$SKIP count=$COUNT 2>/dev/null | sha256sum | cut -d' ' -f1)
  [ \"\$pre\" = $STOCK ] || { echo 'GUARD FAILED: nothing written'; exit 2; }
  dd if=$T/new-boot.img of=/dev/block/mmcblk0 bs=4096 seek=$SKIP count=$COUNT conv=fsync && sync
  post=\$(dd if=/dev/block/mmcblk0 bs=4096 skip=$SKIP count=$COUNT 2>/dev/null | sha256sum | cut -d' ' -f1)
  [ \"\$post\" = $PATCH ] && echo 'WRITE VERIFIED' || echo 'READBACK MISMATCH'"
```

</details>

4. `adb reboot`: it should boot normally in 30–40 seconds. Then:
   - `adb shell ps -A | grep magiskd` shows the daemon running as root.
   - `adb install "$MAGISK"`, open the app and accept "Requires additional setup" (it reboots once).
   - `adb shell su -c id` returns `uid=0(root)` after you grant the on-screen prompt.

If it doesn't boot, use the Step 5 rescue. To undo root, restore your stock `backup/parts/init_boot_a.img` with the guarded write from sub-step 3 above, reversed: push the stock image and use it as the source, the guard must find `$PATCH` before writing, and the readback must match `$STOCK`. Do it with `su` once Step 7's enforcing SELinux is active, or use the Step 5 rescue.

## Step 7 — Install the hy300-clean Magisk module

One systemless module does the removal. Removing the module undoes everything except the remote key-map edit (Step 9) and the global settings it writes (see below).

<details>
<summary>What the module does (table)</summary>

| Component | Effect |
| --- | --- |
| Stubs in [`system/bin`](magisk/hy300-clean/system/bin/) | `qw` (root su daemon), `appsdisable` and `gmsopt` (both disable Google's boot receivers), `preinstall`, `runin.sh` (root `eval` of `/sdcard/runin_config`), `product_update_oem.sh` all just log and exit |
| `.replace` folders | `/product/app/StoreOs_QZ`, `HtcOtaUpdate_QZ`, `ScreenSaveQZ` appear empty, so those packages no longer exist (for as long as the module is installed) |
| [`sepolicy.rule`](magisk/hy300-clean/sepolicy.rule) + [`post-fs-data.sh`](magisk/hy300-clean/post-fs-data.sh) | Fills the vendor's policy gaps, then sets enforcing about 7 s into boot, before HALs, `system_server` and apps start |
| `system/product/overlay` | Our connectivity-check overlay (built below; explained in Step 10) and a zero-byte file that blanks the vendor's `www.google.cn` overlay |
| [`service.sh`](magisk/hy300-clean/service.sh) | Stops the `qw` service, sets Google NTP servers and connectivity URLs, and starts [`remote-buttons.sh`](magisk/hy300-clean/remote-buttons.sh) |
| `keystone.dex` (built from [`keystone/`](keystone/)) | Keystone adjustment from the remote, replacing the launcher's screen (Step 9) |

</details>

**Before building:**

1. Check your build with `adb shell getprop ro.build.display.id`. If it isn't `Projector.20260318.111759`, adapt the SELinux policy first (below).
2. Set `SOURCE` at the top of [`remote-buttons.sh`](magisk/hy300-clean/remote-buttons.sh) to your wired HDMI input. Plug a source into the HDMI port and run `adb shell dumpsys tv_input | grep HdmiInputService`: the input whose state changes is `HWn`, which means `SOURCE=HDMIn` (`HW2` → `HDMI2` on the reference unit). Unsure? Keep `HDMI2`; you can rebuild and reinstall later.
3. Keystone mode (Step 9) is enabled only on build `Projector.20260318.111759` (`KEYSTONE_BUILD` in `remote-buttons.sh`). On another build, test the helper over ADB with `show` and a `set` of your current values first (Step 9), then change `KEYSTONE_BUILD`.

**On a different build, adapt the SELinux part before enforcing.** [`sepolicy.rule`](magisk/hy300-clean/sepolicy.rule) was validated on build 20260318 with zero unexpected denials across boot and normal use. Enforcing too early with an incomplete policy hangs the boot: on the reference unit the audio HAL crash-looped and `system_server` restarted about 10 times.

<details>
<summary>Adapting the SELinux policy to your build</summary>

1. Build without `post-fs-data.sh` (`NO_ENFORCE=1 bash magisk/build.sh`) and install it, so SELinux stays permissive. Lift the audit rate limit with `adb shell su -c 'auditctl -r 0'`, use every feature (HDMI, settings screens, focus, keystone, audio, screensaver), then collect:

   ```bash
   adb shell su -c 'dmesg; logcat -d -b all' > denials.log
   python3 -I tools/avc2rules.py denials.log
   ```

2. Allow only what hardware and system functions need; `dontaudit` anything that reads user data, credentials or app sandboxes. Denials naming an app process (`tcontext=...:s0:c512,c768`) are MLS, and an `allow` alone won't fix them (the power HAL needed `typeattribute hal_power_default mlstrustedsubject`).
3. Dry-run before rebooting; this must exit 0:

   ```bash
   adb push magisk/hy300-clean/sepolicy.rule /data/local/tmp/
   adb shell su -c 'magiskpolicy --load /sys/fs/selinux/policy --save /data/local/tmp/t.pol --apply /data/local/tmp/sepolicy.rule'
   ```

4. Rebuild normally (`bash magisk/build.sh`), reinstall and reboot. If the boot hangs, ADB still works: `adb shell su -c 'setenforce 0'` lets it finish. Fix the rules and repeat until `logcat` shows no `permissive=0` denials outside app sandboxes.

</details>

<details>
<summary>Build and install the module (commands)</summary>

```bash
bash overlay/build.sh        # Step 10's overlay, copied into the module (needs the projector connected)
bash keystone/build.sh       # the keystone helper (Step 9), copied into the module
bash magisk/build.sh         # -> magisk/hy300-clean.zip
adb push magisk/hy300-clean.zip /data/local/tmp/
adb shell su -c 'magisk --install-module /data/local/tmp/hy300-clean.zip'
adb reboot
```

</details>

Removing the module doesn't undo the settings `service.sh` writes. `settings delete global` on `ntp_server`, `captive_portal_http_url`, `captive_portal_https_url`, `captive_portal_fallback_url` and `captive_portal_other_fallback_urls` reverses them.


## Step 8 — Fix the vendor accessibility wipe

The vendor modified `system_server` so that on **every focus change** it sets `accessibility_enabled=0` and empties `enabled_accessibility_services`, unless Netflix or YouTube is in front, when it force-enables its own helpers (`com.android.nfx`, `com.android.ytb`). Any accessibility service you enable is switched off within a second.

[`a11yfix/patch_services.sh`](a11yfix/patch_services.sh) builds a second module, `hy300-a11yfix`, from **your own** `services.jar`:

1. Pulls `/system/framework/services.jar` and finds the dex holding the hook (`classes3.dex` on the reference build).
2. Disassembles it with [baksmali 2.5.2](https://bitbucket.org/JesusFreke/smali/downloads/) and turns `DisplayContent.enableNfxAccessibility` and `enableYtbAccessibility` into `return-void`.
3. Reassembles with smali, then **proves** nothing else changed: after ignoring smali's dropped default static initialisers, `DisplayContent.smali` must be the only difference, or it aborts.
4. Rebuilds the jar, keeping each entry's original compression and 4-byte aligning stored dex entries, and adds `.replace` markers that remove the vendor helper apps.

<details>
<summary>Build and install the accessibility fix (commands)</summary>

```bash
bash a11yfix/patch_services.sh                    # or: ... path/to/stock/services.jar
adb push a11yfix/hy300-a11yfix.zip /data/local/tmp/
adb shell su -c 'magisk --install-module /data/local/tmp/hy300-a11yfix.zip'
adb reboot
```

</details>

The script keeps the stock jar as `a11yfix/build/services.stock.jar`; copy it into `backup/` after the first run. Once the module is active, the device serves the patched jar, so the script detects that and asks for a stock jar as its argument. The first boot takes a few seconds longer, because ART logs a `classes3.dex` checksum mismatch and runs the jar without the stale precompiled code. To check the fix, enable an accessibility service, switch apps, and confirm `adb shell settings get secure enabled_accessibility_services` still lists it. If `system_server` ever crash-loops: `adb shell su -c 'touch /data/adb/modules/hy300-a11yfix/disable'`, then reboot.

To inspect the hook yourself, decompile `services.jar` with [jadx](https://github.com/skylot/jadx/releases) and open `com/android/server/wm/DisplayContent.java`.

## Step 9 — Launcher, HDMI and remote buttons

**Launcher.** [Projectivy Launcher](https://www.apkmirror.com/apk/spocky/projectivy-launcher-android-tv/) is published only on Google Play; APKMirror republishes the Play-signed bundle. Pick the variant matching your ABI (`armeabi-v7a`, Android 12L+ on H726) and save it as `projectivy.apkm` in the repository root. Verify the signing certificate with [`tools/apkcert.py`](tools/apkcert.py): it must be SHA-256 `f6697bf4082ee97511e4de07863193884a015b7ab5860430321bda1042b0aadd` (`CN=Despesse Mickael`).

<details>
<summary>Install Projectivy and make it the launcher (commands)</summary>

```bash
unzip projectivy.apkm base.apk 'split_*.apk' -d proj && python3 -I tools/apkcert.py proj/*.apk
adb install-multiple proj/*.apk
adb shell cmd package set-home-activity com.spocky.projengmenu/.ui.home.MainActivity
adb shell pm disable-user --user 0 com.htc.magcubicos          # the Magcubic launcher
```

</details>

Before the last line, hold the mouse button for a second and check that the picture pulses (keystone mode, below; Back leaves it). If it doesn't, keep the launcher until it does: it holds the only other keystone screen.

Projectivy doesn't need root: deny it if it asks, or revoke it in Magisk → Superuser.

**Keystone.** Disabling `com.htc.magcubicos` removes the only keystone screen; the module's remote keystone mode replaces it:

1. **Hold the mouse button for about a second, then release.** The picture pulses inward once: keystone mode is on, and the remote's keys now go only to it. The mouse pointer may flash; mouse mode is left as it was, and a short press still toggles it.
2. **Up** moves toward a narrower top edge and **Down** toward a narrower bottom edge; **Right / Left** likewise toward a shorter right / left edge. So after narrowing the bottom, Up first widens it back. Hold an arrow to speed up.
3. **OK** saves (one more pulse) and leaves; **Back** restores the previous shape and leaves. 30 seconds without a key also cancels.

The launcher applies keystone by sending four corner points to the vendor display HAL (`vendor.display.config@1.0::IDisplayConfig`, transaction 36) and saving them as eight `persist.display.keystone_*` offsets, which the composer re-applies at boot (`keystoneSetCoordinates` in `logcat`). The helper ([`keystone/src/hy300/Keystone.java`](keystone/src/hy300/Keystone.java)) does the same; your existing zoom and corner offsets are kept as the base the arrows adjust. It can also be driven over ADB:

<details>
<summary>Keystone helper from ADB (commands)</summary>

```bash
K='CLASSPATH=/data/adb/modules/hy300-clean/keystone.dex app_process /system/bin hy300.Keystone'
adb shell su -c "'$K show'"     # saved offsets: ltx lty rtx rty lbx lby rbx rby (pixels in from each corner)
adb shell su -c "'$K set 0 0 0 0 0 0 0 0'"   # apply without saving (0 = no correction); reboot or OK in keystone mode to restore
adb shell su -c "'$K adjust'"   # keystone mode, as from the remote
```

</details>

**HDMI.** The vendor's driver registers three HDMI inputs, but only one is wired: **HDMI 2** (`HW2`) on the reference unit. Plug in a source and see which input changes state with `adb shell dumpsys tv_input | grep HdmiInputService`. Projectivy's Inputs entries can't open it, because nothing on this firmware handles Android's standard TV-passthrough intent. Use the vendor source picker (`com.softwinner.awsource`, under Projectivy's mobile apps) or the remote button below.

**Settings.** Stock TV Settings has no icon and ignores the generic "open Settings" request. Open it with `adb shell am start -n com.android.tv.settings/.MainSettings` or the cast button below. It also holds the vendor's Focus and Picture screens.

**Remote buttons.** The IR remote's key map is `/oem/usr/keylayout/sunxi-ir.kl`. The input button (scancode `0x93`, Linux key 643) is mapped to `PRJ_AIRPLAY`, which only shows casting instructions. The cast button (`0x98`, key 642) is mapped to `PRJ_MIRACAST`. Back up the file, then comment out both lines:

<details>
<summary>Remap the remote's input and cast buttons (commands)</summary>

```bash
adb shell su -c 'cp /oem/usr/keylayout/sunxi-ir.kl /data/local/tmp/sunxi-ir.kl.orig'
adb pull /data/local/tmp/sunxi-ir.kl.orig backup/
adb shell su -c "sed -i 's/^key 64[23][[:space:]]/# &/' /oem/usr/keylayout/sunxi-ir.kl"
```

</details>

The module's [`remote-buttons.sh`](magisk/hy300-clean/remote-buttons.sh) reads those keys raw. The input button toggles HDMI 2 ↔ home; the cast button toggles Settings ↔ home. It launches HDMI with the same intent the vendor picker sends (`--es input_source HDMI2`); without that extra, the viewer opens whichever input it last used, often a dead one. Check your own remote's codes: `adb shell getevent -p | grep -B1 '"sunxi-ir"'` shows its device (for example `/dev/input/event3`), then `adb shell su -c 'getevent -lt <device>'` prints each button press. With `-l` keys show as names; without it they're hex (`0283` = 643, `0282` = 642). If your HDMI port isn't `HDMI2`, change `SOURCE` at the top of the script, then rebuild (`bash magisk/build.sh`), reinstall the module and reboot. The Menu button already sends Android's `MENU`.

## Step 10 — Vendor apps and network endpoints

Most vendor apps run with the shared system UID, so each one effectively holds system powers. Disable what you don't use; everything is reversible with `pm enable`.

<details>
<summary>Vendor app table (what to disable, what to keep)</summary>

| Package | What it is | Action |
| --- | --- | --- |
| `com.hotack.screensaversdk` | The payload | Uninstalled in Step 3 |
| `com.htc.storeos`, `com.htc.htcotaupdate`, `com.htc.screensaver` | Silent installer, OTA updater, SDK host | Removed by the Step 7 module |
| `com.android.nfx`, `com.android.ytb` | Vendor accessibility helpers forced on in Netflix/YouTube | Removed by the Step 8 module |
| `com.htc.magcubicos` | Magcubic launcher; also the only keystone screen (replaced by the module's remote keystone mode); bundles Baidu analytics | Disable after Projectivy works |
| `com.softwinner.update` | Second (Allwinner) OTA updater | Disable: an OTA would overwrite `init_boot` |
| `com.android.toofifi` | Feitu/mphotool casting backend: frame-buffer capture, audio, camera, input injection; uploads logs to and checks updates from `server.mphotool.com` | Disable |
| `com.htc.samescreen`, `com.mphotool.dlna`, `com.mphotool.airplay` | Feitu cast front end, DLNA and AirPlay receivers | Disable |
| `com.softwinner.miracastReceiver` | Allwinner Miracast receiver | Disable unless you mirror from Windows (Win + K) or a Miracast phone; Pixel and Motorola phones only do Google Cast |
| `com.softwinner.tv.factorymenu`, `com.htc.clearmemory`, `com.mobisystems.office` | Factory menu, memory "cleaner", office suite (grabs every `content://` link) | Disable |
| `com.htc.htcsetup_wizard_d55` | Vendor setup wizard | Disable once `settings get global device_provisioned` and `settings get secure user_setup_complete` both return 1 |
| `com.htc.closedialog`, `com.hysd.vafocus` | Focus service and autofocus | **Keep** |
| `com.htc.htcbluetoothremotecontrol`, `com.softwinner.awmanager` | Remote service, Allwinner system manager | **Keep** |
| `com.softwinner.awsource`, `com.softwinner.awlivetv`, `com.softwinner.vis` | HDMI source picker, viewer, input service | **Keep** |

</details>

<details>
<summary>Disable the vendor apps (command)</summary>

```bash
for p in com.htc.magcubicos com.softwinner.update com.android.toofifi com.htc.samescreen com.mphotool.dlna com.mphotool.airplay com.softwinner.miracastReceiver com.softwinner.tv.factorymenu com.htc.clearmemory com.mobisystems.office; do adb shell pm disable-user --user 0 $p; done
# The setup wizard only once setup is recorded as complete (both must print 1):
adb shell settings get global device_provisioned; adb shell settings get secure user_setup_complete
adb shell pm disable-user --user 0 com.htc.htcsetup_wizard_d55
```

</details>

Also re-enable the Google boot receivers that `appsdisable` and `gmsopt` turned off (Play Protect among them). Do this **after** installing the Step 7 module, or `gmsopt` disables them again at the next boot. [`tools/google_boot_receivers.py`](tools/google_boot_receivers.py) lists every Google component that is both disabled and registered for `BOOT_COMPLETED`; `--apply` re-enables them with root and clears the vendor's `start_disable` flag: run `python3 -I tools/google_boot_receivers.py`, then `python3 -I tools/google_boot_receivers.py --apply`. After a reboot, a few may show as disabled again: Google turns off modules that don't apply to a TV (SMS short codes, smart text selection, Games) by itself. The vendor scripts always set `start_disable=1`, so as long as `adb shell settings get global start_disable` prints `null`, they didn't run.

**Without vendor casting receivers:** use HDMI from a trusted device. For a phone, run [scrcpy](https://github.com/Genymobile/scrcpy) on a PC and show it over HDMI; for Apple devices, run [UxPlay](https://github.com/FDH2/UxPlay) (FLOSS AirPlay receiver) on a PC. [Kodi](https://kodi.tv/) can act as a DLNA renderer, and [Sunshine](https://github.com/LizardByte/Sunshine) + [Moonlight](https://moonlight-stream.org/) stream a PC desktop. Don't give the projector ADB access to a phone: that hands it control of the phone.

### Point time sync and connectivity checks at Google US endpoints

After cleanup, the remaining background lookups are the vendor's choice of time and connectivity servers: China's national time service (`ntp.ntsc.ac.cn`), Alibaba (`ntp.aliyun.com`) and `www.google.cn`. The module replaces them with `time.android.com`, `time.google.com`, `connectivitycheck.gstatic.com` and `www.google.com`.

- **Time sync (NTP)** comes from a vendor resource overlay that the global setting overrides. [`service.sh`](magisk/hy300-clean/service.sh) sets it at every boot: `settings put global ntp_server "time.android.com|time.google.com"`.
- **Connectivity checks** can't be fixed by settings alone. Allwinner compiled `www.google.cn/generate_204` into NetworkStack's own default resources, and resource values take priority over the `captive_portal_*` settings. The vendor overlay (`/product/overlay/NetworkStackConfigAosp.apk`) repeats the URLs and is immutable, so `cmd overlay disable` refuses it. The module therefore ships its own static overlay ([`overlay/networkstack`](overlay/networkstack/)) at higher priority, plus a zero-byte file over the vendor overlay.

[`overlay/build.sh`](overlay/build.sh) fetches [aapt2](https://dl.google.com/android/maven2/com/android/tools/build/aapt2/9.4.1-15978811/aapt2-9.4.1-15978811-linux.jar) and [apksig](https://dl.google.com/android/maven2/com/android/tools/build/apksig/9.4.1/apksig-9.4.1.jar) from Google's Maven and checks each against its published `.sha256`. It builds against the device's own `framework-res.apk`, aligns `resources.arsc`, signs v2/v3 with a local key it generates ([`overlay/Sign.java`](overlay/Sign.java)), and copies the result into the module. The overlay targets Android 14 (`minSdkVersion 34`); on an Android 11 H713 build, check the NetworkStack resources first and adjust or skip it.

<details>
<summary>Verify the new endpoints (commands)</summary>

```bash
adb shell dumpsys network_time_update_service | grep getNtpConfig   # ntp://time.android.com, ntp://time.google.com
adb shell cmd overlay list com.android.networkstack                 # [x] local.hy300clean.networkstack.overlay
adb shell cmd overlay lookup com.android.networkstack com.android.networkstack:string/config_captive_portal_https_url
```

</details>

## Step 11 — Verify, keep it contained, and maintain

- [ ] **After a cold reboot:** `adb shell getenforce` says Enforcing; `adb shell ps -A | grep -w qw` is empty; `adb shell pm list packages | grep -E 'hotack|storeos|htcotaupdate'` is empty; `adb shell logcat -d -s hy300-clean` shows the blocked stubs.
- [ ] **No unexpected denials:** `adb shell logcat -d -b all | grep 'avc: *denied' | grep permissive=0` lists nothing outside app sandboxes (`untrusted_app*`).
- [ ] **A day of normal use on the quarantine network**, then check its DNS log against the [domain list](#whats-on-these-units).
- [ ] **Two copies of the backup off the PC**, including the original `sunxi-ir.kl`.
- [ ] **Long-term placement:** a guest network with client isolation (check that yours really keeps guests off the main LAN), or no network at all. Never your main LAN, and never a Google account.
- [ ] **Maintenance:** update Magisk only through its app or GitHub, and never accept a firmware update (the updaters are disabled, and an OTA would also wipe root). Re-run the checks after any change.

## Proof it worked: DNS log analysis

The reference unit sat on the quarantine network (Step 1) throughout the cleanup. Its DNS log is an independent record of what the firmware tried to contact, and when each attempt stopped.

**Summary:** 1,674 lookups from the projector over five hours, 23 distinct names. Every malware or vendor-tracking lookup stopped at the moment its source was disabled, and nothing new appeared afterwards. The nftables rule logged **zero dropped packets** all session, so nothing tried a hard-coded IP address either.

<details>
<summary>Malware and tracking lookups and when they stopped (table)</summary>

| Domain | What it is | Seen | Stopped |
| --- | --- | --- | --- |
| `store-api.aodintech.com` | StoreOS silent installer (malware command server) | 412 times, every 5 s | 16:45:53, one second before StoreOS was disabled at 16:45:54 |
| `saas.zeasn.tv`, `log.saas.zeasn.tv` | Zeasn smart-TV platform telemetry | At start-up, then every 15 min | The next 15-minute lookup never came after the Step 3 containment |
| `hmma.baidu.com` | Baidu mobile analytics SDK | One burst | Never again |
| `server.mphotool.com`, `server2.mphotool.com` | Feitu casting suite update checker and log upload | 385 each, every 2 s | When `com.android.toofifi` was disabled |

</details>

<details>
<summary>All 23 names, with first and last lookup times</summary>

| Lookups | First | Last | Name |
| ---: | --- | --- | --- |
| 412 | 16:11:29 | 16:45:53 | `store-api.aodintech.com` |
| 385 | 20:34:33 | 20:47:35 | `server.mphotool.com` |
| 385 | 20:34:33 | 20:47:35 | `server2.mphotool.com` |
| 144 | 16:15:12 | 21:29:08 | `gmscompliance-pa.googleapis.com` |
| 103 | 16:11:19 | 21:29:19 | `www.google.cn` |
| 30 | 16:11:27 | 21:29:36 | `ntp.ntsc.ac.cn` |
| 30 | 16:11:27 | 21:29:36 | `ntp.aliyun.com` |
| 30 | 16:11:27 | 21:29:36 | `time.android.com` |
| 26 | 16:15:06 | 20:36:23 | `connectivitycheck.gstatic.com` |
| 20 | 20:34:37 | 21:29:24 | `firebaseinstallations.googleapis.com` |
| 18 | 16:15:11 | 20:36:22 | `play-fe.googleapis.com` |
| 17 | 16:11:19 | 21:29:19 | `www.google.com` |
| 16 | 16:11:34 | 21:29:23 | `play.googleapis.com` |
| 14 | 16:15:11 | 20:43:22 | `beacons.gvt2.com` |
| 13 | 16:15:11 | 21:29:20 | `www.googleapis.com` |
| 12 | 16:15:04 | 20:36:08 | `android.clients.google.com` |
| 10 | 16:15:12 | 21:29:32 | `app-measurement.com` |
| 2 | 16:20:52 | 16:35:52 | `log.saas.zeasn.tv` |
| 2 | 16:21:45 | 16:21:47 | `hmma.baidu.com` |
| 2 | 20:35:59 | 21:28:18 | `www.msftconnecttest.com` |
| 1 | 16:11:19 | 16:11:19 | `saas.zeasn.tv` |
| 1 | 16:15:15 | 16:15:15 | `safebrowsing.google.com` |
| 1 | 21:29:21 | 21:29:21 | `android.googleapis.com` |

</details>

After the last vendor app was disabled, the only lookups left were Google Play Services, Android's connectivity checks and time sync. The last two still pointed at `www.google.cn`, `ntp.ntsc.ac.cn` and `ntp.aliyun.com`, which led to the endpoint change in Step 10.

**After the endpoint change** (module v12, 21:49–22:05): zero lookups of `www.google.cn`, `ntp.ntsc.ac.cn` or `ntp.aliyun.com`, and still zero dropped packets. Connectivity checks and time sync now go only to Google:

<details>
<summary>Lookups after the endpoint change (table)</summary>

| Lookups | Name | Purpose |
| ---: | --- | --- |
| 35 | `connectivitycheck.gstatic.com` | Connectivity check (HTTP) |
| 34 | `www.google.com` | Connectivity check (HTTPS) and fallback |
| 22 | `time.google.com` | Time sync |
| 22 | `time.android.com` | Time sync |
| 18 | `firebaseinstallations.googleapis.com` | Google Play Services / app Firebase |
| 16 | `play.googleapis.com` | Google Play Services and connectivity fallback |
| 14 | `gmscompliance-pa.googleapis.com` | Google Play Services device compliance |
| 9 | `app-measurement.com` | Google Analytics for Firebase |
| 4 | `beacons.gvt2.com` | Google network error reporting |
| 2 | `www.msftconnecttest.com` | Microsoft's connectivity probe, used by Projectivy Launcher (the hostname is in its APK, not in the firmware) |

</details>

To reproduce this on your unit, run `sudo bash scripts/quarantine.sh status` during each step, or copy `/var/log/hy300-dns.log` and summarise it per domain.

## What's on these units

<details>
<summary>Packages</summary>

| Package | Role | H726 2026 |
| --- | --- | --- |
| `com.hotack.screensaversdk` | Payload: system UID, `ExpandSdkService`, silent installs and settings control | Present in `/data` |
| `com.hotack.silentsdk` | H713 dropper and residential-proxy enrolment | Absent |
| `com.htc.storeos` | Silent installer; fetches the payload at runtime (HY350 analysis) | Present |
| `com.htc.htcotaupdate` | OTA over plain HTTP; reinstall path | Present |
| `com.android.toofifi` + `com.mphotool.*` | Feitu casting suite with its own updater and log upload | Present |
| `com.hotack.writesn`, `com.htc.eventuploadservice`, `com.htc.expandsdk`, `com.htc.htclauncherhighenglishd08` | Device ID, telemetry, ad injection, launcher (H713/HY350) | Absent |

</details>

<details>
<summary>Files and firmware behaviour on the H726 build</summary>

- `/system/bin/qw` + `/system/etc/init/qw.rc`: a renamed Koush Superuser su daemon, started as root in `class core`.
- `/system/bin/appsdisable`: once after first boot, disables every Google `BOOT_COMPLETED` receiver (Play Protect included).
- `/system/bin/gmsopt` + `/system/etc/init/gmsopt.rc`: the same again, at every boot whenever the `start_disable` flag isn't set, sparing only the permission controller, setup wizard and media provider.
- `/system/bin/preinstall`: at every boot installs any APK/XAPK in `/system`, `/vendor`, `/product`, `/oem` or `/sdcard` `preinstall` folders.
- `/system/bin/runin.sh`: factory burn-in test run as root at every boot; `eval`s lines from `/sdcard/runin_config` if that file exists.
- `/system/bin/product_update_oem.sh`: after an OTA, copies `/product/oem/<channel>` over `/oem` and clears the launcher's data.
- `DisplayContent.updateFocusedWindowLocked` in `services.jar`: wipes all accessibility services on each focus change.
- NetworkStack with `www.google.cn` compiled into its default connectivity-check URLs; NTP via `ntp.ntsc.ac.cn` and `ntp.aliyun.com`.
- `/dev/block/mmcblk0` mode 666, `/oem` world-writable vfat, SELinux permissive via `androidboot.selinux=permissive` in both the kernel command line and the bootconfig.
- The kernel was built by `hotack@dell-PowerEdge-R740`, the same name as the payload SDK.

</details>

<details>
<summary>Domains and IPs for a DNS sinkhole or blocklist</summary>

```
store-api.aodintech.com
event-api.aodintech.com
pb-api.aodintech.com
ota-api.aodintech.com
cdn-store.aodintech.com
server.mphotool.com
server2.mphotool.com
saas.zeasn.tv
log.saas.zeasn.tv
hmma.baidu.com
int.vaicore.site
int.dewrain.life
int.akisinn.info
api.pixelpioneerss.com
sta.smartinnovate.net
bur.thedynamicleap.com
kkoip.com
ota.triplesai.com
otaapi.triplesai.com
shortx.srafx.com
balancer.api.net2fast.com
syslogcollector.com
euads-o.api.leiniao.com
103.124.165.222
64.32.27.247
139.199.190.220
128.12.122.35
```

Also watch for heavy `app.appsflyer.com` / `*.onelink.me` traffic and connections to ports 12341–12342.

</details>

## Troubleshooting

<details>
<summary>Symptoms and fixes</summary>

| Symptom | Cause and fix |
| --- | --- |
| Stuck on the boot logo after enabling SELinux enforcing | The policy is missing something the boot needs. ADB works mid-boot: `adb shell su -c 'setenforce 0'` lets it finish; then fix `sepolicy.rule` (Step 7) |
| Won't boot after the `init_boot` write | FEL + PhoenixSuit with an official image of your build (Step 5); answer NO to format, restore `Reserve0`/`private` |
| Android robot with no text after `adb reboot bootloader` | No fastboot on H726. Unplug power **and** the USB cable, then power on |
| Projector stays partly on when unplugged | The A-to-A cable backfeeds 5 V; unplug it too |
| `adb devices` shows `no permissions` | Install Android udev rules and replug |
| `adb connect` fails with `CERTIFICATE_UNKNOWN` | TLS-only network ADB with no pairing UI; use the USB cable |
| ADB device vanishes while the rescue VM runs | The VM's `1f3a` USB filter grabbed it; deactivate the filter except during a rescue |
| HDMI viewer shows "no signal" | Wrong input: launch it with `--es input_source HDMI2` (or your port), not bare |
| Accessibility services keep turning off | The vendor focus hook; apply Step 8 |
| Picture settings don't persist under enforcing | `tvserver` needs write access to `/oem` (the `panel_config.ini` rules in `sepolicy.rule`) |
| Holding the mouse button doesn't open keystone mode | `adb shell su -c 'ls -l /data/adb/modules/hy300-clean/'` must list `keystone.dex`; if not, run `bash keystone/build.sh` and `bash magisk/build.sh`, reinstall the module and reboot. Then check `adb shell logcat -d -s hy300-keystone hy300-clean AndroidRuntime` (a different build is skipped with a log line). Hold until about 1 s of IR repeats arrive: pointing the remote straight at the projector helps |
| `system_server` crash-loops after Step 8 | `adb shell su -c 'touch /data/adb/modules/hy300-a11yfix/disable'`, reboot, recheck the dex diff |
| `patch_services.sh` says the jar is already patched | The module is active, so the device serves the patched jar; pass a stock `services.jar` as the argument |
| Remote buttons do nothing | Check the two `# key 64x` lines in `sunxi-ir.kl` and that `pgrep -f remote-buttons.sh` returns a process |
| Projector doesn't rejoin the quarantine Wi-Fi after a reboot | Android won't auto-join networks without internet; reconnect by hand |
| Google boot receivers disabled again after a reboot | If `settings get global start_disable` prints `1`, a vendor script ran: check that the module's `gmsopt` and `appsdisable` stubs are in place. If it prints `null`, Google disabled modules that don't apply to TVs itself |
| After a factory reset | `/data` is wiped (modules, Magisk app, disabled-package states); the patched `init_boot` stays. Repeat Steps 3 and 7–10 |

</details>

## Software and sources

**Software used**

<details>
<summary>Software used (table)</summary>

| Software | Used for |
| --- | --- |
| [Android platform tools](https://developer.android.com/tools/releases/platform-tools) | `adb`, `fastboot` |
| [Magisk](https://github.com/topjohnwu/Magisk/releases) (topjohnwu) | Root, systemless modules, SELinux policy patching |
| [jadx](https://github.com/skylot/jadx/releases) | Decompiling vendor apps and `services.jar` |
| [smali / baksmali 2.5.2](https://bitbucket.org/JesusFreke/smali/downloads/) | The `services.jar` patch |
| [D8 (r8 9.4.28)](https://dl.google.com/android/maven2/com/android/tools/r8/9.4.28/r8-9.4.28.jar) (Google Maven) | Compiling the keystone helper to dex |
| [aapt2](https://dl.google.com/android/maven2/com/android/tools/build/aapt2/9.4.1-15978811/aapt2-9.4.1-15978811-linux.jar), [apksig](https://dl.google.com/android/maven2/com/android/tools/build/apksig/9.4.1/apksig-9.4.1.jar) (Google Maven) | Building and signing the NetworkStack overlay |
| [Projectivy Launcher](https://www.apkmirror.com/apk/spocky/projectivy-launcher-android-tv/) (APKMirror) | Replacement launcher |
| [VirtualBox](https://www.virtualbox.org/) | Rescue VM for PhoenixSuit |
| [MVS dump](https://github.com/awuctl/mvs) (awuctl) | Microsoft's own ISO hashes, to verify the Windows image |
| [Official H726 firmware](https://drive.google.com/drive/folders/1Teaoyh3RsPWyENtORIcWdAviP6Jyi_SE) (Magcubic) | `update.img` for the PhoenixSuit rescue |

</details>

**Research**

- [Reverse engineering Android malware with Claude Code](https://zanestjohn.com/blog/reing-with-claude-code) — Zane St. John: H713 silentsdk analysis, firmware init scripts, IOCs
- [hy350max-badbox-removal](https://github.com/maximilian-sh/hy350max-badbox-removal) — maximilian-sh: H726/Android 14 IOCs, StoreOS fetching the payload
- [Android-Projector-C2-Malware](https://github.com/Kavan00/Android-Projector-C2-Malware) — Kavan00: the `qw` su daemon, stage-2 plugins, more C2 domains
- [hy300pro-debloat](https://github.com/micha102/hy300pro-debloat) — micha102: proxy SDK packages and ADB disable commands
- [HY300-H713-Research](https://github.com/lolmam/HY300-H713-Research) — lolmam: H713 eMMC dump and own-boot-image Magisk root
- [Hacking HY300 Pro+ Projector](https://gist.github.com/probonopd/3ad6b7777caea1503f00d5fe7710ad06) — probonopd: ADT-3 spoofing, FEL mode, launcher tips
- [Rooting tutorial for a Magcubic HY300 Pro with an Allwinner H726 and Android 14](https://xdaforums.com/t/guide-rooting-tutorial-for-a-magcubic-hy300-pro-with-an-allwinner-h726-and-android-14.4776519/) — XDA: Magisk on `init_boot`, PhoenixSuit flashing
- [Android TV and root tutorial for Allwinner H713-based projectors](https://xdaforums.com/t/beta-android-tv-and-root-tutorial-for-allwinner-h713-based-projectors.4744020/) — XDA: H713 root path
- [Magcubic HY300 Pro firmware (H713)](https://androidpctv.com/firmware-magcubic-hy300-allwinner-h713/) and [(H726)](https://androidpctv.com/firmware-magcubic-hy300-pro-ultra-h726/) — androidpctv: flash-button procedure
- [HY300 Pro USB-drive firmware update (H726)](https://www.magcubic-support.com/newsinfo/3145157.html) — Magcubic support
- [BADBOX overview](https://www.incibe.es/servicio-antibotnet/info/Badbox) — INCIBE: why resets and antivirus don't remove it
