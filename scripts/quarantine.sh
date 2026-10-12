#!/usr/bin/env bash
# HY300 quarantine Wi-Fi: an access point hosted by this PC with no route anywhere.
# The projector gets DHCP and DNS from this PC. Every DNS query is logged and answered
# NXDOMAIN, and every packet it tries to send past the PC is logged and dropped.
# The PC itself stays on its normal Wi-Fi the whole time.
#
# Usage: sudo bash quarantine.sh up|down|status
#   PARENT=<iface> overrides the auto-detected Wi-Fi client interface.
# Needs NetworkManager (nmcli), iw, nftables and dnsmasq (NetworkManager's shared mode uses it);
# uses ufw only if it is installed and active.
set -euo pipefail

for cmd in nmcli iw nft dnsmasq; do command -v "$cmd" >/dev/null || { echo "missing: $cmd" >&2; exit 1; }; done
# The Wi-Fi interface currently connected as a client; the access point shares its radio.
PARENT=${PARENT:-$(iw dev | awk '/Interface/ {i=$2} /type managed/ {print i; exit}')}
[[ -n $PARENT ]] || { echo "no Wi-Fi client interface found; set PARENT=<iface>" >&2; exit 1; }
IFACE=ap0
CON=hy300-quarantine
SSID=hy300-quarantine
GATEWAY=10.42.99.1/24
AP_MAC=02:48:59:33:30:30   # locally administered, so it never collides with the parent's MAC
DNS_LOG=/var/log/hy300-dns.log
DNSMASQ_CONF=/etc/NetworkManager/dnsmasq-shared.d/hy300.conf
PSK_FILE=/root/hy300-quarantine.psk
FWD_STATE=/run/hy300-quarantine.ip_forward   # restored on down

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

firewall_up() {
  # Forward-path drop in its own nft table, independent of ufw's own FORWARD DROP policy.
  nft -f - <<EOF
table inet hy300
delete table inet hy300
table inet hy300 {
  chain forward {
    type filter hook forward priority -50; policy accept;
    iifname "$IFACE" limit rate 20/second log prefix "hy300-drop "
    iifname "$IFACE" drop
    oifname "$IFACE" drop
  }
  # The projector may reach this PC only for DHCP and DNS; replies to connections the PC opens
  # (adb over Wi-Fi) are allowed, everything else from it is logged and dropped.
  chain input {
    type filter hook input priority -50; policy accept;
    iifname "$IFACE" ct state established,related accept
    iifname "$IFACE" udp dport { 53, 67 } accept
    iifname "$IFACE" tcp dport 53 accept
    iifname "$IFACE" limit rate 20/second log prefix "hy300-in-drop "
    iifname "$IFACE" drop
  }
}
EOF
  # If ufw is active it denies incoming by default; open only DHCP and DNS on the quarantine interface.
  if ufw_active; then
    ufw allow in on "$IFACE" to any port 67 proto udp comment hy300 >/dev/null
    ufw allow in on "$IFACE" to any port 53 comment hy300 >/dev/null
  fi
}

ufw_active() { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; }

firewall_down() {
  nft delete table inet hy300 2>/dev/null || true
  if command -v ufw >/dev/null; then
    ufw delete allow in on "$IFACE" to any port 67 proto udp >/dev/null 2>&1 || true
    ufw delete allow in on "$IFACE" to any port 53 >/dev/null 2>&1 || true
  fi
}

dns_up() {
  mkdir -p "$(dirname "$DNSMASQ_CONF")"
  cat >"$DNSMASQ_CONF" <<EOF
# HY300 quarantine: log every lookup, forward nothing upstream.
log-queries
log-facility=$DNS_LOG
address=/#/
EOF
}

ap_up() {
  iw dev "$IFACE" info &>/dev/null || iw dev "$PARENT" interface add "$IFACE" type __ap

  # Many cards run an AP and a client together only on one channel, so follow the parent's.
  local ch band
  ch=$(iw dev "$PARENT" info | awk '/channel/{print $2; exit}')
  [[ -n $ch ]] || { echo "$PARENT is not connected; can't pick a channel." >&2; exit 1; }
  if (( ch > 14 )); then band=a; else band=bg; fi

  if ! nmcli -t -f NAME connection show | grep -qx "$CON"; then
    head -c 12 /dev/urandom | base64 | tr -d '/+=' >"$PSK_FILE"
    chmod 600 "$PSK_FILE"
    nmcli connection add type wifi ifname "$IFACE" con-name "$CON" autoconnect no ssid "$SSID" \
      802-11-wireless.mode ap 802-11-wireless.cloned-mac-address "$AP_MAC" \
      wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp \
      wifi-sec.psk "$(cat "$PSK_FILE")" \
      ipv4.method shared ipv4.addresses "$GATEWAY" ipv6.method disabled >/dev/null
  fi
  nmcli connection modify "$CON" 802-11-wireless.band "$band" 802-11-wireless.channel "$ch"
  nmcli connection up "$CON" >/dev/null
  echo "AP up: SSID $SSID, band $band, channel $ch"
  echo "Password: $(cat "$PSK_FILE")"
}

status() {
  nmcli -t -f GENERAL.STATE connection show "$CON" 2>/dev/null || echo "connection: absent"
  echo "--- firewall"
  nft list table inet hy300 2>/dev/null | grep -E 'drop|log' || echo "nft table: ABSENT"
  echo "--- DHCP leases"
  cat /var/lib/NetworkManager/dnsmasq-"$IFACE".leases 2>/dev/null || echo "(none)"
  echo "--- last 15 DNS queries"
  grep 'query\[' "$DNS_LOG" 2>/dev/null | tail -15 || echo "(none)"
  echo "--- last 15 dropped packets"
  journalctl -k --no-pager -g 'hy300-(in-)?drop' -n 15 -o cat 2>/dev/null || echo "(none)"
}

case "${1:-}" in
  up)
    # NetworkManager's shared mode turns IPv4 forwarding on; remember the old value for down.
    [[ -f $FWD_STATE ]] || sysctl -n net.ipv4.ip_forward >"$FWD_STATE"
    firewall_up   # firewall first: the AP never exists without the drop rules in place
    dns_up
    ap_up
    ;;
  down)
    nmcli connection down "$CON" >/dev/null 2>&1 || true
    iw dev "$IFACE" del 2>/dev/null || true
    firewall_down
    rm -f "$DNSMASQ_CONF"
    if [[ -f $FWD_STATE ]]; then sysctl -qw net.ipv4.ip_forward="$(cat "$FWD_STATE")"; rm -f "$FWD_STATE"; fi
    echo "Quarantine down. DNS log kept at $DNS_LOG"
    ;;
  status) status ;;
  *) echo "Usage: sudo bash $0 up|down|status" >&2; exit 1 ;;
esac
