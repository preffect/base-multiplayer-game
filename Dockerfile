# The game's prod image: the built server, which also serves the built client (GAME_CLIENT_DIR), so the page, /api
# and the WebSocket at /ws are one port. The platform runs it with its shared chart: as user 65532, on a read-only
# root with an empty /tmp, with PORT set. scripts/check-image.sh checks it does.
# Template-owned: it names no game, only the template's packages/{shared,server,client}.
ARG NODE_IMAGE=node:24.22.2-alpine@sha256:a34ab6d7f6f4813f4d0c5469d74685604b962fbdbf5793a7bc7b4998ecb867c8

FROM ${NODE_IMAGE} AS build
ENV CI=true
WORKDIR /app
# pnpm, pinned by its registry tarball's checksum, inside package.json's engines range.
ARG PNPM_VERSION=10.34.1
ADD --checksum=sha256:b568bc5ee2b68a9735743c1b9f09b3d3065de64befaf186c5d01b2f084d16cc0 \
  https://registry.npmjs.org/pnpm/-/pnpm-${PNPM_VERSION}.tgz /tmp/pnpm.tgz
RUN npm install --global --no-fund --no-audit /tmp/pnpm.tgz
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
COPY packages ./packages
# Top-level folders a game has only sometimes, copied when it has them: public/, which a client may take assets from
# (angular.json's assets), and patches/, which pnpm-workspace.yaml's patchedDependencies name and the install needs.
RUN --mount=type=bind,target=/context for folder in public patches; do \
    if [ -d "/context/$folder" ]; then cp -a "/context/$folder" "./$folder"; fi; \
  done
# Built with everything, then installed again with production dependencies only.
RUN pnpm install --frozen-lockfile && pnpm -r build \
  && rm -rf node_modules packages/*/node_modules && pnpm install --prod --frozen-lockfile --offline
# What runs: the dependencies, the shared package and the server, built, and the client's files. A package with no
# dependencies of its own has no node_modules, so this is a script, not COPY lines.
RUN mkdir -p /out/packages \
  && cp -a node_modules package.json /out/ \
  && for package in shared server; do \
       mkdir -p "/out/packages/$package" && cp -a "packages/$package/package.json" "packages/$package/dist" "/out/packages/$package/" \
       && if [ -d "packages/$package/node_modules" ]; then cp -a "packages/$package/node_modules" "/out/packages/$package/"; fi; \
     done \
  && cp -a packages/client/dist/browser /out/client

FROM ${NODE_IMAGE}
# The game needs only node: no package manager, and none of their bundled packages' CVEs.
RUN rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
  /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-v*
WORKDIR /app
ENV NODE_ENV=production GAME_CLIENT_DIR=/app/client
COPY --from=build /out ./
USER 65532:65532
CMD ["node", "packages/server/dist/index.js"]
