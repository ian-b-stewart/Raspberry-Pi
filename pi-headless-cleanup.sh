#!/usr/bin/env bash
set -euo pipefail

echo "=== Raspberry Pi Headless Cleanup (Ethernet-only) ==="
echo "Disables Wi-Fi/Bluetooth, removes GUI packages, and trims system services."
echo

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

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

# rfkill is assumed to already exist; just block radios
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
ExecStart=/usr/sbin/rfkill block bluetooth
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rfkill-block.service

echo
echo "== Removing desktop / GUI packages =="

# Safe GUI packages to remove; avoids touching networking
GUI_PACKAGES=(
  xserver-xorg-core
  xserver-xorg-video-*
  x11-common
  x11-utils
  x11-xserver-utils
  lightdm
  lxsession
  lxpanel
  lxappearance
  lxterminal
  openbox
  lxde*
  gnome*
  kde*
  gtk*
  mesa-*
)

apt purge -y "${GUI_PACKAGES[@]}" || true

echo
echo "== Removing Raspberry Pi desktop extras =="

PI_DESKTOP_EXTRAS=(
  wolfram-engine
  libreoffice*
  scratch*
  sonic-pi
  python-games
  minecraft-pi
  nuscratch
  penguinspuzzle
)

apt purge -y "${PI_DESKTOP_EXTRAS[@]}" || true

echo
echo "== Autoremove and cleanup =="

apt autoremove --purge -y
apt autoclean -y

echo
echo "== Disabling Wi-Fi and Bluetooth at firmware level =="

BOOTCFG="/boot/config.txt"

grep -q "dtoverlay=disable-bt" "$BOOTCFG" || echo "dtoverlay=disable-bt" >> "$BOOTCFG"
grep -q "dtoverlay=disable-wifi"
