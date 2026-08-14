#!/usr/bin/env bash
# ==============================================================================
# Idempotent bootstrap of the global Caddy infrastructure on the VPS.
# Creates the shared Docker network, directory structure, and starts caddy_global.
#
# Usage (source from deploy.sh):
#   source /opt/deploy-common/scripts/caddy-bootstrap.sh
#   bootstrap_caddy
#
# Or call directly:
#   bash /opt/deploy-common/scripts/caddy-bootstrap.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_COMMON="$(cd "$SCRIPT_DIR/.." && pwd)"
CADDY_BASE="${CADDY_BASE:-/opt/caddy}"
CADDY_COMPOSE="$CADDY_BASE/docker-compose.caddy.yml"
CONF_D="$CADDY_BASE/conf.d"

source "$DEPLOY_COMMON/lib/shared-functions.sh"

# =============================================================================
# BOOTSTRAP
# =============================================================================

bootstrap_caddy() {
    log "Checking global Caddy infrastructure..."

    # ---- Network ------------------------------------------------------------
    if ! docker network inspect caddy_net &>/dev/null; then
        log "Creating shared caddy_net..."
        docker network create --driver bridge caddy_net
    else
        log "caddy_net already exists"
    fi

    # ---- Directory structure ------------------------------------------------
    mkdir -p "$CONF_D" "$CADDY_BASE/data" "$CADDY_BASE/config"

    # ---- Base Caddyfile (only if missing) ----------------------------------
    if [ ! -f "$CADDY_BASE/Caddyfile" ]; then
        log "Initialising base Caddyfile..."
        cp "$DEPLOY_COMMON/caddy.bootstrap/Caddyfile" "$CADDY_BASE/Caddyfile"
    fi

    # ---- Docker compose manifest for Caddy (only if missing) ---------------
    if [ ! -f "$CADDY_COMPOSE" ]; then
        log "Creating $CADDY_COMPOSE..."
        cat > "$CADDY_COMPOSE" << 'EOF'
services:
  caddy:
    image: caddy:2-alpine
    container_name: caddy_global
    restart: always
    networks:
      - caddy_net
    ports:
      - "80:80"
      - "443:443"
      - "127.0.0.1:2019:2019"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./conf.d:/etc/caddy/conf.d:ro
      - ./data:/data
      - ./config:/config
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]

networks:
  caddy_net:
    external: true
    name: caddy_net
EOF
    fi

    # ---- Container lifecycle -------------------------------------------------
    if docker ps -a --format '{{.Names}}' | grep -qFx caddy_global; then
        local state
        state=$(docker inspect -f '{{.State.Running}}' caddy_global 2>/dev/null || echo "missing")
        if [ "$state" = "true" ]; then
            log "caddy_global already running"
        else
            warn "caddy_global exists but is not running — starting..."
            docker start caddy_global
        fi
    else
        log "Starting caddy_global..."
        (cd "$CADDY_BASE" && docker compose up -d)
    fi

    # ---- Validate -----------------------------------------------------------
    local retries=10
    while [ $retries -gt 0 ]; do
        if docker exec caddy_global caddy validate --config /etc/caddy/Caddyfile &>/dev/null; then
            log "Caddy config valid"
            return 0
        fi
        retries=$((retries - 1))
        sleep 1
    done
    die "Caddy failed to initialise after 10 retries"
}

# Run directly if called as main script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    bootstrap_caddy
fi
