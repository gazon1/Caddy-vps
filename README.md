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

## Setup (submodule)

Both consuming projects add this as a git submodule:

```bash
# dacha
git submodule add <url> lib/deploy-common

# wb-parser
git submodule add <url> lib/deploy-common
```

On the VPS, after cloning a project:
```bash
git clone <project-repo>
git submodule update --init --recursive
```

## Usage

### Dacha (just-native)

```just
# justfile:
DEPLOY_COMMON := justfile_directory() / "lib" / "deploy-common"
# ... import or call deploy-common recipes directly
```

### wb-parser (bash deploy.sh)

```bash
DEPLOY_COMMON="${DEPLOY_COMMON:-$PROJECT_DIR/lib/deploy-common}"
source "$DEPLOY_COMMON/lib/shared-functions.sh"
source "$DEPLOY_COMMON/scripts/caddy-bootstrap.sh"
```

### Direct from deploy-common justfile (e.g. on VPS)

```bash
DEPLOY_COMMON=/path/to/deploy-common \
SMOKE_URL=https://example.com \
just -u /path/to/deploy-common/justfile deploy-full
```

## Canonical Caddyfile

Both projects must use `deploy-common/caddy.bootstrap/Caddyfile` as the canonical source.
Do NOT maintain a separate copy in each project — any change to Caddy bootstrap goes here.

## Pushing updates

When deploy-common changes, commit and push in deploy-common, then update each consuming project:

```bash
# In deploy-common
git push

# In each consuming project
cd lib/deploy-common && git pull origin master && cd ../..
git add lib/deploy-common
git commit -m "chore: update deploy-common"
git push
```
