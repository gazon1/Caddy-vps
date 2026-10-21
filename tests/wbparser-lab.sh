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
#   T3  — preflight assertions reject a missing catalog API key
#   T4  — preflight assertions reject a missing admin password
#   T5  — a tag is resolved to a digest, and the digest is what .env and the
#         state file carry — for the crawler AND for the browser runtime
#   T6  — a second run changes nothing (idempotent)
#   T7  — the legacy .deployed-tag is migrated into the digest state file
#   T8  — an image that does not come up healthy rolls back to the previous
#         digest — for both images
#   T9  — a tag that cannot be resolved fails loudly and changes nothing
#   T10 — the route is really applied: the snippet lands in the proxy's conf.d
#         and the proxy answers through it
#   T11 — a registry answer that names no digest is refused, and nothing changes
#   T12 — the first apply of a route waits for the certificate it does not have yet
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
#   • alpine:3 (or the ability to pull it) — the browser stub is built on it
#   • nginx:alpine — the crawler stub is a real HTTP server
#   • caddy:2.8-alpine — the proxy T10 applies the route to
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_BASE="/tmp/wbparser-lab"
LAB_NETWORK="wbparser_net_lab"
LAB_REGISTRY="localhost:5000"
LAB_REGISTRY_CONTAINER="wbparser-lab-registry"
LAB_REPO="lab/wb-parser"
LAB_BROWSER_REPO="lab/wb-parser-adspower"
LAB_CONTAINER="wb-parser-lab"
LAB_BROWSER_CONTAINER="wb-parser-browser-lab"
LAB_COMPOSE="$LAB_BASE/docker-compose.lab.yml"
LAB_DB_PASSWORD="labtest123"
LAB_ADMIN_PASSWORD="lab-admin-secret"
LAB_ADMIN_API_KEY="lab-api-key-$(date +%s)"
# The catalog API's key. The application refuses to start without it, so the
# deploy refuses too — the lab has to carry one, or every play would stop at
# the preflight.
LAB_CATALOG_API_KEY="lab-catalog-key-$(date +%s)"
LAB_TAG_GOOD="good"
LAB_TAG_BAD="bad"
LAB_TAG_MISSING="no-such-tag-$$"

# The proxy the route is applied to. The deploy hands the route to the caddy
# role's routes.yml, so the lab needs a proxy to hand it to — the same role,
# the same playbook (site.yml), the lab's own base directory, container and
# network.
CADDY_LAB_BASE="/tmp/wbparser-lab-caddy"
CADDY_LAB_CONTAINER="caddy_wbparser_lab"
LAB_HTTP_PORT=18081
LAB_HTTPS_PORT=18444
# The site address of the route. The .localhost domain on purpose: Caddy issues
# such a name from its own internal CA, so the lab never contacts Let's Encrypt
# (its rule) and the certificate arrives without a public CA in the way.
LAB_SITE="wb-parser.localhost"

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
    docker rm -f "$LAB_CONTAINER" "$LAB_BROWSER_CONTAINER" "$LAB_REGISTRY_CONTAINER" \
        "$CADDY_LAB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$LAB_NETWORK" >/dev/null 2>&1 || true
    rm -rf "$LAB_BASE" "$CADDY_LAB_BASE" >/dev/null 2>&1 || true
}
trap teardown EXIT

INVENTORY="$REPO_ROOT/inventory/lab.yml"
PLAYBOOK="$REPO_ROOT/playbooks/wbparser.yml"

# The role reads its secrets from the environment, never from -e.
export WBPARSER_DB_PASSWORD="$LAB_DB_PASSWORD"
export WBPARSER_ADMIN_PASSWORD="$LAB_ADMIN_PASSWORD"
export WBPARSER_ADMIN_API_KEY="$LAB_ADMIN_API_KEY"
export WBPARSER_CATALOG_API_KEY="$LAB_CATALOG_API_KEY"

