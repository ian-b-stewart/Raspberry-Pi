#!/usr/bin/env bash
#
# backup.sh
#
# PURPOSE:
#   Backup Docker homelab data from a Raspberry Pi to a remote server.
#   Includes database dumps, bind mounts, and encrypted secrets.
#
# USAGE:
#   ./backup.sh
#   ./backup.sh --dry-run
#
# NOTES:
#   - Requires secrets/backup.env to be configured
#   - Uses GPG symmetric encryption for secrets
#   - Uses ssh-agent for passphrase-protected SSH keys
#   - Supports Healthchecks.io monitoring
#

set -euo pipefail

# -------------------------------
# Configuration
# -------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${BACKUP_DIR}/secrets/backup.env"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DATE_ONLY="$(date +%Y%m%d)"
DAY_OF_WEEK="$(date +%u)"  # 1=Monday, 7=Sunday
DAY_OF_MONTH="$(date +%d)"
DRY_RUN=false
SSH_AGENT_STARTED=false
SSH_AGENT_PID_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
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
# Healthchecks.io Integration
# -------------------------------

hc_ping() {
    local endpoint="${1:-}"
    local message="${2:-}"
    
    # Skip if no healthcheck URL configured
    if [[ -z "${HEALTHCHECK_BACKUP_URL:-}" ]]; then
        return 0
    fi
    
    local url="${HEALTHCHECK_BACKUP_URL}${endpoint}"
    
    if [[ -n "$message" ]]; then
        # POST with message body (for logging output)
        curl -fsS -m 10 --retry 5 --data-raw "$message" "$url" >/dev/null 2>&1 || true
    else
        # Simple GET request
        curl -fsS -m 10 --retry 5 -o /dev/null "$url" || true
    fi
}

# -------------------------------
# Cleanup Function
# -------------------------------

cleanup() {
    local exit_code=$?
    
    log_info "Cleaning up..."
    
    # Remove temporary directory
    if [[ -d "${BACKUP_TEMP_DIR:-}" ]]; then
        rm -rf "${BACKUP_TEMP_DIR}"
    fi
    
    # Kill ssh-agent if we started it
    if [[ "$SSH_AGENT_STARTED" == "true" && -n "${SSH_AGENT_PID:-}" ]]; then
        kill "$SSH_AGENT_PID" 2>/dev/null || true
        log_info "Stopped ssh-agent (PID: $SSH_AGENT_PID)"
    fi
    
    # Remove password file if it exists
    if [[ -f "${PASSWORD_FILE:-}" ]]; then
        rm -f "$PASSWORD_FILE"
    fi
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Backup failed with exit code: $exit_code"
        hc_ping "/fail" "Backup failed with exit code: $exit_code"
    fi
    
    exit $exit_code
}

trap cleanup EXIT

# -------------------------------
# Pre-flight Checks
# -------------------------------

log_info "Starting backup process..."

# Check for environment file
if [[ ! -f "$ENV_FILE" ]]; then
    log_error "Environment file not found: $ENV_FILE"
    log_error "Run setup.sh first or copy backup.env.example to secrets/backup.env"
    exit 1
fi

# Source environment file
# shellcheck source=/dev/null
source "$ENV_FILE"

