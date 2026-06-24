# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Docker Compose stack for a self-hosted dev server, plus a host-prep
script and an env template. There is no application code — the "build" is
deploying containers. Everything lives in three files: `compose.yaml`,
`setup-host.sh`, `.env.example`.

## Common commands

```bash
# One-time on a fresh host: install Docker, create /docker-data bind mounts,
# configure UFW, and start the core services (traefik + portainer).
# Requires .env to exist first — it exits early otherwise.
cp .env.example .env && nano .env        # fill in real values
chmod +x setup-host.sh && ./setup-host.sh

# Validate the compose file
docker compose config -q

# Deploy / update the whole stack
# Do NOT `source .env` — docker compose reads it automatically. Sourcing it
# would let bash expand any $ in the values (e.g. the bcrypt dashboard hash).
docker compose up -d

# Tear down
docker compose down
```

`compose.yaml` uses the default filename, so `docker compose` finds it with no
`-f` flag. The project name is pinned to `dev-stack` via the top-level
`name:` key.

## Architecture & invariants

All services sit on one `dev-stack` bridge network and are **fronted by
Traefik** — nothing is published on its own host port anymore. Traefik is the
only container that binds host ports (80, 443, and the TCP entrypoints 5432 /
27017 / 6379) and routes to everything else by Docker labels.

Three logical groups:

- **Reverse proxy:** `traefik` (v3) — terminates TLS, gets certs from Let's
  Encrypt via the ACME **TLS-ALPN-01** challenge (`certresolver: le`), and
  routes by hostname. The dashboard is at `traefik.${DOMAIN}` behind basic auth.
- **Tooling:** `portainer`, `dbgate` — HTTP routers on `portainer.${DOMAIN}` /
  `dbgate.${DOMAIN}` (443).
- **Data:** `postgres`, `mongodb`, `redis`, `rustfs` — each with a healthcheck.
  The databases use **TCP routers with `HostSNI` + TLS termination** on their
  own entrypoints; `rustfs` uses HTTP routers (`s3.${DOMAIN}`, `storage.${DOMAIN}`).

Routing is hostname-based, so **every service needs a DNS A record**
(`traefik`, `portainer`, `dbgate`, `storage`, `s3`, `postgres`, `mongodb`,
`redis` — all under `${DOMAIN}`, all pointing at the host's public IP).

`dbgate` still connects to the data services **by container name** (`postgres`,
`mongodb`, `redis`) over the `dev-stack` network — internal traffic does not go
through Traefik. (History: this was once two compose files sharing an external
`dev` network; they were merged into `compose.yaml` and the network is now a
single regular bridge named `dev-stack`.)

Key invariants to preserve when editing:

- **All persistent data is in bind mounts under `/docker-data`** — no named
  volumes. Docker does **not** create bind-mount source paths, so any new
  service needing persistence must also get its directory added to
  `setup-host.sh`, or the daemon creates it root-owned / fails.
- **Secrets come from `.env`** via `${VAR}` interpolation. Adding a credentialed
  service means adding the var to both `compose.yaml` and `.env.example`.
- **Never `source .env`.** compose reads it directly; sourcing it into the shell
  lets bash expand `$` in values. A literal `$` in a value (notably the bcrypt
  `TRAEFIK_DASHBOARD_USERS` hash) must be written as `$$` in `.env` so compose
  emits a single `$`.
- **Exposing a new service publicly** means adding Traefik labels (router rule +
  entrypoint + `tls.certresolver: le` + a `loadbalancer.server.port`), a DNS
  record, and — for a new TCP entrypoint — a `ports:` line on traefik plus a UFW
  rule in `setup-host.sh`.

Files that must stay in sync when services change: `compose.yaml` (the service +
its Traefik labels), `setup-host.sh` (its bind-mount dir and any new UFW port),
and `.env.example` (its secrets). The README's service tables document the
current hostname/port/data layout.

## Notes

- `rustfs`, `portainer`, and `dbgate` are unpinned (`:latest`); `traefik` is
  pinned to `:v3` and the data images are version-pinned.
- The cSpell diagnostics flagging `dbgate`, `rustfs`, `healthcheck`, `traefik`,
  `certresolver`, etc. are spell-check noise, not errors.
