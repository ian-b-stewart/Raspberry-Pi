#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly RFKILL_UNIT=/etc/systemd/system/rfkill-block.service
readonly MODPROBE_CONFIG=/etc/modprobe.d/pi-headless-cleanup.conf

APPLY=false
ASSUME_YES=false

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--apply] [--yes]

Safely removes desktop software and disables services that are unnecessary on
this Ethernet-only, headless Raspberry Pi 4 Docker host.

  --apply  Apply the displayed plan (default is a read-only preview)
  --yes    Do not prompt before applying; valid only with --apply
  -h       Show this help
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  printf 'ERROR: command failed at line %s (exit %s)\n' "$1" "$exit_code" >&2
  exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

while (( $# > 0 )); do
  case "$1" in
    --apply) APPLY=true ;;
    --yes) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

if ! $APPLY && $ASSUME_YES; then
  die "--yes is valid only with --apply"
fi
if $APPLY && (( EUID != 0 )); then
  die "--apply must be run as root"
fi

for command in apt-get apt-mark docker dpkg-query grep ip rfkill sed systemctl uname; do
  command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done

MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
[[ "$MODEL" == Raspberry\ Pi\ 4\ Model\ B* ]] \
  || die "Unsupported hardware: ${MODEL:-unknown}; this script is for Raspberry Pi 4 Model B"

[[ -f /etc/os-release ]] || die "/etc/os-release is missing"
# shellcheck source=/dev/null
source /etc/os-release
[[ "${ID:-}" == debian ]] || die "Unsupported OS: ${PRETTY_NAME:-unknown}; Debian is required"

ip link show eth0 >/dev/null 2>&1 || die "eth0 is missing"
[[ "$(cat /sys/class/net/eth0/operstate)" == up ]] \
  || die "eth0 is not up; refusing to disable wireless networking"
ip -4 address show dev eth0 scope global | grep -q 'inet ' \
  || die "eth0 has no global IPv4 address; refusing to disable wireless networking"

CONFIG=/boot/firmware/config.txt
[[ -f "$CONFIG" ]] || CONFIG=/boot/config.txt
[[ -f "$CONFIG" ]] || die "Raspberry Pi boot config was not found"

readonly MODEL CONFIG
readonly CURRENT_KERNEL="$(uname -r)"
readonly CURRENT_IMAGE="linux-image-${CURRENT_KERNEL}"
readonly CURRENT_HEADERS="linux-headers-${CURRENT_KERNEL}"
readonly RFKILL_BIN="$(command -v rfkill)"

