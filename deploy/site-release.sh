#!/bin/bash
# Publishes the landing page: the site/ folder of a commit on origin/main, onto
# the host that serves keepard.com.
#
#   bash deploy/site-release.sh <ssh host> [commit]     (default: origin/main)
#
# The files go to /opt/keepard-site/releases/<commit>, and `current` moves to
# them in one rename, so a visitor sees the old page or the new one and never
# half of each. The container in deploy/site/compose.yaml is installed and
# started too; it serves `current` read-only, so new files need no restart.
# The three newest releases stay on the host; going back is running this
# again with an older commit.
#
# This touches nothing of the application, the showcase or the edge proxy.
set -euo pipefail

host=${1:?usage: bash deploy/site-release.sh <ssh host> [commit]}
ref=${2:-origin/main}

git fetch -q origin
sha=$(git rev-parse --verify "$ref^{commit}")
git merge-base --is-ancestor "$sha" origin/main || {
  echo "refusing: $sha is not on origin/main" >&2
  exit 66
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git archive --format=tar -o "$tmp/site.tar" "$sha" site deploy/site/compose.yaml
scp -q "$tmp/site.tar" "$host:/tmp/keepard-site-$sha.tar"

ssh -o BatchMode=yes "$host" sudo -n bash -s -- "$sha" <<'REMOTE'
set -euo pipefail
sha=$1
base=/opt/keepard-site
tar=/tmp/keepard-site-$sha.tar
work=$(mktemp -d)
trap 'rm -rf "$work" "$tar"' EXIT

tar -xf "$tar" -C "$work"
install -d -m 755 "$base" "$base/releases"
dest=$base/releases/$sha
rm -rf "$dest.new"
mkdir "$dest.new"
cp -R "$work/site/." "$dest.new/"
# The folder's notes are for the repository, not for visitors.
rm -rf "$dest.new/README.md" "$dest.new/brand-options"
chmod -R u=rwX,go=rX "$dest.new"
rm -rf "$dest"
mv "$dest.new" "$dest"
touch "$dest"
install -m 644 "$work/deploy/site/compose.yaml" "$base/compose.yaml"

ln -sfn "releases/$sha" "$base/current.new"
mv -Tf "$base/current.new" "$base/current"

cd "$base"
docker compose up -d --quiet-pull
# The page as the container serves it, before anybody else sees it.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if docker compose exec -T site wget -qO- http://127.0.0.1:8080/ 2>/dev/null |
    grep -q '<title>Keepard'; then
    echo "serving $sha"
    break
  fi
  [ "$attempt" = 10 ] && { echo "the container does not serve the page" >&2; exit 1; }
  sleep 1
done

ls -1t releases | tail -n +4 | while read -r old; do
  [ "$old" = "$sha" ] || rm -rf "releases/$old"
done
REMOTE
