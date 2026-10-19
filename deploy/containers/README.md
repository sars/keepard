# Host units for the container deployment

These replace the `ExecStart` lines of the systemd units in the parent folder
when the application runs from `compose.yaml` instead of
`/opt/private-finances/current`. The timers, their per-bank drop-ins and the
schedule markers under `/etc/private-finances/schedules/` are unchanged: a job
still fires from systemd on the host, it just runs inside a short-lived
container of the release image. The dashboard and the Telegram worker have no
unit here because Compose keeps them running (`restart: unless-stopped`).

| Unit | Runs |
| --- | --- |
| `private-finances-sync@.service` | `node dist/src/schedule.js <instance>` in the `worker` service |
| `private-finances-fx-sync.service` | `node dist/src/fx-sync-cli.js` |
| `private-finances-reports.service` | `node dist/src/report-cli.js` |
| `private-finances-assets-snapshot.service` | `node dist/src/holdings-snapshot-cli.js --when=last-thursday` |
| `private-finances-showcase-nightly.service`, started by `../private-finances-showcase-nightly.timer` | `scripts/request-showcase-reseed.mjs` in the `showcase-reseed` service: leaves a refill request every night, which the reseed `.path` unit below picks up |
| `private-finances-showcase-reseed.path` and `.service` | `scripts/reseed-showcase.mjs` in the `showcase-reseed` service, with the showcase stopped around it, when the reseed page leaves a request file under `PF_STATE_DIR/showcase` |

`PF_COMPOSE_DIR` is where `compose.yaml` and its `.env` live on the host,
`/opt/private-finances` by convention. That `.env` carries `PF_RELEASE`,
`PF_UID`, `PF_GID` and `COMPOSE_FILE=compose.yaml:deploy/compose.edge.yaml`,
so every `docker compose` in that directory — a timer, the release script, an
operator — sees the same stack. `deploy/container-release-remote.sh` refreshes
these units when they change and rewrites `PF_RELEASE` at each switch. The units run
as root because the Docker socket is root-equivalent; the job inside the
container runs as the private-finances account through compose's `user:`.

Status: installed on the container host since the cutover of 17 October 2026 and refreshed by the release script. See [containers](../../docs/containers.md).
