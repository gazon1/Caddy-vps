# Caddy-vps — the one reverse proxy for the whole VPS

**What this is:** the Ansible code that installs and maintains a single Caddy
reverse proxy on your VPS. Every project you deploy gets a hostname by adding
one small file; you never run a second proxy and never fight anyone over
ports 80 and 443.

**What it is not:** an application. It serves nothing of its own. It only
forwards traffic to your project's containers.

---

## How it fits together

```
   internet
      │  :80 / :443
      ▼
┌──────────────────────────┐
│  caddy_global            │   ← this repository
│  /opt/caddy/Caddyfile    │
│    import conf.d/*.caddy │
└───────────┬──────────────┘
            │  docker network: caddy_net
            ├──────────────► frontend:3000
            └──────────────► app:8080
```

Each project ships one file in `/opt/caddy/conf.d/`. Caddy imports the whole
directory, so adding a project means adding a file and reloading — you never
edit the shared config, and one project's mistake cannot break another's route.

Projects reach the proxy by joining `caddy_net` in their compose file. Nothing
of theirs is published to the host.

---

## Setup, once per machine

```bash
git clone git@github.com:gazon1/Caddy-vps.git
cd Caddy-vps

pipx install ansible-core ansible-lint
pipx inject ansible-core requests        # community.docker needs it at runtime
ansible-galaxy collection install -r requirements.yml
```

The `requests` line is not optional. `community.docker` imports it, and without
it the run dies with *"Failed to import the required Python library (requests)"*.

Then tell it where your server is — open `inventory/hosts.yml` and fill in
`ansible_host` and `ansible_user`.

## Using it, once per server

```bash
just bootstrap
```

That is the whole first-time install. It is safe to run again at any time: a
second run changes nothing, because everything is declarative.

Requires on the VPS: `docker` with the **compose v2 plugin**. Nothing else —
no Python, no Ansible on the server.

## Adding a project

Write the route snippet, then apply it:

```bash
just route myproject deploy/myproject.conf.caddy
```

```caddy
myproject.example.com {
    encode zstd gzip
    @api path /api/* /health/*
    reverse_proxy @api app:8080
    reverse_proxy frontend:3000
}
```

The snippet is backed up, validated, and only then reloaded. If Caddy rejects
it, the previous version is restored and the run fails loudly — the proxy
never ends up holding a config it cannot load.

Validation only proves the configuration *loads*. It cannot tell you the
upstream exists, so add a reachability probe when you want that checked too:

```bash
just route myproject deploy/myproject.conf.caddy \
  -e caddy_route_url=https://myproject.example.com/api/health/live
```

The run now also makes a real request and fails if the route does not answer.
It is opt-in because the application is not always up yet at the moment a
route is registered, and a mandatory probe would fail for reasons that have
nothing to do with the route being correct.

A route is always a file — there is no second way to describe one. TLS belongs
to that file too: leave `tls` out for a Let's Encrypt certificate, or write
`tls internal` for a self-signed one. Nothing global forces one mode on every
project, so a site without a domain can sit next to one that has it.

## Commands

| Command | What it does |
|---|---|
| `just` | this list |
| `just bootstrap` | install or repair the proxy (idempotent) |
| `just route <name> <file>` | apply one route snippet, with backup and rollback |
| `just status` | read-only: container, config validity, routes, modules |
| `just lab-test` | prove all of the above locally, without touching the VPS |
| `just wbshop-deploy` | deploy full wbshop stack: adsbrowser → parser → migrations → wbshop |

## Deploying wbshop (full stack)

The `wbshop.yml` playbook deploys in order:
1. **adsbrowser** — headless browser for parser automation
2. **wbparser** — parser container with rollback on failure
3. **Flyway** — baseline + migrate on shared database
4. **wbshop** — product-catalog container
5. **Caddy route** — publish the route

**When to use this:**
- Need to update the parser (wbparser)
- Need to run database migrations
- First-time setup of the full stack

**For wbshop-only updates** (no parser, no migrations), use the GitHub Actions
"Deploy to VPS" workflow in the wbshop repository instead.

### Usage

