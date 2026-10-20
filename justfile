# ==============================================================================
# 🛠️  GLOBAL CADDY — thin wrappers around Ansible
# ==============================================================================
# This repository provisions ONE Caddy reverse proxy shared by every project on
# the VPS. `just` only exists so the everyday commands have short names; the
# real entry point is site.yml.
#
#   just              — this list
#   just bootstrap    — install / repair the proxy on the target host
#   just route N F    — apply one route snippet (with backup + rollback)
#   just status       — read-only inspection
#   just cert-check   — read-only: fail if a certificate is close to expiry
#   just lab-test     — prove the above locally, without touching the VPS
#
# Anything the wrappers do not cover is passed straight through to
# ansible-playbook, e.g.
#
#   just bootstrap -e caddy_http_port=8080
#   just bootstrap -i inventory/lab.yml
# ==============================================================================
set shell := ["bash", "-euo", "pipefail", "-c"]

REPO := justfile_directory()
INVENTORY := REPO / "inventory" / "hosts.yml"
SITE := REPO / "site.yml"
STATUS := REPO / "playbooks" / "status.yml"
CERT_CHECK := REPO / "playbooks" / "cert-check.yml"
LAB := REPO / "tests" / "lab.sh"

export PATH := home_directory() / ".local" / "bin" + ":" + env("PATH")

# ---- HELP ----
[doc("Show all available commands")]
default:
    @just --list --list-heading $'🛠️  Available Commands:\n' --list-prefix '  • '

# NOTE: no `-i` here on purpose. Ansible MERGES every -i it is given rather than
# letting the last one win, so hardcoding an inventory would silently pull the
# production hosts in even when you pass your own. The default comes from
# `inventory = inventory/hosts.yml` in ansible.cfg, and `just bootstrap -i …`
# replaces it cleanly.

# ---- PROVISION ----
[doc("Install or repair the global Caddy proxy (idempotent)")]
bootstrap *args:
    #!/usr/bin/env bash
    ansible-playbook "{{ SITE }}" {{ args }}

# ---- ROUTES ----
[doc("Apply a route snippet: just route <name> <file>")]
route name file *args:
    #!/usr/bin/env bash
    ansible-playbook "{{ SITE }}" \
        --tags caddy_routes \
        -e "caddy_route_name={{ name }}" \
        -e "caddy_route_src={{ file }}" \
        {{ args }}

# ---- STATUS ----
[doc("Read-only inspection: container, config validity, routes, modules")]
status *args:
    #!/usr/bin/env bash
    ansible-playbook "{{ STATUS }}" {{ args }}

# ---- CERTIFICATES ----
# Monitoring only. Caddy renews certificates on its own and this deliberately
# does not force a reissue — repeating an already-scheduled issuance burns the
# Let's Encrypt rate limit. What it catches is a renewal that has silently
# stopped working, which is otherwise invisible until browsers reject the site.
[doc("Fail if a certificate is within 21 days of expiry (read-only)")]
cert-check *args:
    #!/usr/bin/env bash
    ansible-playbook "{{ CERT_CHECK }}" {{ args }}

# ---- WB-PARSER DEPLOY ----
# The crawler runs as an image pulled from a registry, never built here: the VPS
# has no outbound network, so it can neither clone the repository nor resolve
# Gradle dependencies. `just deploy` in the application repository builds the
# image, pushes it, and calls this with the tag.
#
# TWO images are deployed, both by digest, from the same tag: the crawler
# (ghcr.io/gazon1/wb-parser) and the AdsPower browser runtime it drives
# (ghcr.io/gazon1/wb-parser-adspower). The browser runtime is a container
# beside the crawler, sharing its network namespace, so the AdsPower Local API
# is reachable at 127.0.0.1:50325 inside it and nothing is published on the
# host.
#
# Required in the environment:
#   WBPARSER_DB_PASSWORD       postgres password for the crawler database
#   WBPARSER_ADMIN_PASSWORD    password for the admin API; the app ships an empty
#                              default, and an empty one leaves /api/admin/**
#                              reachable with a credential nobody chose
#   WBPARSER_ADMIN_API_KEY     the AdsPower Local API key: the browser runtime
#                              starts the API with it and the crawler
#                              authenticates against it with it. The role
#                              refuses to deploy without it.
# Optional:
#   WBPARSER_GHCR_USER         registry user, if the package is private
#   WBPARSER_GHCR_TOKEN        registry token, if the package is private
#   WBPARSER_COMPOSE_SRC       path to deploy/docker-compose.vps.yml in the app
#                              checkout; `just deploy` passes this directly
#
#   just wbparser-deploy -e wbparser_tag=<sha>           # full stack
#   just wbparser-deploy -e wbparser_tag=<sha> --tags wbparser   # parser only
#   just wbparser-deploy -e wbparser_hostname=""         # remove the route
[doc("Pull, start, health-gate and roll back the wb-parser container")]
wbparser-deploy *args:
    #!/usr/bin/env bash
    ansible-playbook "{{ REPO }}/playbooks/wbparser.yml" {{ args }}

