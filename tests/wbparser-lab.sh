#!/usr/bin/env bash
# ==============================================================================
# Local lab suite for the wbparser role — proves the deploy works without touching
# the VPS.
#
#   just wbparser-lab-test
#
# What it tests:
#   T1  — preflight assertions reject a missing tag
#   T2  — preflight assertions reject a missing DB password
#   T3  — preflight assertions reject a missing admin password
#   T4  — a tag is resolved to a digest, and the digest is what .env and the
#         state file carry
#   T5  — a second run changes nothing (idempotent)
#   T6  — the legacy .deployed-tag is migrated into the digest state file
#   T7  — an image that does not come up healthy rolls back to the previous
#         digest
#   T8  — a tag that cannot be resolved fails loudly and changes nothing
#
# The images come from a throwaway registry on localhost, not from GHCR: the
# lab needs two images in the SAME repository, one that becomes healthy and one
# that never does, so that the rollback has something to roll back TO. The
# production contract — the DIGEST key in .env and its sha256:<64 hex> value —
# is exercised the same way either way.
#
# Requirements:
#   • docker   (compose v2 plugin, buildx, and a local registry image)
#   • ansible  with community.docker collection
#   • alpine:3 (or the ability to pull it) — the stub images are built on it
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_BASE="/tmp/wbparser-lab"
LAB_NETWORK="wbparser_net_lab"
LAB_REGISTRY="localhost:5000"
LAB_REGISTRY_CONTAINER="wbparser-lab-registry"
LAB_REPO="lab/wb-parser"
LAB_CONTAINER="wb-parser-lab"
LAB_COMPOSE="$LAB_BASE/docker-compose.lab.yml"
LAB_DB_PASSWORD="labtest123"
LAB_ADMIN_PASSWORD="lab-admin-secret"
LAB_ADMIN_API_KEY="lab-api-key-$(date +%s)"
LAB_TAG_GOOD="good"
LAB_TAG_BAD="bad"
LAB_TAG_MISSING="no-such-tag-$$"

export PATH="$HOME/.local/bin:$PATH"

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
    docker rm -f "$LAB_CONTAINER" "$LAB_REGISTRY_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$LAB_NETWORK" >/dev/null 2>&1 || true
    rm -rf "$LAB_BASE" >/dev/null 2>&1 || true
}
trap teardown EXIT

INVENTORY="$REPO_ROOT/inventory/lab.yml"
PLAYBOOK="$REPO_ROOT/playbooks/wbparser.yml"

# The role reads its secrets from the environment, never from -e.
export WBPARSER_DB_PASSWORD="$LAB_DB_PASSWORD"
export WBPARSER_ADMIN_PASSWORD="$LAB_ADMIN_PASSWORD"
export WBPARSER_ADMIN_API_KEY="$LAB_ADMIN_API_KEY"

# Everything the role needs to talk to the throwaway registry instead of
# GHCR. The image coordinates are the same shape as production.
LAB_ARGS=(
    --tags wbparser
    -e "wbparser_registry=$LAB_REGISTRY"
    -e "wbparser_image_owner=lab"
    -e "wbparser_image_name=wb-parser"
    -e "wbparser_compose_src=$LAB_COMPOSE"
    -e "wbparser_compose_file=$LAB_COMPOSE"
    -e "wbparser_base=$LAB_BASE"
    -e "wbparser_container_name=$LAB_CONTAINER"
    -e "wbparser_hostname="
    -e "wbparser_registry_user="
    -e "wbparser_registry_token="
    -e "wbparser_db_host=wbparser-db"
    -e "wbparser_db_port=5432"
    -e "wbparser_db_name=wbparser"
    -e "wbparser_db_user=wbparser"
    -e "wbparser_health_timeout=30"
    -e "wbparser_health_retries=3"
    -e "wbparser_health_delay=2"
    -e "wbparser_owner=$(id -un)"
    -e "wbparser_group=$(id -gn)"
)

play() {
    ansible-playbook -i "$INVENTORY" "$PLAYBOOK" "${LAB_ARGS[@]}" "$@"
}

