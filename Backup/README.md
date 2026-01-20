# Raspberry Pi Docker Backup

A secure, automated backup solution for Docker homelab deployments on Raspberry Pi. Backs up databases, stack data, and encrypted secrets to a remote server via rsync over SSH.

## Features

- **Database Dumps**: Automatic MariaDB/MySQL dumps for containers like phpIPAM
- **Stack Data Backup**: Copies bind mount directories from Docker Compose stacks
- **Encrypted Secrets**: GPG AES-256 symmetric encryption for sensitive `.env` files
- **Generational Retention**: Daily (7), Weekly (4), Monthly (3) backup rotation
- **SSH Key Authentication**: Passphrase-protected Ed25519 keys with ssh-agent
- **Healthchecks.io Integration**: Monitoring for backup success/failure and password rotation reminders
- **Restore Support**: List, download, and decrypt backups with automatic password fallback

## Prerequisites

Install required packages on your Raspberry Pi:

```bash
sudo apt update
sudo apt install -y gpg rsync openssh-client docker.io expect
```

Required tools:
- `gpg` - GNU Privacy Guard for encryption
- `rsync` - Fast file transfer
- `ssh` / `ssh-agent` - Secure remote access
- `docker` - Container runtime
- `expect` (optional) - For SSH key passphrase automation

## Quick Start

### 1. Clone the Repository

```bash
cd /opt
git clone https://github.com/ian-b-stewart/Raspberry-Pi.git
cd Raspberry-Pi/Backup
```

### 2. Run Setup

```bash
./scripts/setup.sh
```

This will:
- Create the `secrets/` directory (gitignored)
- Generate a passphrase-protected SSH keypair
- Generate a strong encryption password
- Create `secrets/backup.env` from the template
- Display remote server setup instructions

### 3. Configure Remote Backup Server

On your backup server (as root):

```bash
# Create backup user with dedicated home directory
useradd -m -d /backups/raspberry-pi -s /bin/bash backup-user

# Create backup directories
mkdir -p /backups/raspberry-pi/{daily,weekly,monthly}
chown -R backup-user:backup-user /backups/raspberry-pi

# Setup SSH authorized_keys (paste the public key from setup.sh output)
mkdir -p /backups/raspberry-pi/.ssh
echo 'ssh-ed25519 AAAA... backup@hostname' >> /backups/raspberry-pi/.ssh/authorized_keys
chmod 700 /backups/raspberry-pi/.ssh
chmod 600 /backups/raspberry-pi/.ssh/authorized_keys
chown -R backup-user:backup-user /backups/raspberry-pi/.ssh
```

### 4. Edit Configuration

```bash
nano secrets/backup.env
```

Update these required values:

| Variable | Description | Example |
|----------|-------------|---------|
| `BACKUP_REMOTE_USER` | SSH user on backup server | `backup-user` |
| `BACKUP_REMOTE_HOST` | Hostname/IP of backup server | `backup-server.local` |
| `BACKUP_REMOTE_PATH` | Remote backup directory | `/backups/raspberry-pi` |
| `DOCKER_HOMELAB_PATH` | Path to docker-homelab repo | `/opt/docker-homelab` |
| `HOMELAB_SECRETS_PATH` | Path to secrets directory | `/opt/docker-homelab/secrets` |
| `BACKUP_STACKS` | Stacks to backup (comma-separated) | `smokeping,phpipam` |

### 5. Test Connection

```bash
# Test SSH connection (will prompt for key passphrase)
ssh -i secrets/id_backup_ed25519 backup-user@backup-server.local

# Run dry-run backup
./scripts/backup.sh --dry-run
```

### 6. Run First Backup

```bash
./scripts/backup.sh
```

### 7. Setup Cron Job

```bash
sudo tee /etc/cron.d/raspberry-pi-backup << 'CRON'
# Raspberry Pi Backup - runs daily at 2:00 AM
0 2 * * * root /opt/Raspberry-Pi/Backup/scripts/backup.sh >> /var/log/raspberry-pi-backup.log 2>&1
CRON
```

## Configuration Reference

### backup.env Variables

#### Local Paths

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DOCKER_HOMELAB_PATH` | ✅ | `/opt/docker-homelab` | Path to docker-homelab repo |
| `HOMELAB_SECRETS_PATH` | ✅ | `/opt/docker-homelab/secrets` | Secrets to encrypt |
| `LOCAL_HOSTNAME` | ✅ | `raspberry-pi` | Identifier in backup filenames |

#### Remote Server

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BACKUP_REMOTE_USER` | ✅ | - | SSH username |
| `BACKUP_REMOTE_HOST` | ✅ | - | Server hostname/IP |
| `BACKUP_REMOTE_PATH` | ✅ | - | Remote directory path |
| `BACKUP_REMOTE_PORT` | ❌ | `22` | SSH port |

#### SSH Authentication

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SSH_KEY_PATH` | ✅ | `./secrets/id_backup_ed25519` | Path to SSH private key |
| `SSH_KEY_PASSPHRASE` | ✅ | - | SSH key passphrase |

#### Encryption

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BACKUP_ENCRYPTION_PASSWORD` | ✅ | - | GPG encryption password |
| `BACKUP_PASSWORD_VERSION` | ❌ | `1` | Tracks password rotations |
| `BACKUP_PASSWORD_CREATED` | ❌ | - | Date of last rotation |