# ---- ADSBROWSER DEPLOY ----
# Deploys the full adsbrowser stack onto the VPS:
#   1. adsbrowser_api  — AdsPower Local API as native systemd (port 50325)
#   2. adsbrowser     — Xvfb + headless browser verification
#
# Required:
#   adsbrowser_api_key   AdsPower Local API key (same as WBPARSER_ADMIN_API_KEY)
#   WBPARSER_ADMIN_API_KEY is auto-resolved if adsbrowser_api_key is not set.
#
# Optional:
#   adsbrowser_test_profile_id   pre-created profile ID for the headless launch test
#
#   just adsbrowser-deploy -e adsbrowser_api_key=<key>
#   just adsbrowser-deploy -e adsbrowser_api_key=<key> -e adsbrowser_test_profile_id=kxpu63n
[doc("Deploy adsbrowser-api (systemd) and adsbrowser (Xvfb) to the VPS")]
adsbrowser-deploy *args:
    #!/usr/bin/env bash
    ansible-playbook "{{ REPO }}/playbooks/wbparser.yml" --tags adsbrowser-api,adsbrowser {{ args }}

# ---- ADSBROWSER CLEANUP ----
# Remove adsbrowser-api and adsbrowser from the VPS.
# Does NOT touch the wbparser container or Caddy.
#
#   just adsbrowser-cleanup
#   just adsbrowser-cleanup --check  # dry-run first
[doc("Stop and remove adsbrowser-api and adsbrowser from the VPS")]
adsbrowser-cleanup *args:
    #!/usr/bin/env bash
    ansible-playbook "{{ REPO }}/playbooks/adsbrowser-cleanup.yml" {{ args }}

# ---- ADSBROWSER UPDATE ----
# Update the adspower-browser CLI version.
# Steps:
#   1. Download the new version from npm
#   2. Compute sha256
#   3. Open roles/adsbrowser_api/defaults/main.yml for editing
#
# Usage:
#   just adsbrowser-update [version]   # default: latest
#   just adsbrowser-update 2.2.0
[doc("Update adspower-browser version: download, sha256, open defaults")]
adsbrowser-update version="":
    #!/usr/bin/env bash
    set -euo pipefail

    V="{{ version }}"
    if [ -z "$V" ]; then
        V=$(npm show adspower-browser version)
        echo "[adsbrowser-update] Latest version: $V"
    fi

    echo "[adsbrowser-update] Downloading adspower-browser@$V ..."
    TMP=$(mktemp -d)
    npm pack "adspower-browser@$V" --pack-destination "$TMP" > /dev/null

    PKG=$(ls "$TMP"/adspower-browser-*.tgz)
    SHA=$(sha256sum "$PKG" | awk '{print $1}')
    echo "[adsbrowser-update] sha256: $SHA"

    cp "$PKG" "{{ REPO }}/roles/adsbrowser/files/adspower-browser-${V}.tgz"
    echo "[adsbrowser-update] Copied to roles/adsbrowser/files/"

    rm -rf "$TMP"

    echo ""
    echo "[adsbrowser-update] Update these values in:"
    echo "  roles/adsbrowser/defaults/main.yml"
    echo "    adsbrowser_cli_version: \"$V\""
    echo "    adsbrowser_tarball_sha256: \"$SHA\""
    echo ""
    echo "  roles/adsbrowser-api/defaults/main.yml"
    echo "    adsbrowser_api_version: \"$V\""
    echo "    adsbrowser_api_tarball_sha256: \"$SHA\""
    echo ""
    echo "[adsbrowser-update] Old files can be removed; Ansible uses the version from defaults."
    $EDITOR "{{ REPO }}/roles/adsbrowser/defaults/main.yml"

# ---- LOCAL VERIFICATION ----
[doc("Run the local lab suite against Docker (does not touch the VPS)")]
lab-test:
    #!/usr/bin/env bash
    bash "{{ LAB }}"

# ---- WBSHOP DEPLOY ----
# Deploy the full wbshop stack: adsbrowser → wbparser → Flyway → wbshop → Caddy route.
#
# Required in the environment:
#   WBPARSER_DB_PASSWORD       postgres password for the crawler database
#   WBPARSER_ADMIN_PASSWORD    password for the admin API
#   WBPARSER_ADMIN_API_KEY     the X-Api-Key for admin endpoints
#   WBPARSER_COMPOSE_SRC       path to deploy/docker-compose.vps.yml in the parser checkout
#   WBSHOP_COMPOSE_SRC         path to docker-compose.yml in the wbshop checkout
#
# Usage:
#   just wbshop-deploy -e wbparser_tag=<sha> -e wbshop_tag=<sha>
#   just wbshop-deploy -e wbparser_tag=<sha> -e wbshop_tag=<sha> --tags flyway  # flyway only
#   just wbshop-deploy -e wbparser_tag=<sha> -e wbshop_tag=<sha> --tags wbshop  # wbshop only
[doc("Deploy full wbshop stack: parser + migrations + wbshop + route")]
wbshop-deploy *args:
    #!/usr/bin/env bash
    ansible-playbook "{{ REPO }}/playbooks/wbshop.yml" {{ args }}