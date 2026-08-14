# ==============================================================================
# 🚀 PRODUCTION DEPLOY PIPELINE
# Shared deploy steps that both dacha and wb-parser use.
# Each project wires these into their own justfile or deploy.sh as needed.
# ==============================================================================

[doc("Deploy step 1: git pull")]
deploy-git-pull:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -d .git ]; then
        echo "📦 Pulling latest from main..."
        git pull origin main
    else
        echo "[warn] Not a git repository — skipping git pull"
    fi

[doc("Deploy step 2: idempotent Caddy bootstrap")]
deploy-caddy-bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ DEPLOY_COMMON }}/scripts/caddy-bootstrap.sh
    bootstrap_caddy

# Usage: PROJECT_SNIPPET=<path> just deploy-caddy-config
# PROJECT_SNIPPET defaults to deploy/caddy.conf.caddy in project root
[doc("Deploy step 3: write project Caddy route snippet and validate")]
deploy-caddy-config:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ DEPLOY_COMMON }}/lib/shared-functions.sh

    SNIPPET_SOURCE="${PROJECT_SNIPPET:-deploy/caddy.conf.caddy}"
    SNIPPET_NAME="${PROJECT_CADDY_SNIPPET:-$(basename "$SNIPPET_SOURCE" .caddy)}"
    SNIPPET_TARGET="{{ CONF_D }}/${SNIPPET_NAME}.caddy"
    BACKUP="${SNIPPET_TARGET}.bak.$(date +%Y%m%d-%H%M%S)"

    if [ ! -f "$SNIPPET_SOURCE" ]; then
        die "Caddy snippet source not found: $SNIPPET_SOURCE"
    fi

    if [ -f "$SNIPPET_TARGET" ]; then
        cp "$SNIPPET_TARGET" "$BACKUP"
        log "Backed up previous $SNIPPET_NAME → $(basename "$BACKUP")"
    fi

    cp "$SNIPPET_SOURCE" "$SNIPPET_TARGET"
    log "Written $SNIPPET_TARGET"

    log "Validating Caddy config..."
    if ! docker exec caddy_global caddy validate --config /etc/caddy/Caddyfile; then
        [ -f "$BACKUP" ] && mv "$BACKUP" "$SNIPPET_TARGET"
        die "Caddy config validation failed — backup restored"
    fi

    # Rotate old backups (keep BACKUP_TTL most recent)
    BACKUP_COUNT=$(ls -1t "{{ CONF_D }}/${SNIPPET_NAME}.caddy".bak.* 2>/dev/null | wc -l)
    if [ "$BACKUP_COUNT" -gt "{{ BACKUP_TTL }}" ]; then
        KEEP_PLUS_ONE=$(({{ BACKUP_TTL }} + 1))
        ls -1t "{{ CONF_D }}/${SNIPPET_NAME}.caddy".bak.* | tail -n +"$KEEP_PLUS_ONE" | xargs -r rm --
        log "Rotated old backups (kept {{ BACKUP_TTL }})"
    fi

[doc("Deploy step 4: rebuild and restart project containers (accepts COMPOSE_FILE, TAG)")]
deploy-compose-up:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ DEPLOY_COMMON }}/lib/shared-functions.sh

    COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
    TAG="${TAG:-latest}"
    log "🔨 Deploying containers from $COMPOSE_FILE (tag=$TAG)..."

    docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
    TAG="$TAG" docker compose -f "$COMPOSE_FILE" up -d

    log "⏳ Waiting for app healthchecks..."
    docker compose -f "$COMPOSE_FILE" wait || warn "Compose wait finished (verify app logs if failed)"

[doc("Deploy step 5: reload Caddy routes with zero downtime")]
deploy-caddy-reload:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ DEPLOY_COMMON }}/lib/shared-functions.sh
    source {{ DEPLOY_COMMON }}/scripts/caddy-reload.sh
    caddy_validate_and_reload

# Usage: SMOKE_URL=https://example.com just deploy-smoke-test
[doc("Deploy step 6: verify endpoint connectivity")]
deploy-smoke-test:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ DEPLOY_COMMON }}/lib/shared-functions.sh

    URL="${SMOKE_URL:-http://localhost}"
    log "🚦 Smoke testing $URL..."

    if curl -fsSI --max-time 10 "$URL" > /dev/null 2>&1; then
        log "✅ $URL is reachable"
    else
        warn "⚠️  $URL not reachable (may need warm-up)"
    fi

[doc("Deploy step 7: free disk space after deploy")]
deploy-clean:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ DEPLOY_COMMON }}/lib/shared-functions.sh

    log "🧹 Removing stopped containers and dangling build cache..."
    docker system prune -f

    log "🗑️  Removing unused images older than 7 days..."
    docker image prune -a -f --filter "until=168h"

    log "✨ Cleanup complete. $(disk_usage)"

# Usage: PROJECT_SNIPPET=<path> COMPOSE_FILE=<file> TAG=<tag> just deploy-full
[doc("Full deploy pipeline: bootstrap → git-pull → caddy-config → compose-up → caddy-reload → smoke-test → clean")]
deploy-full: deploy-git-pull deploy-caddy-bootstrap deploy-caddy-config deploy-compose-up deploy-caddy-reload deploy-smoke-test deploy-clean
    @echo "✅ Deploy pipeline completed successfully."
