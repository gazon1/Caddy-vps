#!/usr/bin/env bash
# ==============================================================================
# Local lab suite — proves the role works without touching the VPS.
#
#   just lab-test
#
# Everything lives under /tmp/caddy-lab with its own network, container and
# ports, and is torn down on exit. ACME is never contacted: TLS mode is
# `internal`, so Caddy issues a self-signed certificate locally and no
# Let's Encrypt rate limit is spent.
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

LAB_BASE=/tmp/caddy-lab
LAB_NETWORK=caddy_net_lab
LAB_CONTAINER=caddy_lab
LAB_BACKEND=caddy_lab_backend
LAB_HTTP_PORT=8081
LAB_HTTPS_PORT=8444
LAB_SITE=lab.test
LAB_SITE_DIR="$LAB_BASE/fixtures"

LAB_VARS=(
    -e "caddy_base=$LAB_BASE"
    -e "caddy_network=$LAB_NETWORK"
    -e "caddy_container=$LAB_CONTAINER"
    -e "caddy_http_port=$LAB_HTTP_PORT"
    -e "caddy_https_port=$LAB_HTTPS_PORT"
    -e "caddy_acme_email=lab@example.invalid"
    # The lab runs without sudo, so it cannot claim root ownership.
    -e "caddy_owner=$(id -un)"
    -e "caddy_group=$(id -gn)"
    # ...and without CAP_DAC_OVERRIDE the container could not write there either.
    -e "caddy_hardened_caps=false"
)


FAILURES=0
STEP=0

# ---- output helpers ---------------------------------------------------------
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

# ---- teardown ---------------------------------------------------------------
# Best effort by design. /tmp/caddy-lab/data holds files the container wrote as
# root, which the trash helper may refuse to move. A leftover lab directory is
# harmless: the next run reuses it, and preflight accepts it because this
# role's own Caddyfile is already sitting there.
teardown() {
    docker rm -f "$LAB_CONTAINER" "$LAB_BACKEND" >/dev/null 2>&1 || true
    docker network rm "$LAB_NETWORK" >/dev/null 2>&1 || true
    rm -rf "$LAB_BASE" >/dev/null 2>&1 || true
}
trap teardown EXIT

play() { ansible-playbook -i "$REPO_ROOT/inventory/lab.yml" "$@"; }

# Routes traffic through the proxy the same way a browser would: SNI/Host set
# to the site address, certificate accepted as self-signed.
ask_proxy() {
    curl -sk --max-time 10 \
        --resolve "$LAB_SITE:$LAB_HTTPS_PORT:127.0.0.1" \
        "https://$LAB_SITE:$LAB_HTTPS_PORT/" -o /dev/null -w '%{http_code}'
}

# ==============================================================================
echo "▸ Lab values"
echo "    base      : $LAB_BASE"
echo "    container : $LAB_CONTAINER"
echo "    network   : $LAB_NETWORK"
echo "    ports     : $LAB_HTTP_PORT / $LAB_HTTPS_PORT"
echo "    site      : $LAB_SITE (tls internal, ACME untouched)"

teardown
mkdir -p "$LAB_SITE_DIR"

# The backend is started AFTER the first bootstrap, because the role is what
# creates the network the backend needs to join.

# ==============================================================================
step "Bootstrap on a clean host"
OUT="$(mktemp)"
play "$REPO_ROOT/site.yml" "${LAB_VARS[@]}" | tee "$OUT"
grep -qE 'changed=[1-9]' "$OUT" && pass "proxy was provisioned (something changed)"
grep -qE 'changed=0' "$OUT" && fail "a first run must actually change something"
rm -f "$OUT"

STATE="$(docker inspect -f '{{.State.Running}}' "$LAB_CONTAINER" 2>/dev/null || echo missing)"
[[ "$STATE" == "true" ]] && pass "container $LAB_CONTAINER is running" \
    || fail "container $LAB_CONTAINER is not running (state=$STATE)"

HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$LAB_CONTAINER" 2>/dev/null || echo none)"
[[ "$HEALTH" == "healthy" ]] && pass "container reports healthy" \
    || fail "container health is '$HEALTH'"

if docker exec "$LAB_CONTAINER" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    pass "caddy validate accepts the rendered configuration"
else
    fail "caddy validate rejected the rendered configuration"
fi

for d in "$LAB_BASE" "$LAB_BASE/conf.d" "$LAB_BASE/data" "$LAB_BASE/config"; do
    [[ -d "$d" ]] || fail "missing directory: $d"
done
pass "directory layout is in place"

docker network inspect "$LAB_NETWORK" >/dev/null 2>&1 \
    && pass "shared network $LAB_NETWORK exists" \
    || fail "shared network $LAB_NETWORK is missing"

# ==============================================================================
step "Second run is idempotent (changed=0)"
OUT="$(mktemp)"
play "$REPO_ROOT/site.yml" "${LAB_VARS[@]}" | tee "$OUT"
grep -qE 'changed=0' "$OUT" && pass "re-run changed nothing" \
    || fail "re-run reported changes — role is not idempotent"
