#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Raspberry Pi Headless Cleanup Script
# GUARANTEES:
# - No package installations
# - No DKMS / NVIDIA / driver activity
# - No network configuration changes
# - Ethernet remains functional
###############################################################################

echo "=== Raspberry Pi Headless Cleanup (SAFE MODE) ==="

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Must be run as root"
  exit 1
fi

###############################################################################
# HARD SAFETY GUARDS
###############################################################################

# Abort if apt is configured to auto-install recommended packages
if apt-config dump | grep -q 'APT::Install-Recommends "true"'; then
  echo "ERROR: APT is configured to install recommends. Aborting for safety."
  exit 1
fi

# Force n
