#!/usr/bin/env bash
#
# rotate-password.sh
#
# PURPOSE:
#   Rotate the backup encryption password.
#   Archives current password as .previous for fallback decryption.
#   Pings Healthchecks.io to reset rotation reminder timer.
#
# USAGE:
#   ./rotate-password.sh
#
# NOTES:
#   - Run this quarterly (every 90 days) to maintain security
#   - After rotation, test restore with new password before deleting old backups
#   - Previous password is retained for decrypting older backups
#

set -euo pipefail

# -------------------------------
# Configuration
# -------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${BACKUP_DIR}/secrets/backup.env"
ENV_FILE_PREVIOUS="${BACKUP_DIR}/secrets/backup.env.previous"

# -------------------------------
# Logging Functions
# -------------------------------

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1"
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# -------------------------------
# Healthchecks.io Integration
# -------------------------------

hc_ping() {
    local url="${1:-}"
    
    if [[ -z "$url" ]]; then
        return 0
    fi
    
    curl -fsS -m 10 --retry 5 -o /dev/null "$url" || true
}

# -------------------------------
# Pre-flight Checks
# -------------------------------

log_info "Starting password rotation..."

if [[ ! -f "$ENV_FILE" ]]; then
    log_error "Environment file not found: $ENV_FILE"
    log_error "Run setup.sh first"
    exit 1
fi

# Source current environment
# shellcheck source=/dev/null
source "$ENV_FILE"

# Get current version
CURRENT_VERSION="${BACKUP_PASSWORD_VERSION:-1}"
NEW_VERSION=$((CURRENT_VERSION + 1))

log_info "Current password version: $CURRENT_VERSION"
log_info "New password version: $NEW_VERSION"

# -------------------------------
# Archive Current Password
# -------------------------------

log_info "Archiving current backup.env to backup.env.previous..."

cp "$ENV_FILE" "$ENV_FILE_PREVIOUS"
chmod 600 "$ENV_FILE_PREVIOUS"

log_success "Previous password archived"

# -------------------------------
# Generate New Password
# -------------------------------

log_info "Generating new encryption password..."

NEW_PASSWORD=$(openssl rand -base64 32)
NEW_DATE=$(date +%Y-%m-%d)

# Update the env file with new password
sed -i "s|^BACKUP_ENCRYPTION_PASSWORD=.*|BACKUP_ENCRYPTION_PASSWORD=\"${NEW_PASSWORD}\"|" "$ENV_FILE"
sed -i "s|^BACKUP_PASSWORD_VERSION=.*|BACKUP_PASSWORD_VERSION=\"${NEW_VERSION}\"|" "$ENV_FILE"
sed -i "s|^BACKUP_PASSWORD_CREATED=.*|BACKUP_PASSWORD_CREATED=\"${NEW_DATE}\"|" "$ENV_FILE"

chmod 600 "$ENV_FILE"

log_success "New password generated and saved"

# -------------------------------
# Ping Healthchecks.io
# -------------------------------

if [[ -n "${HEALTHCHECK_ROTATION_URL:-}" ]]; then
    log_info "Pinging Healthchecks.io rotation check..."
    hc_ping "$HEALTHCHECK_ROTATION_URL"
    log_success "Rotation healthcheck pinged - timer reset for 90 days"
else
    log_warn "No HEALTHCHECK_ROTATION_URL configured - skipping ping"
fi

# -------------------------------
# Summary
# -------------------------------

echo ""
log_success "Password rotation completed!"
echo ""
echo "=== ROTATION SUMMARY ==="
echo ""
echo "  Previous version: $CURRENT_VERSION"
echo "  New version:      $NEW_VERSION"
echo "  Rotation date:    $NEW_DATE"
echo ""
echo "=== IMPORTANT NEXT STEPS ==="
echo ""
echo "1. The previous password is saved in:"
echo "   $ENV_FILE_PREVIOUS"
echo ""
echo "2. Existing backups are still encrypted with the OLD password."
echo "   The restore script will automatically try both passwords."
echo ""
echo "3. TEST a restore before the next backup to verify everything works:"
echo "   ./scripts/restore.sh --list"
echo "   ./scripts/restore.sh --latest"
echo ""
echo "4. New backups will use the NEW password."
echo ""
echo "5. Next rotation due: $(date -d "+90 days" +%Y-%m-%d 2>/dev/null || echo "in 90 days")"
echo ""
