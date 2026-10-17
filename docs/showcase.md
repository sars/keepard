# The showcase workspace

The application is going into a public article, with screenshots and short
screencasts. The screens have to be shown without the household's own money in
them, and the pictures are permanent: a screenshot can be zoomed and kept, a
screencast is not reviewed frame by frame, and neither can be taken back.

So the demo workspace holds a household that does not exist. Nothing in it is
derived from the real one, which means no screenshot can leak a figure — there
is no real figure anywhere in it to leak.

## Why not hide the real figures instead

Masking amounts behind stars, or scaling them by a constant, was the cheaper
idea and was rejected:

- **An article of blanked-out numbers shows nothing worth looking at.** A bar
  chart with dotted axes and a category breakdown of `•••` do not demonstrate
  an application; they demonstrate that it has something to hide.
- **Masking fails silently.** A figure that escaped the formatter looks exactly
  like one that did not.
- **Removing things breaks the sums.** Several holdings are not wanted in the
  article at all. Delete them from real data and the parts no longer add up to
  the whole, which is precisely what a careful reader notices. Generated data
  has no such problem: what is not created was never in the total.

## What is real and what is invented

| | |
| --- | --- |
| **Real** — discloses nothing, tedious to fake | the category tree, the bank names, currencies, dates, counts, exchange rates, the interface |
| **Invented** — every one | amounts, merchants, descriptions, both members, holdings and their contents |

The banks stay real deliberately. This repository is public and already names
every integration it has, so "Monobank", "Wise", "Revolut", "Swedbank", "LHV",
"Binance" and "Interactive Brokers" appearing in a screenshot disclose nothing
that is not already published. What those accounts *hold* is invented.

The two members are **Alex** and **Sam**. Only the label changes: every payment
is still owned by `rodion` or `katya` underneath, because that identity is what
the ledger, the audit history and the bank connections are keyed by. The names
come from one map on each side — `OWNER_NAMES` in `src/account-names.ts` and
`owners` in `frontend/src/lib/account-visuals.ts` — and the server states them
in the bootstrap payload so both sides agree.

## Using it

```sh
pnpm demo:seed     # wipe and refill the demo workspace
pnpm demo          # the application, on http://127.0.0.1:3300
pnpm shots         # screenshots, desktop and phone, light and dark
```

The receipt pictures are already committed under `showcase/receipts/`. They
are till slips from shops nobody visited, rendered from the list in
`src/showcase-receipts.ts` so that the total printed on a slip is the amount
on the payment it belongs to — the one disagreement a reader would notice.
`pnpm demo:receipts` redraws them with Playwright if that list changes.

They are committed rather than drawn at seeding time because the server has no
Playwright. A workspace seeded without them skips the receipts and says so, so
the seeder never depends on a browser being present.

The workspace can also be refilled from the running application, at
`/showcase/reseed`. It is a page of its own rather than a button in the
interface, because a Refill button would appear in the article. On the server
that page is the whole of the routine: see **Refilling it from the page** below.

The household is generated from a fixed seed, so reseeding produces the same
people with the same spending: a figure quoted in the article's text still
matches the picture beside it, and screenshots taken a month apart agree.

Dates are generated relative to the day it is seeded, so "this month" on the
Home screen is always the current one. **Reseed before taking screenshots** —
that is the only thing that keeps the workspace from slowly emptying out as
time passes. There is no timer, because it is only wanted before a photograph.

## How much of it there is

Four knobs change the size and shape of the workspace without touching a file.
The reseed page carries them, and the seeder script reads the same four from
the environment:

```sh
SHOWCASE_DENSITY=2 SHOWCASE_MONTHS=24 pnpm demo:seed
```

| | What it does | Range | Default |
| --- | --- | --- | --- |
| `SHOWCASE_DENSITY` | Everyday payments, as a multiple of about eighty a month. Rent, salary, bills and the business invoice are one a month whatever this says — multiplying those would read as nonsense. | 0.25–3 | 1 |
| `SHOWCASE_MONTHS` | How far back the ledger reaches. | 1–24 | 16 |
| `SHOWCASE_REFUNDS` | Refund pairs across the whole window, cycling through the four shapes below. | 0–24 | one per four months |
| `SHOWCASE_RECEIPTS` | How many of the committed slips to attach. | 0–5 | 5 |

Every one is clamped inside the seeder rather than trusted, so a mistyped
figure asks for the ceiling instead of for a workspace the server cannot build.
The ceilings are about cost: seeding a default workspace takes a few minutes
and peaked at 859M, and both scale roughly with the number of payments written.

### The refunds

A refund is one of the more interesting things the application does, and for a
long time the demo could not show it: the seeder wrote a purchase and an equal
credit three days later and left them unlinked, so `refund_links` was empty and
none of the display the feature exists for ever appeared.

They are linked now, and deliberately not all alike. Four shapes, in rotation:

