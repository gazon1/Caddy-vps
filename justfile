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

# ---- LOCAL VERIFICATION ----
[doc("Run the local lab suite against Docker (does not touch the VPS)")]
lab-test:
    #!/usr/bin/env bash
    bash "{{ LAB }}"