# Validate required variables
required_vars=(
    "DOCKER_HOMELAB_PATH"
    "HOMELAB_SECRETS_PATH"
    "LOCAL_HOSTNAME"
    "BACKUP_REMOTE_USER"
    "BACKUP_REMOTE_HOST"
    "BACKUP_REMOTE_PATH"
    "SSH_KEY_PATH"
    "SSH_KEY_PASSPHRASE"
    "BACKUP_ENCRYPTION_PASSWORD"
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

# Check paths exist
if [[ ! -d "$DOCKER_HOMELAB_PATH" ]]; then
    log_error "Docker homelab path not found: $DOCKER_HOMELAB_PATH"
    exit 1
fi

if [[ ! -f "$SSH_KEY_PATH" ]]; then
    log_error "SSH key not found: $SSH_KEY_PATH"
    exit 1
fi

# Check required commands
for cmd in gpg rsync ssh ssh-agent docker tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: $cmd"
        exit 1
    fi
done

# Set defaults
BACKUP_TEMP_DIR="${BACKUP_TEMP_DIR:-/tmp/backup-staging}"
BACKUP_REMOTE_PORT="${BACKUP_REMOTE_PORT:-22}"
BACKUP_RETENTION_DAILY="${BACKUP_RETENTION_DAILY:-7}"
BACKUP_RETENTION_WEEKLY="${BACKUP_RETENTION_WEEKLY:-4}"
BACKUP_RETENTION_MONTHLY="${BACKUP_RETENTION_MONTHLY:-3}"
BACKUP_VERBOSE="${BACKUP_VERBOSE:-false}"
RSYNC_BANDWIDTH_LIMIT="${RSYNC_BANDWIDTH_LIMIT:-0}"

# Signal start to healthchecks
hc_ping "/start"

log_info "Backup configuration validated"
log_info "  Local hostname: $LOCAL_HOSTNAME"
log_info "  Remote target: ${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}:${BACKUP_REMOTE_PATH}"
log_info "  Timestamp: $TIMESTAMP"

# -------------------------------
# Setup SSH Agent
# -------------------------------

log_info "Starting ssh-agent..."

# Start a fresh ssh-agent for this session
eval "$(ssh-agent -s)" > /dev/null
SSH_AGENT_STARTED=true
log_info "ssh-agent started (PID: $SSH_AGENT_PID)"

# Add key using expect-like approach with SSH_ASKPASS
export SSH_ASKPASS_REQUIRE=force
export SSH_ASKPASS="${BACKUP_DIR}/secrets/.ssh-askpass-helper"

# Create temporary askpass helper
cat > "$SSH_ASKPASS" << ASKPASSEOF
#!/bin/bash
echo "$SSH_KEY_PASSPHRASE"
ASKPASSEOF
chmod 700 "$SSH_ASKPASS"

# Add the key
ssh-add "$SSH_KEY_PATH" < /dev/null 2>/dev/null || {
    # Fallback: try with expect if available
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

# Remove askpass helper
rm -f "$SSH_ASKPASS"

log_success "SSH key added to agent"

# -------------------------------
# Create Staging Directory
# -------------------------------

log_info "Creating staging directory: $BACKUP_TEMP_DIR"
rm -rf "$BACKUP_TEMP_DIR"
mkdir -p "$BACKUP_TEMP_DIR"/{databases,stacks,secrets}

# -------------------------------
# Backup Databases
# -------------------------------

log_info "Backing up databases..."

# phpIPAM MariaDB
if [[ -n "${PHPIPAM_DB_CONTAINER:-}" ]]; then
    PHPIPAM_DB_NAME="${PHPIPAM_DB_NAME:-phpipam}"
    PHPIPAM_DB_USER="${PHPIPAM_DB_USER:-phpipam}"
    
    if docker ps --format '{{.Names}}' | grep -q "^${PHPIPAM_DB_CONTAINER}$"; then
        log_info "  Dumping phpIPAM database from container: $PHPIPAM_DB_CONTAINER"
        
        if $DRY_RUN; then
            log_info "  [DRY-RUN] Would dump database: $PHPIPAM_DB_NAME"
        else
            docker exec "$PHPIPAM_DB_CONTAINER" \
                mariadb-dump -u "$PHPIPAM_DB_USER" --password="$(docker exec "$PHPIPAM_DB_CONTAINER" printenv MYSQL_PASSWORD 2>/dev/null || echo '')" \
                --single-transaction --routines --triggers "$PHPIPAM_DB_NAME" \
                > "$BACKUP_TEMP_DIR/databases/phpipam-${TIMESTAMP}.sql" 2>/dev/null || {
                    # Try mysqldump as fallback (older MariaDB versions)
                    docker exec "$PHPIPAM_DB_CONTAINER" \
                        mysqldump -u "$PHPIPAM_DB_USER" --password="$(docker exec "$PHPIPAM_DB_CONTAINER" printenv MYSQL_PASSWORD 2>/dev/null || echo '')" \
                        --single-transaction --routines --triggers "$PHPIPAM_DB_NAME" \
                        > "$BACKUP_TEMP_DIR/databases/phpipam-${TIMESTAMP}.sql"
                }
            log_success "  phpIPAM database dumped"
        fi
    else
        log_warn "  phpIPAM container not running: $PHPIPAM_DB_CONTAINER"
    fi
fi

# -------------------------------
# Backup Stack Bind Mounts
# -------------------------------

log_info "Backing up stack bind mounts..."

IFS=',' read -ra STACKS <<< "${BACKUP_STACKS:-}"
for stack in "${STACKS[@]}"; do
    stack=$(echo "$stack" | xargs)  # Trim whitespace
    stack_path="${DOCKER_HOMELAB_PATH}/stacks/${stack}"
    
    if [[ -d "$stack_path" ]]; then
        log_info "  Backing up stack: $stack"
        
        if $DRY_RUN; then
            log_info "  [DRY-RUN] Would backup: $stack_path"
        else
            mkdir -p "$BACKUP_TEMP_DIR/stacks/$stack"
            
            # Copy bind mount directories (excluding docker-compose.yml which is in git)
            find "$stack_path" -maxdepth 1 -type d ! -name "$stack" | while read -r dir; do
                dir_name=$(basename "$dir")
                cp -a "$dir" "$BACKUP_TEMP_DIR/stacks/$stack/"
                log_info "    Copied: $dir_name"
            done
            
            # Also backup any data files (non-yml)
            find "$stack_path" -maxdepth 1 -type f ! -name "*.yml" ! -name "*.yaml" ! -name "docker-compose*" | while read -r file; do
                cp -a "$file" "$BACKUP_TEMP_DIR/stacks/$stack/"
            done
        fi
    else
        log_warn "  Stack directory not found: $stack_path"
    fi
done

# -------------------------------
# Backup Additional Paths
# -------------------------------

if [[ -n "${ADDITIONAL_BACKUP_PATHS:-}" ]]; then
    log_info "Backing up additional paths..."
    
    for path in $ADDITIONAL_BACKUP_PATHS; do
        if [[ -e "$path" ]]; then
            log_info "  Backing up: $path"
            
            if $DRY_RUN; then
                log_info "  [DRY-RUN] Would backup: $path"
            else
                path_name=$(basename "$path")
                mkdir -p "$BACKUP_TEMP_DIR/additional"
                cp -a "$path" "$BACKUP_TEMP_DIR/additional/$path_name"
            fi
        else
            log_warn "  Additional path not found: $path"
        fi
    done
fi

# -------------------------------
# Backup & Encrypt Secrets
# -------------------------------

log_info "Backing up and encrypting secrets..."

if [[ -d "$HOMELAB_SECRETS_PATH" ]]; then
    if $DRY_RUN; then
        log_info "  [DRY-RUN] Would encrypt: $HOMELAB_SECRETS_PATH"
    else
        # Create temporary password file
        PASSWORD_FILE=$(mktemp)
        echo "$BACKUP_ENCRYPTION_PASSWORD" > "$PASSWORD_FILE"
        chmod 600 "$PASSWORD_FILE"
        
        # Create encrypted tarball of secrets
        tar czf - -C "$(dirname "$HOMELAB_SECRETS_PATH")" "$(basename "$HOMELAB_SECRETS_PATH")" | \
            gpg --symmetric \
                --cipher-algo AES256 \
                --batch \
                --yes \
                --passphrase-file "$PASSWORD_FILE" \
                --output "$BACKUP_TEMP_DIR/secrets/homelab-secrets-${TIMESTAMP}.tar.gz.gpg"
        
        # Clean up password file
        rm -f "$PASSWORD_FILE"
        PASSWORD_FILE=""
        
        log_success "  Secrets encrypted with AES256"
    fi
else
    log_warn "  Secrets path not found: $HOMELAB_SECRETS_PATH"
fi

# -------------------------------
# Create Final Archive
# -------------------------------

log_info "Creating final backup archive..."

ARCHIVE_NAME="${LOCAL_HOSTNAME}-backup-${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="${BACKUP_TEMP_DIR}/${ARCHIVE_NAME}"

if $DRY_RUN; then
    log_info "  [DRY-RUN] Would create archive: $ARCHIVE_NAME"
else
    tar czf "$ARCHIVE_PATH" \
        -C "$BACKUP_TEMP_DIR" \
        databases stacks secrets additional 2>/dev/null || \
    tar czf "$ARCHIVE_PATH" \
        -C "$BACKUP_TEMP_DIR" \
        databases stacks secrets
    
    archive_size=$(du -h "$ARCHIVE_PATH" | cut -f1)
    log_success "  Archive created: $ARCHIVE_NAME ($archive_size)"
fi

# -------------------------------
# Transfer to Remote Server
# -------------------------------

log_info "Transferring backup to remote server..."

RSYNC_OPTS="-avz --progress"
if [[ "$BACKUP_VERBOSE" != "true" ]]; then
    RSYNC_OPTS="-az"
fi
if [[ "$RSYNC_BANDWIDTH_LIMIT" -gt 0 ]]; then
    RSYNC_OPTS="$RSYNC_OPTS --bwlimit=$RSYNC_BANDWIDTH_LIMIT"
fi

SSH_OPTS="-p ${BACKUP_REMOTE_PORT} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

# Determine backup category (daily/weekly/monthly)
BACKUP_CATEGORY="daily"
if [[ "$DAY_OF_MONTH" == "01" ]]; then
    BACKUP_CATEGORY="monthly"
elif [[ "$DAY_OF_WEEK" == "7" ]]; then
    BACKUP_CATEGORY="weekly"
fi

REMOTE_DEST="${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}:${BACKUP_REMOTE_PATH}/${BACKUP_CATEGORY}/"

if $DRY_RUN; then
    log_info "  [DRY-RUN] Would transfer to: $REMOTE_DEST"
else
    # Ensure remote directory exists
    ssh $SSH_OPTS "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}" \
        "mkdir -p ${BACKUP_REMOTE_PATH}/{daily,weekly,monthly}"
    
    # Transfer backup
    rsync $RSYNC_OPTS -e "ssh $SSH_OPTS" \
        "$ARCHIVE_PATH" \
        "$REMOTE_DEST"
    
    log_success "  Backup transferred to: $REMOTE_DEST"
fi

# -------------------------------
# Apply Retention Policy
# -------------------------------

log_info "Applying retention policy..."

apply_retention() {
    local category=$1
    local keep_count=$2
    
    if $DRY_RUN; then
        log_info "  [DRY-RUN] Would apply $category retention: keep $keep_count"
        return
    fi
    
    # List files sorted by date (oldest first), skip the newest $keep_count
    ssh $SSH_OPTS "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}" \
        "cd ${BACKUP_REMOTE_PATH}/${category} 2>/dev/null && \
         ls -t ${LOCAL_HOSTNAME}-backup-*.tar.gz 2>/dev/null | \
         tail -n +$((keep_count + 1)) | \
         xargs -r rm -f" 2>/dev/null || true
    
    log_info "  $category: keeping newest $keep_count backups"
}

apply_retention "daily" "$BACKUP_RETENTION_DAILY"
apply_retention "weekly" "$BACKUP_RETENTION_WEEKLY"
apply_retention "monthly" "$BACKUP_RETENTION_MONTHLY"

log_success "Retention policy applied"

# -------------------------------
# Completion
# -------------------------------

if $DRY_RUN; then
    log_success "Dry run completed successfully"
else
    log_success "Backup completed successfully!"
    log_info "  Archive: $ARCHIVE_NAME"
    log_info "  Category: $BACKUP_CATEGORY"
    log_info "  Destination: $REMOTE_DEST"
    
    # Ping healthcheck success
    hc_ping "" "Backup completed: $ARCHIVE_NAME ($archive_size) -> $BACKUP_CATEGORY"
fi
