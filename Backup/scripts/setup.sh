#!/usr/bin/env bash
#
# setup.sh
#
# PURPOSE:
#   Initial setup for the Raspberry Pi backup system.
#   Creates secrets directory, generates SSH keys and encryption password,
#   and provides instructions for remote server configuration.
#
# USAGE:
#   ./setup.sh
#   ./setup.sh --non-interactive  # Use for automation (generates random passphrases)
#
# NOTES:
#   - Run this once before using backup.sh
#   - Creates secrets/backup.env from template
#   - Generates passphrase-protected SSH key
#

set -euo pipefail

# -------------------------------
# Configuration
# -------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SECRETS_DIR="${BACKUP_DIR}/secrets"
ENV_TEMPLATE="${BACKUP_DIR}/backup.env.example"
ENV_FILE="${SECRETS_DIR}/backup.env"
SSH_KEY_FILE="${SECRETS_DIR}/id_backup_ed25519"

NON_INTERACTIVE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --non-interactive  Generate random passphrases without prompting"
            echo "  --help, -h         Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# -------------------------------
# Logging Functions
# -------------------------------

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1"
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ SUCCESS: $1"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️  WARN: $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERROR: $1" >&2
}

# -------------------------------
# Pre-flight Checks
# -------------------------------

log_info "Starting backup system setup..."

# Check for required commands
for cmd in openssl ssh-keygen; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: $cmd"
        exit 1
    fi
done

# Check for template
if [[ ! -f "$ENV_TEMPLATE" ]]; then
    log_error "Template not found: $ENV_TEMPLATE"
    exit 1
fi

# Check if already set up
if [[ -f "$ENV_FILE" ]]; then
    log_warn "Setup already completed. Environment file exists: $ENV_FILE"
    echo ""
    read -r -p "Do you want to overwrite the existing configuration? [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Setup cancelled"
        exit 0
    fi
fi

# -------------------------------
# Create Secrets Directory
# -------------------------------

log_info "Creating secrets directory..."

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

log_success "Secrets directory created: $SECRETS_DIR"

# -------------------------------
# Generate SSH Key
# -------------------------------

log_info "Generating SSH keypair..."

if [[ -f "$SSH_KEY_FILE" ]]; then
    log_warn "SSH key already exists: $SSH_KEY_FILE"
    read -r -p "Generate new key? (will overwrite existing) [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Keeping existing SSH key"
        SSH_KEY_PASSPHRASE="<existing-passphrase>"
    else
        rm -f "$SSH_KEY_FILE" "${SSH_KEY_FILE}.pub"
    fi
fi

if [[ ! -f "$SSH_KEY_FILE" ]]; then
    if $NON_INTERACTIVE; then
        SSH_KEY_PASSPHRASE=$(openssl rand -base64 24)
        log_info "Generated random SSH key passphrase"
    else
        echo ""
        echo "Enter a passphrase for the SSH key."
        echo "This passphrase protects your SSH key and will be stored in backup.env."
        echo ""
        read -r -s -p "SSH key passphrase: " SSH_KEY_PASSPHRASE
        echo ""
        read -r -s -p "Confirm passphrase: " SSH_KEY_PASSPHRASE_CONFIRM
        echo ""
        
        if [[ "$SSH_KEY_PASSPHRASE" != "$SSH_KEY_PASSPHRASE_CONFIRM" ]]; then
            log_error "Passphrases do not match"
            exit 1
        fi
        
        if [[ -z "$SSH_KEY_PASSPHRASE" ]]; then
            log_error "Passphrase cannot be empty"
            exit 1
        fi
    fi
    
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "$SSH_KEY_PASSPHRASE" -C "backup@$(hostname -s)"
    chmod 600 "$SSH_KEY_FILE"
    chmod 644 "${SSH_KEY_FILE}.pub"
    
    log_success "SSH keypair generated"
fi

# -------------------------------
# Generate Encryption Password
# -------------------------------

log_info "Generating backup encryption password..."

BACKUP_ENCRYPTION_PASSWORD=$(openssl rand -base64 32)

log_success "Encryption password generated"

# -------------------------------
# Create Environment File
# -------------------------------

log_info "Creating environment file from template..."

cp "$ENV_TEMPLATE" "$ENV_FILE"