| | |
| --- | --- |
| **full** | the whole charge comes back, on the card that paid |
| **partial** | some of it comes back and the purchase stays, reduced |
| **settling** | the reversal is still a hold, so the pair reads as still settling |
| **currency** | charged in euro, returned in hryvnia, confirmed by hand |

The last is the one worth having. Automatic matching never crosses an account
or a currency (ADR 0007), so it is recorded as a person's decision; and its
arithmetic runs through the daily quote the workspace holds for the day the
money came back, which is why the refunds are linked after the rates are
written and not before.

## Changing what it holds

Every figure comes from three files, and the fast way to judge a change is to
make it, reseed locally and look — seconds per turn, rather than a release.

```sh
pnpm demo:seed && pnpm demo
```

| What | Where |
| --- | --- |
| How much is spent, and how often | `SPENDING` in `src/showcase.ts` |
| Rent, salary, bills, the business invoice | `RECURRING` in `src/showcase.ts` |
| Savings, their groups and what they hold | `SHOWCASE_HOLDINGS` in `src/showcase-assets.ts` |
| What each bank reports as a balance | `SHOWCASE_BALANCES`, same file |
| Prices and exchange rates | `PRICES` and `FX`, same file |
| The receipts | `SHOWCASE_RECEIPTS` in `src/showcase-receipts.ts` |

**Density** is the knob most likely to be wanted. Each `SPENDING` entry carries
a `monthly` count, and they sum to about eighty payments a month; doubling them
doubles how busy every screen looks. `min` and `max` are minor units, so
`24000` is 240 UAH.

Two things that must stay true. A receipt's items are what the slip in the
photograph adds up to, so changing them means running `pnpm demo:receipts`
again — otherwise the picture and the payment disagree, which is the first
thing a reader notices. And a holding group that is not in `SHOWCASE_HOLDINGS`
simply does not exist: that is why the totals still add up, where deleting rows
from a copy of the real workspace would leave them short.

## It cannot reach the household's own data

Four independent things have to be true at once, and each is enough on its own:

1. **Demo mode never opens `DATABASE_URL`.** One branch in `src/main.ts`
   chooses the database, and demo mode takes the PGlite side of it.
2. **The seeder refuses any database that is not a local PGlite one.** It
   empties the ledger before it writes, so it asks `isMemoryDatabase` — which
   answers from how the database was constructed, not from an environment
   variable that could be wrong.
3. **The script refuses to start** if `DATABASE_URL` is present in the
   environment at all, or if `APP_MODE` is anything but `demo`.
4. **Demo mode runs with no credentials.** Bank connections, Enable Banking
   consent, Telegram and the AI classifier are all gated on `APP_MODE=postgres`
   in `src/main.ts`, so a demo instance cannot call a bank, message anyone or
   spend AI budget. `test/demo.test.ts` holds that line.

## The rule for a demo instance on the server

A demo instance runs on the server so that the installed app, the phone
layouts and the pull-to-refresh gesture can be photographed — a laptop cannot
show those, because a phone cannot reach `localhost` and a LAN address is not a
secure origin, so there is no service worker and no install.

**Demo mode signs itself in unless it is told not to.** There is nobody to
authenticate and nothing real behind it, so a demo on a laptop or a tailnet
has no door. Put that on a public route and it is an open workspace that
anybody can browse and write to, refill button included. Until 17 October
2026 the tailnet was the whole protection: the showcase was served by
Tailscale on the old host and never funnelled. On the container host it has
a public name, so it has a sign-in of its own: `DEMO_LOGIN_PASSWORD` (and
`DEMO_LOGIN_EMAIL`, the address typed on the sign-in screen) in
`showcase.env` seed one account the way the household's own are seeded, the
same screen, the same session cookie, the same throttling of guesses — rather
than a browser-level password at the edge, which gets in the way of the
installable app. The name is also marked `noindex` at the edge. A demo
started at a public name without `DEMO_LOGIN_PASSWORD` is the open workspace
again; the compose file reads the file unconditionally so that cannot happen
by forgetting it. A refill rebuilds the workspace, so it also signs everyone
out; the account is seeded again when the showcase starts.

It must also keep its workspace in a directory of its own. The compose file
sets `DEMO_DATA_DIR` to `/var/lib/private-finances-showcase/demo`, a host
directory under `PF_STATE_DIR` that only the showcase mounts; the old host's
unit did the same under its state directory. The default, `data/demo` under
the working directory, is for a laptop: inside a release or an image it would
be written into the build and lost at the next switch.

## What the demo looks like

It looks like the application, deliberately: an article needs to show the thing
itself, not a sample of it. One quiet **Demo mode** label sits at the left of
the header. That is enough to keep a reader honest, and enough to stop the
owner mistaking it for the real workspace now that the two look alike.

## Bringing the demo instance up on the server

Since 17 October 2026 the showcase is the `showcase` service of the Compose
stack ([containers](containers.md)): the release image in demo mode, port 3301
on the host's loopback, a PGlite workspace under `PF_STATE_DIR/showcase`, no
configuration mounted at all, and the edge serving it at its public name
behind a password. A release recreates it together with the dashboard, so it
follows every release by itself — what the old host's unit needed a refill
for happens at the switch. The steps below are run once per host and need
root there.