```bash
# From the wbshop repository:
just ansible-deploy <tag>

# Or from Caddy-vps directly:
cd ~/Caddy-vps
just wbshop-deploy \
    -e "wbparser_tag=<sha>" \
    -e "wbshop_tag=<sha>" \
    -e "wbparser_compose_src=/path/to/wb-parser/deploy/docker-compose.vps.yml" \
    -e "wbshop_compose_src=/path/to/wbshop/docker-compose.yml"
```

### Required environment variables

```bash
export WBPARSER_DB_PASSWORD="..."       # PostgreSQL password
export WBPARSER_ADMIN_PASSWORD="..."   # Parser admin password
export WBPARSER_ADMIN_API_KEY="..."    # Parser API key
# The catalog API's key. Required: the application refuses to start without
# it, and the deploy refuses without it too. It is a comma-separated list, so
# a key can be rotated without a gap in service — the new key is added first,
# the storefront is switched over, and only then is the old one removed.
export WBPARSER_CATALOG_API_KEY="..."
```

### Tags

```bash
# Full stack (all plays)
just wbshop-deploy -e "wbparser_tag=<sha>" -e "wbshop_tag=<sha>"

# Flyway migrations only
just wbshop-deploy --tags flyway ...

# wbshop only (no parser)
just wbshop-deploy --tags wbshop ...

# Dry-run
just wbshop-deploy ... -- --check --diff
```

## Deploying the crawler from GitHub Actions

The manual way to ship the crawler is `just wbparser-deploy` with the secrets in
the environment. That needs a machine that can reach the VPS, and it puts a key
into a shell history. The **Deploy wb-parser** workflow does the same thing
from a GitHub runner, which reaches the VPS, and keeps the secrets in the
repository instead of in a shell.

One dispatch does it:

```bash
gh workflow run deploy-wbparser.yml \
  -R gazon1/Caddy-vps \
  -f tag=<sha> \
  -f check_only=false
```

…or use the **Actions → Deploy wb-parser → Run workflow** form.

### Inputs

| Input | Required | Default | What it means |
|---|---|---|---|
| `tag` | yes | — | tag or sha of the crawler image to deploy. The role resolves it to a digest and deploys *that* — a tag can be moved, a digest cannot |
| `crawler_ref` | no | `main` | ref of `gazon1/wb-parser-kotlin-new` the compose file is taken from (`deploy/docker-compose.vps.yml`). The application repository owns that contract, so it is not copied here |
| `check_only` | no | `true` | dry run: show what would change, apply nothing |
| `status_only` | no | `false` | read-only inspection of the VPS instead of a deploy |

### Repository secrets

| Secret | Needed for | Meaning |
|---|---|---|
| `VPS_HOST`, `VPS_USER`, `VPS_PORT` | every run | where the VPS is and as whom to enter it |
| `VPS_SSH_KEY` | every run | the private key the runner authenticates with. The host key is pinned with `ssh-keyscan`, so verification stays on |
| `WBPARSER_CATALOG_API_KEY` | deploy | the catalog API's key. The role refuses to deploy without it, and the application refuses to start without it |
| `WBPARSER_DB_PASSWORD` | deploy | the crawler's database password |
| `WBPARSER_ADMIN_PASSWORD` | deploy | the admin API's password |
| `WBPARSER_ADMIN_API_KEY` | deploy | the AdsPower Local API key — the browser runtime starts the API with it and the crawler authenticates against it with it |
| `WBPARSER_GHCR_USER`, `WBPARSER_GHCR_TOKEN` | optional | only for a private image |

The keys travel in the environment, never on a command line: the role reads
them with `lookup('env', …)`, and a `-e key=value` would put them in the shell
history and in the CI log. The workflow checks that they exist **before** it
touches the VPS, so a missing secret is a one-line error instead of a failed
deploy.

`VPS_USER` must be a user that can `sudo` without a password — the deploy
writes into `/opt`, which belongs to `root`.

### What each mode does

`status_only=true` runs `playbooks/status.yml` and nothing else: the container
state, whether the running configuration is valid, which routes are installed,
when the certificates expire. It applies nothing — the workflow skips the
`caddy_infra` and `caddy_routes` tags, which are the parts of the role that
re-render the base configuration and reload Caddy.

