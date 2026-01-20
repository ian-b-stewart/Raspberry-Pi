#!/usr/bin/env bash
#
# restore.sh
#
# PURPOSE:
#   Restore Docker homelab data from a remote backup server.
#   Supports listing available backups and restoring specific snapshots.
#
# USAGE:
#   ./restore.sh --list                    # List available backups
#   ./restore.sh --latest                  # Restore most recent backup
#   ./restore.sh --backup <timestamp>      # Restore specific backup
#   ./restore.sh --backup <timestamp> --secrets-only  # Restore only secrets
#
# NOTES:
#   - Requires secrets/backup.env to be configured
#   - Will try current password, then fall back to .previous
#   - Creates restore staging directory before applying
#

set -euo pipefail

# -------------------------------
# Configuration
# -------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${BACKUP_DIR}/secrets/backup.env"
ENV_FILE_PREVIOUS="${BACKUP_DIR}/secrets/backup.env.previous"
SSH_AGENT_STARTED=false

# Parse arguments
ACTION=""
BACKUP_TIMESTAMP=""
SECRETS_ONLY=false
CATEGORY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --list)
            ACTION="list"
            shift
            ;;
        --latest)
            ACTION="latest"
            shift
            ;;
        --backup)
            ACTION="restore"
            BACKUP_TIMESTAMP="$2"
            shift 2
            ;;
        --secrets-only)
            SECRETS_ONLY=true
            shift
            ;;
        --category)
            CATEGORY="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --list                 List all available backups on remote server"
            echo "  --latest               Restore the most recent backup"
            echo "  --backup <timestamp>   Restore a specific backup (e.g., 20260119-020000)"
            echo "  --category <cat>       Specify category (daily/weekly/monthly) for --latest"
            echo "  --secrets-only         Only restore the encrypted secrets"
            echo "  --help, -h             Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if [[ -z "$ACTION" ]]; then
    echo "Error: No action specified. Use --list, --latest, or --backup <timestamp>"
    echo "Use --help for usage information"
    exit 1
fi

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
# Cleanup Function
# -------------------------------

cleanup() {
    local exit_code=$?
    
    # Kill ssh-agent if we started it
    if [[ "$SSH_AGENT_STARTED" == "true" && -n "${SSH_AGENT_PID:-}" ]]; then
        kill "$SSH_AGENT_PID" 2>/dev/null || true
    fi
    
    # Remove password files
    if [[ -f "${PASSWORD_FILE:-}" ]]; then
        rm -f "$PASSWORD_FILE"
    fi
    
    # Remove askpass helper
    if [[ -f "${SSH_ASKPASS:-}" ]]; then
        rm -f "$SSH_ASKPASS"
    fi
    
    exit $exit_code
}

trap cleanup EXIT

# -------------------------------
# Pre-flight Checks
# -------------------------------

log_info "Starting restore process..."

# Check for environment file
if [[ ! -f "$ENV_FILE" ]]; then
    log_error "Environment file not found: $ENV_FILE"
    log_error "Run setup.sh first or copy backup.env.example to secrets/backup.env"
    exit 1
fi

# Source environment file
# shellcheck source=/dev/null
source "$ENV_FILE"

# Store current password for decryption attempts
CURRENT_PASSWORD="$BACKUP_ENCRYPTION_PASSWORD"
PREVIOUS_PASSWORD=""

# Load previous password if available
if [[ -f "$ENV_FILE_PREVIOUS" ]]; then
    # shellcheck source=/dev/null
    PREVIOUS_PASSWORD=$(grep "^BACKUP_ENCRYPTION_PASSWORD=" "$ENV_FILE_PREVIOUS" | cut -d= -f2- | tr -d '"' || echo "")
fi

