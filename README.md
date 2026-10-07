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