# Raspberry Pi Headless Cleanup Script

A hardened cleanup script for **Raspberry Pi 4** systems running **Raspberry Pi OS (Debian-based)** that are intended to operate as **Ethernet-only, headless servers**.

This script removes desktop and GUI packages, disables unnecessary services, and fully disables Wi-Fi and Bluetooth at **three layers**: services, firmware, and rfkill.

---

## Features

- Removes **X11, Wayland, LightDM, LXDE, GTK, Mesa, and related GUI packages**
- Disables **Wi-Fi and Bluetooth** via:
  - systemd services
  - firmware overlays
  - persistent `rfkill` blocks
- Removes Raspberry Pi desktop extras and games
- Reduces GPU memory to **16 MB**
- Disables onboard audio
- Cleans unused packages and system logs
- Safe to run multiple times (idempotent)

Designed for:
- Docker hosts
- Infrastructure services (DNS, VPN, reverse proxy)
- Homelabs and edge servers
- Security-hardened Raspberry Pi deployments

---

## Supported Systems

- Raspberry Pi 4
- Raspberry Pi OS Lite / Raspberry Pi OS (Debian-based)
- Headless configuration
- Ethernet-only networking

> Not tested on Ubuntu Server. Adjustments may be required.

---

## What This Script Does

### Services Disabled

- `bluetooth.service`
- `wpa_supplicant.service`
- `avahi-daemon.service`
- `triggerhappy.service`
- `ModemManager.service`

### Radios Disabled (Defense in Depth)

- Firmware overlays:
  - `dtoverlay=disable-wifi`
  - `dtoverlay=disable-bt`
- Persistent `rfkill` blocks for Wi-Fi and Bluetooth

### Packages Removed

- X11 and display server components
- Wayland / Weston
- Desktop environments and display managers
- GTK, Mesa, OpenGL libraries
- Raspberry Pi desktop software and games

### System Tweaks

- GPU memory reduced to 16 MB
- Onboard audio disabled
- Journal logs vacuumed to 7 days
- Unused packages fully purged

---

## Installation

Clone the repository:

```bash
cd /opt
git clone https://github.com/ian-b-stewart/Raspberry-Pi.git
cd Raspberry-Pi/Pi-Headless-Cleanup
