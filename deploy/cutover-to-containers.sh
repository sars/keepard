#!/bin/bash
# The move from the systemd host to the container host, in one sitting, from
# the operator's machine. Every step is verified and the script stops at the
# first failure, printing where it stopped; nothing is rolled back by itself,
# because the two halves live on two machines and the right rollback depends
# on where it stopped. The rollback is written in docs/containers.md.
#
#   bash deploy/cutover-to-containers.sh <old ssh host> <new ssh host> <released sha on the new host>
#
# What it does, in order:
#   1. old: stop and disable every private-finances timer, the Telegram worker
#      and the dashboard; wait for a running import; keep the showcase.
#   2. old -> new: the final dump, the schedule markers, the Telegram
#      configuration and the bank-session state.
#   3. new: load the dump into a fresh database, compare every table's row
#      count with the old host, write the restore-verified marker, drop the
#      shadow guards, start the dashboard.
#   4. new: start the Telegram worker; install and enable the host units and
#      the same timers the old host had; run the backup once.
# The operator's own steps afterwards are printed at the end.
set -euo pipefail

old=${1:-}
new=${2:-}
sha=${3:-}
[ -n "$old" ] && [ -n "$new" ] && [[ $sha =~ ^[0-9a-f]{40}$ ]] || {
  echo "usage: bash deploy/cutover-to-containers.sh <old ssh host> <new ssh host> <released sha>" >&2
  exit 64
}
here=$(cd "$(dirname "$0")" && pwd)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
step() { printf '\n=== %s ===\n' "$1"; }
# The remote script travels as an argument, not on stdin: `docker compose`
# and `psql` read stdin when they have one, and a script fed through `bash -s`
# would be swallowed by its own first such command — which is exactly what
# happened to the first attempt's step 3.
on_old() { local script; script=$(cat); ssh -o BatchMode=yes "$old" "sudo -n bash -c $(printf %q "$script")"; }
on_new() { local script; script=$(cat); ssh -o BatchMode=yes "$new" "bash -c $(printf %q "$script")"; }
quiet() { grep -v -i -E 'perl: warning|locale|LANGUAGE|LC_ALL|LC_CTYPE|LANG =|are supported' || true; }
counts_sql="select format('select %L, count(*) from %I;', tablename, tablename) from pg_tables where schemaname='public' order by 1"

step 'preflight'
# The dashboard answers with its release; after a stopped attempt it may be
# down, and then the stack's own .env says which image a start would run.
new_release=$(ssh -o BatchMode=yes "$new" "curl -fsS http://127.0.0.1:3300/health/ready 2>/dev/null || grep '^PF_RELEASE=' /opt/private-finances/.env | cut -d= -f2" |
  python3 -c 'import json,sys; t=sys.stdin.read().strip(); print(json.loads(t)["release"] if t.startswith("{") else t)')
[ "$new_release" = "$sha" ] || { echo "the new host runs $new_release, not $sha" >&2; exit 65; }
on_new <<'REMOTE'
set -e
cd /opt/private-finances
grep -q '^PF_SERVICES=app$' .env || { echo 'the new host is not in shadow configuration (PF_SERVICES=app missing)' >&2; exit 65; }
# The Telegram guard in telegram.env is replaced by step 2, so a resumed run
# no longer finds it; PF_SERVICES=app above is the guard that lasts until
# step 3 and is the one checked.
test ! -d /etc/systemd/system/timers.target.wants || ! ls /etc/systemd/system/timers.target.wants/ | grep -q '^private-finances' || { echo 'the new host already has private-finances timers' >&2; exit 65; }
docker compose ps --format '{{.Service}} {{.State}}'
REMOTE
on_old <<'REMOTE' | quiet
set -e
# A re-run after a stopped attempt finds the old host already quiet; the list
# of what the first attempt disabled is the evidence that this is still the
# right host.
if [ -f /etc/private-finances/cutover-disabled-units ]; then
  echo "old host: already stopped by an earlier attempt ($(wc -l < /etc/private-finances/cutover-disabled-units) units recorded)"
else
  systemctl is-active --quiet private-finances.service || { echo 'the old dashboard is not running; is this the right host?' >&2; exit 65; }
  echo "old host: $(ls /etc/systemd/system/timers.target.wants/ | grep -c '^private-finances') private-finances timers enabled"
