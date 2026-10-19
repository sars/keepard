# Configuration examples

One example per file the Compose stack reads. Copy each to the place below,
replace every `change-me` and `example.com` value, and uncomment only the
optional settings you need. Each file explains its own variables; the order of
a whole first install is in [first install](../../docs/first-install.md).

| Example | Install as | Read by | Needed |
| --- | --- | --- | --- |
| `compose.env.example` | `/opt/private-finances/.env`, mode 644 | Docker Compose and the release script, not the application | always |
| `db.env.example` | `/etc/private-finances/db.env`, root, mode 600 | `db` | always |
| `app.env.example` | `/etc/private-finances/app.env`, root, mode 600 | `app`, `telegram`, `worker` | always |
| `telegram.env.example` | `/etc/private-finances/telegram.env`, root, mode 600 | `telegram` (after `app.env`) | must exist; may be empty |
| `sync.env.example` | `/etc/private-finances/sync.env`, root, mode 600 | `worker` (after `app.env`) | must exist; may be empty |
| `showcase.env.example` | `/etc/private-finances/showcase.env`, root, mode 600 | `showcase` only | must exist; the password is required if the showcase is public |

`/etc/private-finances` is the default of `PF_CONFIG_DIR`. Compose reads the
`.env` files as root on the host, so root ownership is right for them; the
containers run as `PF_UID` and only need to read the files under
`credentials/` and `schedules/`. A setting a later file repeats overrides the
earlier one for that service alone.

Three rules that apply to every file:

- `KEY=value`, one per line, with no comment after the value.
- An optional setting you do not want is commented out, not left empty.
- After a change, recreate the services that read the file, for example
  `docker compose up -d --force-recreate app telegram`; a plain `restart`
  does not re-read it.

## Not here

- **Credential files** — tokens, keys and PEMs are files under
  `/etc/private-finances/credentials/`, never values in these files. Their
  names are listed in [first install](../../docs/first-install.md#5-credential-files)
  and their sources in [credentials](../../docs/credentials.md).
- **`backup.env`** is read by the host's backup unit, not by Compose. Its
  variables are in [backups](../../docs/backups.md#on-the-container-host).
- **The proxy's `.env`** (`PF_DOMAIN`, `PF_DEMO_DOMAIN`) belongs to the
  separate edge stack: [`deploy/edge/.env.example`](../edge/.env.example).
- **Schedule markers** under `/etc/private-finances/schedules/` decide which
  bank imports run: [scheduling](../../docs/scheduling.md).

The older names `RODION_*`, `KATYA_*`, `TELEGRAM_RODION_USER_ID` and
`TELEGRAM_KATYA_USER_ID` are still read, so an existing server needs no edit;
new installs use `MEMBER_1_*` and `MEMBER_2_*`.