# ==============================================================================
echo "▸ Lab values"
echo "    registry : $LAB_REGISTRY"
echo "    image    : $LAB_REGISTRY/$LAB_REPO"
echo "    base     : $LAB_BASE"
echo "    network  : $LAB_NETWORK"

teardown
mkdir -p "$LAB_BASE/img"

# The throwaway registry: two tags of ONE repository, so a rollback has an
# image of the same repository to go back to.
docker network create "$LAB_NETWORK" >/dev/null 2>&1 || true
docker run -d --name "$LAB_REGISTRY_CONTAINER" -p 5000:5000 registry:2 >/dev/null

# `good` answers HTTP on 8080 and passes the healthcheck; `bad` only sleeps, so
# it runs but never becomes healthy. Both are in the SAME repository, which is
# what lets the rollback put the previous image back.
build_stub() {
    local tag="$1" cmd="$2"
    printf '%s\n%s\n' 'FROM alpine:3' "CMD $cmd" > "$LAB_BASE/img/Dockerfile"
    docker build -q -t "$LAB_REGISTRY/$LAB_REPO:$tag" "$LAB_BASE/img" >/dev/null
    docker push -q "$LAB_REGISTRY/$LAB_REPO:$tag" >/dev/null
}

docker image inspect alpine:3 >/dev/null 2>&1 || docker pull alpine:3 >/dev/null
# The CMD is JSON in the Dockerfile: `\\r\\n` reaches the shell as `\r\n`, and
# the shell's printf turns that into the CRLF an HTTP response needs.
build_stub "$LAB_TAG_GOOD" \
    '["sh","-c","while true; do printf '"'"'HTTP/1.1 200 OK\\r\\nContent-Length: 3\\r\\nConnection: close\\r\\n\\r\\nok\\n'"'"' | nc -l -p 8080; done"]'
build_stub "$LAB_TAG_BAD" \
    '["sh","-c","sleep 3600"]'

# The compose file the role copies verbatim. It mirrors the contract of the
# application repository's compose file: the image is named by DIGEST, and
# DIGEST is required — there is no tag and no `latest` to fall back to.
cat > "$LAB_COMPOSE" <<'COMPOSE'
services:
  wb-parser:
    image: localhost:5000/${IMAGE_OWNER:-lab}/wb-parser@${DIGEST:?DIGEST must be set to a sha256 digest}
    container_name: wb-parser-lab
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 3
      start_period: 5s
    networks:
      - lab_net

networks:
  lab_net:
    name: wbparser_net_lab
    external: true
COMPOSE

digest_of() {
    docker buildx imagetools inspect "$LAB_REGISTRY/$LAB_REPO:$1" \
        --format '{{.Manifest.Digest}}' 2>/dev/null | tr -d '[:space:]'
}

GOOD_DIGEST="$(digest_of "$LAB_TAG_GOOD")"
BAD_DIGEST="$(digest_of "$LAB_TAG_BAD")"
info "good digest: $GOOD_DIGEST"
info "bad  digest: $BAD_DIGEST"

# ==============================================================================
step "T1 — missing tag is rejected by preflight"
OUT="$(mktemp)"
if play -e "wbparser_tag=" > "$OUT" 2>&1; then
    fail "the playbook succeeded even though wbparser_tag is empty"
else
    if grep -q 'wbparser_tag is empty' "$OUT"; then
        pass "the playbook rejected an empty tag"
    else
        fail "the playbook failed but not because of the empty tag"
        tail -20 "$OUT"
    fi
fi
rm -f "$OUT"

# ==============================================================================
step "T2 — missing DB password is rejected by preflight"
OUT="$(mktemp)"
if ( unset WBPARSER_DB_PASSWORD; play -e "wbparser_tag=$LAB_TAG_GOOD" ) > "$OUT" 2>&1; then
    fail "the playbook succeeded even though the DB password is empty"
else
    if grep -q 'WBPARSER_DB_PASSWORD is not set' "$OUT"; then
        pass "the playbook rejected an empty DB password"
    else
        fail "the playbook failed but not because of the empty DB password"
        tail -20 "$OUT"
    fi
