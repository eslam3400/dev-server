# Server Config — Replication Guide

A single docker-compose stack (`compose.yaml`) fronted by **Traefik**, covering
management/tooling (Portainer, DBgate) plus databases and object storage
(PostgreSQL, MongoDB, Redis, RustFS). Traefik terminates TLS (Let's Encrypt) and
routes every service by hostname under a single domain.

## Current Stack

**Traefik is the only container that binds host ports.** Everything else is
reached through it by hostname — there are no per-service host-port mappings.
Set `DOMAIN` in `.env`; the hostnames below are all `<name>.${DOMAIN}`.

### Reverse proxy

| App | Image | Host ports | Data |
|-----|-------|-----------|------|
| Traefik | traefik:v3 | 80, 443, 5432, 27017, 6379 | `/docker-data/traefik/certs` |

### Server apps (HTTPS, port 443)

| App | Image | URL | Data |
|-----|-------|-----|------|
| Portainer | portainer/portainer-ce | `https://portainer.${DOMAIN}` | `/docker-data/portainer/data` |
| DBgate | dbgate/dbgate | `https://dbgate.${DOMAIN}` | `/docker-data/dbgate/config` |
| Traefik dashboard | (built-in) | `https://traefik.${DOMAIN}` (basic auth) | — |

### Databases & storage

| App | Image | Endpoint | Data |
|-----|-------|----------|------|
| PostgreSQL | postgres:18.4 | `postgres.${DOMAIN}:5432` (TCP+TLS) | `/docker-data/postgresql/data` |
| MongoDB | mongo:8.3 | `mongodb.${DOMAIN}:27017` (TCP+TLS) | `/docker-data/mongodb/data/db` |
| Redis | redis:8.6.4 | `redis.${DOMAIN}:6379` (TCP+TLS) | `/docker-data/redis/data` |
| RustFS (S3 API) | rustfs/rustfs:latest | `https://s3.${DOMAIN}` | `/docker-data/rustfs/data` |
| RustFS (console) | rustfs/rustfs:latest | `https://storage.${DOMAIN}` | `/docker-data/rustfs/data` |

All services share the `dev-stack` bridge network, so `dbgate` reaches the
databases internally by container name (`postgres`, `mongodb`, `redis`) without
going through Traefik. The database services all have healthchecks. Credentials
and the domain are read from `.env`.

> **Note:** all data lives in bind mounts under `/docker-data` (no named
> volumes). These host paths are **not** auto-created by Docker — run
> `./setup-host.sh` once on a fresh host. `traefik` is pinned to `:v3`; the data
> images are version-pinned; `rustfs`, `portainer`, and `dbgate` are unpinned
> (`:latest`).

### DNS (required)

Because routing is hostname-based, create an **A record for each hostname**, all
pointing at the server's public IP:

```
traefik.${DOMAIN}    portainer.${DOMAIN}   dbgate.${DOMAIN}
storage.${DOMAIN}    s3.${DOMAIN}
postgres.${DOMAIN}   mongodb.${DOMAIN}     redis.${DOMAIN}
```

Let's Encrypt (TLS-ALPN-01) issues certs only after DNS resolves to this host
and ports 80/443 are reachable.

---

## Replication Steps

### 1. Create the .env file (do this first)

`setup-host.sh` requires `.env` to already exist — it starts the core services
at the end and exits early if `.env` is missing.

```bash
cp .env.example .env
# Edit .env and fill in real values (DOMAIN, ACME_EMAIL, dashboard hash,
# passwords, keys)
nano .env
```

`.env` supplies the domain/ACME settings, the Traefik dashboard credentials, and
the PostgreSQL, MongoDB, Redis, and RustFS credentials.

> **Gotcha:** any literal `$` in a value must be written as `$$` (compose turns
> `$$` back into `$`). This matters most for the bcrypt
> `TRAEFIK_DASHBOARD_USERS` hash. Generate it with:
> ```bash
> docker run --rm httpd:alpine htpasswd -nbB admin 'yourpassword'
> ```
> then double every `$` before pasting into `.env`. **Never `source .env`** —
> compose reads it directly, and sourcing would let bash expand those `$`.

### 2. Point DNS at the host

Create the A records listed in [DNS (required)](#dns-required) above, all
resolving to the server's public IP, before deploying — Let's Encrypt needs them.

### 3. Prepare the host

Run the setup script once on the fresh host. It updates packages, installs
Docker (if absent) and adds your user to the `docker` group, creates every
`/docker-data` bind-mount directory, configures UFW (allowing 22/80/443 and the
DB TCP ports), and finally starts the core services (`traefik`, `portainer`).

```bash
chmod +x setup-host.sh
./setup-host.sh
```

### 4. Deploy the full stack

```bash
docker compose up -d
```

Or via Portainer: **Stacks → Add stack**, name it `dev-stack`, paste the
contents of `compose.yaml`, and **Deploy the stack**.

### Connecting to the data services

Traefik terminates TLS in front of the databases, so clients connect with TLS:

```bash
psql 'host=postgres.${DOMAIN} port=5432 sslmode=require sslnegotiation=direct user=USER dbname=DB'
mongosh 'mongodb://USER:PASS@mongodb.${DOMAIN}:27017/DB?tls=true'
redis-cli -h redis.${DOMAIN} -p 6379 -a PASS --tls
```

> **Postgres note:** Traefik routes by SNI, but libpq's default negotiated TLS
> sends no SNI. Use `sslnegotiation=direct` (PostgreSQL 17+ client) so the
> handshake carries SNI and Traefik can route it.

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
├── INTEGRATION.md    # How a separate app repo connects to the DBs + Traefik
├── README.md         # This file
├── setup-host.sh     # Creates /docker-data bind-mount dirs, installs Docker
└── compose.yaml      # portainer + dbgate + postgres + mongodb + redis + rustfs
```
