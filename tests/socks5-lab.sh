#!/usr/bin/env bash
# ==============================================================================
# Local lab suite for the socks5 role — proves the endpoint works without
# touching the VPS.
#
#   just socks5-lab-test
#
# What it proves:
#   T1  — the lab container is up and the machine's address is known
#   T2  — the preflight refuses an endpoint with no allowed client address
#   T3  — the preflight refuses an endpoint with no password
#   T4  — the role installs the proxy and writes a configuration that names
#         the allowed address, asks for a password, and carries BOTH rule sets
#   T5  — the password is hashed in the user's database and is not in the file
#   T6  — the endpoint answers a client with the right credentials
#   T7  — the endpoint refuses a client with a wrong password
#   T8  — the endpoint refuses a client that is not in the allowed list
#   T9  — a second run changes nothing (idempotent)
#
# The endpoint runs inside a Debian container and the playbook runs INSIDE it
# (the `docker` connection), so the role installs real packages and writes real
# /etc files without touching the machine it is developed on.
#
# What the lab cannot prove: that the endpoint gives a DIFFERENT address than
# the machine it runs on. On one machine the proxy's exit address IS the
# machine's address. That property belongs to the deployment, not to the
# software: it is proven by the crawler's probe, which asks the network what
# address the world sees (see the application repository's ADR
# 2026-10-27-the-measurement-does-not-authorize-a-second-address).
#
# Requirements:
#   • docker
#   • ansible with community.docker
#   • debian:bookworm-slim
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

LAB_CONTAINER="socks5_lab"
LAB_DENIED_CONTAINER="socks5_lab_denied"
LAB_IMAGE="debian:bookworm-slim"
LAB_PORT=11080
LAB_PASSWORD="lab-proxy-password"
LAB_USERNAME="egress"
LAB_PROBE="$REPO_ROOT/roles/socks5/files/socks5_probe.py"
INVENTORY="$REPO_ROOT/inventory/socks5-lab.yml"

FAILURES=0
STEP=0

step() {
    STEP=$((STEP + 1))
    printf '\n\033[1;34m▸ T%d %s\033[0m\n' "$STEP" "$1"
}
pass() { printf '\033[0;32m  ✅ %s\033[0m\n' "$1"; }
fail() {
    printf '\033[0;31m  ❌ %s\033[0m\n' "$1"
    FAILURES=$((FAILURES + 1))
}
info() { printf '\033[0;36m  → %s\033[0m\n' "$1"; }

teardown() {
    docker rm -f "$LAB_CONTAINER" "$LAB_DENIED_CONTAINER" >/dev/null 2>&1 || true
}
trap teardown EXIT

# The gateway of the docker bridge is the machine as seen from inside the
# container: it is the address the host connects from, and therefore the one
# the endpoint's allowed list has to name.
bridge_gateway() {
    docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}'
}

run_playbook() {
    ansible-playbook -i "$INVENTORY" "$REPO_ROOT/playbooks/socks5.yml" "$@"
}

# ── The container ────────────────────────────────────────────────────────────
step "prepare the lab container"
if ! docker image inspect "$LAB_IMAGE" >/dev/null 2>&1; then
    docker pull "$LAB_IMAGE" >/dev/null
fi
docker rm -f "$LAB_CONTAINER" "$LAB_DENIED_CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$LAB_CONTAINER" -p "$LAB_PORT:1080" "$LAB_IMAGE" sleep infinity >/dev/null
docker run -d --name "$LAB_DENIED_CONTAINER" "$LAB_IMAGE" sleep infinity >/dev/null
info "the container is up; the port $LAB_PORT is published"

# Ansible's control code runs on the target, so python3 has to be there before
# the playbook can connect. The ROLE also installs python3 — the probe speaks
# SOCKS5 in python — but the connection needs it first.
info "installing python3 in the container (Ansible runs inside it)"
docker exec "$LAB_CONTAINER" bash -c 'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq python3 >/dev/null 2>&1'
docker exec "$LAB_DENIED_CONTAINER" bash -c 'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq python3 >/dev/null 2>&1'

GATEWAY="$(bridge_gateway)"
info "the machine is $GATEWAY as seen from the container"
CIDR="${GATEWAY}/32"

# ── T1 ───────────────────────────────────────────────────────────────────────
step "the preflight refuses an endpoint with no allowed client address"
if run_playbook -e "socks5_client_cidrs=[]" >/tmp/socks5-lab-t1.log 2>&1; then
    fail "the playbook succeeded with an empty allowed list — it should have stopped"
else
    if grep -q "at least one allowed client" /tmp/socks5-lab-t1.log; then
        pass "the playbook stopped and said what was missing"
    else
        fail "the playbook failed, but not for the reason it should have"
        tail -20 /tmp/socks5-lab-t1.log
    fi
fi

# ── T2 ───────────────────────────────────────────────────────────────────────
step "the preflight refuses an endpoint with no password"
if SOCKS5_PASSWORD="" run_playbook -e "socks5_password=" >/tmp/socks5-lab-t2.log 2>&1; then
    fail "the playbook succeeded without a password — it should have stopped"
else
    if grep -q "needs a password" /tmp/socks5-lab-t2.log; then
        pass "the playbook stopped and said what was missing"
    else
        fail "the playbook failed, but not for the reason it should have"
        tail -20 /tmp/socks5-lab-t2.log
    fi
