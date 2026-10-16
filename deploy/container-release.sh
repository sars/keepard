#!/bin/bash
# One command per release onto a container host: build the image of the exact
# commit on the server, prove the migration against a restored copy of the real
# database, recreate the services and verify. Every step is a gate; the first
# failure stops the release and the previous image keeps serving.
#
#   bash deploy/container-release.sh <40-character commit SHA> <ssh host> [--allow-rollback]
#
# The host is named every time: during the move two servers exist, and a
# default would make the wrong one a typo away. The counterpart for the systemd
# deployment is release.sh; this script keeps its gates and changes only the
# commands, see docs/containers.md.
#
# What runs here is small: the checks that need this machine's Git and GitHub
# access, the archive, and the copy. Everything that touches the server is in
# container-release-remote.sh, which is copied over and run as root there.
set -euo pipefail

sha=${1:-}
host=${2:-}
allow_rollback=
for argument in "${@:3}"; do
  case $argument in
  --allow-rollback) allow_rollback=1 ;;
  *)
    echo "unknown argument: $argument" >&2
    exit 64
    ;;
  esac
done
if ! [[ $sha =~ ^[0-9a-f]{40}$ ]] || [ -z "$host" ] || [[ $host == --* ]]; then
  echo "usage: bash deploy/container-release.sh <40-character commit SHA> <ssh host> [--allow-rollback]" >&2
  exit 64
fi
here=$(cd "$(dirname "$0")" && pwd)
port=${PF_PORT:-3300}
gh=${PF_GH:-$HOME/.local/bin/pf-gh}

step() { printf '\n=== %s ===\n' "$1"; }

step 'the commit'
git fetch -q origin
git merge-base --is-ancestor "$sha" origin/main 2>/dev/null || {
  echo "refusing: $sha is not on origin/main" >&2
  exit 65
}

# The systemd release runs the test suite on the server. Here the suite has
# already run, in CI, on this very commit — the image is built there too — and
# the release asks GitHub whether both passed rather than running them again on
# a machine that has no development dependencies.
step 'the checks GitHub ran on it'
[ -x "$gh" ] || {
  echo "refusing: $gh is not available to read the commit's checks; set PF_GH" >&2
  exit 66
}
checks=$("$gh" api "repos/{owner}/{repo}/commits/$sha/check-runs?per_page=100" \
  --jq '.check_runs[] | select(.name == "Application checks" or .name == "Image and stack") | "\(.name): \(.status) \(.conclusion)"' \
  | sort -u)
printf '%s\n' "$checks"
for required in 'Application checks' 'Image and stack'; do
  grep -qx "$required: completed success" <<<"$checks" || {
    echo "refusing: '$required' has not passed for $sha" >&2
    exit 66
  }
done

# Another agent may have released while this one was working. Deploying an
# older commit would silently withdraw their fix, so the running release has to
# be an ancestor of the target unless a rollback is asked for explicitly. A
# shadow installation reports a release that is not a commit at all; the first
# real release onto it is allowed through with a note.
step 'the running release'
running=$(ssh -o BatchMode=yes "$host" "curl -fsS http://127.0.0.1:$port/health/ready" \
  | python3 -c 'import json, sys; print(json.load(sys.stdin).get("release", ""))')
if [ "$running" = "$sha" ]; then
  echo "$sha is already the running release"
  exit 0
fi
if [[ $running =~ ^[0-9a-f]{40}$ ]]; then
  if [ -z "$allow_rollback" ]; then
    git cat-file -e "$running^{commit}" 2>/dev/null || {
      echo "refusing: the running release $running is unknown here; fetch it or pass --allow-rollback" >&2
      exit 65
    }
    git merge-base --is-ancestor "$running" "$sha" || {
      echo "refusing: $sha does not contain the running release $running; pass --allow-rollback to go back deliberately" >&2
      exit 65
    }
  fi
  echo "replacing $running"
else
  echo "the running release is '$running', not a commit; treating this as the first release onto this host"
fi

short=${sha:0:7}
archive_local=$(mktemp -t "pf-$short.XXXXXX")
archive=/tmp/pf-$short.tar.gz
remote_script=/tmp/pf-release-$short.sh
if ssh -o BatchMode=yes "$host" 'test "$(id -u)" = 0'; then sudo=; else sudo='sudo -n'; fi

# Whatever happens below, nothing of this release is left on either machine
# except the image, the predeploy dump and the installed files. The remote
# script removes its own build tree and archive; this covers the case where it
# never ran.
cleanup_on_exit() {
  status=$?
  rm -f "$archive_local"
  ssh -o BatchMode=yes "$host" "$sudo rm -rf $remote_script $archive /tmp/pf-build-$short" 2>/dev/null ||
    echo "warning: temporary files may remain on $host" >&2
  exit $status
}
trap cleanup_on_exit EXIT

step 'archiving and copying'
git archive --format=tar.gz --output "$archive_local" "$sha"
digest=$(shasum -a 256 "$archive_local" | cut -d' ' -f1)
scp -q "$archive_local" "$host:$archive"
scp -q "$here/container-release-remote.sh" "$host:$remote_script"
echo "archive $digest"

# The remote script's own output narrates the rest: build, rehearsal, pause,
# switch, verification, pruning.
ssh -o BatchMode=yes "$host" "$sudo bash $remote_script $sha $archive $digest"
