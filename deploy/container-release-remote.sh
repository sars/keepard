#!/bin/bash
# The server side of a container release; container-release.sh copies this
# over and runs it as root. It can also run on any machine that has the stack
# up, which is how CI rehearses it on every change.
#
#   bash container-release-remote.sh <sha> <archive.tar.gz> <sha256 of the archive>
#
# Environment, all optional:
#   PF_COMPOSE_DIR    where compose.yaml and .env live      /opt/private-finances
#   PF_PREDEPLOY_DIR  where the pre-switch dump is kept     /var/lib/private-finances/predeploy
#   PF_SERVICES       the services recreated at the switch  "app telegram"
#                     (also read from .env in PF_COMPOSE_DIR, so a host that
#                     must not run the Telegram worker — a shadow — says so
#                     once, in its own configuration)
#
# Every step is a gate. Nothing is switched until the rehearsal has passed; a
# failure after the timers were stopped resumes them before this exits; a
# failed switch puts the previous image back and reports that it did.
set -euo pipefail

sha=${1:-}
archive=${2:-}
digest=${3:-}
[[ $sha =~ ^[0-9a-f]{40}$ ]] && [ -f "$archive" ] && [[ $digest =~ ^[0-9a-f]{64}$ ]] || {
  echo "usage: bash container-release-remote.sh <sha> <archive.tar.gz> <sha256>" >&2
  exit 64
}
[ "$(id -u)" = 0 ] || {
  echo "refusing: must run as root (the Docker socket is root's)" >&2
  exit 77
}
compose_dir=${PF_COMPOSE_DIR:-/opt/private-finances}
predeploy_dir=${PF_PREDEPLOY_DIR:-/var/lib/private-finances/predeploy}
scratch_db=private_finances_migration_check
short=${sha:0:7}
build=/tmp/pf-build-$short
check_script=/tmp/pf-migrate-check-$short.mjs
database_user=private-finances
database=private_finances

step() { printf '\n=== %s ===\n' "$1"; }
fail() {
  echo "$2" >&2
  exit "$1"
}
compose() { docker compose "$@"; }

cd "$compose_dir" 2>/dev/null && [ -f compose.yaml ] && [ -f .env ] ||
  fail 78 "refusing: $compose_dir has no compose.yaml and .env; the stack is not installed here"
setting() { grep -E "^$1=" .env | tail -1 | cut -d= -f2- | tr -d '"' || true; }
port=$(setting PF_PORT)
port=${port:-3300}
config_dir=$(setting PF_CONFIG_DIR)
config_dir=${config_dir:-/etc/private-finances}
previous_release=$(setting PF_RELEASE)
services=${PF_SERVICES:-$(setting PF_SERVICES)}
services=${services:-app telegram}

ready_release() {
  curl -fsS "http://127.0.0.1:$port/health/ready" 2>/dev/null |
    python3 -c 'import json, sys; print(json.load(sys.stdin).get("release", ""))' 2>/dev/null || true
}
wait_for_release() {
  for _ in $(seq 1 60); do
    [ "$(ready_release)" = "$1" ] && return 0
    sleep 2
  done
  return 1
}
workers_running() {
  [ -n "$(docker ps -q \
    --filter label=com.docker.compose.project=private-finances \
    --filter label=com.docker.compose.service=worker)" ]
}

# Resumption is the one thing that must survive any failure: the imports and the
# Telegram worker pause for the switch and nothing below may leave the
# household without them. Only what was running is resumed: a host whose
# Telegram worker was deliberately stopped — a shadow beside the live server —
# must not have it started by a release.
timers=
paused=
rehearsing=
telegram_was_running=
resume_services() {
  if [ -n "$timers" ]; then
    # shellcheck disable=SC2086
    systemctl start $timers || echo 'warning: the import timers did not all resume; start them by hand' >&2
  fi
  if [ -n "$telegram_was_running" ]; then
    compose up -d --no-build telegram >/dev/null 2>&1 ||
      echo 'warning: the Telegram worker did not resume; `docker compose up -d telegram` by hand' >&2
  fi
}
cleanup_on_exit() {
  status=$?
  if [ -n "$rehearsing" ]; then
    compose exec -T db psql -U "$database_user" -d postgres -qc "drop database if exists $scratch_db" >/dev/null 2>&1 ||
      echo "warning: the scratch database $scratch_db was not dropped" >&2
  fi
  if [ -n "$paused" ]; then
    echo 'resuming imports and the worker'
    resume_services
  fi
  rm -rf "$build" "$archive" "$check_script"
  exit $status
}
trap cleanup_on_exit EXIT

