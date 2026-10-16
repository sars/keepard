# ADR 0009: Containers on a shared server, behind one edge proxy

Date: 2026-10-16. Status: accepted; the image and the stack exist and are
exercised in CI, nothing is deployed from them yet. The running deployment is
still the systemd one described in [running](../running.md); the plan to move
is in [containers](../containers.md).

## Context

The application runs on a VPS it shares with unrelated services, as a set of
systemd units reading a native PostgreSQL over a unix socket, reached only over
Tailscale. The owner is moving it to a second server they already run, where
another project of theirs lives as a Docker Compose stack: its own application,
its own PostgreSQL 16 and its own Caddy, nothing installed on the host but
Docker and SSH. The dashboard will be served on a public domain name there, and
Tailscale will not be installed.

Three questions had to be answered before any file was written: how the two
projects share one machine, whether they share a database server, and who owns
ports 80 and 443.

## Decision

**One Compose stack per project, nothing shared between them but the network
the proxy lives on.** Private Finances gets its own PostgreSQL container with
its own volume, as the other project already has. A second PostgreSQL costs
about a hundred megabytes of memory; a shared one would make one project's
restart or major-version upgrade the other project's outage, and would put the
household's data inside a stack this repository does not control.

**HTTPS comes from a third stack, the edge, that belongs to neither project.**
Only one process can bind ports 80 and 443. Today that is the other project's
Caddy, which would make this project's domain a line in that project's
configuration. Instead `deploy/edge/` holds a Caddy of its own on a Docker
network named `edge`; each project joins that network under a distinct alias
and gets one site block. The other project's Caddy moves into it when this
project arrives, keeping its certificate volume so nothing is re-issued. The
edge stack lives in this repository for now because this is the project that
needed it; it holds no address — hostnames come from a `.env` on the server.

**The host keeps the timers.** Scheduled imports, exchange rates, reports and
the weekly assets snapshot stay systemd timers on the host, with their per-bank
drop-ins and the schedule markers that gate them, because that machinery is
proven and documented ([scheduling](../scheduling.md)). Each firing runs
`docker compose run --rm worker …`, one short-lived container of the release
image, so a running import outlives a dashboard restart and a release can still
wait for it. The dashboard and the Telegram worker are long-running Compose
services with restart policies, and need no unit.

**Configuration and credentials stay on the host, read-only to the containers.**
`/etc/private-finances` is bind-mounted at the same path, so every documented
credential path and every schedule marker keeps its meaning. Containers run as
the host's private-finances account, read-only root filesystem, all capabilities
dropped, no new privileges, a tmpfs for the PDF renderer's scratch files, and
no published port except the dashboard on the loopback interface for an SSH
tunnel. Environment values are visible to whoever can read the Docker socket,
which on a server is root: the same trust as the systemd `EnvironmentFile`.

**Public domain, no Tailscale.** The sign-in screen becomes reachable from the
internet. It already delays guessing per address and per caller with no
lockout ([authentication](../authentication.md)), cookies are `Secure` and
`SameSite=Lax`, and the application refuses any `Host` but its own, so the
proxy adds HSTS and passes the header through. The owner declined an IP
allowlist for administrative paths; the next layer, if one is ever wanted, is a
second factor, which PF-021 lists as an open gap. Tailscale may come back for
development convenience, but nothing depends on it.

## Consequences

- The release procedure changes shape: build an image of the commit, rehearse
  the migration against a restored copy inside the database container, pause
  the timers, recreate the two services, verify, resume. The gates stay the
  same; the commands do not. That script is not written yet.
- The backup job dumps through `docker compose exec db pg_dump` instead of the
  socket, and the restore target is the container. restic and the bucket are
  unchanged.
- Image builds leave BuildKit cache behind. On the destination server 76 GB of
  it had accumulated from the other project before this decision; pruning it
  becomes part of the release script, like the release-tree retention today.
- When the domain changes, the bank provider's registered redirect URL, the
  application's `PUBLIC_ORIGIN`, and the Telegram links all change with it;
  the cutover checklist in [containers](../containers.md) names each one.
- Two copies of the application must never import from banks or poll Telegram
  at the same time. The cutover is written around that constraint.
