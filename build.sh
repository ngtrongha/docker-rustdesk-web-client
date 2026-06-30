#!/usr/bin/env bash
set -Eeuo pipefail

readonly RUSTDESK_REF="0b24f1ba9f69b0022d09464c6d24f1c45271f294"
readonly WEB_DEPS_SHA256="b66011c4fc066b90c46ba0c78884fe5d1a7e5a7fad3dce401300ad893de63818"

cd "$(dirname "$0")"

actual_sha="$(sha256sum web_deps.tar.gz | awk '{print $1}')"
if [[ "$actual_sha" != "$WEB_DEPS_SHA256" ]]; then
  printf 'web_deps.tar.gz SHA-256 mismatch\n' >&2
  exit 1
fi

case "${1:-build}" in
  build)
    docker build \
      --build-arg "RUSTDESK_REF=$RUSTDESK_REF" \
      --build-arg "WEB_DEPS_SHA256=$WEB_DEPS_SHA256" \
      --tag local-rustdesk-web-client:dev .
    ;;
  start)
    docker compose up -d --no-deps rustdesk-web
    ;;
  stop)
    docker compose stop rustdesk-web
    ;;
  logs)
    docker compose logs --follow rustdesk-web
    ;;
  *)
    printf 'Usage: %s [build|start|stop|logs]\n' "$0" >&2
    exit 2
    ;;
esac