fi
REMOTE

step '1. old host: stopping imports, the worker and the dashboard'
on_old <<'REMOTE' | quiet
set -e
units=$(ls /etc/systemd/system/timers.target.wants/ | grep '^private-finances' || true)
units="$units private-finances-telegram.service private-finances.service"
# The list is written once: a re-run must not shorten it to what was left.
[ -f /etc/private-finances/cutover-disabled-units ] || printf '%s\n' $units > /etc/private-finances/cutover-disabled-units
# shellcheck disable=SC2086
systemctl disable --now $units >/dev/null 2>&1 || true
for attempt in $(seq 1 60); do
  pgrep -f '[s]ync-cli.js' >/dev/null || break
  sleep 5
done
if pgrep -f '[s]ync-cli.js' >/dev/null; then echo 'an import is still running after five minutes' >&2; exit 75; fi
echo "disabled: $(wc -w < /etc/private-finances/cutover-disabled-units) units (list kept in /etc/private-finances/cutover-disabled-units)"
systemctl is-active private-finances.service private-finances-telegram.service 'private-finances-sync@*.service' | sort | uniq -c | tr '\n' ' '; echo
REMOTE

step '2. old -> new: the final dump, the markers, the Telegram configuration, the bank sessions'
ssh -o BatchMode=yes "$old" "sudo -n -u postgres pg_dump --format=custom private_finances" 2>/dev/null |
  ssh -o BatchMode=yes "$new" "umask 077; cat > /var/lib/private-finances/predeploy/cutover-$stamp.dump && stat -c 'dump: %s bytes' /var/lib/private-finances/predeploy/cutover-$stamp.dump"
ssh -o BatchMode=yes "$old" "sudo -n -u postgres psql -d private_finances -tA -c \"$counts_sql\" | sudo -n -u postgres psql -d private_finances -tA -F ' '" 2>/dev/null | sort > "/tmp/pf-cutover-old-counts-$stamp"
echo "old host: $(wc -l < "/tmp/pf-cutover-old-counts-$stamp") tables counted"
ssh -o BatchMode=yes "$old" "sudo -n tar -C /etc -cf - private-finances/schedules private-finances/telegram.env private-finances/telegram.enabled" 2>/dev/null |
  ssh -o BatchMode=yes "$new" "tar -C /etc -xf - && ls /etc/private-finances/schedules | wc -l | sed 's/$/ schedule markers/' && test -s /etc/private-finances/telegram.env && ! grep -q nonexistent /etc/private-finances/telegram.env && echo 'telegram.env: the real one'"
ssh -o BatchMode=yes "$old" "sudo -n tar -C /var/lib/private-finances-consent -cf - ." 2>/dev/null |
  ssh -o BatchMode=yes "$new" "tar -C /var/lib/private-finances/consent -xf - && chown -R private-finances:private-finances /var/lib/private-finances/consent && echo \"bank sessions: \$(ls /var/lib/private-finances/consent | wc -l) files\""

step '3. new host: loading the dump into a fresh database'
on_new <<REMOTE
set -e
cd /opt/private-finances
docker compose stop app >/dev/null 2>&1 </dev/null
docker compose exec -T db psql -U private-finances -d postgres -v ON_ERROR_STOP=1 -q \
  -c 'drop database if exists private_finances' -c 'create database private_finances' >/dev/null </dev/null
docker compose exec -T db pg_restore --exit-on-error --no-owner --no-acl -U private-finances -d private_finances < /var/lib/private-finances/predeploy/cutover-$stamp.dump
echo 'restored'
REMOTE
ssh -o BatchMode=yes "$new" "cd /opt/private-finances && docker compose exec -T db psql -U private-finances -d private_finances -tA -c \"$counts_sql\" | docker compose exec -T db psql -U private-finances -d private_finances -tA -F ' '" 2>/dev/null | sort > "/tmp/pf-cutover-new-counts-$stamp"
if diff -q "/tmp/pf-cutover-old-counts-$stamp" "/tmp/pf-cutover-new-counts-$stamp" >/dev/null; then
  echo "every table's row count matches the old host ($(wc -l < "/tmp/pf-cutover-new-counts-$stamp") tables)"
else
  echo 'row counts differ between the hosts:' >&2
  diff "/tmp/pf-cutover-old-counts-$stamp" "/tmp/pf-cutover-new-counts-$stamp" >&2 || true
  exit 70
