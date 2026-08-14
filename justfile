# ==============================================================================
# 🛠️  DEPLOY-COMMON — shared CI/CD library
# ==============================================================================
set dotenv-load := true
set shell := ["bash", "-euo", "pipefail", "-c"]
set export
set positional-arguments
set quiet

# ---- HELP ----
[doc("Show all available commands")]
default:
    @just --list --list-heading $'🛠️  Available Commands:\n' --list-prefix '  • '


# ---- GLOBAL CONSTANTS ----
DEPLOY_COMMON := justfile_directory()
CADDY_BASE := env("CADDY_BASE", "/opt/caddy")
CONF_D := CADDY_BASE + "/conf.d"
BACKUP_TTL := "5"

# ---- IMPORTS ----
import '.just/caddy.just'
import '.just/docker-compose.just'
import '.just/deploy.just'
