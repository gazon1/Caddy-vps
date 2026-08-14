# ==============================================================================
# 🌐 CADDY INFRASTRUCTURE
# Idempotent setup and reload of the global Caddy reverse proxy.
# ==============================================================================

# Canonical Caddy bootstrap config (checked into deploy-common)
CADDY_BOOTSTRAP := DEPLOY_COMMON + "/caddy.bootstrap/Caddyfile"

# ---- CADDY BOOTSTRAP -------------------------------------------------------

[doc("Idempotent initialization of global Caddy infrastructure")]
caddy-bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ DEPLOY_COMMON }}/scripts/caddy-bootstrap.sh
    bootstrap_caddy

[doc("Validate current Caddy config without reloading")]
caddy-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ DEPLOY_COMMON }}/lib/shared-functions.sh
    if ! docker exec caddy_global caddy validate --config /etc/caddy/Caddyfile 2>&1; then
        warn "Caddy config is invalid"
        exit 1
    fi
    log "Caddy config is valid"

[doc("Validate and reload Caddy routes (after writing a new route snippet)")]
caddy-reload:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ DEPLOY_COMMON }}/lib/shared-functions.sh
    source {{ DEPLOY_COMMON }}/scripts/caddy-reload.sh
    caddy_validate_and_reload

[doc("List registered Caddy routes")]
caddy-routes:
    docker exec caddy_global caddy list 2>/dev/null | head -30 || echo "(caddy_global not running)"
