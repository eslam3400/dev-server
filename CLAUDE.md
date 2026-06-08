# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Docker Compose stack for a self-hosted dev server, plus a host-prep
script and an env template. There is no application code — the "build" is
deploying containers. Everything lives in three files: `compose.yml`,
`setup-host.sh`, `.env.example`.

## Common commands

```bash
# One-time on a fresh host: create the /docker-data bind-mount dirs + TUN device
chmod +x setup-host.sh && ./setup-host.sh

# Validate the compose file
docker compose config -q

# Deploy / update the whole stack (load .env into the shell first)
set -a && source .env && set +a
docker compose up -d

# Tear down
docker compose down

# Connect Tailscale after first boot
docker exec tailscale tailscale up --authkey=<your-auth-key>
```

`compose.yml` uses the default filename, so `docker compose` finds it with no
`-f` flag. The project name is pinned to `server-config` via the top-level
`name:` key.

## Architecture & invariants

The stack has two logical groups of services on one `dev` bridge network:

- **Tooling:** `tailscale` (host network), `portainer`, `code-server`, `dbgate`.
- **Data:** `postgres`, `mongodb`, `redis`, `rustfs` — each with a healthcheck.

`dbgate` connects to the data services **by container name** (`postgres`,
`mongodb`, `redis`) over the shared `dev` network. The history matters here: this
was previously two separate compose files (`server-apps.yml` + `dev-stack.yml`)
where `dev` was an external network shared between them. They were merged into
`compose.yml`, so `dev` is now defined once as a regular bridge and the
external-network / stack-ordering dependency is gone.

Key invariants to preserve when editing:

- **All persistent data is in bind mounts under `/docker-data`** — no named
  volumes. Docker does **not** create bind-mount source paths, so any new
  service needing persistence must also get its directory added to
  `setup-host.sh`, or the daemon creates it root-owned / fails.
- **Secrets come from `.env`** via `${VAR}` interpolation. Adding a credentialed
  service means adding the var to both `compose.yml` and `.env.example`.
  `LINUX_USER` is special: it's consumed by both `compose.yml` (code-server home
  mounts) and `setup-host.sh`.
- `setup-host.sh` reads `LINUX_USER` from `.env`, falling back to `$USER`; it can
  be overridden inline (`LINUX_USER=eslam ./setup-host.sh`).

Three files must stay in sync when services change: `compose.yml` (the service),
`setup-host.sh` (its bind-mount dir), and `.env.example` (its secrets). The
README's service tables document the current port/data layout.

## Notes

- `rustfs`, and the tooling images (`portainer`, `code-server`, `tailscale`,
  `dbgate`) are unpinned (`:latest`); the data images are version-pinned.
- The cSpell diagnostics flagging `dbgate`, `rustfs`, `healthcheck`, etc. are
  spell-check noise, not errors.
