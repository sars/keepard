#!/bin/bash
# Removes the finance installation from the systemd host after the move to
# the container host, from the operator's machine, leaving the showcase (an
# invented household, no credentials) running there. Without --execute it
# only prints what it would remove; with --execute it first streams one last
# dump of the old database to the new host, then removes.
#
#   bash deploy/decommission-old-host.sh <old ssh host> <new ssh host> [--execute]
#
# What goes: the units the cutover disabled and their drop-ins, the local
# backup unit, the Tailscale serve mapping of the old dashboard, the
# PostgreSQL database and role, the credentials and configuration except
# `showcase.env`, the state, consent, sync and local-backup directories, the
# contents of the account's home directory, and every release except the one
# the showcase runs. What stays: the showcase service, its reseed units, its
# state directory, `showcase.env`, the `private-finances` account the showcase
# runs as, the release it runs, PostgreSQL itself and everything that is not
# this project's.
set -euo pipefail

old=${1:-}
new=${2:-}
mode=${3:-}
[ -n "$old" ] && [ -n "$new" ] && { [ -z "$mode" ] || [ "$mode" = --execute ]; } || {
  echo "usage: bash deploy/decommission-old-host.sh <old ssh host> <new ssh host> [--execute]" >&2
  exit 64
}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
step() { printf '\n=== %s ===\n' "$1"; }
# Scripts travel as arguments, not on stdin, for the reason written in
# deploy/cutover-to-containers.sh.
on_old() { local script; script=$(cat); ssh -o BatchMode=yes "$old" "sudo -n bash -c $(printf %q "$script")"; }
on_new() { local script; script=$(cat); ssh -o BatchMode=yes "$new" "bash -c $(printf %q "$script")"; }
quiet() { grep -v -i -E 'perl: warning|locale|LANGUAGE|LC_ALL|LC_CTYPE|LANG =|are supported' || true; }

step 'preflight: the new host serves the household'
on_new <<'REMOTE'
set -e
cd /opt/private-finances
curl -fsS http://127.0.0.1:3300/health/ready; echo
running=$(docker compose ps --status running --format '{{.Service}}' | sort | tr '\n' ' ')
echo "services running: $running"
case "$running" in *app*db*telegram*) ;; *) echo 'app, db and telegram must all be running' >&2; exit 65;; esac
timers=$(ls /etc/systemd/system/timers.target.wants/ | grep -c '^private-finances' || true)
echo "timers enabled: $timers"
[ "$timers" -ge 8 ] || { echo 'the new host has fewer timers than the move installed' >&2; exit 65; }
REMOTE

step 'preflight: the old host is the stopped one'
on_old <<'REMOTE' | quiet
set -e
[ -f /etc/private-finances/cutover-disabled-units ] || { echo 'no cutover-disabled-units list: this host was not cut over' >&2; exit 65; }
# shellcheck disable=SC2046
active=$(systemctl is-active $(cat /etc/private-finances/cutover-disabled-units) 2>/dev/null | grep -vc '^inactive$' || true)
[ "$active" = 0 ] || { echo "$active of the disabled units are active" >&2; exit 65; }
systemctl is-active --quiet private-finances-showcase.service && echo 'showcase: running, stays' || echo 'showcase: not running (nothing to keep running)'
REMOTE

step 'what goes'
on_old <<'REMOTE' | quiet
set -e
current=$(readlink -f /opt/private-finances/current)
echo "units:"
ls /etc/systemd/system | grep '^private-finances' | grep -v showcase | sed 's/^/  /'
echo "database: $(sudo -u postgres psql -Atc "select pg_size_pretty(pg_database_size('private_finances'))" 2>/dev/null || echo absent) private_finances, role private-finances"
echo "configuration: $(find /etc/private-finances -mindepth 1 ! -name showcase.env | wc -l) entries under /etc/private-finances (showcase.env stays)"
echo "directories:"
du -sh /var/lib/private-finances-backups /var/lib/private-finances-consent /var/lib/private-finances-sync 2>/dev/null | sed 's/^/  /'
echo "  $(du -sh /var/lib/private-finances | cut -f1) contents of /var/lib/private-finances (the account's home stays)"
echo "releases: $(ls /opt/private-finances/releases | grep -vc "^$(basename "$current")$" || true) of $(ls /opt/private-finances/releases | wc -l); $(basename "$current") stays for the showcase"
echo "tailscale serve: the https:8443 mapping of the old dashboard (10000, the showcase, stays)"
REMOTE

