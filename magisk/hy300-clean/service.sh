#!/system/bin/sh
# qw.rc is not oneshot: init restarts the (stubbed) service after each exit. Stop it for good.
stop qw
log -t hy300-clean "service.sh: qw stopped (init.svc.qw=$(getprop init.svc.qw))"

log -t hy300-clean "service.sh: SELinux $(getenforce)"

# Remote input/cast buttons: HDMI and Settings toggles (see remote-buttons.sh).
MODDIR=${0%/*}
nohup sh "$MODDIR/remote-buttons.sh" >/dev/null 2>&1 &

# Network time and connectivity checks: Google endpoints instead of the vendor's
# ntp.ntsc.ac.cn / ntp.aliyun.com / www.google.cn. The google.cn probe URLs are compiled into the
# vendor NetworkStack and win over settings, so system/product/overlay also carries our own
# overlay (NetworkStackConfigHy300.apk) and blanks the vendor one; the settings are a fallback.
settings put global ntp_server "time.android.com|time.google.com"
settings put global captive_portal_http_url http://connectivitycheck.gstatic.com/generate_204
settings put global captive_portal_https_url https://www.google.com/generate_204
settings put global captive_portal_fallback_url http://www.google.com/gen_204
settings put global captive_portal_other_fallback_urls http://play.googleapis.com/generate_204