# Update with generated values
sed -i "s|^BACKUP_ENCRYPTION_PASSWORD=.*|BACKUP_ENCRYPTION_PASSWORD=\"${BACKUP_ENCRYPTION_PASSWORD}\"|" "$ENV_FILE"
sed -i "s|^BACKUP_PASSWORD_VERSION=.*|BACKUP_PASSWORD_VERSION=\"1\"|" "$ENV_FILE"
sed -i "s|^BACKUP_PASSWORD_CREATED=.*|BACKUP_PASSWORD_CREATED=\"$(date +%Y-%m-%d)\"|" "$ENV_FILE"
sed -i "s|^SSH_KEY_PASSPHRASE=.*|SSH_KEY_PASSPHRASE=\"${SSH_KEY_PASSPHRASE}\"|" "$ENV_FILE"
sed -i "s|^LOCAL_HOSTNAME=.*|LOCAL_HOSTNAME=\"$(hostname -s)\"|" "$ENV_FILE"

chmod 600 "$ENV_FILE"

log_success "Environment file created: $ENV_FILE"

# -------------------------------
# Summary & Next Steps
# -------------------------------

SSH_PUBLIC_KEY=$(cat "${SSH_KEY_FILE}.pub")

echo ""
echo "=============================================================================="
echo "                        SETUP COMPLETED SUCCESSFULLY"
echo "=============================================================================="
echo ""
echo "=== FILES CREATED ==="
echo ""
echo "  SSH Private Key:  $SSH_KEY_FILE"
echo "  SSH Public Key:   ${SSH_KEY_FILE}.pub"
echo "  Environment File: $ENV_FILE"
echo ""
echo "=== SSH PUBLIC KEY ==="
echo ""
echo "Add this key to your backup server's authorized_keys file:"
echo ""
echo "$SSH_PUBLIC_KEY"
echo ""
echo "=== REMOTE SERVER SETUP ==="
echo ""
echo "Run these commands on your backup server (as root):"
echo ""
echo "  # Create backup user"
echo "  useradd -m -d /backups/raspberry-pi -s /bin/bash backup-user"
echo ""
echo "  # Create backup directories"
echo "  mkdir -p /backups/raspberry-pi/{daily,weekly,monthly}"
echo "  chown -R backup-user:backup-user /backups/raspberry-pi"
echo ""
echo "  # Setup SSH authorized_keys"
echo "  mkdir -p /backups/raspberry-pi/.ssh"
echo "  echo '$SSH_PUBLIC_KEY' >> /backups/raspberry-pi/.ssh/authorized_keys"
echo "  chmod 700 /backups/raspberry-pi/.ssh"
echo "  chmod 600 /backups/raspberry-pi/.ssh/authorized_keys"
echo "  chown -R backup-user:backup-user /backups/raspberry-pi/.ssh"
echo ""
echo "=== CONFIGURATION ==="
echo ""
echo "Edit $ENV_FILE and update these values:"
echo ""
echo "  BACKUP_REMOTE_USER     - Username on backup server (e.g., backup-user)"
echo "  BACKUP_REMOTE_HOST     - Hostname/IP of backup server"
echo "  BACKUP_REMOTE_PATH     - Path on backup server (e.g., /backups/raspberry-pi)"
echo "  DOCKER_HOMELAB_PATH    - Path to your docker-homelab repo"
echo "  HOMELAB_SECRETS_PATH   - Path to secrets within docker-homelab"
echo "  BACKUP_STACKS          - Comma-separated list of stacks to backup"
echo "  HEALTHCHECK_BACKUP_URL - (Optional) Healthchecks.io ping URL"
echo ""
echo "=== CRON SETUP ==="
echo ""
echo "To run backups daily at 2:00 AM, add this cron job:"
echo ""
echo "  sudo tee /etc/cron.d/raspberry-pi-backup << 'EOF'"
echo "  # Raspberry Pi Backup - runs daily at 2:00 AM"
echo "  0 2 * * * root ${SCRIPT_DIR}/backup.sh >> /var/log/raspberry-pi-backup.log 2>&1"
echo "  EOF"
echo ""
echo "=== TEST YOUR SETUP ==="
echo ""
echo "1. Edit the environment file:"
echo "   nano $ENV_FILE"
echo ""
echo "2. Test SSH connection (after setting up remote server):"
echo "   ssh -i $SSH_KEY_FILE backup-user@your-backup-server.local"
echo ""
echo "3. Run a dry-run backup:"
echo "   ${SCRIPT_DIR}/backup.sh --dry-run"
echo ""
echo "4. Run actual backup:"
echo "   ${SCRIPT_DIR}/backup.sh"
echo ""
echo "=============================================================================="
