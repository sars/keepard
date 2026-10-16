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

`PF_COMPOSE_DIR` is where `compose.yaml` and its `.env` (PF_RELEASE, PF_UID,
PF_GID) live on the host, `/opt/private-finances` by convention. The units run
as root because the Docker socket is root-equivalent; the job inside the
container runs as the private-finances account through compose's `user:`.

Status: written, not installed anywhere. See [containers](../../docs/containers.md).
