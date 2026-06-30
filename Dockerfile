# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:20-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df
ARG NGINX_IMAGE=nginx:alpine@sha256:54f2a904c251d5a34adf545a72d32515a15e08418dae0266e23be2e18c66fefa

###############################################################################
# JavaScript bundle
###############################################################################
FROM ${NODE_IMAGE} AS js-build

ARG RUSTDESK_REPO=https://github.com/MonsieurBiche/rustdesk-web-client.git
ARG RUSTDESK_REF=0b24f1ba9f69b0022d09464c6d24f1c45271f294
ARG YARN_VERSION=3.2.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates git protobuf-compiler python3 python-is-python3 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY patches/same-origin-websocket.patch /tmp/same-origin-websocket.patch
RUN git init rustdesk \
 && cd rustdesk \
 && git remote add origin "${RUSTDESK_REPO}" \
 && git fetch --depth 1 origin "${RUSTDESK_REF}" \
 && test "$(git rev-parse FETCH_HEAD)" = "${RUSTDESK_REF}" \
 && git checkout --detach FETCH_HEAD \
 && git submodule update --init --recursive --depth 1 \
 && git apply --check /tmp/same-origin-websocket.patch \
 && git apply /tmp/same-origin-websocket.patch

WORKDIR /src/rustdesk/flutter/web
RUN if [ -d v1 ]; then cp -a v1/. .; fi

RUN sed -i '/chunkFileNames:/a\        manualChunks(id) {\
          if (id.includes("node_modules")) return "vendor";\
        },' /src/rustdesk/flutter/web/js/vite.config.js \
 && sed -i 's/ConnectionPage(key: _connKey);/ConnectionPage(key: _connKey, appBarActions: const <Widget>[]);/' \
      /src/rustdesk/flutter/lib/mobile/pages/home_page.dart

WORKDIR /src/rustdesk/flutter/web/js
RUN --mount=type=cache,target=/root/.yarn/berry/cache \
    corepack enable \
 && corepack prepare "yarn@${YARN_VERSION}" --activate \
 && YARN_ENABLE_GLOBAL_CACHE=true yarn install --immutable \
 && yarn build

###############################################################################
# Flutter Web bundle
###############################################################################
FROM ${DEBIAN_IMAGE} AS flutter-build

ARG FLUTTER_VERSION=3.22.1
ARG FLUTTER_REF=a14f74ff3a1cbd521163c5f03d68113d50af93d3
ARG RUST_VERSION=1.75.0
ARG WEB_DEPS_SHA256=b66011c4fc066b90c46ba0c78884fe5d1a7e5a7fad3dce401300ad893de63818
ENV FLUTTER_HOME=/opt/flutter \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH} \
    FLUTTER_ALLOW_ROOT=1 \
    RUSTFLAGS='--cfg getrandom_backend="js"'

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash build-essential ca-certificates clang cmake curl git libgl1-mesa-dev \
      libglu1-mesa libgtk-3-dev ninja-build pkg-config protobuf-compiler \
      python3 python-is-python3 unzip wget xz-utils zip \
 && rm -rf /var/lib/apt/lists/*

RUN --mount=type=cache,target=/usr/local/cargo \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --default-toolchain "${RUST_VERSION}" \
 && . /root/.cargo/env \
 && rustup target add wasm32-unknown-unknown

RUN --mount=type=cache,target=/root/.cache/flutter \
    git clone --depth 1 --branch "${FLUTTER_VERSION}" \
      https://github.com/flutter/flutter.git "${FLUTTER_HOME}" \
 && test "$(git -C "${FLUTTER_HOME}" rev-parse HEAD)" = "${FLUTTER_REF}" \
 && flutter config --enable-web --no-analytics \
 && flutter precache --web

COPY --from=js-build /src/rustdesk /build/rustdesk
COPY web_deps.tar.gz /tmp/web_deps.tar.gz
WORKDIR /build/rustdesk/flutter

RUN echo "${WEB_DEPS_SHA256}  /tmp/web_deps.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/web_deps.tar.gz -C web/ \
 && rm /tmp/web_deps.tar.gz

RUN --mount=type=cache,target=/usr/local/cargo \
    --mount=type=cache,target=/root/.cache/flutter \
    . /root/.cargo/env \
 && find web/js -mindepth 1 -maxdepth 1 ! -name dist -exec rm -rf {} + \
 && flutter build web --release \
 && mkdir -p build/web/js \
 && cp -r web/js/dist/. build/web/js/ \
 && sed -i 's#</head>#  <script src="/runtime-config.js"></script>\n  <script src="/runtime-config-bootstrap.js"></script>\n</head>#' build/web/index.html \
 && grep -q '/runtime-config.js' build/web/index.html

###############################################################################
# Static UI and same-origin API/WebSocket proxy
###############################################################################
FROM ${NGINX_IMAGE} AS final

ARG RUSTDESK_REF=0b24f1ba9f69b0022d09464c6d24f1c45271f294
ARG WEB_DEPS_SHA256=b66011c4fc066b90c46ba0c78884fe5d1a7e5a7fad3dce401300ad893de63818
LABEL org.opencontainers.image.source="https://github.com/ngtrongha/docker-rustdesk-web-client" \
      org.opencontainers.image.revision="${RUSTDESK_REF}" \
      io.bvkhanhhoa.web-deps-sha256="${WEB_DEPS_SHA256}"

COPY --from=flutter-build /build/rustdesk/flutter/build/web /usr/share/nginx/html
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY docker/runtime-config-bootstrap.js /usr/share/nginx/html/runtime-config-bootstrap.js
COPY docker/entrypoint.sh /usr/local/bin/rustdesk-web-entrypoint

RUN chmod 0555 /usr/local/bin/rustdesk-web-entrypoint \
 && chown -R nginx:nginx /usr/share/nginx/html

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1/healthz >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/rustdesk-web-entrypoint"]