fi
rm -f "$OUT"

# ==============================================================================
step "T3 — missing admin password is rejected by preflight"
OUT="$(mktemp)"
if ( unset WBPARSER_ADMIN_PASSWORD; play -e "wbparser_tag=$LAB_TAG_GOOD" ) > "$OUT" 2>&1; then
    fail "the playbook succeeded even though the admin password is empty"
else
    if grep -q 'WBPARSER_ADMIN_PASSWORD is not set' "$OUT"; then
        pass "the playbook rejected an empty admin password"
    else
        fail "the playbook failed but not because of the empty admin password"
        tail -20 "$OUT"
    fi
fi
rm -f "$OUT"

# ==============================================================================
step "T4 — the tag is resolved to a digest, and the digest is what is deployed"
OUT="$(mktemp)"
if play -e "wbparser_tag=$LAB_TAG_GOOD" > "$OUT" 2>&1; then
    ENV_DIGEST="$(grep '^DIGEST=' "$LAB_BASE/.env" | cut -d= -f2 | tr -d '[:space:]')"
    if [[ "$ENV_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        pass ".env carries a digest: $ENV_DIGEST"
    else
        fail ".env does not carry a sha256:<64 hex> digest: '$ENV_DIGEST'"
    fi
    if [[ "$ENV_DIGEST" == "$GOOD_DIGEST" ]]; then
        pass "the digest is the one the registry reports for the tag"
    else
        fail "the digest does not match the registry: '$ENV_DIGEST' != '$GOOD_DIGEST'"
    fi
    if [[ -f "$LAB_BASE/.deployed-digest" ]]; then
        DEPLOYED="$(tr -d '[:space:]' < "$LAB_BASE/.deployed-digest")"
        if [[ "$DEPLOYED" == "$GOOD_DIGEST" ]]; then
            pass "the state file holds the running digest"
        else
            fail "the state file holds '$DEPLOYED', expected '$GOOD_DIGEST'"
        fi
    else
        fail "the state file was not written"
    fi
    if [[ "$(docker inspect -f '{{.State.Health.Status}}' "$LAB_CONTAINER" 2>/dev/null)" == "healthy" ]]; then
        pass "the container is healthy"
    else
        fail "the container is not healthy"
    fi
else
    fail "the deploy failed"
    tail -30 "$OUT"
fi
rm -f "$OUT"

# ==============================================================================
step "T5 — a second run changes nothing (idempotent)"
ENV_BEFORE="$(cat "$LAB_BASE/.env")"
STATE_BEFORE="$(cat "$LAB_BASE/.deployed-digest")"
OUT="$(mktemp)"
play -e "wbparser_tag=$LAB_TAG_GOOD" > "$OUT" 2>&1 || true
if [[ "$ENV_BEFORE" == "$(cat "$LAB_BASE/.env")" \
   && "$STATE_BEFORE" == "$(cat "$LAB_BASE/.deployed-digest")" ]]; then
    pass ".env and the state file are unchanged"
else
    fail "a second run rewrote .env or the state file"
fi
if grep -qE 'failed=0' "$OUT"; then
    pass "the second run did not fail"
else
    fail "the second run failed"
    tail -20 "$OUT"
fi
rm -f "$OUT"

# ==============================================================================
step "T6 — the legacy .deployed-tag is migrated into the digest state file"
printf '%s\n' "$LAB_TAG_GOOD" > "$LAB_BASE/.deployed-tag"
rm -f "$LAB_BASE/.deployed-digest"
OUT="$(mktemp)"
if play -e "wbparser_tag=$LAB_TAG_GOOD" > "$OUT" 2>&1; then
    pass "the deploy over the legacy tag file succeeded"
    if [[ ! -f "$LAB_BASE/.deployed-tag" ]]; then
        pass "the legacy tag file was migrated away"
    else
        fail "the legacy tag file is still there"
    fi
    DEPLOYED="$(tr -d '[:space:]' < "$LAB_BASE/.deployed-digest" 2>/dev/null || true)"
    if [[ "$DEPLOYED" == "$GOOD_DIGEST" ]]; then
        pass "the state file holds the running digest"
    else
        fail "the state file holds '$DEPLOYED', expected '$GOOD_DIGEST'"
    fi
    if grep -q "Rollback target: $LAB_REGISTRY/$LAB_REPO@$GOOD_DIGEST" "$OUT"; then
        pass "the legacy tag was resolved to a digest and kept as the rollback target"
    else
        fail "the legacy tag was not kept as the rollback target"
        tail -30 "$OUT"
    fi
else
    fail "the deploy over the legacy tag file failed"
    tail -30 "$OUT"
fi
rm -f "$OUT"

# ==============================================================================
step "T7 — an image that never becomes healthy rolls back to the previous digest"
OUT="$(mktemp)"
if play -e "wbparser_tag=$LAB_TAG_BAD" > "$OUT" 2>&1; then
    fail "the deploy of an unhealthy image succeeded"
else
    if grep -q "Rolled back to $LAB_REGISTRY/$LAB_REPO@$GOOD_DIGEST" "$OUT"; then
        pass "the failure names the digest it rolled back to"
    else
        fail "the failure does not name the digest it rolled back to"
        tail -30 "$OUT"
    fi
    ENV_DIGEST="$(grep '^DIGEST=' "$LAB_BASE/.env" | cut -d= -f2 | tr -d '[:space:]')"
    if [[ "$ENV_DIGEST" == "$GOOD_DIGEST" ]]; then
        pass ".env was re-rendered with the previous digest"
    else
        fail ".env holds '$ENV_DIGEST', expected the previous digest '$GOOD_DIGEST'"
    fi
    DEPLOYED="$(tr -d '[:space:]' < "$LAB_BASE/.deployed-digest" 2>/dev/null || true)"
    if [[ "$DEPLOYED" == "$GOOD_DIGEST" ]]; then
        pass "the state file still holds the previous digest"
    else
        fail "the state file holds '$DEPLOYED', expected '$GOOD_DIGEST'"
    fi
    if [[ "$(docker inspect -f '{{.State.Health.Status}}' "$LAB_CONTAINER" 2>/dev/null)" == "healthy" ]]; then
        pass "the previous image is running and healthy again"
    else
        fail "the previous image is not running"
    fi
fi
rm -f "$OUT"

# ==============================================================================
step "T8 — a tag that cannot be resolved fails loudly and changes nothing"
OUT="$(mktemp)"
if play -e "wbparser_tag=$LAB_TAG_MISSING" > "$OUT" 2>&1; then
    fail "the deploy succeeded even though the tag does not resolve"
else
    if grep -q 'does not resolve to an image digest' "$OUT"; then
        pass "the failure says the image cannot be named"
    else
        fail "the failure does not say the image cannot be named"
        tail -30 "$OUT"
    fi
    ENV_DIGEST="$(grep '^DIGEST=' "$LAB_BASE/.env" | cut -d= -f2 | tr -d '[:space:]')"
    if [[ "$ENV_DIGEST" == "$GOOD_DIGEST" ]]; then
        pass ".env still holds the previous digest"
    else
        fail ".env holds '$ENV_DIGEST', expected the previous digest '$GOOD_DIGEST'"
    fi
    DEPLOYED="$(tr -d '[:space:]' < "$LAB_BASE/.deployed-digest" 2>/dev/null || true)"
    if [[ "$DEPLOYED" == "$GOOD_DIGEST" ]]; then
        pass "the state file still holds the previous digest"
    else
        fail "the state file holds '$DEPLOYED', expected '$GOOD_DIGEST'"
    fi
fi
rm -f "$OUT"

# ==============================================================================
echo
if [[ "$FAILURES" -eq 0 ]]; then
    printf '\033[0;32m✅ wbparser lab suite passed\033[0m\n'
    exit 0
else
    printf '\033[0;31m❌ wbparser lab suite: %d check(s) failed\033[0m\n' "$FAILURES"
    exit 1
fi
