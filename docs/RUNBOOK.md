# Runbook — global Caddy proxy

What to do when something breaks, and how to add a project without causing an
outage. Companion to [../README.md](../README.md).

---

## First response to any problem

```bash
just status
```

Read-only, safe at any time, answers most questions in one shot:

- is the container running and healthy
- is the **running** configuration valid, and if not, what Caddy says
- which route snippets are installed
- which non-standard modules are compiled in

Then `docker logs --tail=200 caddy_global` — logs are JSON on stdout and live
only as long as the container does, so grab what you need before it restarts.

---

## Common situations

### The proxy is down

```bash
just bootstrap
```

Idempotent: repairs whatever is missing without touching what is already
correct. If the container is up but the configuration is invalid, fix the
configuration first — `bootstrap` reloads, it does not repair.

### A route snippet was rejected

The playbook already restored the previous version and exited non-zero. The
running proxy kept serving the old route the whole time, so there is no
outage to handle.

Two different messages come out of this, and they matter:

| Message | Meaning | What to do |
|---|---|---|
| "...has been rolled back to its previous version. The rest of the configuration is fine" | your snippet is what Caddy rejects | fix the snippet |
| "the rolled-back one fails too... the breakage predates this run" | some **other** file in `conf.d` was already broken | inspect every file in `/opt/caddy/conf.d/`, not just yours |

### Roll a snippet back by hand

Every apply leaves timestamped backups next to the snippet:

```bash
ls -1t /opt/caddy/conf.d/<name>.caddy.bak.*
```

```bash
cp /opt/caddy/conf.d/<name>.caddy.bak.<timestamp> /opt/caddy/conf.d/<name>.caddy
docker exec caddy_global caddy validate --config /etc/caddy/Caddyfile && \
  docker exec caddy_global caddy reload --config /etc/caddy/Caddyfile
```

Validate before reloading. Always. `caddy reload` on a broken config leaves
you with a proxy that is running but refusing to serve.

Rotation keeps the newest `caddy_backup_ttl` (default 5) copies and deletes the
rest during the next apply of that snippet.

### Certificate problems

Caddy renews on its own, but only while it is running. If the container was
down across a renewal date, the certificate can lapse.

```bash
ls -R /opt/caddy/data/caddy/certificates
docker exec caddy_global caddy validate --config /etc/caddy/Caddyfile
```

Fixing the underlying problem (ports closed, DNS pointing elsewhere) and
restarting is usually enough:

```bash
just bootstrap
```

**Never delete `/opt/caddy/data`.** It holds every certificate. Emptying it
forces a full reissue and eats into Let's Encrypt's rate limit — roughly five
failed validations per registered domain per week, after which issuance stops
entirely.

### What validation does and does not catch

`caddy validate` **adapts** the configuration. It reliably catches syntax
errors, unknown directives, bad directive arguments, and a broken Caddyfile
global block.

It does **not** exercise the running proxy. A snippet can validate perfectly
and still fail every request, for example when:

- the upstream host name does not resolve (container not on `caddy_net`, or a
  typo in the compose service name)
- the upstream refuses connections (container up but not listening yet)
- `reverse_proxy` points at a port nothing serves

So a successful `just route` means "this configuration is loadable", not "this
project is now reachable".

For that, pass a URL to probe and the run checks it for you:

```bash
just route myproject deploy/myproject.conf.caddy \
  -e caddy_route_url=https://myproject.example.com/api/health/live
```

The probe runs *after* validation and *outside* the rollback logic on
purpose — an unreachable backend is not a configuration error, so rolling the
snippet back would hide the real problem behind a misleading message. The
snippet stays applied and the run fails with an explanation.

Without the probe, do the check by hand:

```bash
curl -I https://myproject.example.com/api/health/live
```

### Ports 80/443 are in the way

`just bootstrap` refuses to start if some other container already publishes
them, and names the offender. Either stop that container, or point this proxy
at different ports:

```bash
just bootstrap -e caddy_http_port=8080 -e caddy_https_port=8443
```

### Diagnosing traffic

The admin API is bound to loopback inside the container and is not published.
To talk to it, exec into the container:

```bash
docker exec caddy_global caddy list-modules --skip-standard
```

If you need the admin API on the host for debugging, set
`caddy_publish_admin: true` in `inventory/group_vars/vps.yml` and re-run
`just bootstrap`. It binds the API to `0.0.0.0` inside the container and
publishes it on host loopback only.

---

## Adding a project

The order below matters. Doing it in a different order costs you an outage.

1. **Make sure the application container joins `caddy_net`** and is reachable
   there by its compose service name. Nothing of the project needs to be
   published to the host — and it should not be.

   ```yaml
   networks: [caddy_net]
   networks:
     caddy_net: {external: true, name: caddy_net}
   ```

   The database stays off that network.

2. **Deploy the application.** Confirm it answers from inside the network:

   ```bash
   docker exec caddy_global wget -qO- http://app:8080/api/health/live
   ```

   Fix this before touching the proxy. A route pointing at a dead upstream is
   the most common way to break a shared proxy.

3. **Write the snippet** and apply it:

   ```bash
   just route myproject deploy/myproject.conf.caddy
   ```

4. **Verify end to end:**

   ```bash
   curl -I https://myproject.example.com/api/health/live
   ```

### Rolling a project back to its own local proxy

While a project is still on its own Caddy, do not remove that service until the
shared proxy is confirmed working for it. The shared proxy is shared: a
mistake in one project's snippet can take down traffic for all of them. If a
migration goes wrong, restore the project's local proxy from git history and
remove its snippet:

```bash
just bootstrap   # caddy_net still exists either way
git revert <the commit that removed the local caddy service>
```

---

## Changing this repository

Before changing anything, prove it locally — the lab suite does not touch the
VPS and does not contact Let's Encrypt:

```bash
just lab-test
```

It checks that a first run provisions, a second run changes nothing, an invalid
snippet is rejected and rolled back, and the proxy keeps serving the previous
route while that happens.

Static checks, also run on every push:

```bash
ansible-playbook --syntax-check site.yml playbooks/status.yml
ansible-lint
yamllint .
```

---

## Things not to do

| Do not | Why |
|---|---|
| edit `/opt/caddy/Caddyfile` or `conf.d/*.caddy` by hand and leave it | the next `just bootstrap` overwrites it, and the hand edit is lost |
| `docker system prune -a` | it does not touch the bind-mounted `data/`, but `docker volume prune`-style cleanups elsewhere have taken certificates with them |
| restart the container to apply a config change | use `caddy reload` — it drains connections gracefully; a restart drops them |
| run two deploys of the same snippet at once | file writes are atomic so nothing corrupts, but the backups can interleave |
| delete `/opt/caddy/data` | see certificates above |