fi

# ── T3 ───────────────────────────────────────────────────────────────────────
step "the role installs the endpoint and writes a usable configuration"
if run_playbook -e "socks5_client_cidrs=[\"${CIDR}\"]" >/tmp/socks5-lab-t3.log 2>&1; then
    CONFIG="$(docker exec "$LAB_CONTAINER" cat /etc/danted.conf 2>/dev/null || true)"
    missing=""
    for needle in \
        "socksmethod: username" \
        "internal: 0.0.0.0 port = 1080" \
        "from: ${CIDR} to: 0.0.0.0/0" \
        "client pass {" \
        "socks pass {"; do
        if ! grep -qF "$needle" <<<"$CONFIG"; then
            missing="$missing\n    - $needle"
        fi
    done
    if [[ -z "$missing" ]]; then
        pass "the configuration names the allowed address, asks for a password, and carries both rule sets"
    else
        fail "the configuration is missing:${missing}"
        printf '%s\n' "$CONFIG"
    fi
else
    fail "the playbook failed"
    tail -40 /tmp/socks5-lab-t3.log
fi

# ── T4 ───────────────────────────────────────────────────────────────────────
step "the password is hashed in the user's database and absent from the config"
CONFIG="$(docker exec "$LAB_CONTAINER" cat /etc/danted.conf 2>/dev/null || true)"
SHADOW="$(docker exec "$LAB_CONTAINER" getent shadow egress 2>/dev/null || true)"
if grep -qF "$LAB_PASSWORD" <<<"$CONFIG"; then
    fail "the password is in the configuration file"
elif grep -qF "$LAB_PASSWORD" <<<"$SHADOW"; then
    # The user module hashes the password ON THE CONTROL NODE, and a control
    # node whose python has no `crypt` stores it AS IT IS. The failure is
    # silent: the task succeeds, and the secret ends up in a file every
    # account on the host can read.
    fail "the password is stored in cleartext in the user's database"
elif [[ "$SHADOW" != *'$'* ]]; then
    fail "the user's database holds no password hash at all"
else
    pass "the password is hashed in the user's database, and the configuration carries none"
fi

# ── T5 ───────────────────────────────────────────────────────────────────────
step "the endpoint answers a client with the right credentials"
if SOCKS5_PROBE_PASSWORD="$LAB_PASSWORD" python3 "$LAB_PROBE" \
    --host 127.0.0.1 --port "$LAB_PORT" --username "$LAB_USERNAME" \
    --target-host 1.1.1.1 --target-port 80 >/tmp/socks5-lab-t5.log 2>&1; then
    pass "the endpoint authenticated the client and connected to the target"
    info "$(cat /tmp/socks5-lab-t5.log)"
else
    fail "the endpoint did not answer: $(cat /tmp/socks5-lab-t5.log)"
fi

# ── T6 ───────────────────────────────────────────────────────────────────────
step "the endpoint refuses a client with a wrong password"
if SOCKS5_PROBE_PASSWORD="wrong-password-on-purpose" python3 "$LAB_PROBE" \
    --host 127.0.0.1 --port "$LAB_PORT" --username "$LAB_USERNAME" \
    --target-host 1.1.1.1 --target-port 80 >/tmp/socks5-lab-t6.log 2>&1; then
    fail "the endpoint accepted a wrong password — it is not authenticated"
else
    pass "the endpoint refused the wrong password"
    info "$(cat /tmp/socks5-lab-t6.log)"
fi

# ── T7 ───────────────────────────────────────────────────────────────────────
step "the endpoint refuses a client that is not in the allowed list"
docker cp "$LAB_PROBE" "$LAB_DENIED_CONTAINER:/tmp/socks5_probe.py" >/dev/null
CONTAINER_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$LAB_CONTAINER")"
if docker exec -e SOCKS5_PROBE_PASSWORD="$LAB_PASSWORD" "$LAB_DENIED_CONTAINER" \
    python3 /tmp/socks5_probe.py --host "$CONTAINER_IP" --port 1080 \
    --username "$LAB_USERNAME" --target-host 1.1.1.1 --target-port 80 \
    >/tmp/socks5-lab-t7.log 2>&1; then
    fail "a client outside the allowed list was served — the endpoint is open"
else
    pass "the client outside the allowed list was refused"
    info "$(cat /tmp/socks5-lab-t7.log)"
fi

# ── T8 ───────────────────────────────────────────────────────────────────────
step "a second run changes nothing"
run_playbook -e "socks5_client_cidrs=[\"${CIDR}\"]" >/tmp/socks5-lab-t8.log 2>&1 || true
CHANGED="$(grep -cE '^changed: [1-9]' /tmp/socks5-lab-t8.log || true)"
if [[ "$CHANGED" == "0" ]]; then
    pass "the second run changed nothing"
else
    fail "the second run reported $CHANGED changed task(s)"
    grep -E '^changed: [1-9]' /tmp/socks5-lab-t8.log | head
fi

# ── Verdict ──────────────────────────────────────────────────────────────────
printf '\n'
if [[ $FAILURES -eq 0 ]]; then
    printf '\033[1;32m✅ the socks5 role works: %d checks passed\033[0m\n' "$STEP"
    exit 0
fi
printf '\033[1;31m❌ %d of %d checks failed\033[0m\n' "$FAILURES" "$STEP"
exit 1
