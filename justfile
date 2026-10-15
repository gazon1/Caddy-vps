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
# Required in the environment:
#   WBPARSER_DB_PASSWORD       postgres password for the crawler database
#   WBPARSER_ADMIN_PASSWORD    password for the admin API; the app ships an empty
#                              default, and an empty one leaves /api/admin/**
#                              reachable with a credential nobody chose
# Optional:
#   WBPARSER_ADMIN_API_KEY     the X-Api-Key for admin endpoints (also used for
#                              adsbrowser: the AdsPower Local API key)
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
# Install Xvfb, adspower-browser CLI, start the virtual display, and verify
# that AdsPower launches a browser in headless mode.
#
# Prerequisites:
#   The AdsPower Local API must already be running at localhost:50325.
#   On the VPS that means the kotlin-try adspower container is up:
#     cd /opt/kotlin-try && docker compose -f docker-compose.prod.yml up -d adspower
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
[doc("Install adsbrowser CLI, start Xvfb, verify headless browser launch")]
adsbrowser-deploy *args:
    #!/usr/bin/env bash
    ansible-playbook "{{ REPO }}/playbooks/wbparser.yml" --tags adsbrowser {{ args }}

# ---- ADSBROWSER CLEANUP ----
# Remove adsbrowser from the VPS: stop Xvfb, disable service, uninstall CLI, purge config.
# Does NOT remove the kotlin-try adspower container.
#
#   just adsbrowser-cleanup
#   just adsbrowser-cleanup --check  # dry-run first
[doc("Stop Xvfb, uninstall adspower-browser, purge adsbrowser config")]
adsbrowser-cleanup *args:
    #!/usr/bin/env bash
    ansible-playbook "{{ REPO }}/playbooks/adsbrowser-cleanup.yml" {{ args }}

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