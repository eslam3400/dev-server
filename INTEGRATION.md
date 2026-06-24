# Integrating an App with the dev-stack

This guide is for an app living in **its own repo / its own `compose.yaml`** that
needs to:

1. **Talk to the shared data services** (PostgreSQL, MongoDB, Redis, RustFS) that
   already run in the `dev-stack`, and
2. **Be published to end users** through the shared Traefik reverse proxy
   (automatic HTTPS via Let's Encrypt), without binding any host ports itself.

It assumes the `dev-stack` (this repo's `compose.yaml`) is **already deployed and
running** on the same host. You are adding a *second* compose project beside it,
not editing the stack itself.

---

## The one rule that makes everything work

Your app's containers must join the stack's network, which already exists as an
**external Docker bridge named `dev-stack`**. Everything below — both database
access and Traefik routing — depends on this.

```yaml
# in YOUR app's compose.yaml
networks:
  dev-stack:
    external: true        # do NOT redefine it; reuse the running one
```

Then attach each service to it (`networks: [dev-stack]`).

Why it matters:

- **Databases** are reachable only *inside* this network, by container name
  (`postgres`, `mongodb`, `redis`, `rustfs`). They are **not** published on host
  ports.
- **Traefik** is started with `--providers.docker.network=dev-stack`, so it only
  routes to backends it can find **on that network**. An app on a different
  network is invisible to Traefik even with perfect labels.

---

## 1. Connecting to the data services (internal)

Connect **by container name over the `dev-stack` network**, in **plaintext** — do
*not* use TLS here. (TLS termination only happens at Traefik for traffic coming
from the public internet; inside the Docker network it's a private link.)

| Service    | Host (container name) | Port  | Notes |
|------------|-----------------------|-------|-------|
| PostgreSQL | `postgres`            | 5432  | no TLS internally (`sslmode=disable`) |
| MongoDB    | `mongodb`             | 27017 | no `tls=true` internally |
| Redis      | `redis`               | 6379  | password required (`--requirepass`) |
| RustFS     | `rustfs`              | 9000  | S3 API; path-style addressing |

Example connection strings (substitute the real credentials):

```bash
# PostgreSQL
postgres://USER:PASSWORD@postgres:5432/DBNAME?sslmode=disable

# MongoDB (root creds from the stack)
mongodb://USER:PASSWORD@mongodb:27017/DBNAME?authSource=admin

# Redis
redis://:PASSWORD@redis:6379/0

# RustFS (S3-compatible)
endpoint:        http://rustfs:9000
forcePathStyle:  true
accessKeyId / secretAccessKey: from the stack's RUSTFS_ACCESS_KEY / RUSTFS_SECRET_KEY
```

### Credentials

The usernames/passwords are defined in the **dev-stack's `.env`**
(`POSTGRES_USER`, `POSTGRES_PASSWORD`, `MONGO_ROOT_USER`, …, `REDIS_PASSWORD`,
`RUSTFS_ACCESS_KEY`/`RUSTFS_SECRET_KEY`). Your app needs the same values. Put them
in **your app's own `.env`** and reference them with `${VAR}`; never hard-code
secrets in compose.

> Best practice: don't reuse the Postgres/Mongo superuser for your app. Create a
> dedicated database + least-privilege user once (via DBgate at
> `https://dbgate.<DOMAIN>`, or `psql`/`mongosh`), and point the app at that.

### Startup ordering

Your compose project and the stack are **separate projects**, so you can't
`depends_on` the database containers. Make the app resilient instead: retry the
DB connection on boot (the data services already have healthchecks, but your app
won't see them cross-project).

---

## 2. Publishing the app through Traefik

Traefik auto-discovers containers via Docker labels. Two non-negotiables:

- `traefik.enable=true` — the stack runs with `exposedbydefault=false`, so a
  container is ignored unless it opts in.
- `loadbalancer.server.port` — the **container-internal** port your app listens
  on (e.g. 3000/8000/8080). Do **not** add a `ports:` mapping; Traefik reaches the
  app over the `dev-stack` network, and only Traefik binds host ports.

### HTTP/HTTPS app (the common case)

```yaml
services:
  myapp:
    image: your/image:tag
    restart: unless-stopped
    env_file: .env
    networks:
      - dev-stack
    labels:
      traefik.enable: "true"
      # Router: which hostname maps to this app
      traefik.http.routers.myapp.rule: "Host(`myapp.${DOMAIN}`)"
      traefik.http.routers.myapp.entrypoints: websecure
      traefik.http.routers.myapp.tls.certresolver: le
      # Service: the port your app listens on INSIDE the container
      traefik.http.services.myapp.loadbalancer.server.port: "3000"

networks:
  dev-stack:
    external: true
```

That's the whole integration. On `docker compose up -d`, Traefik picks up the
labels, requests a Let's Encrypt cert for `myapp.<DOMAIN>`, and serves the app on
HTTPS. The `web` (port 80) entrypoint auto-redirects to HTTPS, so you don't need
an HTTP router.

**Naming:** replace `myapp` in the label keys with a unique slug per app — it's
just the Traefik router/service id and must not collide with existing ones
(`portainer`, `dbgate`, `rustfs-console`, `rustfs-s3`, `dashboard`).

### DNS (required, per app)

Add an **A record** `myapp.<DOMAIN>` → the server's public IP. Without it the
hostname won't resolve and Let's Encrypt can't issue the cert. Use the same
`DOMAIN` as the stack.

### Path-based routing (optional)

To serve under a path instead of a subdomain:

```yaml
traefik.http.routers.myapp.rule: "Host(`api.${DOMAIN}`) && PathPrefix(`/myapp`)"
# strip the prefix before it reaches the app:
traefik.http.routers.myapp.middlewares: "myapp-strip"
traefik.http.middlewares.myapp-strip.stripprefix.prefixes: "/myapp"
```

### Raw TCP service (only if you're NOT speaking HTTP)

Most backends are HTTP — use the block above. A raw-TCP service (custom
protocol) additionally needs a **new entrypoint**, which means editing the
**stack's** `compose.yaml` (a `--entrypoints.<name>.address=:PORT` flag + a
`ports:` line on Traefik) and opening that port in `setup-host.sh`'s UFW rules.
Coordinate that change with the stack repo; it can't be done from the app repo
alone.

---

## Minimal end-to-end example

A backend that uses Postgres + Redis and is served at `https://api.<DOMAIN>`:

```yaml
# myapp/compose.yaml
name: myapp

services:
  api:
    image: your/api:latest
    restart: unless-stopped
    environment:
      DATABASE_URL: "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${APP_DB}?sslmode=disable"
      REDIS_URL: "redis://:${REDIS_PASSWORD}@redis:6379/0"
    networks:
      - dev-stack
    labels:
      traefik.enable: "true"
      traefik.http.routers.api.rule: "Host(`api.${DOMAIN}`)"
      traefik.http.routers.api.entrypoints: websecure
      traefik.http.routers.api.tls.certresolver: le
      traefik.http.services.api.loadbalancer.server.port: "8080"

networks:
  dev-stack:
    external: true
```

Deploy:

```bash
# .env holds DOMAIN, POSTGRES_*, REDIS_PASSWORD, APP_DB, etc.
# Do NOT `source .env` — compose reads it automatically. (A literal $ in a value
# must be written as $$ so compose emits a single $.)
docker compose up -d
```

---

## Checklist for the integrating agent

- [ ] App service has `networks: [dev-stack]` and the top-level
      `networks.dev-stack.external: true`.
- [ ] DB connections target container names (`postgres`/`mongodb`/`redis`/`rustfs`)
      in **plaintext** (no TLS, no `ports:`).
- [ ] Secrets come from the app's own `.env` via `${VAR}` and match the stack's
      credentials (literal `$` written as `$$`).
- [ ] Traefik labels present: `traefik.enable=true`, a `Host(...)` router on
      `entrypoints: websecure` with `tls.certresolver: le`, and a
      `loadbalancer.server.port` = the app's internal port.
- [ ] Router/service label ids are unique (no clash with existing routers).
- [ ] A DNS A record exists for the app's hostname under the same `DOMAIN`.
- [ ] App retries its DB connection on startup (no cross-project `depends_on`).
```