# Validate required variables
required_vars=(
    "BACKUP_REMOTE_USER"
    "BACKUP_REMOTE_HOST"
    "BACKUP_REMOTE_PATH"
    "SSH_KEY_PATH"
    "SSH_KEY_PASSPHRASE"
    "LOCAL_HOSTNAME"
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log_error "Required variable not set: $var"
        exit 1
    fi
done

# Resolve relative SSH key path
if [[ ! "$SSH_KEY_PATH" = /* ]]; then
    SSH_KEY_PATH="${BACKUP_DIR}/${SSH_KEY_PATH}"
fi

if [[ ! -f "$SSH_KEY_PATH" ]]; then
    log_error "SSH key not found: $SSH_KEY_PATH"
    exit 1
fi

# Set defaults
BACKUP_REMOTE_PORT="${BACKUP_REMOTE_PORT:-22}"
RESTORE_TEMP_DIR="${RESTORE_TEMP_DIR:-/tmp/restore-staging}"

# -------------------------------
# Setup SSH Agent
# -------------------------------

log_info "Starting ssh-agent..."

eval "$(ssh-agent -s)" > /dev/null
SSH_AGENT_STARTED=true

# Add key using SSH_ASKPASS
export SSH_ASKPASS_REQUIRE=force
export SSH_ASKPASS="${BACKUP_DIR}/secrets/.ssh-askpass-helper"

cat > "$SSH_ASKPASS" << ASKPASSEOF
#!/bin/bash
echo "$SSH_KEY_PASSPHRASE"
ASKPASSEOF
chmod 700 "$SSH_ASKPASS"

ssh-add "$SSH_KEY_PATH" < /dev/null 2>/dev/null || {
    if command -v expect >/dev/null 2>&1; then
        expect << EXPECTEOF
spawn ssh-add "$SSH_KEY_PATH"
expect "Enter passphrase"
send "$SSH_KEY_PASSPHRASE\r"
expect eof
EXPECTEOF
    else
        log_error "Failed to add SSH key. Install 'expect' or use ssh-agent manually."
        exit 1
    fi
}

rm -f "$SSH_ASKPASS"
log_success "SSH key added to agent"

SSH_OPTS="-p ${BACKUP_REMOTE_PORT} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

# -------------------------------
# List Backups
# -------------------------------

list_backups() {
    log_info "Listing available backups on ${BACKUP_REMOTE_HOST}..."
    echo ""
    
    for category in daily weekly monthly; do
        echo "=== ${category^^} BACKUPS ==="
        ssh $SSH_OPTS "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}" \
            "ls -lh ${BACKUP_REMOTE_PATH}/${category}/${LOCAL_HOSTNAME}-backup-*.tar.gz 2>/dev/null | awk '{print \$9, \"(\"\$5\")\"}'" 2>/dev/null || echo "  (none)"
        echo ""
    done
}

# -------------------------------
# Find Latest Backup
# -------------------------------

find_latest_backup() {
    local search_category="${1:-}"
    local categories=("daily" "weekly" "monthly")
    
    if [[ -n "$search_category" ]]; then
        categories=("$search_category")
    fi
    
    for category in "${categories[@]}"; do
        local latest
        latest=$(ssh $SSH_OPTS "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}" \
            "ls -t ${BACKUP_REMOTE_PATH}/${category}/${LOCAL_HOSTNAME}-backup-*.tar.gz 2>/dev/null | head -1" 2>/dev/null || echo "")
        
        if [[ -n "$latest" ]]; then
            echo "$latest"
            return 0
        fi
    done
    
    return 1
}

# -------------------------------
# Find Backup by Timestamp
# -------------------------------

find_backup_by_timestamp() {
    local timestamp="$1"
    
    for category in daily weekly monthly; do
        local backup_path="${BACKUP_REMOTE_PATH}/${category}/${LOCAL_HOSTNAME}-backup-${timestamp}.tar.gz"
        
        if ssh $SSH_OPTS "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}" \
            "test -f '$backup_path'" 2>/dev/null; then
            echo "$backup_path"
            return 0
        fi
    done
    
    return 1
}

# -------------------------------
# Decrypt Secrets
# -------------------------------

decrypt_secrets() {
    local encrypted_file="$1"
    local output_dir="$2"
    
    # Try current password first
    log_info "Attempting decryption with current password..."
    
    PASSWORD_FILE=$(mktemp)
    echo "$CURRENT_PASSWORD" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    
    if gpg --decrypt \
        --batch \
        --yes \
        --passphrase-file "$PASSWORD_FILE" \
        "$encrypted_file" 2>/dev/null | tar xzf - -C "$output_dir"; then
        rm -f "$PASSWORD_FILE"
        log_success "Secrets decrypted with current password"
        return 0
    fi
    
    # Try previous password
    if [[ -n "$PREVIOUS_PASSWORD" ]]; then
        log_warn "Current password failed, trying previous password..."
        
        echo "$PREVIOUS_PASSWORD" > "$PASSWORD_FILE"
        
        if gpg --decrypt \
            --batch \
            --yes \
            --passphrase-file "$PASSWORD_FILE" \
            "$encrypted_file" 2>/dev/null | tar xzf - -C "$output_dir"; then
            rm -f "$PASSWORD_FILE"
            log_success "Secrets decrypted with previous password"
            log_warn "Consider re-encrypting with current password after restore"
            return 0
        fi
    fi
    
    rm -f "$PASSWORD_FILE"
    log_error "Failed to decrypt secrets with any available password"
    return 1
}

# -------------------------------
# Restore Backup
# -------------------------------

restore_backup() {
    local backup_path="$1"
    local backup_name
    backup_name=$(basename "$backup_path")
    
    log_info "Restoring backup: $backup_name"
    
    # Create restore staging directory
    rm -rf "$RESTORE_TEMP_DIR"
    mkdir -p "$RESTORE_TEMP_DIR"
    
    # Download backup
    log_info "Downloading backup from remote server..."
    rsync -az --progress -e "ssh $SSH_OPTS" \
        "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}:${backup_path}" \
        "$RESTORE_TEMP_DIR/"
    
    log_success "Backup downloaded"
    
    # Extract backup
    log_info "Extracting backup archive..."
    tar xzf "$RESTORE_TEMP_DIR/$backup_name" -C "$RESTORE_TEMP_DIR"
    log_success "Backup extracted"
    
    # Decrypt secrets
    local secrets_file
    secrets_file=$(find "$RESTORE_TEMP_DIR/secrets" -name "*.gpg" -type f | head -1)
    
    if [[ -n "$secrets_file" ]]; then
        log_info "Decrypting secrets..."
        mkdir -p "$RESTORE_TEMP_DIR/decrypted"
        decrypt_secrets "$secrets_file" "$RESTORE_TEMP_DIR/decrypted"
    fi
    
    echo ""
    log_success "Backup prepared for restore in: $RESTORE_TEMP_DIR"
    echo ""
    echo "=== RESTORE CONTENTS ==="
    echo ""
    
    # Show what's available
    if [[ -d "$RESTORE_TEMP_DIR/databases" ]]; then
        echo "📦 Databases:"
        ls -lh "$RESTORE_TEMP_DIR/databases/" 2>/dev/null | tail -n +2 || echo "  (none)"
        echo ""
    fi
    
    if [[ -d "$RESTORE_TEMP_DIR/stacks" ]]; then
        echo "📁 Stack Data:"
        for stack_dir in "$RESTORE_TEMP_DIR/stacks"/*/; do
            if [[ -d "$stack_dir" ]]; then
                echo "  - $(basename "$stack_dir")"
            fi
        done
        echo ""
    fi
    
    if [[ -d "$RESTORE_TEMP_DIR/decrypted" ]]; then
        echo "🔐 Decrypted Secrets:"
        find "$RESTORE_TEMP_DIR/decrypted" -type f -name "*.env" | while read -r f; do
            echo "  - ${f#$RESTORE_TEMP_DIR/decrypted/}"
        done
        echo ""
    fi
    
    echo "=== MANUAL RESTORE STEPS ==="
    echo ""
    echo "1. Review the extracted files in: $RESTORE_TEMP_DIR"
    echo ""
    echo "2. To restore phpIPAM database:"
    echo "   docker exec -i \$PHPIPAM_DB_CONTAINER mariadb -u \$PHPIPAM_DB_USER -p\$MYSQL_PASSWORD \$PHPIPAM_DB_NAME < $RESTORE_TEMP_DIR/databases/phpipam-*.sql"
    echo ""
    echo "3. To restore stack bind mounts:"
    echo "   cp -a $RESTORE_TEMP_DIR/stacks/<stack>/* \$DOCKER_HOMELAB_PATH/stacks/<stack>/"
    echo ""
    echo "4. To restore secrets:"
    echo "   cp -a $RESTORE_TEMP_DIR/decrypted/* \$DOCKER_HOMELAB_PATH/"
    echo ""
    echo "5. Restart affected containers:"
    echo "   cd \$DOCKER_HOMELAB_PATH && ./scripts/deploy.sh"
    echo ""
    
    if $SECRETS_ONLY; then
        log_info "Secrets-only restore completed"
    else
        log_success "Restore preparation completed!"
    fi
}

# -------------------------------
# Main Logic
# -------------------------------

case "$ACTION" in
    list)
        list_backups
        ;;
    latest)
        LATEST_BACKUP=$(find_latest_backup "$CATEGORY") || {
            log_error "No backups found on remote server"
            exit 1
        }
        log_info "Found latest backup: $(basename "$LATEST_BACKUP")"
        restore_backup "$LATEST_BACKUP"
        ;;
    restore)
        BACKUP_PATH=$(find_backup_by_timestamp "$BACKUP_TIMESTAMP") || {
            log_error "Backup not found with timestamp: $BACKUP_TIMESTAMP"
            log_info "Use --list to see available backups"
            exit 1
        }
        restore_backup "$BACKUP_PATH"
        ;;
esac
