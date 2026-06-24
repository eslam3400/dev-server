#!/usr/bin/env bash
#
# setup-host.sh — bootstrap a fresh host: update packages, install Docker,
# prepare bind-mount directories, configure the firewall, then start the
# core services (traefik + portainer).
#
# Docker auto-creates *named* volumes but NOT bind-mount source paths; if those
# paths don't exist, the daemon creates them as root-owned dirs (or fails).
# Run this once on a fresh host before or alongside `docker compose up`.

set -euo pipefail

# Resolve to the directory containing this script so docker compose always
# finds compose.yaml regardless of where the script is invoked from.
cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# 1. System package update (skipped if apt cache is less than 24 h old)
# ---------------------------------------------------------------------------
APT_CACHE="/var/cache/apt/pkgcache.bin"
if [[ ! -f "${APT_CACHE}" ]] || [[ $(( $(date +%s) - $(stat -c %Y "${APT_CACHE}") )) -gt 86400 ]]; then
  echo ">> Updating system packages..."
  sudo apt-get update -y
  sudo apt-get upgrade -y
else
  echo ">> apt cache is fresh (< 24 h), skipping update."
fi
# Always ensure the Docker prereqs are present; apt skips already-installed packages.
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# ---------------------------------------------------------------------------
# 2. Docker Engine + Docker Compose plugin (official repo)
# ---------------------------------------------------------------------------
if command -v docker &>/dev/null; then
  echo ">> Docker already installed ($(docker --version)), skipping."
else
  echo ">> Installing Docker Engine..."

  # Add Docker's official GPG key
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  # Add the Docker apt repository
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  sudo systemctl enable --now docker
  echo ">> Docker installed: $(docker --version)"
fi

# Add the invoking user to the docker group so they can run docker without sudo.
if ! groups "${USER}" | grep -q '\bdocker\b'; then
  echo ">> Adding '${USER}' to the docker group (re-login to take effect)..."
  sudo usermod -aG docker "${USER}"
fi

# ---------------------------------------------------------------------------
# 3. Bind-mount directory prep
# ---------------------------------------------------------------------------
echo ">> Preparing /docker-data bind mounts (sudo required)..."

sudo mkdir -p /docker-data/traefik/certs
sudo mkdir -p /docker-data/portainer/data
sudo mkdir -p /docker-data/dbgate/config
sudo mkdir -p /docker-data/postgresql/data
sudo mkdir -p /docker-data/mongodb/data/db
sudo mkdir -p /docker-data/redis/data
sudo mkdir -p /docker-data/rustfs/data

# ---------------------------------------------------------------------------
# 4. Firewall (UFW)
# ---------------------------------------------------------------------------
echo ">> Configuring UFW..."
sudo apt-get install -y ufw

sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp    comment 'SSH'
sudo ufw allow 80/tcp    comment 'HTTP (Traefik redirect)'
sudo ufw allow 443/tcp   comment 'HTTPS (Traefik)'
sudo ufw allow 5432/tcp  comment 'PostgreSQL (Traefik TCP+TLS)'
sudo ufw allow 27017/tcp comment 'MongoDB (Traefik TCP+TLS)'
sudo ufw allow 6379/tcp  comment 'Redis (Traefik TCP+TLS)'
sudo ufw --force enable

# ---------------------------------------------------------------------------
# 5. Start core services (traefik + portainer)
# ---------------------------------------------------------------------------
if [[ ! -f .env ]]; then
  echo ""
  echo "ERROR: .env file not found. Copy .env.example to .env and fill in all"
  echo "       values before running this script, then re-run."
  exit 1
fi

echo ">> Starting core services (traefik, portainer)..."
# Use sudo docker because the docker group membership added above is not
# active in this shell session until the user logs out and back in.
# Do NOT `source .env` — docker compose reads it automatically, and sourcing
# would let bash expand any $ in the values (e.g. the bcrypt dashboard hash).
sudo docker compose up -d traefik portainer

echo ""
echo ">> Done. Core services are up."
echo ""
echo "   To start the full stack:"
echo "     docker compose up -d"
echo ""
echo "   DNS A records needed (all → this server's public IP):"
echo "     traefik.<DOMAIN>   portainer.<DOMAIN>   dbgate.<DOMAIN>"
echo "     storage.<DOMAIN>   s3.<DOMAIN>"
echo "     postgres.<DOMAIN>  mongodb.<DOMAIN>      redis.<DOMAIN>"
echo ""
echo "   Data service connection strings (TLS required for all remote connections):"
echo "     PostgreSQL : psql 'host=postgres.<DOMAIN> port=5432 sslmode=require user=USER dbname=DB'"
echo "     MongoDB    : mongosh 'mongodb://USER:PASS@mongodb.<DOMAIN>:27017/DB?tls=true&tlsAllowInvalidCertificates=true'"
echo "     Redis      : redis-cli -h redis.<DOMAIN> -p 6379 -a PASS --tls --insecure"
echo "     RustFS S3  : endpoint https://s3.<DOMAIN>"
