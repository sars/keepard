# First install on a fresh server

How to run your own copy of Private Finances on a Linux VPS with Docker, from
an empty machine to two people signed in, banks importing, Telegram talking and
a daily backup leaving the server.

**This guide has not been run on a fresh server.** It is assembled from the
scripts and units in this repository and from how the original installation
was moved into containers ([containers](containers.md)). Those scripts were
written for one server, and where they assume it — a path, a hostname, a
neighbouring project — this guide says so and says what to do instead. The
list of what is still awkward is at the end, under [Known gaps](#known-gaps).
Expect to fix a detail or two, and correct this file when you do.

What you end up with:

- one Compose stack, `private-finances`: PostgreSQL, the dashboard, the
  Telegram worker and, optionally, a demo "showcase" with an invented
  household ([containers](containers.md) describes it in full);
- a Caddy proxy in a stack of its own that holds ports 80 and 443 and gets the
  certificate;
- systemd timers on the host that start a short-lived container for each
  scheduled job: bank imports, exchange rates, reports, the assets snapshot
  and the backup.

Commands below run on the server, as a user with `sudo`, unless they say
otherwise. `finances.example.com` and `203.0.113.10` stand for your own domain
and server address.

## 1. The server

- A Linux VPS on x86_64. The original runs Ubuntu 24.04.
- **Docker Engine with the Compose v2 plugin and buildx.** The Dockerfile uses
  BuildKit cache mounts, which the legacy builder refuses. Install from
  [Docker's own repository](https://docs.docker.com/engine/install/).
- `git`, `python3` and `curl` (the release script and the checks below use
  them), `systemd` (the timers), and `restic` for the backup:
  `sudo apt-get install -y git python3 curl restic`.
- Ports 80 and 443 reachable from the internet, and a DNS name with an A
  record pointing at the server.
- Memory: `compose.yaml` caps the database at 768 MB, the dashboard at
  512 MB, the Telegram worker at 256 MB, a scheduled job at 512 MB and the
  showcase at 1280 MB (3 GB while it is refilled). How small a machine really
  works has not been measured; building the image needs headroom too.

[What the production server needs](server-requirements.md) is the detailed
record, but it still describes the older deployment where Node and
PostgreSQL ran on the host and Tailscale served the dashboard. On a container
host none of those three are needed; its notes on restic and on file
ownership still apply.

## 2. Fork and clone

Fork the repository on GitHub and enable Actions on the fork. The fork is not
needed to run the application, but the release script (step 13) checks your
fork's CI results before it deploys anything.

Clone into `/opt/private-finances`. The host units and the backup unit
hard-code that directory (`WorkingDirectory=/opt/private-finances`), so any
other place means editing every unit.

```sh
sudo git clone https://github.com/<you>/<your-fork>.git /opt/private-finances
```

## 3. The account and the directories

Every application container runs as one unprivileged host account, so the
files it reads keep their owners. Create it and note its numbers; they become
`PF_UID` and `PF_GID`.

```sh
sudo useradd --system --no-create-home --shell /usr/sbin/nologin private-finances
id -u private-finances; id -g private-finances

sudo install -d -m 750 -o root -g private-finances /etc/private-finances
sudo install -d -m 700 -o private-finances -g private-finances /etc/private-finances/credentials
sudo install -d -m 755 -o root -g root /etc/private-finances/schedules
sudo install -d -m 755 /var/lib/private-finances
sudo install -d -m 700 -o private-finances -g private-finances \
  /var/lib/private-finances/consent /var/lib/private-finances/sync /var/lib/private-finances/showcase
sudo install -d -m 700 /var/lib/private-finances/predeploy
```

Create the state directories before the first start: Docker would otherwise
create them owned by root, and the containers could not write the bank
approvals (`consent`), the import scheduler's state (`sync`) or the demo
workspace (`showcase`). Keep `schedules` root-owned and writable by root
alone, as [scheduling](scheduling.md) requires; the scheduler itself checks
that each marker in it is owned by root, not writable by others, and says
exactly what it should.

## 4. Configuration

The examples are in [`deploy/config-examples`](../deploy/config-examples/README.md);
each variable is explained in the file itself.

```sh
cd /opt/private-finances
sudo install -m 644 deploy/config-examples/compose.env.example .env
for f in app db telegram sync showcase; do
  sudo install -m 600 -o root -g root deploy/config-examples/$f.env.example /etc/private-finances/$f.env
done
```

All five `/etc/private-finances/*.env` files must exist even when a service
is not used yet; compose refuses an `env_file` that is missing. Then edit:

- `.env`: `PF_UID` and `PF_GID` from step 3, and `PF_SERVICES=app` for now
  (Telegram and the showcase come later). Leave `COMPOSE_FILE` commented out
  until the proxy exists (step 6).
- `db.env`: a generated `POSTGRES_PASSWORD` (`openssl rand -hex 32`).
- `app.env`: the same password inside `DATABASE_URL`; both members' names,
  addresses and passwords (at least 20 characters — `openssl rand -hex 24`
  gives 48); `PUBLIC_ORIGIN=https://finances.example.com`. Leave Telegram,
  Enable Banking and OpenAI commented out for now.

The placeholder passwords in the examples are deliberately shorter than 20
characters, so a forgotten one stops the dashboard instead of opening it.

## 5. Credential files

Tokens and keys are files under `/etc/private-finances/credentials/`, owned
by `private-finances`, mode 600; the application refuses a key file that
group or others can read. None is needed for the first start. Where each one
comes from is in [credentials](credentials.md).

| File | What | Set in `app.env` |
| --- | --- | --- |
| `monobank-rodion-token` | member 1's Monobank personal API token | nothing; the name is fixed |
| `monobank-kate-token` | member 2's Monobank token (`kate`, not `katya`) | nothing; the name is fixed |
| `enablebanking.pem` | member 1's Enable Banking private key | `ENABLEBANKING_RODION_PRIVATE_KEY_FILE` |
| `enablebanking-katya.pem` | member 2's Enable Banking private key | `ENABLEBANKING_KATYA_PRIVATE_KEY_FILE` |
| `telegram-bot-token` | the bot token from @BotFather | `TELEGRAM_BOT_TOKEN_FILE` |
| `openai-api-key` | an OpenAI API project key | `OPENAI_API_KEY_FILE` |
| `ibkr-flex-token`, `ibkr-flex-query` | Interactive Brokers Flex Web Service ([assets](assets.md)) | nothing; the names are fixed |
| `binance-api-key`, `binance-api-secret` | a read-only Binance key | nothing; the names are fixed |

`rodion` and `katya` are the internal keys for member 1 and member 2; nobody
sees them on screen. The PEM and OpenAI file names are only the ones the
examples point at; any absolute path under `credentials/` works.

To write a token without it reaching your shell history or the screen:

```sh
sudo bash -c 'read -rsp "Token: " v; echo; [ -n "$v" ] || exit 1; umask 077
  f=/etc/private-finances/credentials/monobank-rodion-token
  printf "%s\n" "$v" > "$f"; chown private-finances:private-finances "$f"; unset v'
```

A PEM is copied to the server with `scp` and then installed with
`sudo install -m 600 -o private-finances -g private-finances <file> /etc/private-finances/credentials/`.
Delete any other copy afterwards.

## 6. Build and start

```sh
cd /opt/private-finances
sha=$(git rev-parse HEAD)
sudo sed -i "s/^PF_RELEASE=.*/PF_RELEASE=$sha/" .env
sudo docker compose build app
sudo docker compose up -d db app
curl -fsS http://127.0.0.1:3300/health/ready
```

The image is tagged `private-finances:<sha>` and every service runs it. On
its first start the dashboard creates the schema in the empty database and
both members' sign-ins from `app.env`. Name the services: a bare
`docker compose up -d` also starts the Telegram worker, which exits and
restarts in a loop until Telegram is configured, and the showcase.

If `/health/ready` does not answer, `sudo docker compose logs app` says why.
The usual reasons: a password under 20 characters, the two members sharing an
address, `DATABASE_URL` and `POSTGRES_PASSWORD` disagreeing, `PUBLIC_ORIGIN`
not an `https://` origin, or only half of an Enable Banking pair set.

To look before the proxy exists, tunnel from your own computer
(`ssh -L 3300:127.0.0.1:3300 <your server>`) and open http://localhost:3300.
Use local port 3300: the dashboard accepts `localhost:3300` and its public
name, and no other port.

## 7. HTTPS: the edge proxy

[`deploy/edge`](../deploy/edge/README.md) is the proxy stack the original
server runs. **It is shared there with another project and cannot be used
unchanged:** its `Caddyfile` carries that project's site blocks, and its
`compose.yaml` mounts three external volumes named after that project, which
do not exist on your server, so `docker compose up` there fails. To use it:

1. Point the A record for `finances.example.com` (and, for the showcase, its
   own name) at the server, and wait until it resolves. Caddy asks Let's
   Encrypt for a certificate only once it does.
2. `sudo cp -r /opt/private-finances/deploy/edge /opt/edge`.
3. In `/opt/edge/Caddyfile`, delete the other project's section, from its
   `# ---- Hlyna` heading to the end of the file, and the showcase block if
   you will not run the showcase.
4. In `/opt/edge/compose.yaml`, delete the `hlyna_media` mount and volume,
   and make `caddy_data` and `caddy_config` ordinary volumes: remove their
   `external:` and `name:` lines.
5. `cp .env.example .env` in `/opt/edge` and set `PF_DOMAIN` (and
   `PF_DEMO_DOMAIN` if you kept that block). Every name the Caddyfile uses
   must be set: an empty site name fails the whole file.
6. Start it and join the dashboard to it:

   ```sh
   sudo docker network create edge
   cd /opt/edge && sudo docker compose up -d
   cd /opt/private-finances
   echo 'COMPOSE_FILE=compose.yaml:deploy/compose.edge.yaml' | sudo tee -a .env
   sudo docker compose up -d app
   ```

7. Check that `PUBLIC_ORIGIN` in `app.env` is exactly
   `https://finances.example.com` and open it.

Any other reverse proxy on the host works too, if it forwards to
`127.0.0.1:3300` and passes the `Host` header through unchanged: the
dashboard refuses a host other than its `PUBLIC_ORIGIN`.

## 8. Signing in

Each member signs in with the address and password from `app.env`, which are
applied at every start. To change a password, edit the file and run
`sudo docker compose up -d --force-recreate app`; that is also the only way
back in, since nothing resets a password by email. See
[authentication](authentication.md).

## 9. Banks

### Monobank

Each member gets their own personal API token at
[api.monobank.ua](https://api.monobank.ua/) and it goes into
`monobank-rodion-token` or `monobank-kate-token` (step 5). Nothing else is
configured; imports start once the schedule is enabled (step 10).

### Enable Banking: Wise, Revolut, Swedbank, LHV

1. In the [Enable Banking control panel](https://enablebanking.com/sign-in/)
   register a **Production** application, and save its private PEM and its
   application ID. Set the allowed redirect URL to
   `https://finances.example.com/connections/enablebanking/callback`
   (`PUBLIC_ORIGIN` plus that path).
2. In restricted production mode, link every account you want imported in the
   control panel.
3. Install the PEM (step 5), set `ENABLEBANKING_RODION_APPLICATION_ID` and
   `ENABLEBANKING_RODION_PRIVATE_KEY_FILE` in `app.env` (the `KATYA` pair for
   member 2), and recreate the dashboard.
4. Each member signs in and approves **their own** banks on Bank connections.
   The approval writes a session file under `/var/lib/private-finances/consent`;
   it lasts as long as the bank allows and is renewed on the same page.

The original installation registered one application per member, and the
code never lets member 2 fall back to member 1's. Details:
[credentials](credentials.md), [bank consent](bank-consent.md) (which
describes the original private callback address; yours is the public one
above), [bank connections](bank-connectors.md).

Scheduled imports read a rolling 31 days. Older history is a separate,
deliberate backfill: [historical imports](historical-imports.md).

## 10. The scheduled jobs

The host runs every job through systemd. The **services** to install are the
container ones in `deploy/containers/`; the **timers** are in `deploy/`.
Do not install the `.service` files in `deploy/` itself: they belong to the
older deployment and run Node on the host.

```sh
cd /opt/private-finances
sudo cp deploy/containers/private-finances-sync@.service \
  deploy/containers/private-finances-fx-sync.service \
  deploy/containers/private-finances-reports.service \
  deploy/containers/private-finances-assets-snapshot.service \
  deploy/containers/private-finances-backup.service /etc/systemd/system/
sudo cp deploy/private-finances-sync@.timer deploy/private-finances-fx-sync.timer \
  deploy/private-finances-reports.timer deploy/private-finances-assets-snapshot.timer \
  deploy/private-finances-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now private-finances-fx-sync.timer private-finances-reports.timer
```

Exchange rates are read three times a day, reports are checked daily at
06:00 UTC, and the assets snapshot fires every Thursday and runs on the last
one of the month (enable its timer once Assets is set up; [assets](assets.md)).
The backup timer is enabled in step 12.

**Bank imports have three gates**, so that nothing calls a bank by accident
([scheduling](scheduling.md)):

1. **A restore marker.** No import runs until
   `/etc/private-finances/off-server-restore-verified` (or
   `local-restore-verified`) exists, root-owned, containing exactly its own
   name. It records that you have proved a backup can be restored. On a new,
   empty install there is nothing to lose yet, so writing it before the first
   backup is a judgement you make deliberately — and then prove a restore once
   backups run (step 12).
2. **A marker per connection** in `/etc/private-finances/schedules/`, named
   `<instance>.enabled` and containing the instance name. Instances are
   `monobank-rodion`, `monobank-katya` and
   `enablebanking-<rodion|katya>-<wise|revolut|swedbank|lhv>`.
3. **The timer** for that instance.

```sh
printf 'local-restore-verified\n' | sudo tee /etc/private-finances/local-restore-verified >/dev/null
i=monobank-rodion
printf '%s\n' "$i" | sudo tee /etc/private-finances/schedules/$i.enabled >/dev/null
sudo chmod 644 /etc/private-finances/local-restore-verified /etc/private-finances/schedules/$i.enabled
sudo systemctl enable --now private-finances-sync@$i.timer
```

An Enable Banking timer may be enabled before its bank is approved; it waits
quietly until the approval exists. By default a connection is read six hours
after its previous run. The committed drop-ins
`deploy/private-finances-sync@<instance>.timer.d/frequency.conf` shorten that
to thirty minutes; they are named after the original household's
connections, so copy only those that match yours, or create the same file for
your own instance. Enable Banking additionally needs a
`schedules/<instance>.half-hourly` marker (same form) before it polls every
half hour, and many banks allow only four unattended reads a day — LHV among
them, which is why it keeps six hours.

Watch the result on the Bank imports page, or with
`systemctl list-timers 'private-finances-sync@*'` and `journalctl -u 'private-finances-sync@*'`.

## 11. Telegram

Follow [Telegram setup](telegram-setup.md) to create the bot, turn its privacy
mode off (so receipt photos reach it) and add it to a private group with both
members. That page was written for the older deployment: run its token
command on your own server instead of `ssh radar`, and skip its systemd part.

To find the IDs, have each member send `/start@YourBotUsername` in the group,
then, **before** starting the worker (which consumes the updates), read only
the numbers:

```sh
sudo bash -c 'printf "url = \"https://api.telegram.org/bot%s/getUpdates\"\n" \
  "$(cat /etc/private-finances/credentials/telegram-bot-token)" | curl -fsS --config -' |
  python3 -c 'import json,sys
for u in json.load(sys.stdin)["result"]:
    m = u.get("message")
    if m: print("chat", m["chat"]["id"], "from", m["from"]["id"])'
```

Set `TELEGRAM_BOT_TOKEN_FILE`, `TELEGRAM_CHAT_ID`, `MEMBER_1_TELEGRAM_USER_ID`
and `MEMBER_2_TELEGRAM_USER_ID` in `app.env`, and any of the optional settings
in `telegram.env`. Then add `telegram` to `PF_SERVICES` in `.env` and:

```sh
sudo docker compose up -d --force-recreate app telegram
sudo docker compose logs --tail 20 telegram
```

## 12. Backups

[Backups](backups.md) has the whole procedure; in short:

1. Create the bucket, its lifecycle rule, a user with a policy for that
   bucket alone, and an access key, as "What the owner does in AWS"
   describes. Invent a restic password and keep it in a password manager: it
   cannot be recovered.
2. Write `/etc/private-finances/backup.env` (root, mode 600) with the
   variables under [On the container host](backups.md#on-the-container-host):
   `PGDATABASE=private_finances`, `RESTIC_REPOSITORY`,
   `RESTIC_PASSWORD_FILE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`. The
   restic password file is root-owned, mode 600, and not under
   `credentials/` (the containers must not read it).
3. Initialise the repository once, then run and enable the backup:

   ```sh
   sudo bash -c 'set -a; . /etc/private-finances/backup.env; restic init'
   sudo systemctl start private-finances-backup.service
   sudo systemctl enable --now private-finances-backup.timer
   ```

4. Check System health shows the backup, then prove a restore into a
   disposable database as [Proving recovery](backups.md#proving-recovery)
   describes, and write the `off-server-restore-verified` marker.

The unit runs `/opt/private-finances/scripts/backup.sh`, which exists because
the repository was cloned there. Any restic repository works; the label
stored with each run defaults to `amazon-s3` (`BACKUP_DESTINATION_LABEL` in
`backup.env` changes it).

## 13. Later releases

**With the release script.** From your own computer, in a checkout of your
fork: `bash deploy/container-release.sh <40-character sha> <ssh host>`. It
builds the image of that commit on the server, rehearses the migration on a
copy of the live database, pauses the imports and the Telegram worker,
switches, verifies and rolls back by itself if the new release does not come
up ([containers](containers.md#the-release)). A stranger can use it, given:

- the commit is on `origin/main` of your checkout;
- a GitHub CLI authenticated for your fork: the script defaults to the
  original owner's wrapper `~/.local/bin/pf-gh`, so run it with
  `PF_GH=$(command -v gh)`;
- your fork's "Application checks" and "Image and stack" jobs passed on that
  exact commit. Those workflows skip commits that change only Markdown, so
  such a commit cannot be released this way;
- key-based SSH to the server as root or with passwordless `sudo`;
- the stack already installed and answering at `/opt/private-finances` — the
  script upgrades, it does not do a first install;
- `PF_SERVICES` in `.env` naming exactly the services you run.

**Without it.** In `/opt/private-finances`: `git pull`, set `PF_RELEASE` to
the new commit as in step 6, `docker compose build app`, then
`docker compose up -d` with your services. This skips the rehearsal and the
pre-deployment dump, so run the backup first, and copy any host unit that
changed. Pick one of the two ways: the release script overwrites
`compose.yaml` and a few other files in that directory, which a later
`git pull` then sees as local changes.

## 14. The showcase (optional)

A second, separate workspace full of invented data, for showing the
application without your own figures ([showcase](showcase.md)). Set
`DEMO_LOGIN_PASSWORD` in `showcase.env` — without it, anyone who reaches the
showcase is signed in automatically — and `PF_SHOWCASE_ORIGIN` in `.env`,
keep its block in the edge Caddyfile, add `showcase` to `PF_SERVICES`, and
start it with `sudo docker compose up -d showcase`. For refills from its
`/showcase/reseed` page, install
`deploy/containers/private-finances-showcase-reseed.path` and `.service` and
enable the path unit.

## Known gaps

- **Not tested end to end.** No one has followed this guide on a fresh
  server yet.
- **The edge stack is the original server's.** It carries another project's
  site blocks and external volumes and has to be edited (step 7).
- **Fixed paths.** The host units and the backup unit assume
  `/opt/private-finances`; the showcase path unit assumes
  `/var/lib/private-finances/showcase`; the release script defaults to
  `/opt/private-finances` and `/var/lib/private-finances/predeploy`. Moving
  `PF_CONFIG_DIR` or `PF_STATE_DIR` away from the defaults means editing
  those units as well.
- **Ports are not really configurable.** The dashboard accepts only
  `127.0.0.1:3300`, `localhost:3300` and its public name as `Host`, so a
  different `PF_PORT` breaks the release script's readiness check and local
  tunnels; the same holds for the showcase and 3301.
- **The release script assumes the original setup**: a GitHub fork with these
  CI job names, the `pf-gh` path unless `PF_GH` is set, an SSH alias you pass
  in, and an already running stack. There is no first-install script for the
  container host; `deploy/initial-install.sh` is the older deployment's and
  installs Node and PostgreSQL on the host.
- **The Telegram worker starts with a bare `docker compose up`** and
  crash-loops until it is configured. The older deployment had a
  `telegram.enabled` marker for this; the container stack has none, so you
  must name your services and keep `PF_SERVICES` right.
- **Exactly two members.** Their internal keys `rodion` and `katya` still
  appear in credential file names (`monobank-kate-token`), in the Enable
  Banking variable names (`ENABLEBANKING_RODION_*`, `ENABLEBANKING_KATYA_*`),
  in timer instance names, and in the committed timer drop-ins, which are
  named after the original household's bank connections.
- **One time zone.** `Europe/Riga` is written into about eighteen source
  files and the assets snapshot timer; `REPORT_TIMEZONE` changes only the
  report job.
- **Exchange rates are Ukrainian.** They come from PrivatBank and Minfin,
  with the hryvnia as the pivot, for USD, EUR, GBP, JPY and KWD only
  ([FX policy](fx-policy.md)).
- **A fixed list of banks.** Monobank, and Wise, Revolut, Swedbank and LHV
  through Enable Banking. Another bank needs code ([bank connections](bank-connectors.md)).
- **Automatic triage ignores older payments.** The Telegram worker's
  automatic review considers only payments booked after
  `2025-12-31T22:00:00Z`, a date written into `src/telegram-cli.ts`.
- **The restore gate on a fresh install.** Imports refuse to run until a
  restore marker exists; on an empty install you decide when to write it.
- **No `backup.env` example.** Its variables are only described in
  [backups](backups.md).
- **Older pages describe the original server.** [Server requirements](server-requirements.md),
  [running](running.md), [bank consent](bank-consent.md) and
  [Telegram setup](telegram-setup.md) mention the SSH alias `radar`,
  Tailscale and the systemd units of the earlier deployment.
- **Passwords live in `app.env`.** There is no change-password screen and no
  reset by email ([authentication](authentication.md)).