mapfile -t INITIAL_CONTAINER_IDS < <(docker ps --quiet)
(( ${#INITIAL_CONTAINER_IDS[@]} > 0 )) \
  || die "No running Docker containers found; refusing to modify this Docker host"
readonly -a INITIAL_CONTAINER_IDS

package_is_installed() {
  [[ "$(dpkg-query -Wf '${db:Status-Status}' "$1" 2>/dev/null || true)" == installed ]]
}

installed_packages() {
  dpkg-query -Wf '${binary:Package}\t${db:Status-Status}\n' 2>/dev/null \
    | awk -F '\t' '$2 == "installed" { print $1 }'
}

unit_exists() {
  systemctl cat "$1" >/dev/null 2>&1
}

append_installed_match() {
  local regex="$1"
  local package
  while IFS= read -r package; do
    if [[ "$package" =~ $regex ]]; then
      REMOVE_PACKAGES+=("$package")
    fi
  done < <(installed_packages)
}

log "Inspecting $MODEL running ${PRETTY_NAME} with kernel $CURRENT_KERNEL"

package_is_installed "$CURRENT_IMAGE" \
  || die "Running-kernel package $CURRENT_IMAGE is not installed; kernel cleanup is unsafe"
package_is_installed linux-image-rpi-v8 \
  || die "Pi 4 kernel metapackage linux-image-rpi-v8 is not installed"

# Keep the running Pi 4 kernel and the newest other Pi 4 image as a fallback.
mapfile -t V8_IMAGES < <(
  installed_packages \
    | grep -E '^linux-image-[0-9].*-rpi-v8$' \
    | sort -V
)
FALLBACK_IMAGE=""
for package in "${V8_IMAGES[@]}"; do
  [[ "$package" == "$CURRENT_IMAGE" ]] || FALLBACK_IMAGE="$package"
done

readonly GUI_REGEX='^(chromium|chromium-.*|rpi-chromium-mods|firefox|firefox-.*|rpi-imager|pocketsphinx-.*|rpd-.*|wf-panel-pi|wfplug-.*|wayfire.*|labwc|squeekboard|wayvnc|pipanel|rasputin|rpinters|pixtrix-.*|lxterminal|lxtask|lxmenu-data|mate-desktop-common|gnome-menus|raspberrypi-ui-mods)$'
declare -a REMOVE_PACKAGES=()
append_installed_match "$GUI_REGEX"

for package in firmware-atheros firmware-mediatek linux-image-rpi-2712 linux-headers-rpi-2712; do
  if package_is_installed "$package"; then
    REMOVE_PACKAGES+=("$package")
  fi
done

# All Pi 5-specific kernels/headers are unnecessary on a Pi 4.
append_installed_match '^linux-(image|headers)-[0-9].*-rpi-2712$'

# Remove stale Pi 4 images, but preserve the running image and one fallback.
for package in "${V8_IMAGES[@]}"; do
  if [[ "$package" != "$CURRENT_IMAGE" && "$package" != "$FALLBACK_IMAGE" ]]; then
    REMOVE_PACKAGES+=("$package")
  fi
done

# Header packages are not boot-critical. Keep only headers for the running kernel.
while IFS= read -r package; do
  if [[ "$package" != "$CURRENT_HEADERS" ]]; then
    REMOVE_PACKAGES+=("$package")
  fi
done < <(installed_packages | grep -E '^linux-headers-[0-9].*-rpi-v8$' || true)

# Deduplicate the transaction while retaining deterministic output.
if (( ${#REMOVE_PACKAGES[@]} > 0 )); then
  mapfile -t REMOVE_PACKAGES < <(printf '%s\n' "${REMOVE_PACKAGES[@]}" | sort -u)
fi

declare -a DISABLE_SERVICES=(
  bluetooth.service
  wpa_supplicant.service
  avahi-daemon.service
  triggerhappy.service
  ModemManager.service
  wayvnc-control.service
  rpcbind.service
  rpcbind.socket
  nfs-blkmap.service
  udisks2.service
  NetworkManager-wait-online.service
)

declare -a CLOUD_INIT_SERVICES=(
  cloud-init.service
  cloud-init-local.service
  cloud-init-main.service
  cloud-init-network.service
  cloud-init-hotplugd.socket
  cloud-config.service
  cloud-final.service
)

echo
echo "=== Cleanup plan ==="
printf 'Hardware:        %s\n' "$MODEL"
printf 'Boot config:     %s\n' "$CONFIG"
printf 'Running kernel:  %s (kept)\n' "$CURRENT_IMAGE"
printf 'Fallback kernel: %s\n' "${FALLBACK_IMAGE:-none available}"
echo "Services to disable when present:"
printf '  %s\n' "${DISABLE_SERVICES[@]}"
echo "Explicit packages to purge:"
if (( ${#REMOVE_PACKAGES[@]} > 0 )); then
  printf '  %s\n' "${REMOVE_PACKAGES[@]}"
else
  echo "  (none)"
fi

if (( ${#REMOVE_PACKAGES[@]} > 0 )); then
  echo
  echo "=== Complete APT transaction preview (includes autoremove) ==="
  apt-get --simulate --autoremove purge "${REMOVE_PACKAGES[@]}"
fi

if ! $APPLY; then
  echo
  log "Preview complete; no changes were made. Re-run with --apply to proceed."
  exit 0
fi

if ! $ASSUME_YES; then
  echo
  read -r -p "Apply this cleanup plan? Type 'yes' to continue: " response
  [[ "$response" == yes ]] || die "Cleanup cancelled"
fi

BACKUP_CONFIG="${CONFIG}.pre-headless-cleanup-$(date '+%Y%m%d-%H%M%S')"
log "Backing up boot config to $BACKUP_CONFIG"
cp --preserve=mode,ownership,timestamps "$CONFIG" "$BACKUP_CONFIG"

log "Disabling unnecessary services"
for unit in "${DISABLE_SERVICES[@]}"; do
  if unit_exists "$unit"; then
    systemctl stop "$unit" || die "Failed to stop $unit"
    case "$(systemctl is-enabled "$unit" 2>/dev/null || true)" in
      enabled|enabled-runtime|linked|linked-runtime)
        systemctl disable "$unit" || die "Failed to disable $unit"
        ;;
    esac
  fi
done

# Prevent D-Bus/socket activation of hardware and RPC services that are absent.
for unit in bluetooth.service wpa_supplicant.service rpcbind.service rpcbind.socket; do
  if unit_exists "$unit"; then
    systemctl mask "$unit"
  fi
done

cloud_init_status=""
if [[ -e /etc/cloud/cloud-init.disabled ]]; then
  log "Cloud-init is already disabled"
elif command -v cloud-init >/dev/null 2>&1; then
  cloud_init_status="$(cloud-init status --long 2>/dev/null || true)"
  if grep -q '^status: done$' <<<"$cloud_init_status"; then
    log "Disabling cloud-init on this already-provisioned host"
    touch /etc/cloud/cloud-init.disabled
    for unit in "${CLOUD_INIT_SERVICES[@]}"; do
      if unit_exists "$unit"; then
        systemctl disable --now "$unit" 2>/dev/null || true
      fi
    done
  else
    log "Cloud-init is incomplete; leaving it unchanged"
  fi
else
  log "Cloud-init is absent"
fi

log "Blocking Wi-Fi and Bluetooth radios"
rfkill block wifi || true
rfkill block bluetooth || true

log "Installing persistent rfkill unit"
cat >"$RFKILL_UNIT" <<EOF
[Unit]
Description=Block Wi-Fi and Bluetooth
After=systemd-rfkill.service

[Service]
Type=oneshot
ExecStart=-$RFKILL_BIN block wifi
ExecStart=-$RFKILL_BIN block bluetooth
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now rfkill-block.service

# Protect the host's core runtime and backup tooling from autoremove.
declare -a PROTECTED_PACKAGES=(
  apparmor
  containerd.io
  cron
  curl
  docker-ce
  docker-ce-cli
  gnupg
  network-manager
  openssh-client
  openssh-server
  openssl
  rsync
  linux-image-rpi-v8
)
for package in "${PROTECTED_PACKAGES[@]}"; do
  if package_is_installed "$package"; then
    apt-mark manual "$package" >/dev/null
  fi
done

if (( ${#REMOVE_PACKAGES[@]} > 0 )); then
  log "Purging selected packages and orphaned dependencies"
  DEBIAN_FRONTEND=noninteractive apt-get -y --autoremove purge "${REMOVE_PACKAGES[@]}"
fi
apt-get clean

log "Vacuuming system journal to seven days"
journalctl --vacuum-time=7d || log "WARNING: journal vacuum failed; continuing"

log "Applying headless firmware configuration"
sed -i \
  -e '/^# BEGIN pi-headless-cleanup managed settings$/,/^# END pi-headless-cleanup managed settings$/d' \
  -e '/^[[:space:]]*dtparam=audio=/d' \
  -e '/^[[:space:]]*camera_auto_detect=/d' \
  -e '/^[[:space:]]*display_auto_detect=/d' \
  -e '/^[[:space:]]*dtoverlay=disable-wifi[[:space:]]*$/d' \
  -e '/^[[:space:]]*dtoverlay=disable-bt[[:space:]]*$/d' \
  "$CONFIG"

# Preserve HDMI video for emergency console access but disable HDMI audio.
sed -Ei \
  '/^[[:space:]]*dtoverlay=vc4-kms-v3d(,.*)?[[:space:]]*$/ {
    /(^|,)noaudio(,|$)/! s/[[:space:]]*$/,noaudio/
  }' \
  "$CONFIG"

cat >>"$CONFIG" <<'EOF'

# BEGIN pi-headless-cleanup managed settings
[all]
dtparam=audio=off
camera_auto_detect=0
display_auto_detect=0
dtoverlay=disable-wifi
dtoverlay=disable-bt
# END pi-headless-cleanup managed settings
EOF

log "Disabling unused legacy audio and camera modules"
cat >"$MODPROBE_CONFIG" <<'EOF'
# Managed by pi-headless-cleanup.sh. This host has no audio or camera workload.
blacklist snd_bcm2835
blacklist bcm2835_v4l2
blacklist bcm2835_codec
blacklist bcm2835_isp
EOF

log "Verifying essential services and boot packages"
systemctl is-active --quiet docker.service || die "docker.service is not active after cleanup"
systemctl is-active --quiet containerd.service || die "containerd.service is not active after cleanup"
systemctl is-active --quiet ssh.service || die "ssh.service is not active after cleanup"
systemctl is-active --quiet NetworkManager.service || die "NetworkManager.service is not active after cleanup"
package_is_installed "$CURRENT_IMAGE" || die "Running-kernel package was removed unexpectedly"
package_is_installed linux-image-rpi-v8 || die "Pi 4 kernel metapackage was removed unexpectedly"
for container_id in "${INITIAL_CONTAINER_IDS[@]}"; do
  [[ "$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null)" == true ]] \
    || die "Docker container $container_id is no longer running"
done

echo
log "Cleanup completed successfully. Reboot is required for firmware changes."
log "Boot config backup: $BACKUP_CONFIG"
