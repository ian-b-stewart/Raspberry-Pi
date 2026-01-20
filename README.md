# Raspberry Pi Homelab Utilities

A collection of scripts and tools for managing Raspberry Pi servers in a homelab environment.

## Repository Structure

```
Raspberry-Pi/
├── README.md               # This file
├── LICENSE                 # MIT License
├── .gitignore              # Excludes secrets and sensitive files
│
├── Backup/                 # Docker backup solution
│   ├── README.md           # Comprehensive backup documentation
│   ├── backup.env.example  # Configuration template
│   ├── secrets/            # (gitignored) Keys, passwords, env files
│   └── scripts/
│       ├── backup.sh       # Run daily backups
│       ├── restore.sh      # List and restore backups
│       ├── rotate-password.sh  # Quarterly password rotation
│       └── setup.sh        # Initial setup wizard
│
└── Pi-Headless-Cleanup/    # Headless server optimization
    ├── README.md           # Script documentation
    └── pi-headless-cleanup.sh  # Remove GUI, disable radios
```

## Projects

### 🔒 [Backup](Backup/README.md)

Secure, automated backup solution for Docker homelab deployments. Features:

- **Database dumps** from MariaDB/MySQL containers
- **Stack data backup** for Docker Compose bind mounts
- **GPG AES-256 encryption** for secrets
- **Generational retention** (7 daily, 4 weekly, 3 monthly)
- **Passphrase-protected SSH keys** with ssh-agent
- **Healthchecks.io integration** for monitoring
- **Restore support** with automatic password fallback

[📖 Full Documentation →](Backup/README.md)

### 🖥️ [Pi-Headless-Cleanup](Pi-Headless-Cleanup/README.md)

Optimize a Raspberry Pi for headless server operation:

- Disables Bluetooth and Wi-Fi radios
- Removes GUI packages (X11, LXDE, etc.)
- Disables unnecessary services
- Reduces memory usage and attack surface

[📖 Full Documentation →](Pi-Headless-Cleanup/README.md)

## Quick Start

### Clone the Repository

```bash
cd /opt
git clone https://github.com/ian-b-stewart/Raspberry-Pi.git
```

### Setup Backup System

```bash
cd /opt/Raspberry-Pi/Backup
./scripts/setup.sh
# Follow the interactive prompts
```

### Run Headless Cleanup

```bash
cd /opt/Raspberry-Pi/Pi-Headless-Cleanup
sudo ./pi-headless-cleanup.sh
```

## Security

This is a **public repository**. All sensitive data is excluded via `.gitignore`:

- `Backup/secrets/` - Contains SSH keys, passwords, environment files
- `*.env` files (except `*.env.example` templates)
- SSH private keys (`id_*`)
- Key/certificate files (`*.key`, `*.pem`)

**Never commit secrets to this repository.**

## Requirements

- Raspberry Pi 4 (or compatible ARM device)
- Raspberry Pi OS Lite (Bookworm/Bullseye)
- Bash 4.0+
- Standard Unix tools (gpg, rsync, ssh, docker)

## License

MIT License - See [LICENSE](LICENSE) for details.

## Author

Ian Stewart - [GitHub](https://github.com/ian-b-stewart)
