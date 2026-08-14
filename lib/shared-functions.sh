#!/usr/bin/env bash
# ==============================================================================
# Shared shell functions for deploy scripts across all projects.
# Source this file in any bash deploy script:
#   source /path/to/deploy-common/lib/shared-functions.sh
# ==============================================================================

set -euo pipefail

# ---- Colours ----------------------------------------------------------------
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

# ---- Logging helpers --------------------------------------------------------
log()  { echo -e "${GREEN}[deploy]${NC} $*"; }
info() { echo -e "${BLUE}[info]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*" >&2; }
die()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ---- Environment validation -------------------------------------------------
require_env() {
    local var="$1"
    local desc="${2:-}"
    if [ -z "${!var:-}" ]; then
        if [ -n "$desc" ]; then
            die "Required env var $var ($desc) is not set"
        else
            die "Required env var $var is not set"
        fi
    fi
}

require_file() {
    local file="$1"
    local desc="${2:-}"
    if [ ! -f "$file" ]; then
        if [ -n "$desc" ]; then
            die "Required file $file ($desc) does not exist"
        else
            die "Required file $file does not exist"
        fi
    fi
}

# ---- Docker helpers ---------------------------------------------------------
wait_for_healthy() {
    local container="$1"
    local retries="${2:-30}"
    local interval="${3:-5}"
    local service_name="${4:-$container}"

    while [ $retries -gt 0 ]; do
        if docker exec "$container" curl -sf http://localhost/health &>/dev/null; then
            log "$service_name is healthy"
            return 0
        fi
        retries=$((retries - 1))
        sleep "$interval"
    done
    warn "$service_name healthcheck timed out after $((retries * interval))s"
    return 1
}

# ---- Caddy helpers ----------------------------------------------------------
caddy_validate() {
    local cfg="${1:-/etc/caddy/Caddyfile}"
    if ! docker exec caddy_global caddy validate --config "$cfg" &>/dev/null; then
        docker exec caddy_global caddy validate --config "$cfg" || true
        return 1
    fi
    return 0
}

caddy_reload() {
    log "Reloading Caddy config..."
    if ! docker exec caddy_global caddy reload --config /etc/caddy/Caddyfile; then
        die "Caddy reload failed"
    fi
}

# ---- Disk cleanup -----------------------------------------------------------
disk_usage() {
    df -h / | tail -n 1 | awk '{print $3 " used, " $4 " available"}'
}

# ---- Retry loop -------------------------------------------------------------
retry() {
    local max_attempts="${1:-3}"
    local delay="${2:-5}"
    shift 2
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        if [ $attempt -lt $max_attempts ]; then
            warn "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done
    return 1
}
