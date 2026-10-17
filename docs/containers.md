# Containers

How the application runs as a Docker Compose stack, and how it gets from the
systemd deployment to that. The decision and its reasons are in
[ADR 0009](adr/0009-containers-on-a-shared-server.md). This is how the
application has run since 17 October 2026; the systemd deployment it replaced
is described in [running](running.md) and survives only as the showcase's host.

## State of the work

| Piece | State |
| --- | --- |
| `Dockerfile`, `compose.yaml`, `deploy/compose.edge.yaml` | written; built and started in CI by the Container workflow |
| `deploy/edge/` (the proxy stack) | **running since 17 October 2026** in `/opt/edge`: it serves both projects, obtained the dashboard's certificate from Let's Encrypt within a minute, and the other project's site was unreachable for four seconds during the handover plus six during its one restart |
| `deploy/containers/` (host units for the timers) | **installed at the cutover, 17 October 2026**: the eleven timers fire and the backup service succeeds |
| `deploy/container-release.sh` and `container-release-remote.sh` | **in use**: the first real run deployed a0bd82a9, the second rolled itself back as designed, the third deployed 42767990; the server side is still rehearsed in CI on every change |
| Backup through the container (`scripts/backup.sh` with `BACKUP_DATABASE_VIA=compose`, `deploy/containers/private-finances-backup.service`) | **running daily on the container host since 17 October 2026**, proven as a service after its first run failed for the working-directory reason below; still exercised in CI ([backups](backups.md)) |
| Showcase in a container | not planned yet; it stays on the old host until decided |
| Restore proof on the new host from the bucket | not done; the shadow was loaded from a direct dump, not from the bucket |
| Shadow installation on the destination server | **done 16 October 2026**; see "The shadow, as installed" below |
| Edge takeover and the domain | **done 17 October 2026**; the other project's change is on its `main` and marked as its deployed commit |
| Cutover | **done 17 October 2026, 00:40–01:15 Riga time**; see "The cutover, as it went" below |
| Leaving the old host | `deploy/decommission-old-host.sh` written and dry-run on 17 October 2026; the owner chose to run it the same day rather than keep the two-week rollback; see "Leaving the old host" below |

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

`deploy/edge/compose.yaml` runs one Caddy that owns ports 80 and 443 on the
Docker network `edge`, which is created once by hand and belongs to the host.
`deploy/compose.edge.yaml` is the override that joins the dashboard to it under
the alias `private-finances`; the Caddyfile proxies the dashboard's name to
`private-finances:3300`, adds HSTS and leaves the `Host` header alone because
the application checks it against `PUBLIC_ORIGIN`. The dashboard's hostname
comes from `deploy/edge/.env` on the server. On the server the dashboard is
started with both files through `COMPOSE_FILE` in `/opt/private-finances/.env`.

The same Caddyfile carries the other project's site blocks, copied verbatim
with only the upstream renamed, and the edge Caddy mounts that project's
certificate, config and media volumes under their old names, so nothing is
re-issued and its access log continues. Who owns what, the takeover sequence
with its seconds of downtime, and the rollback are in
[the edge README](../deploy/edge/README.md). The other project's side — its
`caddy` service removed, its app joined to `edge` as `hlyna` — is prepared as
a commit in that repository and is deployed only with the owner, as that
repository's rules require.

The takeover happened on 17 October 2026, in the order the README gives.
One thing went wrong on the way and was fixed within minutes: the other
project's new compose file had lost its top-level `secrets:` line in
preparation (a filtered read had hidden it), so its first `compose up` was
refused by validation — which left its running app untouched and still
reachable, exactly the failure mode the live network join was chosen for.
The line was restored, the amended commit applied, and its app recreated
once. Since then the shadow dashboard answers at its public name over HTTPS
with HSTS, 200 on the sign-in page and 401 on the API without a session;
the other project's site, its media files and its redirects answer as before.

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
   Telegram worker is stopped if it was running, and a running worker
   container is waited for up to five minutes. From the first stop on, every
   exit resumes what was running — and only that, so a shadow's stopped
   worker stays stopped.
