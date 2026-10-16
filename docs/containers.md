# Containers

How the application runs as a Docker Compose stack, and how it gets from the
systemd deployment to that. The decision and its reasons are in
[ADR 0009](adr/0009-containers-on-a-shared-server.md). Nothing described here is
deployed: the live server still runs the systemd units in [running](running.md).

## State of the work

| Piece | State |
| --- | --- |
| `Dockerfile`, `compose.yaml`, `deploy/compose.edge.yaml` | written; built and started in CI by the Container workflow |
| `deploy/edge/` (the proxy stack) | written; not run anywhere |
| `deploy/containers/` (host units for the timers) | written; not installed anywhere |
| `deploy/container-release.sh` and `container-release-remote.sh` | written; the server side is rehearsed in CI on every change against the stack it just started; never run against a server |
| Backup through the container | not written |
| Showcase in a container | not planned yet; it stays on the old host until decided |
| Shadow installation on the destination server | not started |
| Cutover | not started |

## The stack

`compose.yaml` at the repository root defines one project, `private-finances`:

| Service | What | Started by |
| --- | --- | --- |
| `db` | PostgreSQL 16, volume `pgdata`, no published port | `docker compose up` |
| `app` | the dashboard, `node dist/src/main.js`, loopback port 3300 | `docker compose up` |
| `telegram` | the Telegram worker, `node dist/src/telegram-cli.js` | `docker compose up` |
| `worker` | profile `tools`; one short-lived container per scheduled job | the host's systemd timers |

The image is built from the `Dockerfile`: Node 24.19 as `.nvmrc` says, pnpm
11.19.0 as `package.json` pins, poppler-utils for PDF receipts, production
dependencies only, the built `dist/` tree and the `.mjs` scripts. It carries no
configuration. `PF_RELEASE=<sha> docker compose build` tags it with the commit
and the dashboard reports that value as its release.

Every application container runs as `PF_UID:PF_GID`, read-only, with all
capabilities dropped and `/tmp` on a tmpfs, and mounts:

| Host path | In the container | Why |
| --- | --- | --- |
| `$PF_CONFIG_DIR` (`/etc/private-finances`) | `/etc/private-finances`, read-only | `app.env`, `sync.env`, `telegram.env`, `db.env`, `credentials/`, `schedules/` — the same files at the same paths as [credentials](credentials.md) documents |
| `$PF_STATE_DIR/consent` (`/var/lib/private-finances/consent`) | `/var/lib/private-finances-consent` | the bank-session secrets the consent flow writes |
| `$PF_STATE_DIR/sync` (`/var/lib/private-finances/sync`) | `/var/lib/private-finances-sync` | the scheduler's state, `worker` only |

The dashboard listens on the loopback interface unless `BIND_ADDRESS` says
otherwise; compose sets it to the container's every address, and publishes the
port on the host's loopback only. The variable did not exist before this
change and the systemd units do not set it, so nothing changes for them.

`db.env` is new: it holds `POSTGRES_PASSWORD`, and `DATABASE_URL` in `app.env`
becomes `postgresql://private-finances:<that password>@db:5432/private_finances`.
Peer authentication over the socket does not cross a container boundary.

The variables compose reads from `.env` next to `compose.yaml` on the host:
`PF_RELEASE`, `PF_UID`, `PF_GID`, and optionally `PF_CONFIG_DIR`,
`PF_STATE_DIR` and `PF_PORT`. The CI job sets the same variables to a
throwaway directory under the runner's temp folder.

## The edge

`deploy/edge/compose.yaml` runs one Caddy that owns ports 80 and 443 and creates
the Docker network `edge`. `deploy/compose.edge.yaml` is the override that joins
the dashboard to it under the alias `private-finances`; the Caddyfile proxies
`$PF_DOMAIN` to `private-finances:3300`, adds HSTS and leaves the `Host` header
alone because the application checks it against `PUBLIC_ORIGIN`. Hostnames
come from `deploy/edge/.env` on the server; the example file carries
`example.com`. On the server the dashboard is started with both files:

```sh
docker compose -f compose.yaml -f deploy/compose.edge.yaml up -d
```

The other project on the destination server has its own Caddy today. Moving it
into the edge is a change to that project: its site blocks move into this
Caddyfile, its stack drops the `caddy` service and joins `edge` under its own
alias, and its certificate volume is attached to the edge Caddy so nothing is
re-issued. That happens when this project arrives, not before.

## The timers

`deploy/containers/` holds the host units whose `ExecStart` is
`docker compose --profile tools run --rm worker <job>`. The `.timer` files, the
per-bank `timer.d` drop-ins and the markers under `/etc/private-finances/schedules`
are those of the systemd deployment, unchanged; see [scheduling](scheduling.md).
The marker check inspects ownership and mode, and a bind mount preserves both.

## The release

```sh
bash deploy/container-release.sh <40-character commit sha> <ssh host> [--allow-rollback]
```

The host is named every time, because during the move two servers exist. The
script is the container counterpart of `deploy/release.sh` and keeps its gates
in the same order; what changed is the commands, and one source of evidence:

