#!/system/bin/sh
# hy300-clean: repurposes IR remote buttons by reading the remote's raw input events.
#   input button (scancode 0x93, key 643): HDMI 2 <-> home
#   cast button  (scancode 0x98, key 642): stock TV Settings <-> home
#     (both keys are commented out in /oem/usr/keylayout/sunxi-ir.kl, so Android ignores them)
#   mouse button (key 365), held ~1 s: keystone mode (keystone.dex): arrows adjust, OK saves,
#     Back cancels. A short press still toggles mouse mode as before.
HDMI=com.softwinner.awlivetv/.MainActivity
# Same intent the vendor source picker (awsource) sends: string extra input_source,
# flags NEW_TASK + SINGLE_TOP. Without the extra the viewer opens its last internal source.
# Per unit: the HDMI input wired to the physical port (README Step 9 shows how to find it).
SOURCE=HDMI2
SETTINGS=com.android.tv.settings/.MainSettings
MODDIR=${0%/*}
LONG_PRESS_SCANS=9  # a held IR key repeats its scancode about every 108 ms: 9 is about 1 s
# keystone.dex calls this build's display service by transaction number; elsewhere, test it over
# ADB first (README Step 9), then set your build here.
KEYSTONE_BUILD=Projector.20260318.111759

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done

ir_device() {
  getevent -i 2>/dev/null | awk '/^add device/ {d=$4} /name:/ && /"sunxi-ir"/ {print d; exit}'
}

top_pkg() {
  dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity | sed -n 's/.* u0 \([^/]*\)\/.*/\1/p'
}

keystone_mode() {  # keystone_mode <ir device>
  if [ "$(getprop ro.build.display.id)" != "$KEYSTONE_BUILD" ]; then
    log -t hy300-clean "remote-buttons: keystone mode skipped: build is not $KEYSTONE_BUILD"
    return
  fi
  # Android's TvWindowManager toggles mouse mode when the mouse button is released, however long
  # it was held. Replay one press into the remote's device to toggle it back; `input keyevent`
  # can't, because Android maps the vendor keycode (10009) to KEYCODE_UNKNOWN on injection.
  for e in "1 365 1" "0 0 0" "1 365 0" "0 0 0"; do sendevent "$1" $e; done
  CLASSPATH="$MODDIR/keystone.dex" app_process /system/bin hy300.Keystone adjust >/dev/null 2>&1 ||
    log -t hy300-clean "remote-buttons: keystone helper failed"
}

toggle() {  # toggle <package> <am start args...>
  pkg=$1; shift
  if [ "$(top_pkg)" = "$pkg" ]; then
    input keyevent KEYCODE_HOME
  else
    am start "$@" >/dev/null 2>&1
  fi
}

while true; do
  DEV=$(ir_device)
  if [ -n "$DEV" ]; then
    log -t hy300-clean "remote-buttons: watching $DEV"
    # EV_KEY (0001), key 643 (0283) / 642 (0282) / 365 (016d), down (00000001) / up (00000000);
    # EV_MSC (0004) MSC_SCAN (0004): the scancode, repeated while a key is held
    scans=-1
    getevent "$DEV" | while read t c v; do
      case "$t $c $v" in
        "0001 0283 00000001") toggle com.softwinner.awlivetv -n "$HDMI" --es input_source "$SOURCE" -f 0x30000000 ;;
        "0001 0282 00000001") toggle com.android.tv.settings -n "$SETTINGS" ;;
        "0001 016d 00000001") scans=0 ;;
        "0004 0004 "*) [ "$scans" -ge 0 ] && scans=$((scans + 1)) ;;
        "0001 016d 00000000") [ "$scans" -ge "$LONG_PRESS_SCANS" ] && keystone_mode "$DEV"; scans=-1 ;;
      esac
    done
  fi
  sleep 5  # getevent exited or device missing: retry
done