step 'the running stack'
running=$(ready_release)
[ -n "$running" ] || fail 78 "refusing: the dashboard on 127.0.0.1:$port does not answer; start the stack first"
if [ "$running" = "$sha" ]; then
  echo "$sha is already the running release"
  exit 0
fi
echo "running $running, .env says $previous_release"

step 'building the image'
echo "$digest  $archive" | sha256sum --check --quiet
rm -rf "$build" && mkdir -p "$build" && tar -xzf "$archive" -C "$build"
[ -f "$build/Dockerfile" ] && [ -f "$build/compose.yaml" ] || fail 65 'the archive has no Dockerfile or compose.yaml'
docker build --quiet --tag "private-finances:$sha" "$build" >/dev/null
echo "private-finances:$sha"

# The migration has to be proven against a database that is already at the
# deployed schema version, so the live one is dumped and restored into a
# scratch database inside the same container. The dump is also the
# pre-deployment copy a rollback would need, kept under the same retention rule
# as the systemd deployment's.
step 'rehearsing the migration'
mkdir -p -m 700 "$predeploy_dir"
dump=$predeploy_dir/$(date +%s%N).dump
if ! compose exec -T db pg_dump --format=custom --no-owner --no-acl -U "$database_user" "$database" >"$dump" ||
  [ "$(stat -c %s "$dump")" -le 1024 ]; then
  rm -f "$dump"
  fail 70 'the pre-deployment dump failed or is implausibly small'
fi
chmod 600 "$dump"
compose exec -T db psql -U "$database_user" -d postgres -v ON_ERROR_STOP=1 -q \
  -c "drop database if exists $scratch_db" -c "create database $scratch_db" >/dev/null
rehearsing=1
restore_log=$(mktemp)
compose exec -T db pg_restore --no-owner --no-acl -U "$database_user" -d "$scratch_db" <"$dump" 2>"$restore_log" ||
  echo "note: pg_restore reported $(wc -l <"$restore_log") lines; the rehearsal below decides" >&2
rm -f "$restore_log"
scratch_url_from() {
  python3 - "$1" "$2" <<'PY'
import sys, urllib.parse
path, scratch = sys.argv[1:]
url = ''
for line in open(path):
    if line.startswith('DATABASE_URL='):
        url = line.split('=', 1)[1].strip().strip('"').strip("'")
if not url:
    sys.exit('DATABASE_URL not found in app.env')
parts = urllib.parse.urlsplit(url)
print(urllib.parse.urlunsplit(parts._replace(path='/' + scratch)))
PY
}
scratch_url=$(scratch_url_from "$config_dir/app.env" "$scratch_db")
cat >"$check_script" <<'CHECK'
const { postgresDatabase, migrate } = await import(
  process.env.RELEASE_DATABASE_MODULE,
);
const db = postgresDatabase(process.env.DATABASE_URL);
const started = Date.now();
await migrate(db);
const one = async (sql) => (await db.query(sql)).rows[0].v;
console.log(
  JSON.stringify({
    migrationMs: Date.now() - started,
    schema: await one('select max(version)::int as v from schema_versions'),
    transactions: await one('select count(*)::int as v from transactions'),
    activeRefundLinks: await one(
      "select count(*)::int as v from refund_links where state='active'",
    ),
    expensesWithoutCategory: await one(
      "select count(*)::int as v from transactions where kind='personal_expense' and category is null",
    ),
    filedOnHeading: await one(
      'select count(*)::int as v from transactions t join category_tree c on c.id=t.category_id where exists(select 1 from category_tree k where k.parent_id=c.id)',
    ),
  }),
);
await db.close();
CHECK
chmod 644 "$check_script"
PF_RELEASE=$sha compose run --rm --no-deps -T \
  -e DATABASE_URL="$scratch_url" \
  -e RELEASE_DATABASE_MODULE=/app/dist/src/database.js \
  -v "$check_script:/app/migrate-check.mjs:ro" \
  app node /app/migrate-check.mjs
compose exec -T db psql -U "$database_user" -d postgres -qc "drop database if exists $scratch_db" >/dev/null
rehearsing=

# Imports write while they run and the worker holds leases; both pause for the
# switch so no process is left speaking the previous schema. The enabled set is
# read from systemd's own wants directory. `paused` is set before the first
# stop so that a failure anywhere after it resumes them.
step 'pausing imports and the worker'
timers=$(ls /etc/systemd/system/timers.target.wants/ 2>/dev/null | grep '^private-finances-sync@' || true)
paused=1
if [ -n "$timers" ]; then
  # shellcheck disable=SC2086
  systemctl stop $timers
else
  echo 'no import timers are enabled on this host'
fi
if compose ps --status running --services 2>/dev/null | grep -qx telegram; then
  telegram_was_running=1
  compose stop telegram >/dev/null 2>&1 || true