# Everything the role needs to talk to the throwaway registry instead of
# GHCR. The image coordinates are the same shape as production.
LAB_ARGS=(
    -e "wbparser_registry=$LAB_REGISTRY"
    -e "wbparser_image_owner=lab"
    -e "wbparser_image_name=wb-parser"
    -e "wbparser_browser_image_name=wb-parser-adspower"
    -e "wbparser_compose_src=$LAB_COMPOSE"
    -e "wbparser_compose_file=$LAB_COMPOSE"
    -e "wbparser_base=$LAB_BASE"
    -e "wbparser_container_name=$LAB_CONTAINER"
    -e "wbparser_browser_container_name=$LAB_BROWSER_CONTAINER"
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
    ansible-playbook -i "$INVENTORY" "$PLAYBOOK" --tags wbparser "${LAB_ARGS[@]}" "$@"
}

# The route is applied by the same playbook, but by a different set of tasks:
# the ones that hand the route to the caddy role. The catalog probe is skipped
# — the lab has no catalog to ask (there is no database behind it), and the
# point of this run is the route itself.
play_routes() {
    ansible-playbook -i "$INVENTORY" "$PLAYBOOK" \
        --tags caddy_routes --skip-tags catalog_probe "${LAB_ARGS[@]}" "$@"
}

# The proxy the route is applied to. The same caddy role and the same
# site.yml the production host uses, with the lab's own base directory,
# container, network and ports. The network is the crawler's: on the VPS the
# proxy and the crawler share one network, and the snippet's upstream is
# resolved by name on it.
CADDY_LAB_VARS=(
    -e "caddy_base=$CADDY_LAB_BASE"
    -e "caddy_network=$LAB_NETWORK"
    -e "caddy_container=$CADDY_LAB_CONTAINER"
    -e "caddy_http_port=$LAB_HTTP_PORT"
    -e "caddy_https_port=$LAB_HTTPS_PORT"
    -e "caddy_acme_email=lab@example.invalid"
    # The lab runs without sudo, so it cannot claim root ownership.
    -e "caddy_owner=$(id -un)"
    -e "caddy_group=$(id -gn)"
    # ...and without CAP_DAC_OVERRIDE the container could not write there either.
    -e "caddy_hardened_caps=false"
)

# A request through the route, the way a browser would make it: the site's own
# name for SNI and Host, and the self-signed certificate accepted explicitly.
ask_route() {
    curl -sk --max-time 10 \
        --resolve "$LAB_SITE:$LAB_HTTPS_PORT:127.0.0.1" \
        "https://$LAB_SITE:$LAB_HTTPS_PORT/api/health/live" \
        -o /dev/null -w '%{http_code}' 2>/dev/null || true
}

