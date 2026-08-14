# ==============================================================================
# 🐳 DOCKER COMPOSE HELPERS
# Shared docker-compose operations used in CI/CD pipelines.
# ==============================================================================

DEPLOY_COMMON := justfile_directory() / ".just" / ".." / ".just" / ".."

[doc("Prune unused Docker assets (containers, networks, dangling images)")]
docker-prune:
    docker system prune -f

[doc("Prune all unused images older than 7 days")]
docker-prune-old-images:
    docker image prune -a -f --filter "until=168h"

[doc("Full disk cleanup: prune containers + dangling images + old images")]
docker-clean: docker-prune docker-prune-old-images
    @echo "✨ Cleanup complete. Disk usage:"
    df -h / | tail -n 1

[doc("Validate docker-compose.yml syntax (accepts COMPOSE_FILE env var)")]
docker-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
    docker compose -f "$COMPOSE_FILE" config --quiet && echo "✅ $COMPOSE_FILE is valid"