rm -f "$OUT"

# ==============================================================================
step "Start a stand-in application container on the shared network"
docker run -d --name "$LAB_BACKEND" --network "$LAB_NETWORK" \
    --network-alias "$LAB_BACKEND" nginx:alpine >/dev/null
docker inspect -f '{{.State.Running}}' "$LAB_BACKEND" 2>/dev/null | grep -q true \
    && pass "backend $LAB_BACKEND is running on $LAB_NETWORK" \
    || fail "backend $LAB_BACKEND did not start"

# ==============================================================================
step "Apply a route snippet"
# A route is just a file, and TLS is whatever that file says. `tls internal`
# here is what lets the lab use a self-signed certificate without touching
# Let's Encrypt; in production you would leave it out.
cat > "$LAB_SITE_DIR/good.caddy" <<EOF
$LAB_SITE {
    tls internal
    encode zstd gzip
    @app path /
    reverse_proxy @app $LAB_BACKEND:80
}
EOF

play "$REPO_ROOT/site.yml" --tags caddy_routes "${LAB_VARS[@]}" \
    -e "caddy_route_name=lab" \
    -e "caddy_route_src=$LAB_SITE_DIR/good.caddy" >/dev/null

SNIPPET="$LAB_BASE/conf.d/lab.caddy"
[[ -f "$SNIPPET" ]] && pass "snippet written to $SNIPPET" || fail "snippet was not written"
grep -q 'tls internal' "$SNIPPET" \
    && pass "the snippet's own tls directive survived the copy" \
    || fail "tls internal directive missing from the installed snippet"
cmp -s "$LAB_SITE_DIR/good.caddy" "$SNIPPET" \
    && pass "the installed snippet is byte-identical to the source" \
    || fail "the installed snippet differs from the source file"

CODE="$(ask_proxy || echo 000)"
[[ "$CODE" == "200" ]] && pass "proxy answers 200 through the route" \
    || fail "proxy answered '$CODE' instead of 200"

# ==============================================================================
step "An invalid snippet is rejected and rolled back"
BEFORE="$(cat "$SNIPPET")"
# An UNKNOWN DIRECTIVE is the right kind of broken on purpose: `caddy validate`
# adapts the configuration, so this fails at validation time. A snippet that is
# syntactically fine but points at a dead upstream would pass validation and
# only break at request time — that case is covered further down.
cat > "$LAB_SITE_DIR/broken.caddy" <<'EOF'
lab.test {
    this_directive_does_not_exist
}
EOF

if play "$REPO_ROOT/site.yml" --tags caddy_routes "${LAB_VARS[@]}" \
    -e "caddy_route_name=lab" \
    -e "caddy_route_src=$LAB_SITE_DIR/broken.caddy" >/dev/null 2>&1; then
    fail "the playbook accepted an invalid snippet"
else
    pass "the playbook refused an invalid snippet (non-zero exit)"
fi

AFTER="$(cat "$SNIPPET")"
[[ "$BEFORE" == "$AFTER" ]] && pass "the previous snippet was restored byte for byte" \
    || fail "the snippet was left in a modified state"

if docker exec "$LAB_CONTAINER" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    pass "the rolled-back configuration validates"
else
    fail "the configuration is still invalid after the rollback"
fi

CODE="$(ask_proxy || echo 000)"
[[ "$CODE" == "200" ]] && pass "the proxy kept serving the old route throughout" \
    || fail "the proxy stopped answering after the failed apply (got '$CODE')"

# ==============================================================================
step "A valid snippet pointing at a dead upstream is caught by the probe"
# This is the gap validation cannot close: the configuration loads fine, and
# only a real request reveals that nothing is listening. caddy_route_url is
# what turns that from a mystery into a failed run.
cat > "$LAB_SITE_DIR/dead.caddy" <<EOF
dead.$LAB_SITE {
    tls internal
    reverse_proxy nothing-is-listening-here:80
}
EOF

# A distinct hostname on purpose: two snippets claiming the same site address
# would make Caddy reject the config outright, and the run would then fail for
# the wrong reason — which is exactly what an earlier version of this test did.
DEAD_SITE="dead.$LAB_SITE"
DEAD_URL="https://$DEAD_SITE:$LAB_HTTPS_PORT/"
DEAD_RESOLVE="$DEAD_SITE:$LAB_HTTPS_PORT:127.0.0.1"
DEAD_OUT="$(mktemp)"

if play "$REPO_ROOT/site.yml" --tags caddy_routes "${LAB_VARS[@]}" \
    -e "caddy_route_name=dead" \
    -e "caddy_route_src=$LAB_SITE_DIR/dead.caddy" \
    -e "caddy_route_url=$DEAD_URL" \
    -e "caddy_route_insecure=true" \
    -e "caddy_route_resolve=$DEAD_RESOLVE" >"$DEAD_OUT" 2>&1; then
    fail "the run succeeded even though the route could not answer"
