# Keepard landing page

The public page meant for keepard.com: what the project is, who it is for, and
how to fork and run your own. One static `index.html`, no build step and no
third-party requests except the GitHub API call that fills in the star count.

## How it is served

On the container host, in a container of its own: `deploy/site/compose.yaml`
runs a small Caddy that serves `/opt/keepard-site/current` read-only on the
`edge` network, and the edge proxy (`deploy/edge/Caddyfile`) answers for
keepard.com, redirects www.keepard.com to it, and holds the certificate. The
page shares nothing with the application or the showcase.

To publish what is on `origin/main`:

```sh
bash deploy/site-release.sh hlyna
```

It copies `site/` (without this README) to
`/opt/keepard-site/releases/<commit>`, switches `current` to it in one rename,
starts or updates the container, and checks that the container serves the
page. It keeps the three newest releases; to go back, run it again with an
older commit as the second argument.

## Preview

```sh
python3 -m http.server 4321 --bind 127.0.0.1 --directory site
```

Open <http://127.0.0.1:4321>. Add `?lang=uk` or `?lang=en` to force a language.

## How the two languages work

Every translated piece is written twice, as `<span lang="en">` and
`<span lang="uk">`, and CSS hides the one that does not match `<html lang>`.
A small script in `<head>` sets that attribute before the first paint, in this
order: `?lang=`, the visitor's saved choice (`localStorage`), then the browser's
language list (any `uk*` gives Ukrainian, anything else English). The switch in
the header saves the choice. Without JavaScript the page is English.

When you edit copy, change both spans; a piece with only one language
disappears in the other.

## Screenshots

`img/` holds five screenshots from the demo workspace, filled with an invented
household (Alex and Sam). Never put a screenshot of the real dashboard here.

## The repository name

The repository URL is set once, in `REPO` at the bottom of `index.html`; the
`href`s in the markup are the no-JavaScript fallback. If the repository is
renamed, change both.