7. **The switch.** `compose.yaml`, the edge override and the retention rule are
   installed into the compose directory; a host unit that exists and changed
   is refreshed; `PF_RELEASE` in `.env` is rewritten atomically; `app` and
   `telegram` — or only what `PF_SERVICES` in `.env` names — are recreated
   and waited for. If the new release does not
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

## The shadow, as installed

Installed on 16 October 2026 on the destination server, reached as the SSH
alias `hlyna`. Everything below was done by hand once; the container release
script takes over from here.

- **Host.** Ubuntu 24.04, Docker 29 with Compose 2.40. Added that day:
  `docker-buildx` (the Dockerfile's cache mounts need BuildKit, which the
  legacy builder refuses) and `restic` 0.16.4. The other project's three
  containers were not touched; `docker builder prune` had freed about 75 GB
  the same day, by the owner.
- **Account and directories.** `private-finances` with the same uid and gid
  as on the old host (997:986), so the copied credentials kept their owners.
  `/opt/private-finances` holds `compose.yaml`, `deploy/compose.edge.yaml`,
  `deploy/local-backup.py`, `scripts/backup.sh` and `.env` (`PF_RELEASE`,
  `PF_UID`, `PF_GID`; no `COMPOSE_FILE` yet, the edge is not up).
  `/var/lib/private-finances/{consent,sync,predeploy}` as the stack expects.
- **Configuration.** `/etc/private-finances` was copied directly from the old
  host over SSH through the operator's machine, never stored in between, with
  three omissions: `schedules/` is an empty directory, `telegram.env` is an
  empty file, and `telegram.enabled` was not copied. So no timer could touch a
  bank even if one were installed, and the Telegram worker has no token. The
  two restore-verified markers were removed: nothing has been proved on this
  host yet. `db.env` was created with a generated password and `DATABASE_URL`
  in `app.env` rewritten to the container form; every other key is as on the
  old host, including the dashboard's own Telegram and OpenAI settings — the
  dashboard uses them only on a signed-in person's action.
- **Image and data.** `private-finances:a38d35ae…` was built from the
  archive of that commit on the host. A dump of the live database
  (8.3 MB, taken 20:55 UTC) was streamed into
  `/var/lib/private-finances/predeploy/shadow-20261016T205535Z.dump` and
  restored with `--exit-on-error` into the fresh `db` container before the
  dashboard first started, so the schema came from the dump, not from a
  migration of an empty database.
- **Verified.** `db` and `app` healthy; `/health/ready` answers with the
  release; schema version 68; 4,424 transactions. All 52 tables were counted
  on both hosts: identical except `bank_import_windows` and
  `bank_sync_attempts`, each one row higher on the live host because an import
  ran after the dump. The dashboard listens on the host's loopback only,
  returns the sign-in page on `/` and 401 on an API call without a session.
  Memory in use: about 27 MB for the dashboard and 73 MB for the database.