else
  echo 'the Telegram worker is not running on this host and will not be started'
fi
for _ in $(seq 1 60); do
  workers_running || break
  sleep 5
done
workers_running && fail 75 'an import is still running after five minutes; the previous release keeps serving'
echo paused

step 'installing and switching'
[ "$(ready_release)" = "$running" ] ||
  fail 65 "the running release moved from $running to $(ready_release) during the build; release again"
install -m 644 "$build/compose.yaml" compose.yaml.next && mv -f compose.yaml.next compose.yaml
mkdir -p deploy
install -m 644 "$build/deploy/compose.edge.yaml" deploy/compose.edge.yaml
install -m 644 "$build/deploy/local-backup.py" deploy/local-backup.py
mkdir -p scripts
install -m 755 "$build/scripts/backup.sh" scripts/backup.sh
# A unit that changed in the repository takes effect at the next release;
# installing a new one, and the per-bank timer drop-ins, stay deliberate acts.
changed=0
for unit in "$build"/deploy/containers/*.service; do
  installed=/etc/systemd/system/$(basename "$unit")
  [ -f "$installed" ] || continue
  cmp -s "$unit" "$installed" && continue
  install -m 644 "$unit" "$installed"
  echo "unit updated: $(basename "$unit")"
  changed=1
done
[ $changed = 1 ] && systemctl daemon-reload
set_release() {
  python3 - "$1" <<'PY'
import os, re, sys
release = sys.argv[1]
text = open('.env').read()
if re.search(r'^PF_RELEASE=', text, flags=re.M):
    text = re.sub(r'^PF_RELEASE=.*$', 'PF_RELEASE=' + release, text, flags=re.M)
else:
    text += ('' if text.endswith('\n') or not text else '\n') + 'PF_RELEASE=' + release + '\n'
with open('.env.next', 'w') as out:
    out.write(text)
os.chmod('.env.next', 0o644)
os.replace('.env.next', '.env')
PY
}
set_release "$sha"
# shellcheck disable=SC2086
if compose up -d --no-build --wait --wait-timeout 180 $services && wait_for_release "$sha"; then
  echo "{\"event\":\"deployment_succeeded\",\"release\":\"$sha\",\"previousRelease\":\"$running\"}"
else
  echo 'the new release did not become ready; putting the previous image back' >&2
  set_release "$previous_release"
  # shellcheck disable=SC2086
  compose up -d --no-build --wait --wait-timeout 180 $services >/dev/null 2>&1 || true
  wait_for_release "$running" || echo "warning: the previous release $running is not answering either" >&2
  fail 70 '{"event":"deployment_failed","action":"previous_release_restored_inspect_logs"}'
fi

step 'resuming imports and the worker'
resume_services
paused=

step 'verifying'
schema=$(compose exec -T db psql -U "$database_user" -d "$database" -tAc 'select max(version) from schema_versions')
rows=$(compose exec -T db psql -U "$database_user" -d "$database" -tAc 'select count(*) from transactions')
printf '{"release":"%s","schema":%s,"transactions":%s,"services":"%s"}\n' \
  "$(ready_release)" "$schema" "$rows" "$(compose ps --format '{{.Service}}={{.State}}' | tr '\n' ' ')"
[ "$(ready_release)" = "$sha" ] || fail 76 'the dashboard answers with a different release'

# Pruning runs only after a switch has succeeded, and a prune that fails is
# reported rather than failing a deployment that has already worked. Images
# beyond the newest ten (and never the live one or the one it replaced) go,
# dangling layers go, and the BuildKit cache is held to a bound — on the
# destination server it had grown to 76 GB unattended.
step 'pruning'
python3 - "$predeploy_dir" <<'PY' || echo '{"event":"predeploy_prune_failed"}' >&2
import sys
from pathlib import Path
from runpy import run_path
expired = run_path('deploy/local-backup.py')['expired_backups']
removed = 0
for old in expired(Path(sys.argv[1])):
    old.unlink()
    removed += 1
print('{"event":"predeploy_pruned","removed":%d}' % removed)
PY
{
  gone=0
  for tag in $(docker image ls --format '{{.CreatedAt}}\t{{.Tag}}' private-finances | sort -r | cut -f2 | tail -n +11); do
    [ "$tag" = "$sha" ] || [ "$tag" = "$running" ] && continue
    docker image rm --no-prune "private-finances:$tag" >/dev/null && gone=$((gone + 1))
  done
  docker image prune --force >/dev/null
  docker builder prune --force --keep-storage 10GB >/dev/null
  echo "{\"event\":\"images_pruned\",\"removed\":$gone}"
} || echo '{"event":"image_prune_failed"}' >&2

echo "deployed $sha"