1. **The state directory**, owned by the account the stack runs as (the
   `PF_UID`/`PF_GID` in the stack's `.env`):

   ```sh
   install -d -m 700 -o private-finances -g private-finances /var/lib/private-finances/showcase
   ```

2. **The origin and the door.** `PF_SHOWCASE_ORIGIN=https://<demo name>` in
   `/opt/private-finances/.env`: the application compares the `Host` header
   with it and refuses anything else with `invalid_host`; left empty there is
   no check, which is for CI and laptops only. And `showcase.env` beside the
   household's configuration, root-owned, mode 0640 for the stack's group,
   with `DEMO_LOGIN_EMAIL` and a `DEMO_LOGIN_PASSWORD` of at least twenty
   characters; the password stays with the operator.

3. **Start it.** A release does, or `docker compose up -d showcase`. It comes
   up with an empty workspace and is healthy within a minute:

   ```sh
   curl -fsS http://127.0.0.1:3301/health/live
   ```

4. **Fill it.** The refill unit below does nothing without a request file
   from the page, so the first fill is by hand, with the showcase stopped —
   PGlite allows one process per data directory:

   ```sh
   cd /opt/private-finances
   docker compose stop showcase
   docker compose --profile tools run --rm showcase-reseed node scripts/seed-showcase.mjs
   docker compose start showcase
   ```

   A few minutes at the default size. It prints one line of counts, and that
   line must end in `5 receipts`: the pictures travel in the image, and a
   count of zero means the image was built without them.

5. **The refill watcher.** The two units are in `deploy/containers/`; the
   release script refreshes them once installed, installing them is a
   deliberate act:

   ```sh
   install -m 644 deploy/containers/private-finances-showcase-reseed.path deploy/containers/private-finances-showcase-reseed.service /etc/systemd/system/
   systemctl daemon-reload && systemctl enable --now private-finances-showcase-reseed.path
   ```

6. **The name.** An A record for the demo name pointing at the host. Then in
   `/opt/edge`: `PF_DEMO_DOMAIN` in `.env`, the Caddyfile from `deploy/edge/`,
   then — because Caddy reads `.env` at container start, not at reload —
   `docker compose run --rm caddy caddy validate --config /etc/caddy/Caddyfile`
   and `docker compose up -d`. Recreating Caddy costs every site on the host a
   few seconds; the certificate follows within a minute of the record
   resolving.

7. **Check it.** Open the name, sign in, install it on the phone,
   and confirm the header says **Demo mode** and the people are Alex and Sam.
   If it says anything else, stop and do not photograph it.

## Refilling it from the page

`/showcase/reseed` carries the four knobs and a Refill button, and pressing it
does the whole job: the demo stops, the workspace is rebuilt from nothing, and
the demo starts again — **on whatever release the server currently has**. That
last part is the point. Nothing in the release switch restarts the showcase,
and `WorkingDirectory` is resolved once at start, so a demo left alone keeps
serving the release it booted with. It did that for four months once, and the
only thing that said so was the screens looking wrong.

The page cannot do any of that itself. PGlite allows one process per data
directory and the running showcase is holding it, so a workspace can only be
rebuilt while the showcase is stopped — and stopping a container needs the
Docker socket, which is root, which the demo has none of and should never be
given: it is a public service with one shared account.

So the page writes a request file, `private-finances-showcase-reseed.path` on
the host notices it, and `private-finances-showcase-reseed.service` does the
work: it stops the showcase, runs `scripts/reseed-showcase.mjs` in the
`showcase-reseed` container (the same image and account as the showcase), and
starts the showcase again whatever the outcome. On the old host the same
script stopped and started the systemd unit itself. The page follows along by
polling a status file — including across the minutes when the demo is stopped
and cannot answer at all, which it reports as "Working" rather than as an
error, because that is what it is. The status is answered without a session,
because a refill rebuilds the workspace with its sessions, and the page says
so at the end: reload, and sign in again.

A refill that fails says so on the page, names the reason, and starts the demo
again anyway: a workspace that is empty or half built can be recognised and
refilled, where a demo that is simply not there looks like a broken server.

### Checking the watcher

The units are installed in step 5 of "Bringing the demo instance up on the
server". Afterwards:

1. **Is it waiting?**

   ```sh
   systemctl status private-finances-showcase-reseed.path --no-pager | head -5
   ```

   It should say `active (waiting)`. `active (running)` means a refill is in
   progress; `inactive` means it was not enabled.

2. **Try it.** Open `/showcase/reseed` at the demo name, leave the defaults,
   and press Refill. The page should move through Queued → Building the
   household → Starting the demo → Done, and end by naming the counts and the
   release. It takes a few minutes at the default size.

   If it sits on "Working" far longer than that, read the unit:

   ```sh
   journalctl -u private-finances-showcase-reseed -n 40 --no-pager
   ```
