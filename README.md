# GLPI + Traefik + Let's Encrypt — Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/glpi-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/glpi-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Contents

- [Why this stack?](#why-this-stack)
- [Prerequisites](#prerequisites)
- [Getting started](#getting-started)
- [Features](#features)
- [Supply chain trust](#supply-chain-trust)
- [Production checklist](#production-checklist)
- [Backups](#backups)
- [Testing](#testing)
- [Security Notes](#security-notes)
- [About the maintainer](#about-the-maintainer)

This repository deploys **GLPI** (IT asset management + helpdesk) behind **Traefik** with automatic **Let's Encrypt TLS**, backed by **MariaDB 11.4 LTS**, with scheduled **backups** (database + application data) and companion **restore scripts**. One `docker compose up` away from an ITSM service at `https://your-domain`.

📙 Full narrative installation guide on the blog: [heyvaldemar.com/install-glpi-using-docker-compose/](https://www.heyvaldemar.com/install-glpi-using-docker-compose/).

## Why this stack?

| Need | This stack | Manual install | Other compose examples |
|------|-----------|----------------|------------------------|
| Ready to deploy in <10 min | ✅ | ❌ PHP + webserver + DB by hand | Often |
| TLS via Let's Encrypt, auto-renewed | ✅ Traefik ACME built-in | Manual certbot | Rare |
| MariaDB LTS wired with healthchecks | ✅ | Separate install | Varies |
| Scheduled DB + data backups + pruning | ✅ | Manual cron | Rare |
| Restore scripts included | ✅ two scripts | Manual | Rare |
| Upstream images pinned by `sha256` digest | ✅ | N/A | Rare |
| Weekly pin-freshness check in CI | ✅ | N/A | Rare |
| CI-verified deployment on every push | ✅ | N/A | Rare |
| Credentials via env (never committed) | ✅ | N/A | Often committed plaintext |

Four moving parts (Traefik + GLPI + MariaDB + backups). No Kubernetes prerequisites, no manual certificate management.

## Prerequisites

- **A Linux server** with a public IP. Tested on Ubuntu 22.04 LTS+ and Debian 12+.
- **Docker Engine 24+ and Docker Compose 2.20+.**
- **A domain you control,** with two `A` records pointing at your server's public IP — one for GLPI, one for the Traefik dashboard. DNS must propagate before deploy.
- **Ports 80 and 443 open** on the server's firewall.
- **~1 GB free RAM** for a small helpdesk, plus disk for attachments and backups.

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/glpi-traefik-letsencrypt-docker-compose
cd glpi-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create glpi-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ Required: GLPI_DB_PASSWORD, GLPI_DB_ADMIN_PASSWORD, GLPI_HOSTNAME,
#   TRAEFIK_HOSTNAME, TRAEFIK_ACME_EMAIL, TRAEFIK_BASIC_AUTH.

# 4. Deploy
docker compose -f glpi-traefik-letsencrypt-docker-compose.yml -p glpi up -d
```

Within a couple of minutes `https://${GLPI_HOSTNAME}` serves the GLPI setup wizard with a fresh Let's Encrypt certificate. Point the wizard at host `mariadb`, database `glpidb`, user `glpidbuser` with your `GLPI_DB_PASSWORD`. Default UI logins after setup (`glpi/glpi` etc.) must be changed immediately.

### What success looks like

```bash
# All services healthy:
docker compose -f glpi-traefik-letsencrypt-docker-compose.yml -p glpi ps

# Front page answers:
curl -fskL -o /dev/null -w "%{http_code}\n" "https://${GLPI_HOSTNAME}/"

# Traefik issued a certificate:
docker compose -p glpi logs traefik | grep -i "adding certificate"

# First backup lands after BACKUP_INIT_SLEEP (default 30m):
docker compose -p glpi logs backups | tail -3
```

### Common first-deploy issues

- **Cert issuance fails.** DNS hasn't propagated or port 80 isn't reachable from the internet.
- **`docker compose up` fails with `set in .env`.** A required variable is empty; the error names it.
- **`network glpi-network not found`.** Step 2 was skipped.

### Apply `.env` or compose-file changes

```bash
docker compose -f glpi-traefik-letsencrypt-docker-compose.yml -p glpi up -d --force-recreate
```

## Features

- **GLPI 11** — asset inventory, helpdesk tickets, contracts, knowledge base.
- **MariaDB 11.4 LTS** backing store with healthcheck and start-order dependency.
- **Traefik v3** with automatic HTTP→HTTPS redirect and Let's Encrypt TLS-ALPN certificate issuance.
- **Basic-auth protected Traefik dashboard** on a separate hostname.
- **Scheduled backups** of the database (`mysqldump | gzip`) and application data (`tar.gz`) with retention pruning, plus restore scripts for both.
- **Credentials required at deploy time** — compose fails fast if `.env` is incomplete.

## Supply chain trust

This repository is a **deployment template**, not a custom Docker image. It orchestrates three upstream images:

- [`traefik`](https://hub.docker.com/_/traefik) — reverse proxy, Docker Hub official image
- [`elestio/glpi`](https://hub.docker.com/r/elestio/glpi) — GLPI packaging by Elestio
- [`mariadb`](https://hub.docker.com/_/mariadb) — MariaDB, Docker Hub official image

All three are pinned to `tag@sha256:<digest>` as interpolation defaults in the compose file's `x-images` block — `git pull` alone delivers the version combination this repository has tested; an `*_IMAGE_TAG` variable in `.env` overrides deliberately.

The weekly `check-pin-freshness` CI job re-resolves each pinned tag against its registry and compares the pinned GLPI and Traefik versions against the latest upstream releases. CI runs on every push, pull request, and every Monday at 06:00 UTC. GitHub Actions are pinned by commit SHA; Dependabot keeps those fresh.

## Production checklist

- [ ] **Change the stock GLPI logins immediately after setup** (`glpi`, `tech`, `normal`, `post-only` all ship with known passwords).
- [ ] **Delete `install/` when the wizard tells you to** — GLPI warns until the installer is removed.
- [ ] **Strong secrets.** Both database passwords at 24+ random characters; regenerate the Traefik dashboard hash per deployment.
- [ ] **Host-mount the backup volumes** for disaster recovery.
- [ ] **Verify Let's Encrypt cert issuance** in the Traefik logs on first start.
- [ ] **Back up before upgrades** — GLPI migrates its schema on first start with a newer image.

## Backups

The `backups` container performs a dump → archive → prune → sleep loop: `mysqldump | gzip` of the GLPI database, `tar.gz` of the application data, pruning by retention windows, then sleeping `BACKUP_INTERVAL` (default 24h).

Each cycle logs `Database backup OK: <file> (<bytes> bytes)` or `Database backup FAILED` (the same for the data archive where there is one). A failed dump is kept as `<file>.failed` for diagnosis and never overwrites a good backup — grep the log for `FAILED` from your monitoring.

**Restore** with the interactive scripts (`chmod +x *.sh` once): `./glpi-restore-database.sh`, then `./glpi-restore-application-data.sh`.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/glpi-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every Monday at 06:00 UTC:

1. **Lint** — shellcheck on both restore scripts, actionlint on the workflow.
2. **Trivy scans** of all three pinned images (CRITICAL/HIGH, SARIF to the Security tab).
3. **Pin freshness** (weekly/manual) — digest drift plus release-lag checks for GLPI and Traefik.
4. **Deploy-and-test** — boots the full stack with ephemeral credentials and requires the front page to answer through Traefik.

A green run is the authoritative proof that the template deploys end-to-end.

## Security Notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and compose fails fast on missing required variables.
- **Pre-rotation advisory.** Releases before v1.0.0 (2026-08-31) shipped a tracked `.env` with generated-looking database passwords. Rotate them if your deployment reused them.
- MariaDB listens only on the internal network.
- Upstream image digests are pinned; the weekly freshness job flags drift loudly.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** — Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
