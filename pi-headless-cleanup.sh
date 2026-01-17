#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

echo "=== Raspberry Pi Headless Cleanup (FIXED) ==="

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root"
  exit 1
fi

# Safety: ensure ethernet exists
if ! ip link show eth0 >/dev/null 2>&1; then
  echo "ERROR: eth0 not found, aborting"
  exit 1
fi

# Safety: ensure rfkill exists (DO NOT INSTALL)
command -v rfkill >/dev/null 2>&1 || {
  echo "ERROR: rfkill not present"
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

for svc in "${SERVICES[@]}"; do
  systemctl disable --now "$svc" 2>/dev/null || true
done

echo "== Blocking Wi-Fi and Bluetooth via rfkill =="

rfkill block wifi || true
rfkill block bluetooth || true
rfkill list || true

echo "== Persisting rfkill blocks =="

RFKILL_SERVICE="/etc/systemd/system/rfkill-block.service"

# Delete any broken version first
rm -f "$RFKILL_SERVICE"

# Create service WITHOUT heredocs
printf "%s\n" \
"[Unit]" \
"Description=Block Wi-Fi and Bluetooth via rfkill" \
"After=multi-user.target" \
"" \
"[Service]" \
"Type=oneshot" \
"ExecStart=/usr/sbin/rfkill block wifi" \
"ExecStart=/usr/sbin/rfkill block bluetooth" \
"RemainAfterExit=yes" \
"" \
"[Install]" \
"WantedBy=multi-user.target" \
> "$RFKILL_SERVICE"

# Force systemd to fully reload unit state
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable rfkill-block.service

echo "== Removing GUI packages (purge only) =="

GUI_PACKAGES=(
  lightdm
  xserver-xorg-core
  x11-common
  lxsession
  lxpanel
  openbox
  lxde*
)

# VALID apt-get usage ONLY
apt-get -y purge "${GUI_PACKAGES[@]}" || true
apt-get -y autoremove --purge
apt-get -y autoclean

echo "== Firmware-level disables =="

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
echo "No NVIDIA / DKMS possible."
echo "eth0 untouched