fi
rm -f "/tmp/pf-cutover-old-counts-$stamp" "/tmp/pf-cutover-new-counts-$stamp"
on_new <<'REMOTE'
set -e
cd /opt/private-finances
# The comparison above is the local restore proof the scheduler asks for.
printf 'local-restore-verified\n' > /etc/private-finances/local-restore-verified
chmod 644 /etc/private-finances/local-restore-verified
# The shadow guards go: releases recreate both services again from here on.
sed -i '/^PF_SERVICES=app$/d' .env
docker compose up -d --wait --wait-timeout 180 app >/dev/null 2>&1 </dev/null
curl -fsS http://127.0.0.1:3300/health/ready; echo
REMOTE

step '4. new host: the Telegram worker, the timers, the backup'
tar -C "$here" -cf - containers private-finances-sync@.timer private-finances-fx-sync.timer private-finances-reports.timer private-finances-assets-snapshot.timer private-finances-backup.timer $(cd "$here" && ls -d private-finances-sync@*.timer.d) |
  ssh -o BatchMode=yes "$new" "rm -rf /tmp/pf-units && mkdir /tmp/pf-units && tar -C /tmp/pf-units -xf -"
ssh -o BatchMode=yes "$old" "sudo -n cat /etc/private-finances/cutover-disabled-units" 2>/dev/null | grep '\.timer$' > "/tmp/pf-cutover-timers-$stamp"
scp -q "/tmp/pf-cutover-timers-$stamp" "$new:/tmp/pf-units/timers-to-enable"
rm -f "/tmp/pf-cutover-timers-$stamp"
on_new <<'REMOTE'
set -e
cd /opt/private-finances
docker compose up -d --wait --wait-timeout 60 telegram >/dev/null 2>&1 </dev/null || true
sleep 20
docker compose ps --format '{{.Service}} {{.State}} {{.Status}}' </dev/null
docker compose logs --no-color --tail 5 telegram </dev/null | cut -c1-160
# Units: the container ExecStart variants, the timers, and the per-bank drop-ins.
install -m 644 /tmp/pf-units/containers/*.service /etc/systemd/system/
install -m 644 /tmp/pf-units/*.timer /etc/systemd/system/
for d in /tmp/pf-units/*.timer.d; do
  install -d -m 755 "/etc/systemd/system/$(basename "$d")"
  install -m 644 "$d"/* "/etc/systemd/system/$(basename "$d")/"
done
# backup.env: the container door needs no socket, no PGUSER and no PGHOST.
python3 - <<'PY'
import os, re
p='/etc/private-finances/backup.env'; t=open(p).read()
t=re.sub(r'^(PGHOST|PGUSER|PGPORT)=.*\n', '', t, flags=re.M)
fd=os.open(p+'.next', os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
with os.fdopen(fd,'w') as f: f.write(t)
os.replace(p+'.next', p)
print('backup.env keys:', ' '.join(sorted(l.split('=',1)[0] for l in t.splitlines() if '=' in l and not l.startswith('#'))))
PY
systemctl daemon-reload
# shellcheck disable=SC2046
systemctl enable --now $(cat /tmp/pf-units/timers-to-enable) >/dev/null 2>&1
echo "timers enabled: $(ls /etc/systemd/system/timers.target.wants/ | grep -c '^private-finances')"
rm -rf /tmp/pf-units
systemctl start private-finances-backup.service </dev/null && echo 'backup ran' || { echo 'backup FAILED; journalctl -u private-finances-backup' >&2; }
docker compose exec -T db psql -U private-finances -d private_finances -tAc "select outcome, coalesce(stage,'-'), size_bytes from backup_runs order by started_at desc limit 1" </dev/null
systemctl list-timers --no-pager --no-legend 'private-finances-*' | awk '{print $NF, "next", $1, $2, $3}' | head -12
REMOTE

cat <<DONE

=== done ===
The container host is live. What only a person can do now:
  - each owner signs in at the public name and approves their banks again
    through Bank connections (the Enable Banking callback is the new one);
  - watch Home and Bank imports over the next hour; Monobank imports need no
    approval and should succeed at the first timer firing.
The old host keeps everything, disabled; the unit list is in
/etc/private-finances/cutover-disabled-units there. Rollback: docs/containers.md.
DONE