[ "$mode" = --execute ] || { printf '\nDry run. Add --execute to remove.\n'; exit 0; }

step '1. one last dump of the old database, kept on the new host'
dump=/var/lib/private-finances/predeploy/old-host-final-$stamp.dump
ssh -o BatchMode=yes "$old" 'sudo -n -u postgres pg_dump --format=custom private_finances' 2> >(quiet >&2) |
  ssh -o BatchMode=yes "$new" "umask 077 && cat > $dump"
on_new <<REMOTE
set -e
cd /opt/private-finances
tables=\$(docker compose exec -T db pg_restore --list < $dump | grep -c 'TABLE DATA')
echo "\$(stat -c %s $dump) bytes, \$tables tables, at $dump"
[ "\$tables" -ge 40 ] || { echo 'the dump lists too few tables' >&2; exit 70; }
REMOTE

step '2. old host: units, mapping, database, files'
on_old <<'REMOTE' | quiet
set -e
current=$(readlink -f /opt/private-finances/current)
units=$(ls /etc/systemd/system | grep '^private-finances' | grep -v showcase | grep -v '\.d$')
# shellcheck disable=SC2086
systemctl disable --now $units >/dev/null 2>&1 || true
for unit in $units; do rm -f "/etc/systemd/system/$unit"; done
rm -rf /etc/systemd/system/private-finances-sync@*.timer.d
systemctl daemon-reload
systemctl reset-failed
echo 'units removed'
tailscale serve --https=8443 off >/dev/null 2>&1 || true
if tailscale serve status --json 2>/dev/null | grep -q ':8443"'; then echo 'tailscale serve 8443: still mapped, remove by hand'; else echo 'tailscale serve 8443 removed'; fi
sudo -u postgres psql -qAtc "select pg_terminate_backend(pid) from pg_stat_activity where datname='private_finances'" >/dev/null
sudo -u postgres psql -qc 'drop database if exists private_finances'
sudo -u postgres psql -qc 'drop role if exists "private-finances"'
echo 'database and role dropped'
find /etc/private-finances -mindepth 1 ! -name showcase.env -delete
rm -rf /var/lib/private-finances-backups /var/lib/private-finances-consent /var/lib/private-finances-sync
find /var/lib/private-finances -mindepth 1 -maxdepth 1 ! -name '.bash*' ! -name .profile ! -name '.face*' -exec rm -rf {} +
for release in /opt/private-finances/releases/*; do [ "$release" = "$current" ] || rm -rf "$release"; done
echo 'files removed'
REMOTE

step '3. old host: what is left'
on_old <<'REMOTE' | quiet
set -e
echo "units: $(ls /etc/systemd/system | grep '^private-finances' | tr '\n' ' ')"
echo "failed: $(systemctl --failed --no-legend --no-pager | grep -c private-finances || true) private-finances units"
echo "databases named private_finances: $(sudo -u postgres psql -Atc "select count(*) from pg_database where datname='private_finances'")"
echo "configuration: $(ls -A /etc/private-finances | tr '\n' ' ')"
echo "releases: $(ls /opt/private-finances/releases | tr '\n' ' ')"
echo "home: $(ls -A /var/lib/private-finances | tr '\n' ' ')"
echo "tailscale serve: $(tailscale serve status --json 2>/dev/null | grep -oE ':[0-9]+"' | tr -d '":' | tr '\n' ' ')"
systemctl is-active --quiet private-finances-showcase.service && curl -fsS -o /dev/null http://127.0.0.1:3301/health/live && echo 'showcase: running and answering' || echo 'showcase: not running'
REMOTE

printf '\nDone. The old host now carries only the showcase.\n'
