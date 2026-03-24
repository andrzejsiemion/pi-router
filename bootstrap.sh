#!/usr/bin/env bash
# Bootstrap script: installs Ansible on a fresh Raspberry Pi 5 (Debian 13 Trixie)
# then runs the full playbook.
# Run as root: sudo bash bootstrap.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Bootstrap: updating package lists ==="
apt-get update -qq

echo "=== Bootstrap: installing Ansible ==="
apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv git ansible

echo "=== Bootstrap: installing Ansible collections ==="
ansible-galaxy collection install ansible.posix community.general community.docker

echo "=== Bootstrap: checking for secrets.yml ==="
if [[ ! -f "$SCRIPT_DIR/secrets.yml" ]]; then
    echo "ERROR: secrets.yml not found."
    echo "Copy secrets.yml.example to secrets.yml and fill in the values:"
    echo "  cp $SCRIPT_DIR/secrets.yml.example $SCRIPT_DIR/secrets.yml"
    exit 1
fi

echo "=== Bootstrap: running playbook ==="
cd "$SCRIPT_DIR"
ansible-playbook pi-router.yml -e @secrets.yml
