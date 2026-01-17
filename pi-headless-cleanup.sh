#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

echo "=== Raspberry Pi Headless Cleanup (CLEAN ONLY) ==="

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root"
  exit 1
fi

# Abort if eth0 is missing
if ! ip link show eth0 >/dev/null 2>&1; then
  echo "ERROR: eth0 not found, aborting"
  exit 1
fi

# Ensure rfkill exists (do NOT install)
command -v rfkill >/dev/null 2>&1 || {
  echo "ERROR: rfkill missing"
  exit 1
}

echo "== Disabling unnecessary services =="

SERVICES=(
  bluetooth.service
  wpa_supplicant.service
  avahi-daemon.service
  triggerhappy.service
  ModemManager.service
)

for s in "${SERVICES[@]}"; do
  systemctl disable --now "$s" 2>/dev/null || true
done

echo "== Blocking Wi-Fi and Bluetooth via rfkill =="

rfkill block wifi || true
rfkill block bluetooth || true
rfkill list || true

echo "== Persisting rfkill blocks =="

RFKILL_SERVICE="/etc/systemd/system/rfkill-block.service"

if [[ ! -f "$RFKILL_SERVICE" ]]; then
  {
    echo "[Unit]"
    echo "Description=Block Wi-Fi and Bluetooth"
    echo "After=multi-user.target"
    echo
    echo "[Service]"
    echo "Type=oneshot"
    echo "ExecStart=/usr/sbin/rfkill block wifi"
    echo "ExecStart=/usr/sbin/rfkill block bluetooth"
    echo "RemainAfterExit=yes"
    echo
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } > "$RFKILL_SERVICE"
fi

systemctl daemon-reload
systemctl enable rfkill-block.service

echo "== Removing GUI packages (purge only) =="

APT_FLAGS="--yes --no-install-recommends --no-install-suggests"

GUI_PACKAGES=(
  lightdm
  xserver-xorg-core
  x11-common
  lxsession
  lxpanel
  openbox
  lxde*
)

apt-get purge $APT_FLAGS "${GUI_PACKAGES[@]}" || true
apt-get autoremove $APT_FLAGS
apt-get autoclean -y

echo "== Firmware disables =="

BOOTCFG="/boot/config.txt"

grep -q "^dtoverlay=disable-bt" "$BOOTCFG" || echo "dtoverlay=disable-bt" >> "$BOOTCFG"
grep -q "^dtoverlay=disable-wifi" "$BOOTCFG" || echo "dtoverlay=disable-wifi" >> "$BOOTCFG"
grep -q "^dtparam=audio=off" "$BOOTCFG" || echo "dtparam=audio=off" >> "$BOOTCFG"

if grep -q "^gpu_mem=" "$BOOTCFG"; then
  sed -i 's/^gpu_mem=.*/gpu_mem=16/' "$BOOTCFG"
else
  echo "gpu_mem=16" >> "$BOOTCFG"
fi

echo "== Cleaning logs =="

journalctl --vacuum-time=7d || true

echo "=== DONE ==="
echo "No packages installed."
echo "eth0 untouched."
echo "Reboot recommended."
