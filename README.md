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
| Hermes Agent (dashboard) | nousresearch/hermes-agent:latest | `https://hermes.${DOMAIN}` (Hermes basic auth, set in config.yaml) | `/docker-data/hermes` |
| Hermes Agent (API) | nousresearch/hermes-agent:latest | `https://hermes-api.${DOMAIN}` (API key) | `/docker-data/hermes` |
| Traefik dashboard | (built-in) | `https://traefik.${DOMAIN}` (basic auth) | — |

### Databases & storage

| App | Image | Endpoint | Data |
|-----|-------|----------|------|
| PostgreSQL | postgres:18.4 | `postgres.${DOMAIN}:5432` (TCP+TLS) | `/docker-data/postgresql/data` |
| MongoDB | mongo:7.0 | `mongodb.${DOMAIN}:27017` (TCP+TLS) | `/docker-data/mongodb/data/db` |
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
hermes.${DOMAIN}     hermes-api.${DOMAIN}
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

### 5. Link Hermes Agent to Ollama Cloud (one-time)

`OLLAMA_API_KEY` in `.env` authenticates Hermes to ollama.com, but the provider
and default model are chosen once and written into the `/docker-data/hermes`
bind mount. After the stack is up, run the interactive picker against the
running container:

```bash
docker exec -it hermes hermes model
#  → choose "Ollama Cloud"
#  → the key from OLLAMA_API_KEY is already present
#  → pick a model, e.g. gpt-oss:120b, qwen3-coder:480b-cloud, glm-4.6:cloud
```

This writes `/docker-data/hermes/config.yaml`:

```yaml
model:
  provider: "ollama-cloud"     # endpoint: https://api.ollama.com/v1
  default: "gpt-oss:120b"
```

**Dashboard auth (required).** Hermes refuses to bind its dashboard to a
non-loopback address (needed so Traefik can reach it) unless an auth provider is
registered in its own `config.yaml` — Traefik's basic-auth middleware does not
count, because Hermes can't see it. Add a `dashboard.basic_auth` block to the
same `/docker-data/hermes/config.yaml`:

```bash
# generate a password hash inside the container
docker compose exec hermes python -c \
  "from plugins.dashboard_auth.basic import hash_password; print(hash_password('your-password'))"
```

```yaml
dashboard:
  basic_auth:
    username: admin
    password_hash: "<paste the hash>"
```

Then `docker compose restart hermes`.

Then use it via the dashboard at `https://hermes.${DOMAIN}` (Hermes basic
auth), or call the OpenAI-compatible API at `https://hermes-api.${DOMAIN}`
sending `Authorization: Bearer ${HERMES_API_SERVER_KEY}`. Other containers on
the `dev-stack` network can reach it directly at `http://hermes:8642`.

### Connecting to the data services

> **TLS is required.** Traefik terminates TLS in front of every database TCP
> entrypoint. A client that opens the socket without speaking TLS will hang
> until it times out — this looks like a network problem but is a missing SSL
> flag. Always enable TLS on the client side when connecting remotely.

The certs are Let's Encrypt-issued but Traefik presents them as a passthrough,
so most clients need `rejectUnauthorized: false` / `tlsAllowInvalidCertificates`
unless you explicitly supply the CA. This is fine for self-hosted dev databases.

**CLI**

```bash
psql 'host=postgres.${DOMAIN} port=5432 sslmode=require user=USER dbname=DB'
mongosh 'mongodb://USER:PASS@mongodb.${DOMAIN}:27017/DB?tls=true&tlsAllowInvalidCertificates=true'
redis-cli -h redis.${DOMAIN} -p 6379 -a PASS --tls --insecure
```

**NestJS / Node.js env vars** (set these when the API targets the remote host)

```bash
# .env  — remote dev server
POSTGRES_HOST=postgres.${DOMAIN}
POSTGRES_PORT=5432
DB_SSL=true          # enables ssl: { rejectUnauthorized: false } in db.config.ts

MONGO_URI=mongodb://USER:PASS@mongodb.${DOMAIN}:27017/DB?tls=true&tlsAllowInvalidCertificates=true
MONGO_SSL=true       # appends tls params to the URI in app-config.service.ts

REDIS_HOST=redis.${DOMAIN}
REDIS_PORT=6379
REDIS_TLS=true
```

```bash
# .env.prod  — containers on the same dev-stack network (no Traefik in the path)
DB_SSL=false
MONGO_SSL=false
REDIS_TLS=false
```

**Verification matrix**

| Connection | No TLS     | With TLS |
|------------|------------|----------|
| Postgres   | ❌ timeout | ✅ OK    |
| MongoDB    | ❌ timeout | ✅ OK    |

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
└── compose.yaml      # portainer + dbgate + hermes + postgres + mongodb + redis + rustfs
```