- **Not running on the shadow.** `telegram`, every timer, the backup. Nothing
  on this host contacts a bank, Telegram or the bucket. Two guards keep it
  so, added on 17 October 2026 after noticing that the bot token's path is in
  `app.env`, which the Telegram worker also reads: the shadow's `telegram.env`
  overrides `TELEGRAM_BOT_TOKEN_FILE` with a path that does not exist, and its
  `.env` says `PF_SERVICES=app`, so a release recreates the dashboard only and
  never starts the worker. Both are removed at cutover. Not verified: signing
  in and using the screens (the owner's passwords are not read by agents); the
  consent state directory was not copied and will be at cutover.
- **Name resolution.** The host's own resolver answers SERVFAIL for the
  broker's statement host (an Akamai-fronted name) while every public resolver
  answers it, which made the assets feed check fail there with a transient
  error. The stack's application containers therefore use public resolvers
  (`dns:` in `compose.yaml`); the host and the other project are untouched.

To look at it: `ssh -L 3300:127.0.0.1:3300 hlyna`, then http://localhost:3300.
Nothing done on the shadow reaches the household: a classification made there
is lost at cutover, when the database is loaded again from the final dump.

## Moving, without breaking the running system

The current server keeps running throughout and stays intact for two weeks
after the cutover as the rollback. Two instances must never import from banks
or poll Telegram at the same time; the order below exists for that reason.

1. **Shadow.** Done, as described above. Still open from it: the owner signs
   in over the tunnel and compares the screens with the live dashboard.
2. **Edge.** Done on 17 October 2026: A record, takeover, certificate. The
   shadow is now the dashboard at its public name, still without timers,
   Telegram or markers.
3. **Keys that know the old server's address.** The Binance read-only key
   used by the assets feed is restricted to the server's address
   ([credentials](credentials.md)); the owner added the new server's address
   to it on 17 October 2026, keeping the old one until after the cutover, and
   the feed check from the new server then read Binance successfully. **The
   IBKR Flex Web Service token is restricted by address too**: the same check
   from the new server fails with the service's error 1013 while the old
   server reads the broker, and nothing in this repository had recorded the
   restriction. The owner adds the new address in Client Portal before
   cutover. The proof is one command on the new host, writing nothing:
   `docker compose --profile tools run --rm worker node dist/src/holdings-snapshot-cli.js --check`.
   Checked and found unrestricted by address: the backup bucket's IAM policy
   (scoped to the bucket, no source condition), Monobank's personal tokens,
   the OpenAI key and the Telegram bot. Enable Banking knows the redirect URL,
   not the address; that is the next item.
4. **Bank provider.** Register the new callback,
   `https://<new domain>/connections/enablebanking/callback`, in the Enable
   Banking control panel alongside the old one ([bank consent](bank-consent.md)).
   Consents are approved again by each owner after the cutover; the restored
   PEM keys and tokens are what carry over.
5. **Cutover, one sitting.** `deploy/cutover-to-containers.sh`, described
   under "The cutover" below. Each owner then re-approves their banks through
   Bank connections if a consent has lapsed. The Telegram links in reports
   carry the new domain from then on.
6. **Afterwards.** Install `backup.env` and the restic password on the new
   host, run the backup once by hand and prove the restore as in
   [backups](backups.md). Remove the old callback from the bank provider.
   Remove the old server's address from every key that was allowed it.
   Record the new host in `~/.config/private-finances/server-access.md` and a
   new SSH alias; update [server requirements](server-requirements.md) and
   [running](running.md) to describe the container host. Only then disable
   the old server's units.

## The cutover

`deploy/cutover-to-containers.sh <old host> <new host> <released sha>` does
the move from the operator's machine in one sitting, verifying each step and
stopping at the first failure without undoing anything by itself, because
the right rollback depends on where it stopped:

1. Old host: every `private-finances` timer, the Telegram worker and the
   dashboard are disabled and stopped (the list is kept in
   `/etc/private-finances/cutover-disabled-units` there); a running import is
   waited for up to five minutes. The showcase stays.
2. Old to new: the final dump, the schedule markers, `telegram.env` and
   `telegram.enabled`, and the bank-session state directory.
3. New host: the dashboard stops, the database is dropped and created again,
   the dump is loaded with `--exit-on-error`, every table's row count is
   compared with the old host and must match, the `local-restore-verified`
   marker is written on that evidence, the shadow guards are removed, the
   dashboard starts.
4. New host: the Telegram worker starts; the container host units, the timers
   and the per-bank drop-ins are installed; `backup.env` loses its socket
   settings; the same timers the old host had are enabled; the backup runs
   once and its row is shown.

### The cutover, as it went

Four attempts on the night of 16–17 October 2026, each stopping where it
said it would and none undoing anything; the household was without a live
system for about fifty minutes in between, longer than planned.

1. The first run (the owner's, from this script) waited five minutes for an
   import on the old host that did not finish and stopped with the old host
   already disabled. The script now accepts an old host that an earlier
   attempt stopped and never shortens the recorded unit list.
2. The second run reached step 3, emptied the new database and loaded
   nothing: the remote steps travelled on stdin and the first `docker compose`
   command swallowed the rest. Remote steps now travel as arguments and the
   stdin-reading commands get `</dev/null` besides.
3. The third and fourth runs stopped in preflight on checks that assumed a
   fresh start (the dashboard answering; the Telegram guard still in place).
   Both checks now tolerate a resumed run.
4. The fifth run went through: dump of 8.3 MB, 13 markers, the real
   `telegram.env`, 5 bank-session files; restored with `--exit-on-error`;
   all 52 tables' row counts equal on both hosts; marker written; dashboard
   ready at release a0bd82a9; Telegram worker polling within twenty seconds;
   11 timers enabled. The five Enable Banking imports succeeded at their
   first firing with the consents carried over, so no re-approval was needed
   that night; the two Monobank imports were still running when this was
   written.

The first release after the cutover, carrying these fixes, rolled itself
back as designed: `compose up --wait` refuses a service that has no health
check, which the Telegram worker now deliberately has not, so the switch was
judged failed and the previous image came back within the minute while the
updated backup script and unit stayed installed. The script now starts the
services plainly and reads readiness from the dashboard and the container
states. The rollback path had never run before; it worked.

The backup's first run as a service failed at the dump stage, although the
same script succeeds by hand: `COMPOSE_FILE` in the stack's `.env` names its
files relative to the current directory, and a service starts in `/`. The
script now enters the compose directory and the unit sets
`WorkingDirectory`; both reach the host with the next release.

**Rollback**, for as long as the old host is untouched: on the new host
`systemctl disable --now` the timers listed in its `timers.target.wants`,
`docker compose stop telegram app`; on the old host
`systemctl enable --now $(cat /etc/private-finances/cutover-disabled-units)`.
Anything the household did on the new host after the cutover — a
classification, an import — exists only there; dump it with the container
backup and load it on the old host before enabling, or accept the loss.

## Leaving the old host

The plan kept the old host untouched for two weeks as the rollback. On
17 October 2026, with every import succeeded at least once from the new host,
the backup proven as a service, the broker and exchange feeds read from the new
address and the second release deployed, the owner chose to remove the old
installation the same day. `deploy/decommission-old-host.sh <old> <new>` prints
what it would remove and refuses unless the new host serves the household (the
dashboard ready, `app`, `db` and `telegram` running, the timers enabled) and
the old host is the one the cutover stopped (its disabled-units list present
and every unit on it inactive). With `--execute` it first streams one last
dump of the old database into the new host's `predeploy` directory and checks
that the archive lists the tables, then removes, on the old host: the units
the cutover disabled and their drop-ins, the local backup unit, the Tailscale
mapping of the old dashboard, the `private_finances` database and its role,
everything under `/etc/private-finances` except `showcase.env`, the consent,
sync and local-backup directories, the contents of the account's home
directory (golden files, operations notes, pre-deployment dumps), and every
release except the one the showcase runs. The showcase, its reseed units, its
state directory, the account it runs as, PostgreSQL itself and the other
projects on that host are not touched — unless `--with-showcase` is given,
which the script accepts only while the new host's own showcase answers, and
which then also removes the showcase's units and Tailscale mapping, its
state, the whole release and configuration directories and the account, so
that nothing of this project is left on the old host. The journal keeps the units' logs,
which by the logging rule carry no financial descriptions; it is shared with
the other projects and is left alone.

From then on there is no rollback to the old host. A failure of the new host
is answered by [backups](backups.md): the bucket holds the database and
configuration snapshots of both hosts, and the new host also keeps the
cutover dump and this final dump under `/var/lib/private-finances/predeploy`.
The two owner-side leftovers are the old server's address on the Binance key
and the old callback URL in the Enable Banking panel; both are removals the
owner makes in those consoles.

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