1. **The commit** is on `origin/main`, and the running release, read from
   `/health/ready` through SSH, is an ancestor of it unless `--allow-rollback`
   is passed. A host whose release is not a commit at all — a shadow started
   with the default tag — is treated as receiving its first release.
2. **The checks GitHub ran.** The systemd release runs the test suite on the
   server; the container host has no development dependencies, so the script
   asks GitHub, through `pf-gh`, whether "Application checks" and "Image and
   stack" completed successfully for that exact commit, and refuses otherwise.
3. **The archive** is `git archive` of the commit, copied with its SHA-256,
   verified on the host before anything is built.
4. **The image** is built on the host from that archive and tagged
   `private-finances:<sha>`.
5. **The rehearsal.** The live database is dumped through the `db` container
   into the pre-deployment directory, restored into a scratch database inside
   the same container, and the new image runs the migration there and reports
   schema version and the same counts the systemd release prints. The scratch
   database is dropped on every exit once it has been created.
6. **The pause.** The enabled `private-finances-sync@` timers are stopped, the
   Telegram worker is stopped, and a running worker container is waited for up
   to five minutes. From the first stop on, every exit resumes both.
7. **The switch.** `compose.yaml`, the edge override and the retention rule are
   installed into the compose directory; a host unit that exists and changed
   is refreshed; `PF_RELEASE` in `.env` is rewritten atomically; `app` and
   `telegram` are recreated and waited for. If the new release does not
   answer with its SHA, `.env` goes back and the previous image is brought up
   again before the script fails.
8. **Verification** prints the release, schema version, transaction count and
   service states, and fails unless the dashboard answers with the new SHA.
9. **Pruning**, only after success and never fatal: pre-deployment dumps by
   the rule `local-backup.py` defines, images beyond the newest ten except the
   live one and its predecessor, dangling layers, and the BuildKit cache held
   to ten gigabytes.

The server side is `deploy/container-release-remote.sh`, which the orchestrator
copies over and runs as root. CI runs that same script on every change against
the stack it has just started, so the rehearsal, the switch and the rollback
path are exercised before any host sees them; the orchestrator's own checks
need this machine's Git and GitHub access and are not rehearsed there.

Two things the systemd release does that this one does not, yet:

- **Open browser tabs across releases.** The systemd switch copies the previous
  release's fingerprinted frontend files into the new tree so a tab opened
  before the switch can still load them. An image is immutable; a tab opened
  before a container release may fail to load a chunk until it is reloaded.
  Acceptable for a household; recorded so it is not forgotten.
- **Deploy lock.** Two releases at once are prevented by the running-release
  check, not by a lock file. The systemd script holds one in
  `/var/lib/private-finances/deploy.lock`.

## Moving, without breaking the running system

The current server keeps running throughout and stays intact for two weeks
after the cutover as the rollback. Two instances must never import from banks
or poll Telegram at the same time; the order below exists for that reason.

1. **Shadow.** On the destination server, after `docker builder prune` has
   freed its disk: create the private-finances account, `/opt/private-finances`
   with `compose.yaml`, `.env`, `/etc/private-finances` restored from the
   backup bucket ([backups](backups.md)), and the state directories. Start
   `db` and `app` only, with no schedule markers and no `telegram.env`. Restore
   the latest dump into `db`. Sign in over an SSH tunnel and compare the
   figures with the live dashboard.
2. **Edge.** Point the new domain at the server, start the edge stack, move
   the other project's Caddy into it, start the dashboard with the edge
   override. `PUBLIC_ORIGIN` on the shadow is the new origin from here on.
3. **Bank provider.** Register the new callback,
   `https://<new domain>/connections/enablebanking/callback`, in the Enable
   Banking control panel alongside the old one ([bank consent](bank-consent.md)).
   Consents are approved again by each owner after the cutover; the restored
   PEM keys and tokens are what carry over.
4. **Cutover, one sitting.** On the old server: stop the sync timers, wait for
   imports, stop the Telegram worker, take a final dump. On the new server:
   restore it, create the schedule markers, add `telegram.env`, start
   `telegram`, enable the timers. Each owner re-approves their banks through
   Bank connections. The Telegram links in reports now carry the new domain.
5. **Afterwards.** Install `backup.env` and the restic password on the new
   host, run the backup once by hand and prove the restore as in
   [backups](backups.md). Remove the old callback from the bank provider.
   Record the new host in `~/.config/private-finances/server-access.md` and a
   new SSH alias; update [server requirements](server-requirements.md) and
   [running](running.md) to describe the container host. Only then disable
   the old server's units.

## Security, stated plainly

- Secrets are files on the host that root owns; containers see them read-only,
  at the same paths, as the private-finances account. No secret is in the
  image, in Git, or in a Compose file.
- The dashboard is published on the loopback interface only; the edge is the
  only process on the public ports, and it speaks to the dashboard over an
  internal network.
- Sign-in is unchanged: per-address and per-caller delays, thirty-day sessions
  in the database, `Secure` and `SameSite=Lax` cookies, a `Host` check. The
  proxy adds HSTS. A second factor remains the open gap PF-021 names.
- The database has no published port; it is reached through
  `docker compose exec db psql -U private-finances private_finances`.
