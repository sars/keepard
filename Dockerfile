# syntax=docker/dockerfile:1.7
# The application image: one build of one commit, run by compose.yaml as the
# dashboard, the Telegram worker, the showcase and the scheduled jobs. Nothing private is
# baked in — configuration and credentials are mounted at run time from
# /etc/private-finances, exactly where the systemd deployment reads them.
#
#   docker compose build                      # tags private-finances:local
#   PF_RELEASE=<sha> docker compose build     # tags private-finances:<sha>
#
# The Node version matches .nvmrc and package.json's engines range; pnpm is the
# version package.json pins, installed the way the CI workflow installs it.
ARG NODE_VERSION=24.19.0

FROM node:${NODE_VERSION}-bookworm-slim AS base
ENV PNPM_HOME=/pnpm \
    PATH=/pnpm:$PATH \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN npm install --global pnpm@11.19.0 >/dev/null
WORKDIR /app
# The postinstall hook is macOS-only and a no-op elsewhere, but it must exist
# for `pnpm install` to run at all.
COPY package.json pnpm-lock.yaml ./
COPY scripts/hide-node-modules-from-spotlight.mjs scripts/

# Every dependency, for the TypeScript and Vite builds.
FROM base AS build
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile --store-dir=/pnpm/store
COPY . .
RUN pnpm build \
 && test -f dist/src/main.js \
 && test -f dist/frontend/index.html

# Production dependencies only, resolved from the same lockfile.
FROM base AS production-dependencies
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile --prod --store-dir=/pnpm/store

# What runs. poppler-utils renders PDF receipts, as on the systemd host;
# nothing else outside the Node tree is needed inside the container.
FROM node:${NODE_VERSION}-bookworm-slim AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends poppler-utils \
 && rm -rf /var/lib/apt/lists/*
ENV NODE_ENV=production \
    PORT=3300
WORKDIR /app
COPY --from=production-dependencies /app/package.json ./
COPY --from=production-dependencies /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
# The showcase's reseed job and the demo seeders run from the built tree, and
# the seeder attaches the committed receipt pictures, resolved from dist/src
# as ../../showcase/receipts.
COPY --from=build /app/scripts/*.mjs ./scripts/
COPY --from=build /app/showcase/receipts ./showcase/receipts
# The frontend is served from dist/frontend relative to the working directory.
# The container runs read-only and as the uid compose assigns; everything here
# is world-readable and nothing is written under /app.
RUN chmod -R go+rX /app
USER node
EXPOSE 3300
HEALTHCHECK --interval=15s --timeout=5s --start-period=40s --retries=5 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:' + process.env.PORT + '/health/live').then((r) => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]
CMD ["node", "dist/src/main.js"]
