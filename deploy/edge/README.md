# The edge: one HTTPS front for every project on the server

Ports 80 and 443 can belong to one process. On the destination server that
was the other project's Caddy, which would have made this project's domain a
line in that project's configuration. This stack is that Caddy, moved out
into a home that belongs to neither project: a Docker network named `edge`
that each project joins under its own alias, and one Caddyfile with a site
block per project. The reasons are in
[ADR 0009](../../docs/adr/0009-containers-on-a-shared-server.md).

Lives at `/opt/edge` on the host: `compose.yaml`, `Caddyfile`, `.env`
(`PF_DOMAIN`). Hostnames come from `.env` so this repository carries no
address; the other project's names are public ones and are written out.

## Who owns what

| Thing | Owner | Changed by |
| --- | --- | --- |
| the `edge` network | the host, created once by hand | nobody |
| this Caddy and its Caddyfile | this directory | a change here, then `docker compose up -d` and `docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile` in `/opt/edge` |
| `hlyna_caddy_data`, `hlyna_caddy_config`, `hlyna_media` | the other project's stack, kept under their old names | that project; this stack mounts them and never creates or removes them |
| a project's upstream alias (`private-finances`, `hlyna`) | the project's own compose file | that project |

## Taking over from the other project's Caddy

Done in one sitting, in this order, so the public site is down for seconds
rather than for the minute its application takes to restart. The other
project's compose change (its `caddy` service removed, its `app` joined to
`edge` under the alias `hlyna`) is prepared and reviewed in that repository
first.

```sh
docker network create edge
# the running application joins the network live, no restart
docker network connect --alias hlyna edge hlyna-app-1
# ports 80/443 change hands
cd /opt/hlyna && docker compose stop caddy && docker compose rm -f caddy
cd /opt/edge && docker compose up -d
curl -sf -o /dev/null --resolve hlyna.com.ua:443:127.0.0.1 https://hlyna.com.ua/health && echo hlyna ok
# the project's compose file now says the same thing the live connect did;
# this recreates its app once (the branded 503 page covers the restart)
cd /opt/hlyna && docker compose up -d --remove-orphans
```

The finance dashboard joins through `deploy/compose.edge.yaml` in its own
stack: `COMPOSE_FILE=compose.yaml:deploy/compose.edge.yaml` in
`/opt/private-finances/.env`, then `docker compose up -d app`. Caddy only
starts asking Let's Encrypt for the dashboard's certificate once `PF_DOMAIN`
resolves to this host, so the A record comes first.

## Rolling back

The old Caddy is one command away for as long as the other project's previous
compose file exists: `cd /opt/edge && docker compose down`, restore that
file, `cd /opt/hlyna && docker compose up -d`. The certificate volume was
never touched, so nothing is re-issued either way.