else
    pass "the run failed on an unreachable upstream"
fi

if grep -q 'did not answer' "$DEAD_OUT"; then
    pass "the failure says the route did not answer"
else
    fail "the failure did not explain that the route was unreachable"
fi

if grep -q 'NOT been rolled back' "$DEAD_OUT"; then
    pass "the failure says the snippet was kept, not rolled back"
else
    fail "the failure left the operator guessing about rollback"
fi

# The probe must not be mistaken for a validation failure: Caddy accepted this
# configuration, it simply has nothing to forward to.
if grep -q 'ambiguous site definition' "$DEAD_OUT"; then
    fail "the snippet was rejected by Caddy — the test is measuring the wrong thing"
else
    pass "the configuration itself was accepted by Caddy"
fi
rm -f "$DEAD_OUT"

# The good route must still be untouched — a probe failure is not a
# configuration failure, so nothing may be rolled back.
if docker exec "$LAB_CONTAINER" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    pass "the proxy is still in a valid state after the probe failed"
else
    fail "the configuration was left invalid"
fi

CODE="$(ask_proxy || echo 000)"
[[ "$CODE" == "200" ]] && pass "the working route was not disturbed" \
    || fail "the working route broke (got '$CODE')"

# --- Same dead snippet, but no probe configured: must succeed ---
if play "$REPO_ROOT/site.yml" --tags caddy_routes "${LAB_VARS[@]}" \
    -e "caddy_route_name=dead" \
    -e "caddy_route_src=$LAB_SITE_DIR/dead.caddy" >/dev/null 2>&1; then
    pass "without caddy_route_url the dead upstream is not detected (opt-in works)"
else
    fail "the probe ran even though no URL was configured"
fi

# --- The live route, probed: must succeed ---
if play "$REPO_ROOT/site.yml" --tags caddy_routes "${LAB_VARS[@]}" \
    -e "caddy_route_name=lab" \
    -e "caddy_route_src=$LAB_SITE_DIR/good.caddy" \
    -e "caddy_route_url=https://$LAB_SITE:$LAB_HTTPS_PORT/" \
    -e "caddy_route_insecure=true" \
    -e "caddy_route_resolve=$LAB_SITE:$LAB_HTTPS_PORT:127.0.0.1" >/dev/null 2>&1; then
    pass "the probe passes when the route really works"
else
    fail "the probe failed on a working route — it is too strict"
fi

# ==============================================================================
step "Backup rotation keeps only caddy_backup_ttl copies"
# Apply the same snippet more times than the retention limit. Every apply must
# leave a .bak behind, and rotation must cap them at caddy_backup_ttl.
for i in 1 2 3 4 5 6 7; do
    play "$REPO_ROOT/site.yml" --tags caddy_routes "${LAB_VARS[@]}" \
        -e "caddy_route_name=lab" \
        -e "caddy_route_src=$LAB_SITE_DIR/good.caddy" >/dev/null
done

BAK_COUNT="$(find "$LAB_BASE/conf.d" -name 'lab.caddy.bak.*' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$BAK_COUNT" == "5" ]]; then
    pass "7 applies left exactly 5 backups (limit is 5)"
else
    fail "backup rotation left $BAK_COUNT files, expected 5"
fi

if find "$LAB_BASE/conf.d" -name 'lab.caddy.bak.*' | head -1 | grep -qE '\.bak\.[0-9]+$'; then
    pass "backups use a predictable .bak.<timestamp> name"
else
    fail "backup names are not the documented .bak.<timestamp> form"
fi

# ==============================================================================
step "playbooks/status.yml changes nothing"
BEFORE_STATE="$(docker inspect -f '{{.State.Running}}' "$LAB_CONTAINER")"
BEFORE_SNIPPET="$(md5sum "$SNIPPET" | cut -d' ' -f1)"
play "$REPO_ROOT/playbooks/status.yml" "${LAB_VARS[@]}" >/dev/null
AFTER_STATE="$(docker inspect -f '{{.State.Running}}' "$LAB_CONTAINER")"
AFTER_SNIPPET="$(md5sum "$SNIPPET" | cut -d' ' -f1)"

[[ "$BEFORE_STATE" == "$AFTER_STATE" ]] && pass "container state untouched" \
    || fail "status.yml changed the container state"
[[ "$BEFORE_SNIPPET" == "$AFTER_SNIPPET" ]] && pass "route snippet untouched" \
    || fail "status.yml modified the route snippet"

# ==============================================================================
echo
if [[ "$FAILURES" -eq 0 ]]; then
    printf '\033[0;32m✅ Lab suite passed\033[0m\n'
    exit 0
else
    printf '\033[0;31m❌ Lab suite: %d check(s) failed\033[0m\n' "$FAILURES"
    exit 1
fi