# The proxy answers a moment after the reload: the certificate for a .localhost
# name comes from Caddy's own CA, and issuing it takes a moment. The lab waits
# for the route instead of assuming it.
wait_for_route() {
    local deadline=$(( $(date +%s) + ${1:-60} )) code
    while [ "$(date +%s)" -lt "$deadline" ]; do
        code="$(ask_route)"
        [ "$code" = "200" ] && return 0
        sleep 1
    done
    info "the route did not answer within the window (last code: ${code:-none})"
    return 1
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

# `good` is a real HTTP server, not a socket trick: it answers 200 to
# everything, on the port the healthcheck asks for.
#
# It has to be a real one, because the route proxies to it (T10) and Go's HTTP
# client — the one inside Caddy — refuses a response that arrives before the
# request has been written. busybox nc answers without reading the request
# first: wget is happy with it, Caddy is not.
build_good_stub() {
    local tag="$1"
    cat > "$LAB_BASE/img/Dockerfile" <<'DOCKERFILE'
FROM nginx:alpine
RUN printf 'server {\n    listen 8080;\n    location / { return 200 "ok"; }\n}\n' \
        > /etc/nginx/conf.d/default.conf
DOCKERFILE
    docker build -q -t "$LAB_REGISTRY/$LAB_REPO:$tag" "$LAB_BASE/img" >/dev/null
    docker push -q "$LAB_REGISTRY/$LAB_REPO:$tag" >/dev/null
}

# The browser runtime: a second image, in a second repository, published under
# the same tag — which is the production contract. The label makes the two
# tags DIFFERENT images, so the two digests differ, so the rollback of the
# browser digest is a real rollback and not a no-op.
build_browser_stub() {
    local tag="$1"
    printf '%s\n%s\n' 'FROM alpine:3' 'CMD ["sh","-c","sleep 3600"]' > "$LAB_BASE/img/Dockerfile"
    docker build -q --label "lab.tag=$tag" \
        -t "$LAB_REGISTRY/$LAB_BROWSER_REPO:$tag" "$LAB_BASE/img" >/dev/null
    docker push -q "$LAB_REGISTRY/$LAB_BROWSER_REPO:$tag" >/dev/null
}

docker image inspect alpine:3 >/dev/null 2>&1 || docker pull alpine:3 >/dev/null
docker image inspect nginx:alpine >/dev/null 2>&1 || docker pull nginx:alpine >/dev/null
build_good_stub "$LAB_TAG_GOOD"
build_stub "$LAB_TAG_BAD" \
    '["sh","-c","sleep 3600"]'
build_browser_stub "$LAB_TAG_GOOD"
build_browser_stub "$LAB_TAG_BAD"

# The compose file the role copies verbatim. It mirrors the contract of the
# application repository's compose file: the images are named by DIGEST, and
# DIGEST is required — there is no tag and no `latest` to fall back to. The
# browser service is there too, sharing the crawler's network namespace, which
# is what makes the AdsPower Local API reachable at 127.0.0.1 inside it.
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

  wb-parser-browser:
    image: localhost:5000/${IMAGE_OWNER:-lab}/wb-parser-adspower@${BROWSER_DIGEST:?BROWSER_DIGEST must be set to a sha256 digest}
    container_name: wb-parser-browser-lab
    restart: unless-stopped
    network_mode: "service:wb-parser"
    env_file:
      - browser.env

networks:
  lab_net:
    name: wbparser_net_lab
    external: true
COMPOSE

digest_of() {
    docker buildx imagetools inspect "$LAB_REGISTRY/$1:$2" \
        --format '{{.Manifest.Digest}}' 2>/dev/null | tr -d '[:space:]'
}

GOOD_DIGEST="$(digest_of "$LAB_REPO" "$LAB_TAG_GOOD")"
BAD_DIGEST="$(digest_of "$LAB_REPO" "$LAB_TAG_BAD")"
GOOD_BROWSER_DIGEST="$(digest_of "$LAB_BROWSER_REPO" "$LAB_TAG_GOOD")"
BAD_BROWSER_DIGEST="$(digest_of "$LAB_BROWSER_REPO" "$LAB_TAG_BAD")"
info "good digest: $GOOD_DIGEST"
info "bad  digest: $BAD_DIGEST"
info "good browser digest: $GOOD_BROWSER_DIGEST"
info "bad  browser digest: $BAD_BROWSER_DIGEST"

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
step "T3 — missing catalog API key is rejected by preflight"
OUT="$(mktemp)"
if ( unset WBPARSER_CATALOG_API_KEY; play -e "wbparser_tag=$LAB_TAG_GOOD" ) > "$OUT" 2>&1; then
    fail "the playbook succeeded even though the catalog API key is empty"
else
    if grep -q 'WBPARSER_CATALOG_API_KEY is not set' "$OUT"; then
        pass "the playbook rejected an empty catalog API key"
    else
        fail "the playbook failed but not because of the empty catalog API key"
        tail -20 "$OUT"
    fi
fi
rm -f "$OUT"

# ==============================================================================
step "T4 — missing admin password is rejected by preflight"
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
step "T5 — the tag is resolved to a digest, and the digest is what is deployed"
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
    # The browser runtime: the same tag, a second image, a second digest.
    BROWSER_DIGEST="$(grep '^BROWSER_DIGEST=' "$LAB_BASE/.env" | cut -d= -f2 | tr -d '[:space:]')"
    if [[ "$BROWSER_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        pass ".env carries a browser digest: $BROWSER_DIGEST"
    else
        fail ".env does not carry a sha256:<64 hex> browser digest: '$BROWSER_DIGEST'"
    fi
    if [[ "$BROWSER_DIGEST" == "$GOOD_BROWSER_DIGEST" ]]; then
        pass "the browser digest is the one the registry reports for the tag"
    else
        fail "the browser digest does not match the registry: '$BROWSER_DIGEST' != '$GOOD_BROWSER_DIGEST'"
    fi
    if [[ -f "$LAB_BASE/.deployed-browser-digest" ]]; then
        BROWSER_DEPLOYED="$(tr -d '[:space:]' < "$LAB_BASE/.deployed-browser-digest")"
        if [[ "$BROWSER_DEPLOYED" == "$GOOD_BROWSER_DIGEST" ]]; then
            pass "the browser state file holds the running digest"
        else
            fail "the browser state file holds '$BROWSER_DEPLOYED', expected '$GOOD_BROWSER_DIGEST'"
        fi
    else
        fail "the browser state file was not written"
    fi
    if [[ -f "$LAB_BASE/browser.env" ]]; then
        pass "browser.env was rendered"
    else
        fail "browser.env was not rendered"
    fi
    if grep -q "^ADSPOWER_API_KEY=$LAB_ADMIN_API_KEY$" "$LAB_BASE/browser.env" 2>/dev/null; then
        pass "browser.env carries the AdsPower key"
    else
        fail "browser.env does not carry the AdsPower key"
    fi
    if grep -q "^CATALOG_API_KEY=$LAB_CATALOG_API_KEY$" "$LAB_BASE/app.env" 2>/dev/null; then
        pass "app.env carries the catalog API key"
    else
        fail "app.env does not carry the catalog API key"
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "$LAB_BROWSER_CONTAINER" 2>/dev/null)" == "true" ]]; then
        pass "the browser runtime container is running"
    else
        fail "the browser runtime container is not running"
    fi
else
    fail "the deploy failed"
    tail -30 "$OUT"
fi
rm -f "$OUT"

# ==============================================================================
step "T6 — a second run changes nothing (idempotent)"
ENV_BEFORE="$(cat "$LAB_BASE/.env")"
STATE_BEFORE="$(cat "$LAB_BASE/.deployed-digest")"
BROWSER_ENV_BEFORE="$(cat "$LAB_BASE/browser.env")"
BROWSER_STATE_BEFORE="$(cat "$LAB_BASE/.deployed-browser-digest")"
OUT="$(mktemp)"
play -e "wbparser_tag=$LAB_TAG_GOOD" > "$OUT" 2>&1 || true
if [[ "$ENV_BEFORE" == "$(cat "$LAB_BASE/.env")" \
   && "$STATE_BEFORE" == "$(cat "$LAB_BASE/.deployed-digest")" \
   && "$BROWSER_ENV_BEFORE" == "$(cat "$LAB_BASE/browser.env")" \
   && "$BROWSER_STATE_BEFORE" == "$(cat "$LAB_BASE/.deployed-browser-digest")" ]]; then
    pass ".env, browser.env and the state files are unchanged"
else
    fail "a second run rewrote .env, browser.env or a state file"
fi
if grep -qE 'failed=0' "$OUT"; then
    pass "the second run did not fail"
else
    fail "the second run failed"
    tail -20 "$OUT"
fi
rm -f "$OUT"

# ==============================================================================
step "T7 — the legacy .deployed-tag is migrated into the digest state file"
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
step "T8 — an image that never becomes healthy rolls back to the previous digest"
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
    # The browser runtime rolls back with it: the browser image changed with
    # the tag, so the previous browser digest is what has to be running again.
    BROWSER_DIGEST="$(grep '^BROWSER_DIGEST=' "$LAB_BASE/.env" | cut -d= -f2 | tr -d '[:space:]')"
    if [[ "$BROWSER_DIGEST" == "$GOOD_BROWSER_DIGEST" ]]; then
        pass ".env was re-rendered with the previous browser digest"
    else
        fail ".env holds the browser digest '$BROWSER_DIGEST', expected '$GOOD_BROWSER_DIGEST'"
    fi
    BROWSER_DEPLOYED="$(tr -d '[:space:]' < "$LAB_BASE/.deployed-browser-digest" 2>/dev/null || true)"
    if [[ "$BROWSER_DEPLOYED" == "$GOOD_BROWSER_DIGEST" ]]; then
        pass "the browser state file still holds the previous digest"
    else
        fail "the browser state file holds '$BROWSER_DEPLOYED', expected '$GOOD_BROWSER_DIGEST'"
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "$LAB_BROWSER_CONTAINER" 2>/dev/null)" == "true" ]]; then
        pass "the browser runtime is running again"
    else
        fail "the browser runtime is not running"
    fi
fi
rm -f "$OUT"

# ==============================================================================
step "T9 — a tag that cannot be resolved fails loudly and changes nothing"
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
    BROWSER_DIGEST="$(grep '^BROWSER_DIGEST=' "$LAB_BASE/.env" | cut -d= -f2 | tr -d '[:space:]')"
    if [[ "$BROWSER_DIGEST" == "$GOOD_BROWSER_DIGEST" ]]; then
        pass ".env still holds the previous browser digest"
    else
        fail ".env holds the browser digest '$BROWSER_DIGEST', expected '$GOOD_BROWSER_DIGEST'"
    fi
fi
rm -f "$OUT"

# ==============================================================================
step "T10 — the route is really applied: the snippet lands in the proxy's conf.d"
# The defect this catches: the deploy declared the route's name in the play's
# `vars:`, and the play's `vars_files` — the caddy role's defaults, where
# caddy_route_name is "" ("no route") — outranks it. The name therefore
# arrived at routes.yml empty, the block at the top of routes.yml was skipped
# (`when: caddy_route_name | length > 0`), and the deploy finished green with
# no route on the server: the container was up and nothing pointed at it.
#
# The check is on the FILE the route leaves behind, not on the exit code: a
# deploy that reports success and writes nothing is exactly the failure, and
# it is invisible to every other check in this suite.
#
# The proxy is the caddy role's own, bootstrapped from site.yml — the same
# role and the same playbook the VPS uses.
#
# The snippets of an earlier run are cleared first. The lab directory can
# survive a run (the trash helper may refuse to remove it), and a snippet left
# over from an earlier run would make this step pass without the route having
# been applied at all — which is the very failure this step is about.
rm -f "$CADDY_LAB_BASE/conf.d/"*.caddy >/dev/null 2>&1 || true
OUT="$(mktemp)"
if ansible-playbook -i "$INVENTORY" "$REPO_ROOT/site.yml" "${CADDY_LAB_VARS[@]}" > "$OUT" 2>&1; then
    pass "the lab proxy is up"
else
    fail "the lab proxy did not come up"
    tail -30 "$OUT"
fi
rm -f "$OUT"

# The route is applied without the probe first. The probe inside routes.yml
# asks the route in the same second as the reload, and the certificate for a
# .localhost name is issued by Caddy's own CA a moment later — so a probe
# fired right after the reload is a race the lab would lose. The lab asks the
# route itself, with a wait, in the step below.
OUT="$(mktemp)"
if play_routes \
    -e "wbparser_hostname=$LAB_SITE" \
    -e "caddy_route_url=" \
    "${CADDY_LAB_VARS[@]}" > "$OUT" 2>&1; then
    if grep -q "Install the snippet" "$OUT"; then
        pass "the deploy applied the route"
    else
        fail "the deploy did not apply the route — it skipped the route entirely"
        tail -40 "$OUT"
    fi
else
    fail "the deploy did not apply the route"
    tail -40 "$OUT"
fi
rm -f "$OUT"

SNIPPET="$CADDY_LAB_BASE/conf.d/wbparser.caddy"
if [[ -f "$SNIPPET" ]]; then
    pass "the route snippet was written to $SNIPPET"
else
    fail "the route snippet was not written to $SNIPPET — the route was never applied"
fi

if grep -q "$LAB_SITE" "$SNIPPET" 2>/dev/null; then
    pass "the snippet carries the site address"
else
    fail "the snippet does not carry the site address"
fi

if grep -q "$LAB_CONTAINER:8080" "$SNIPPET" 2>/dev/null; then
    pass "the snippet points at the crawler"
else
    fail "the snippet does not point at the crawler"
fi

# The route is not just on disk, it serves. A snippet that was written but
# does not answer is a route that does not exist for anyone.
if wait_for_route 60; then
    pass "the proxy answers through the applied route"
else
    fail "the route was written but the proxy does not answer through it"
fi

# And the deploy says so itself: the same run, now with the probe switched on.
# The probe asks the route for the crawler's liveness endpoint and fails the
# run when the route does not answer — so a green run here means the route the
# deploy wrote is the route that answers.
#
# The task header is looked for as well: a run that skipped the route entirely
# is green too, and green is exactly what the bug looked like.
OUT="$(mktemp)"
if play_routes \
    -e "wbparser_hostname=$LAB_SITE" \
    -e "wbparser_route_url=https://$LAB_SITE:$LAB_HTTPS_PORT/api/health/live" \
    -e "caddy_route_insecure=true" \
    -e "caddy_route_resolve=$LAB_SITE:$LAB_HTTPS_PORT:127.0.0.1" \
    -e "caddy_route_timeout=30" \
    "${CADDY_LAB_VARS[@]}" > "$OUT" 2>&1; then
    if grep -q "Probe the route end to end" "$OUT"; then
        pass "the deploy's own probe asked the route, and the route answered"
    else
        fail "the deploy did not probe the route at all"
        tail -40 "$OUT"
    fi
else
    fail "the deploy's own probe did not answer through the route it applied"
    tail -40 "$OUT"
fi
rm -f "$OUT"

# ==============================================================================
step "T11 — the digest is read from the registry's answer, and an answer without one is refused"
# The defect this catches: the resolution read the digest through a buildx
# template, `--format '{{.Manifest.Digest}}'`, whose field set buildx changes
# between versions. On the VPS the request came back with the plain listing
# instead of the templated field — the digest WAS in the answer, just not where
# the template looked for it. The role read that answer as "no digest named" and
# refused to deploy, which was the right thing to do and still stopped the
# deploy.
#
# The registry is faked here, because the shape of the answer is the whole
# point: a `docker` earlier in PATH answers with a listing the way an older
# buildx does, and everything else is delegated to the real docker.
#
# First case: the answer carries a `Digest:` line, in the listing form. The
# role must take the digest from the text — that is the production shape, the
# one that broke the deploy.
#
# Second case: the answer carries no `Digest:` line at all. The role must
# refuse it — a deploy that cannot name the image must not name it — and the
# refusal must say which buildx answered, so that the next occurrence is
# diagnosable without hunting through the environment.
REAL_DOCKER="$(command -v docker)"
FAKE_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
FAKE_BIN="$(mktemp -d)"
cat > "$FAKE_BIN/docker" <<FAKE
#!/usr/bin/env bash
if [ "\$1" = "buildx" ] && [ "\$2" = "version" ]; then
    echo "github.com/docker/buildx v0.0.0-lab"
    exit 0
fi
if [ "\$1" = "buildx" ] && [ "\$2" = "imagetools" ]; then
    echo "Name:      lab/wb-parser:tag"
    echo "MediaType: application/vnd.oci.image.index.v1+json"
    echo "Digest:    ${FAKE_DIGEST}"
    exit 0
fi
exec ${REAL_DOCKER} "\$@"
FAKE
chmod +x "$FAKE_BIN/docker"
OUT="$(mktemp)"
PATH="$FAKE_BIN:$PATH" play --check --diff -e "wbparser_tag=$LAB_TAG_GOOD" > "$OUT" 2>&1 || true
if grep -q 'does not name a sha256' "$OUT"; then
    fail "the role refused an answer that does name a digest"
    tail -30 "$OUT"
else
    pass "the role accepted an answer that names a digest"
fi
if grep -q "$FAKE_DIGEST" "$OUT"; then
    pass "the digest was taken from the text of the answer"
else
    fail "the digest did not come from the text of the answer"
    tail -30 "$OUT"
fi
rm -f "$OUT"

# The answer without a digest: the refusal.
FAKE_BIN_NO_DIGEST="$(mktemp -d)"
cat > "$FAKE_BIN_NO_DIGEST/docker" <<FAKE
#!/usr/bin/env bash
if [ "\$1" = "buildx" ] && [ "\$2" = "version" ]; then
    echo "github.com/docker/buildx v0.0.0-lab"
    exit 0
fi
if [ "\$1" = "buildx" ] && [ "\$2" = "imagetools" ]; then
    echo "Name:      lab/wb-parser:tag"
    echo "MediaType: application/vnd.oci.image.index.v1+json"
    exit 0
fi
exec ${REAL_DOCKER} "\$@"
FAKE
chmod +x "$FAKE_BIN_NO_DIGEST/docker"
OUT="$(mktemp)"
if PATH="$FAKE_BIN_NO_DIGEST:$PATH" play -e "wbparser_tag=$LAB_TAG_GOOD" > "$OUT" 2>&1; then
    fail "the deploy succeeded even though the registry named no digest"
else
    if grep -q 'does not name a sha256:<64 hex> digest' "$OUT"; then
        pass "the failure says the answer names no digest"
    else
        fail "the failure does not say the answer names no digest"
        tail -30 "$OUT"
    fi
    if grep -q 'v0.0.0-lab' "$OUT"; then
        pass "the failure names the buildx that answered"
    else
        fail "the failure does not name the buildx that answered"
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
rm -rf "$FAKE_BIN" "$FAKE_BIN_NO_DIGEST"

# ==============================================================================
step "T12 — the first apply of a route waits for the certificate it does not have yet"
# The defect this catches: the probe asked the route once, right after the
# reload, and failed when the answer did not come. On the first apply of a
# route there is no certificate yet — Caddy issues it in the background — so
# the handshake cannot complete, and the deploy failed for a state that is
# normal for a first deploy. The route was applied and everything was fine.
#
# The route goes to a FRESH address, so the proxy has no certificate for it
# and has to issue one while the deploy is waiting. Before the fix this step
# failed; now the probe waits and the deploy ends green.
FRESH_SITE="wb-parser-fresh.localhost"
OUT="$(mktemp)"
if play_routes \
    -e "wbparser_hostname=$FRESH_SITE" \
    -e "caddy_route_name=wbparser-fresh" \
    -e "wbparser_route_url=https://$FRESH_SITE:$LAB_HTTPS_PORT/api/health/live" \
    -e "caddy_route_insecure=true" \
    -e "caddy_route_resolve=$FRESH_SITE:$LAB_HTTPS_PORT:127.0.0.1" \
    -e "caddy_route_timeout=10" \
    "${CADDY_LAB_VARS[@]}" > "$OUT" 2>&1; then
    pass "the deploy waited for the certificate and finished green"
    if grep -q "RETRYING" "$OUT"; then
        pass "the probe retried instead of asking once"
    else
        info "the certificate was ready before the first probe — the wait was not needed this time"
    fi
else
    fail "the deploy failed on a route whose certificate was still being issued"
    tail -40 "$OUT"
    # Что сказал прокси: без этого причину приходится искать по всей системе.
    echo "    --- the proxy's own log (last 15 lines):"
    docker logs "$CADDY_LAB_CONTAINER" 2>&1 | tail -15 | sed 's/^/    /'
fi
rm -f "$OUT"

# The route for the fresh address must not have broken the first one.
if ask_route >/dev/null 2>&1; then
    pass "the first route still answers"
else
    fail "the first route stopped answering"
fi

# ==============================================================================
echo
if [[ "$FAILURES" -eq 0 ]]; then
    printf '\033[0;32m✅ wbparser lab suite passed\033[0m\n'
    exit 0
else
    printf '\033[0;31m❌ wbparser lab suite: %d check(s) failed\033[0m\n' "$FAILURES"
    exit 1
fi
