# Server Config — Replication Guide

A single docker-compose stack (`compose.yaml`) covering management/tooling
(Portainer, DBgate) plus databases and object storage
(PostgreSQL, MongoDB, Redis, RustFS).

## Current Stack

### Server apps

| App | Image | Port(s) | Data |
|-----|-------|---------|------|
| Portainer | portainer/portainer-ce | 8000, 9000, 9443 | `/docker-data/portainer/data` |
| DBgate | dbgate/dbgate | 3000 | `/docker-data/dbgate/config` |

### Databases & storage

| App | Image | Port(s) | Data |
|-----|-------|---------|------|
| PostgreSQL | postgres:18.4 | 5432 | `/docker-data/postgresql/data` |
| MongoDB | mongo:8.3 | 27017 | `/docker-data/mongodb/data/db` |
| Redis | redis:8.6.4 | 6379 | `/docker-data/redis/data` |
| RustFS | rustfs/rustfs:latest | 9100→9000, 9101→9001 | `/docker-data/rustfs/data` |

The database/storage services and `dbgate` share a `dev-stack` bridge network, so
`dbgate` reaches the databases by container name (`postgres`, `mongodb`,
`redis`). The database services all have healthchecks. Credentials are read from
`.env` (`*_USER`/`*_PASSWORD`/`*_DB`, etc.).

> **Note:** all data lives in bind mounts under `/docker-data` (no named
> volumes). These host paths are **not** auto-created by Docker — run
> `./setup-host.sh` once on a fresh host first. RustFS and the tooling images
> (`portainer`, `dbgate`) are still unpinned (`:latest`).

---

## Replication Steps

### 1. Prepare the host

All data lives in bind mounts under `/docker-data`. Docker won't create those
source paths for you, so run the setup script once on the fresh host. It
installs Docker (if absent), adds your user to the `docker` group, and creates
every bind-mount directory.

```bash
chmod +x setup-host.sh
./setup-host.sh
```

### 2. Create the .env file

```bash
cp .env.example .env
# Edit .env and fill in real values (passwords, keys)
nano .env
```

`.env` supplies the PostgreSQL, MongoDB, Redis, and RustFS credentials.

### 3. Deploy the stack

```bash
set -a && source .env && set +a
docker compose up -d
```

Or via Portainer: **Stacks → Add stack**, name it `dev-stack`, paste the
contents of `compose.yaml`, and **Deploy the stack**.

---

## Data Migration (optional)

To carry over existing data from the old device:

Everything (configs and database data) lives under `/docker-data`, so the
simplest migration is a single rsync of that tree while the stack is stopped:

```bash
# On old device: stop the stack, then sync the whole data tree
docker compose down
rsync -avz /docker-data/ <new-host>:/docker-data/
```

Alternatively, do a logical dump per database (lets you migrate while running):

```bash
# On old device: dump and transfer
docker exec postgres pg_dumpall -U "$POSTGRES_USER" > postgres_dump.sql
docker exec mongodb mongodump --out /tmp/mongodump && \
  docker cp mongodb:/tmp/mongodump ./mongodump

# On new device: restore after starting the stack
cat postgres_dump.sql | docker exec -i postgres psql -U "$POSTGRES_USER"
docker cp ./mongodump mongodb:/tmp/mongodump && \
  docker exec mongodb mongorestore /tmp/mongodump
```

---

## File Layout

```
dev-server/
├── .env.example      # Secrets template — copy to .env and fill in
├── README.md         # This file
├── setup-host.sh     # Creates /docker-data bind-mount dirs, installs Docker
└── compose.yaml      # portainer + dbgate + postgres + mongodb + redis + rustfs
```
