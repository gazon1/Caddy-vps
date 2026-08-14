#!/usr/bin/env bash
# ==============================================================================
# Validate and reload Caddy after route changes.
#
# Usage:
#   source /opt/deploy-common/scripts/caddy-reload.sh
#   caddy_validate_and_reload
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_COMMON="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$DEPLOY_COMMON/lib/shared-functions.sh"

caddy_validate_and_reload() {
    if ! caddy_validate; then
        die "Caddy config validation failed"
    fi
    caddy_reload
}
