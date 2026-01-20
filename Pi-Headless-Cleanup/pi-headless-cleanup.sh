#!/usr/bin/env bash
set -e

echo "=== Raspberry Pi Headless Cleanup ==="

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root"
  exit 1
fi

ip link show eth0 >/dev/null 2>&1 || {
  echo "eth0 missing, aborting"
  exit 1
}

command -v rfkill >/dev/null 2>&1 || {
  echo "rfkill missing, aborting"
  exit 1
}

echo "Disabling services"
systemctl disable --now bluetooth.service 2>/dev/null || true
systemctl disable --now wpa_supplicant.service 2>/dev/null || true
systemctl disable --now avahi-daemon.service 2>/dev/null || true
systemctl disable --now triggerhappy.service 2>/dev/null || true
systemctl disable --now ModemManager.service 2>/dev/null || true

echo "Blocking radios"
rfkill block wifi || true
rfkill block bluetooth || true

echo "Persisting rfkill"
rm -f /etc/systemd/system/rfkill-block.service
printf "%s\n" \
"[Unit]" \
"Description=Block Wi-Fi and Bluetooth" \
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
> /etc/systemd/system/rfkill-block.service

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable rfkill-block.service

echo "Removing GUI packages"
apt-get -y purge lightdm xserver-xorg-core x11-common lxsession lxpanel openbox lxde* || true
apt-get -y autoremove --purge
apt-get -y autoclean

echo "Firmware config"
grep -q disable-bt /boot/config.txt || echo dtoverlay=disable-bt >> /boot/config.txt
grep -q disable-wifi /boot/config.txt || echo dtoverlay=disable-wifi >> /boot/config.txt
grep -q audio=off /boot/config.txt || echo dtparam=audio=off >> /boot/config.txt
grep -q '^gpu_mem=' /boot/config.txt && sed -i 's/^gpu_mem=.*/gpu_mem=16/' /boot/config.txt || echo gpu_mem=16 >> /boot/config.txt

echo "Done. No installs. Reboot recommended."