`check_only=true` adds Ansible's `--check`: the playbook is evaluated, the
changes are shown, and nothing is applied. **Known limitation:** the `wbparser`
and `adsbrowser` roles are not written for check mode — they read the result of
a probe that check mode skips — so the dry run stops early with an error about
an undefined result instead of printing a complete diff. Nothing is applied
when that happens. Use `status_only` to look at production, and treat
`check_only=false` as the real thing.

`check_only=false` is the deploy. It is a deliberate choice, made by a person
in the dispatch form.

## Configuration

Defaults live in `roles/caddy/defaults/main.yml`; anything can be overridden
per host in `inventory/group_vars/vps.yml` or on the command line with `-e`.

| Variable | Default | Meaning |
|---|---|---|
| `caddy_base` | `/opt/caddy` | root of the installation |
| `caddy_conf_d` | derived | where route snippets live |
| `caddy_container` | `caddy_global` | container name |
| `caddy_network` | `caddy_net` | network projects join |
| `caddy_http_port` / `caddy_https_port` | `80` / `443` | **host** ports |
| `caddy_image` | `caddy:2.8-alpine` | pinned on purpose — floating tags make deploys unreproducible |
| `caddy_acme_email` | — | Let's Encrypt account address |
| `caddy_backup_ttl` | `5` | snippet backups kept per snippet |
| `caddy_publish_admin` | `false` | expose the admin API on host loopback for debugging |
| `caddy_route_url` | *(empty)* | after applying a route, request this URL and fail if it does not answer |
| `caddy_log_max_size` / `caddy_log_max_file` | `10m` / `5` | proxy log retention |

## Certificates

TLS is chosen per snippet, not globally. A site block with no `tls` directive
gets a real Let's Encrypt certificate over HTTP-01, so its address must be a
real domain with an A record pointing at the server. Adding `tls internal`
gives that one snippet a self-signed certificate instead — useful for testing
or when there is no domain yet, but browsers will warn. Both kinds can be
served by the same proxy at the same time.

Certificates live in `/opt/caddy/data`. **That directory must never be
deleted or pruned.** Losing it forces every certificate to be reissued and
burns through the Let's Encrypt rate limit.

Caddy automatically renews them, and you should never force a reissue from
outside: repeating an issuance Caddy is already about to make burns the
Let's Encrypt rate limit, which is how every certificate for a domain gets
taken down at once.

What deserves monitoring is a renewal that has **silently stopped working** —
no route to the ACME endpoint, port 80 blocked, DNS no longer pointing here, or
the host down during the attempt. Caddy then keeps serving the old certificate
until a browser refuses the connection.

```bash
just cert-check          # fails when a certificate is within 21 days of expiry
just cert-check -- -e cert_expiry_warning_days=30
```

Read-only: it reads the PEMs Caddy stored and writes nothing on the server.
It deliberately does not use `status.yml`, which pulls in the whole role and
re-renders the base configuration.

Note that the caddy image ships without `openssl`, so the expiry is parsed with
the Python that Ansible already requires. `status.yml` still reports
"expiry unreadable" for the same reason — prefer `cert-check` for this.

## Testing changes without the VPS

```bash
just lab-test
```

Provisions a throwaway proxy under `/tmp/caddy-lab` on non-standard ports,
then checks that a first run works, that a second run changes nothing, that an
invalid snippet is rejected and rolled back, and that the proxy keeps serving
the previous route throughout. ACME is never contacted.

## Repository layout

```
site.yml                 the one entry point
playbooks/status.yml     read-only inspection (see the caveat in Certificates)
playbooks/cert-check.yml read-only: certificate expiry, safe to schedule
roles/caddy/             the role: tasks, templates, handlers
inventory/               where the servers are, and their defaults
tests/lab.sh             local verification suite
docs/RUNBOOK.md          when something breaks
```

## When something breaks

Start with `just status` — it reports the container state, whether the running
configuration is valid, which routes are installed, and which non-standard
modules are compiled in. It never changes anything.

For rollbacks, certificate problems and recovery procedures, see
[docs/RUNBOOK.md](docs/RUNBOOK.md).