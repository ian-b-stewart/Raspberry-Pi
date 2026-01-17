#!/usr/bin/env bash
set -euo pipefail

echo "=== Raspberry Pi Headless Cleanup (Ethernet-only) ==="
echo "Safe, disaster-proof cleanup script"
echo

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

# Ensure APT never installs recommended packages
APT_FLAGS="--yes --no-install-recommends"

echo "== Disabling unnecessary services =="

SERVICES=(
  bluetooth.service
  wpa_supplicant.service
  avahi-daemon.service
  triggerhappy.service
  ModemManager.service
)

for svc in "${SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "$svc"; then
    systemctl disable --now "$svc" || true
    echo "Disabled $svc"
  fi
done

echo
echo "== Blocking Wi-Fi and Bluetooth via rfkill =="

# rfkill assumed installed; just block radios
rfkill block wifi || true
rfkill block bluetooth || true

rfkill list || true

echo
echo "== Persisting rfkill blocks across reboots =="

cat >/etc/systemd/system/rfkill-block.service <<'EOF'
[Unit]
Description=Block Wi-Fi and Bluetooth via rfkill
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill block wifi
ExecStart=/usr/sbin/rfkill
