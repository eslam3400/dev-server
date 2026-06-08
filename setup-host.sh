#!/usr/bin/env bash
#
# setup-host.sh — prepare host directories used as bind mounts by both stacks.
#
# Docker auto-creates *named* volumes but NOT bind-mount source paths; if those
# paths don't exist, the daemon creates them as root-owned dirs (or fails).
# Run this once on a fresh host before `docker compose up`.
#
# Usage:
#   ./setup-host.sh            # uses $USER for code-server home mounts
#   LINUX_USER=eslam ./setup-host.sh

set -euo pipefail

# Pick up LINUX_USER from .env if present, else fall back to the invoking user.
if [[ -z "${LINUX_USER:-}" && -f .env ]]; then
  LINUX_USER="$(grep -E '^LINUX_USER=' .env | head -n1 | cut -d= -f2- || true)"
fi
LINUX_USER="${LINUX_USER:-$USER}"

echo ">> Preparing /docker-data bind mounts (sudo required)..."

# --- server-apps stack ---------------------------------------------------
sudo mkdir -p /docker-data/portainer/data
sudo mkdir -p /docker-data/code-server/config
sudo mkdir -p /docker-data/dbgate/config
sudo mkdir -p /docker-data/tailscale

# --- dev stack -----------------------------------------------------------
sudo mkdir -p /docker-data/postgresql/data
sudo mkdir -p /docker-data/mongodb/data/db
sudo mkdir -p /docker-data/redis/data
sudo mkdir -p /docker-data/rustfs/data

echo ">> Preparing code-server home mounts for user '${LINUX_USER}'..."
mkdir -p "/home/${LINUX_USER}/work"
mkdir -p "/home/${LINUX_USER}/.ssh"

echo ">> Enabling TUN device for Tailscale..."
sudo mkdir -p /dev/net
sudo mknod /dev/net/tun c 10 200 2>/dev/null || true
sudo chmod 0666 /dev/net/tun

echo ">> Done. Host is ready for: docker compose up -d"
