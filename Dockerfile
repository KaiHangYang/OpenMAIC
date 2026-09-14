# syntax=docker/dockerfile:1

# ---- Stage 1: Base ----
FROM node:22-alpine AS base

ARG ALPINE_MIRROR=""
ARG NPM_REGISTRY=""

RUN if [ -n "$ALPINE_MIRROR" ]; then \
      sed -i "s|dl-cdn.alpinelinux.org|$ALPINE_MIRROR|g" /etc/apk/repositories; \
    fi && \
    apk add --no-cache libc6-compat

RUN npm_registry="$NPM_REGISTRY"; \
    while [ "${npm_registry%/}" != "$npm_registry" ]; do \
      npm_registry="${npm_registry%/}"; \
    done; \
    if [ -n "$npm_registry" ]; then \
      export COREPACK_NPM_REGISTRY="$npm_registry"; \
    fi && \
    corepack enable && \
    corepack prepare pnpm@10.28.0 --activate

WORKDIR /app

# ---- Stage 2: Dependencies ----
FROM base AS deps

ARG NPM_REGISTRY

# Native build tools for sharp, @napi-rs/canvas
RUN apk add --no-cache python3 build-base g++ cairo-dev pango-dev jpeg-dev giflib-dev librsvg-dev

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages/ ./packages/
COPY scripts/ ./scripts/

RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
    npm_registry="$NPM_REGISTRY"; \
    while [ "${npm_registry%/}" != "$npm_registry" ]; do \
      npm_registry="${npm_registry%/}"; \
    done; \
    if [ -n "$npm_registry" ]; then \
      pnpm config set registry "$npm_registry"; \
    fi && \
    pnpm install --frozen-lockfile

# ---- Stage 3: Builder ----
FROM base AS builder

ARG ALLOWED_FRAME_ANCESTORS
ARG NEXT_PUBLIC_PERSISTENCE
ARG NEXT_PUBLIC_PERSISTENCE_TOKEN
ARG NEXT_PUBLIC_MAIC_EDITOR_ENABLED
ARG NEXT_PUBLIC_MAIC_EDITOR_RENDERER_ENABLED
ARG NEXT_PUBLIC_MAIC_PLAYBACK_RENDERER_ENABLED
ARG NEXT_PUBLIC_PI_CHAT_ENABLED
ARG NEXT_PUBLIC_COURSEWARE_REFERENCE_ENABLED
ARG NEXT_PUBLIC_SHOW_VOCATIONAL_TEST_UI
ARG NEXT_PUBLIC_ENABLE_VIDEO_EXPORT
ARG NEXT_PUBLIC_VIDEO_EXPORT_CTA_DESTINATION
ARG NEXT_PUBLIC_ENABLE_PPTX_IMPORT
ENV ALLOWED_FRAME_ANCESTORS=$ALLOWED_FRAME_ANCESTORS
ENV NEXT_PUBLIC_PERSISTENCE=$NEXT_PUBLIC_PERSISTENCE
ENV NEXT_PUBLIC_PERSISTENCE_TOKEN=$NEXT_PUBLIC_PERSISTENCE_TOKEN
ENV NEXT_PUBLIC_MAIC_EDITOR_ENABLED=$NEXT_PUBLIC_MAIC_EDITOR_ENABLED
ENV NEXT_PUBLIC_MAIC_EDITOR_RENDERER_ENABLED=$NEXT_PUBLIC_MAIC_EDITOR_RENDERER_ENABLED
ENV NEXT_PUBLIC_MAIC_PLAYBACK_RENDERER_ENABLED=$NEXT_PUBLIC_MAIC_PLAYBACK_RENDERER_ENABLED
ENV NEXT_PUBLIC_PI_CHAT_ENABLED=$NEXT_PUBLIC_PI_CHAT_ENABLED
ENV NEXT_PUBLIC_COURSEWARE_REFERENCE_ENABLED=$NEXT_PUBLIC_COURSEWARE_REFERENCE_ENABLED
ENV NEXT_PUBLIC_SHOW_VOCATIONAL_TEST_UI=$NEXT_PUBLIC_SHOW_VOCATIONAL_TEST_UI
ENV NEXT_PUBLIC_ENABLE_VIDEO_EXPORT=$NEXT_PUBLIC_ENABLE_VIDEO_EXPORT
ENV NEXT_PUBLIC_VIDEO_EXPORT_CTA_DESTINATION=$NEXT_PUBLIC_VIDEO_EXPORT_CTA_DESTINATION
ENV NEXT_PUBLIC_ENABLE_PPTX_IMPORT=$NEXT_PUBLIC_ENABLE_PPTX_IMPORT

COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/packages ./packages
COPY . .
COPY --from=deps /app/public/vendor ./public/vendor

RUN pnpm build

# ---- Stage 4: Runner ----
FROM node:22-alpine AS runner

ARG ALPINE_MIRROR=""

WORKDIR /app

ENV NODE_ENV=production
ENV HOSTNAME=0.0.0.0
ENV PORT=3000

RUN if [ -n "$ALPINE_MIRROR" ]; then \
      cp /etc/apk/repositories /tmp/apk.repositories; \
      sed -i "s|dl-cdn.alpinelinux.org|$ALPINE_MIRROR|g" /etc/apk/repositories; \
    fi && \
    apk add --no-cache libc6-compat cairo pango jpeg giflib librsvg && \
    if [ -n "$ALPINE_MIRROR" ]; then \
      mv /tmp/apk.repositories /etc/apk/repositories; \
    fi

RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

# Restore sharp's prebuilt libvips. sharp's binding (.node) dlopens
# libvips-cpp.so.* out of the sibling @img/sharp-libvips-* package through an ELF
# RPATH -- no JS references the file, so Next's file tracing copies the binding
# and drops the library, and the standalone server dies on the first image op with
#   ERR_DLOPEN_FAILED: Error loading shared library libvips-cpp.so.<v>
# Only fill directories the traced output already created, so this copies the one
# library actually reachable from the shipped bindings instead of every platform
# variant in the store (declaring the .so via outputFileTracingIncludes instead
# makes Next materialize pnpm's symlinked package dirs, duplicating it 14x).
RUN --mount=type=bind,from=deps,source=/app/node_modules,target=/deps-node-modules \
    set -e; \
    restored=0; \
    for so in $(find /deps-node-modules/.pnpm -name 'libvips-cpp.so.*' -type f -path '*linuxmusl*'); do \
      dest="/app/node_modules/${so#/deps-node-modules/}"; \
      if [ -d "$(dirname "$dest")" ] && [ ! -e "$dest" ]; then \
        cp "$so" "$dest"; \
        restored=$((restored + 1)); \
      fi; \
    done; \
    echo "restored $restored libvips shared library/libraries"

# Fail the build here rather than at runtime if the restore above ever stops
# matching (a sharp/libvips upgrade changing the package layout, say).
RUN node -e "const s=require('sharp');s({create:{width:8,height:8,channels:3,background:'#000'}}).png().toBuffer().then(()=>console.log('sharp OK: sharp '+s.versions.sharp+', libvips '+s.versions.vips))"

# The compose stack mounts a named volume at /app/data. Docker seeds an empty
# volume from the image's directory, ownership included, so this path has to
# exist and belong to `nextjs` here -- otherwise the volume is created root-owned
# and every writer under it (usage logs, classrooms, classroom-jobs, material
# bytes) fails with EACCES against the uid 1001 the server runs as.
RUN mkdir -p /app/data && chown nextjs:nodejs /app/data

USER nextjs

EXPOSE 3000

CMD ["node", "server.js"]
