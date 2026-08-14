# deploy-common

Shared CI/CD library for dacha-na-udachu and wb-parser-enterprise.

## What lives here

- `lib/shared-functions.sh` — logging, colours, retry loops, docker/caddy helpers
- `scripts/caddy-bootstrap.sh` — idempotent Caddy network + container setup
- `scripts/caddy-reload.sh` — validate + reload Caddy
- `caddy.bootstrap/Caddyfile` — canonical base Caddyfile (single source of truth)
- `.just/caddy.just` — Caddy management recipes
- `.just/docker-compose.just` — Docker prune/cleanup recipes
- `.just/deploy.just` — 7-step deploy pipeline recipes

## Usage from a project

### Option A: Import in project's justfile

```just
# In your justfile:
import '/mnt/Backup/deploy-common/.just/deploy.just'
import '/mnt/Backup/deploy-common/.just/caddy.just'

# Override variables as needed:
PROJECT_CADDY_SNIPPET := "webcrawler"
COMPOSE_FILE := "docker-compose.prod.yml"

# Wire the shared deploy steps:
prod-deploy: deploy-git-pull deploy-caddy-bootstrap deploy-caddy-config deploy-compose-up deploy-caddy-reload deploy-smoke-test deploy-clean
```

### Option B: Use the scripts directly in deploy.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

DEPLOY_COMMON="${DEPLOY_COMMON:-/mnt/Backup/deploy-common}"
source "$DEPLOY_COMMON/lib/shared-functions.sh"
source "$DEPLOY_COMMON/scripts/caddy-bootstrap.sh"

# ... use bootstrap_caddy, log, warn, die, etc.
```

### Option C: Full pipeline via just

```bash
# On VPS, after cloning the project:
cd /path/to/project
PROJECT_SNIPPET=deploy/caddy.conf.caddy \
COMPOSE_FILE=docker-compose.yml \
TAG=$(git rev-parse --short HEAD) \
just -u /mnt/Backup/deploy-common/justfile deploy-full
```

## Canonical Caddyfile

Both projects must use `deploy-common/caddy.bootstrap/Caddyfile` as the canonical source.
Do NOT maintain a separate copy in each project — any change to Caddy bootstrap goes here.

## On the VPS

deploy-common should live at a fixed path that both projects reference:

```
/mnt/Backup/deploy-common          # on this machine
/mnt/Backup/deploy-common         # on wb-parser VPS
```

Set `DEPLOY_COMMON` env var to override the default path, or pass the path
explicitly when importing justfiles.