#### Monitoring

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `HEALTHCHECK_BACKUP_URL` | ❌ | - | Healthchecks.io ping URL |
| `HEALTHCHECK_ROTATION_URL` | ❌ | - | Rotation reminder URL |

#### Retention

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BACKUP_RETENTION_DAILY` | ❌ | `7` | Daily backups to keep |
| `BACKUP_RETENTION_WEEKLY` | ❌ | `4` | Weekly backups (Sundays) |
| `BACKUP_RETENTION_MONTHLY` | ❌ | `3` | Monthly backups (1st) |

#### Stacks & Databases

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BACKUP_STACKS` | ❌ | `smokeping,phpipam` | Stacks to backup |
| `PHPIPAM_DB_CONTAINER` | ❌ | `phpipam-mariadb` | Database container name |
| `PHPIPAM_DB_NAME` | ❌ | `phpipam` | Database name |
| `PHPIPAM_DB_USER` | ❌ | `phpipam` | Database user |

## Usage

### Backup

```bash
# Run backup
./scripts/backup.sh

# Dry run (no changes)
./scripts/backup.sh --dry-run
```

### Restore

```bash
# List available backups
./scripts/restore.sh --list

# Restore latest backup
./scripts/restore.sh --latest

# Restore specific backup
./scripts/restore.sh --backup 20260119-020000

# Restore only secrets
./scripts/restore.sh --latest --secrets-only
```

The restore script downloads and extracts the backup to `/tmp/restore-staging/`, then provides manual instructions for applying the restore.

### Password Rotation

Rotate the encryption password quarterly (every 90 days):

```bash
./scripts/rotate-password.sh
```

This will:
1. Archive current `backup.env` to `backup.env.previous`
2. Generate a new encryption password
3. Increment the password version
4. Ping Healthchecks.io (if configured) to reset the 90-day timer

**Important**: After rotation, test a restore before the next backup to verify the password works.

## Healthchecks.io Setup

### Backup Monitoring

1. Create a new check at [healthchecks.io](https://healthchecks.io)
2. Set period to **1 day** with **1 hour** grace
3. Copy the ping URL to `HEALTHCHECK_BACKUP_URL`

### Rotation Reminder

1. Create a separate check
2. Set period to **90 days** with **7 days** grace
3. Copy the ping URL to `HEALTHCHECK_ROTATION_URL`
4. You'll be alerted when password rotation is overdue

## What Gets Backed Up

| Category | Contents | Encrypted |
|----------|----------|-----------|
| **Databases** | MariaDB/MySQL dumps from configured containers | ❌ |
| **Stack Data** | Bind mount directories (config, data) | ❌ |
| **Secrets** | All `.env` files from HOMELAB_SECRETS_PATH | ✅ AES-256 |

### Backup Archive Structure

```
raspberry-pi-backup-20260119-020000.tar.gz
├── databases/
│   └── phpipam-20260119-020000.sql
├── stacks/
│   ├── smokeping/
│   │   ├── config/
│   │   └── data/
│   └── phpipam/
└── secrets/
    └── homelab-secrets-20260119-020000.tar.gz.gpg  (encrypted)
```

## Security Considerations

### File Permissions

The setup script configures secure permissions:

| Path | Permissions | Description |
|------|-------------|-------------|
| `secrets/` | `700` | Directory readable only by owner |
| `secrets/backup.env` | `600` | Env file readable only by owner |
| `secrets/id_backup_ed25519` | `600` | SSH private key |

### Secrets Protection

- Secrets are encrypted with GPG AES-256 before leaving the Raspberry Pi
- The encryption password never leaves the local machine (stored in gitignored `secrets/`)
- SSH keys are passphrase-protected
- Password rotation maintains a "previous" password for decrypting older backups

### Public Repository Safety

This repository is public. All sensitive data is excluded via `.gitignore`:

```gitignore
Backup/secrets/
*.env
!*.env.example
id_*
*.key
*.pem
```

## Troubleshooting

### SSH Connection Fails

```bash
# Test SSH manually
ssh -v -i secrets/id_backup_ed25519 backup-user@backup-server.local

# Check key permissions
ls -la secrets/id_backup_ed25519
# Should be: -rw------- (600)
```

### GPG Decryption Fails

```bash
# Test decryption manually
gpg --decrypt secrets/test.gpg

# Check if password file is correct
cat secrets/backup.env | grep BACKUP_ENCRYPTION_PASSWORD
```

### Container Not Found

```bash
# List running containers
docker ps --format '{{.Names}}'

# Check container name matches config
grep PHPIPAM_DB_CONTAINER secrets/backup.env
```

### Rsync Permission Denied

```bash
# Check remote directory ownership
ssh backup-user@backup-server.local "ls -la /backups/"

# Ensure backup user owns the directory
# On remote: chown -R backup-user:backup-user /backups/raspberry-pi
```

## License

MIT License - See [LICENSE](../LICENSE) for details.
