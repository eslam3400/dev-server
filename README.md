# Server Config — Replication Guide

## Current Stack

| App | Image | Port(s) | Manager |
|-----|-------|---------|---------|
| Tailscale | tailscale/tailscale:v1.90.8 | host network | CasaOS |
| code-server | linuxserver/code-server:4.118.0 | 8080→8443 | CasaOS |
| DBgate | dbgate/dbgate:7.1.11-alpine | 3000 | CasaOS |
| Portainer | portainer/portainer-ce:2.41.1-alpine | 8000, 9000, 9443 | CasaOS |
| PostgreSQL | postgres:18-alpine | 5432 | Portainer stack: dev |
| MongoDB | mongo:7-jammy | 27017 | Portainer stack: dev |
| Redis | redis:8-alpine | 6379 | Portainer stack: dev |
| RustFS | rustfs/rustfs:latest | 9100, 9101 | Portainer stack: dev |

AppData lives under `/DATA/AppData/` — only postgres/mongo/redis/rustfs use named Docker volumes.

---

## Replication Steps

### 1. Install CasaOS

```bash
curl -fsSL https://get.casaos.io | sudo bash
```

### 2. Prepare the host

```bash
# Create AppData directories CasaOS apps expect
sudo mkdir -p /DATA/AppData/tailscale
sudo mkdir -p /DATA/AppData/big-bear-code-server/config
sudo mkdir -p /DATA/AppData/big-bear-dbgate/config
sudo mkdir -p /DATA/AppData/big-bear-portainer/data

# Create the work and ssh dirs (adjust username as needed)
mkdir -p /home/<user>/work
mkdir -p /home/<user>/.ssh

# Enable TUN device for Tailscale
sudo mkdir -p /dev/net
sudo mknod /dev/net/tun c 10 200 2>/dev/null || true
sudo chmod 0666 /dev/net/tun
```

### 3. Create the .env file

```bash
cp .env.example .env
# Edit .env and fill in real values (passwords, API keys)
nano .env
```

### 4. Deploy CasaOS apps

You can install each app through the CasaOS UI (BigBear app store) **or** deploy them
directly with docker compose. The compose files in `casaos-apps/` are the canonical source.

**Option A — via CasaOS UI:**
Install Tailscale, code-server, DBgate, and Portainer from the BigBear app store. They will
land in `/var/lib/casaos/apps/` automatically.

**Option B — directly with docker compose:**
```bash
# Load env vars, then start each app
set -a && source .env && set +a

docker compose -f casaos-apps/tailscale.yml up -d
docker compose -f casaos-apps/portainer.yml up -d
docker compose -f casaos-apps/dbgate.yml up -d
docker compose -f casaos-apps/code-server.yml up -d
```

> **Note for code-server:** edit `casaos-apps/code-server.yml` and update the two
> bind-mount paths (`/home/eslam/.ssh` and `/home/eslam/work`) to match the new user's
> home directory before deploying.

### 5. Deploy the Portainer "dev" stack (postgres + mongo + redis + rustfs)

After Portainer is running:
1. Open Portainer at `http://<host>:9000`
2. Go to **Stacks → Add stack**
3. Name it `dev`
4. Paste the contents of `portainer-stacks/dev-stack.yml`
5. Click **Deploy the stack**

Or deploy directly without Portainer:
```bash
docker compose -f portainer-stacks/dev-stack.yml up -d
```

### 6. Connect Tailscale

```bash
docker exec tailscale tailscale up --authkey=<your-auth-key>
```

---

## Data Migration (optional)

To carry over existing data from the old device:

```bash
# From the OLD device — sync AppData (config files, dbgate saved connections, etc.)
rsync -avz /DATA/AppData/ <new-host>:/DATA/AppData/

# Named Docker volumes (postgres, mongo, redis, rustfs data)
# On old device: dump and transfer
docker exec postgres pg_dumpall -U root > postgres_dump.sql
docker exec mongodb mongodump --out /tmp/mongodump && \
  docker cp mongodb:/tmp/mongodump ./mongodump

# On new device: restore after starting the stack
cat postgres_dump.sql | docker exec -i postgres psql -U root
docker cp ./mongodump mongodb:/tmp/mongodump && \
  docker exec mongodb mongorestore /tmp/mongodump
```

---

## File Layout

```
server-config/
├── .env.example                  # Secrets template — copy to .env and fill in
├── README.md                     # This file
├── casaos-apps/
│   ├── tailscale.yml
│   ├── code-server.yml
│   ├── dbgate.yml
│   └── portainer.yml
└── portainer-stacks/
    └── dev-stack.yml             # postgres + mongodb + redis + rustfs
```
