#!/bin/sh
set -eu

PUBLIC_HOST="${PUBLIC_HOST:-remote-connect.bvkhanhhoa.cloud}"
API_SERVER="${API_SERVER:-https://${PUBLIC_HOST}}"
RUSTDESK_PUBLIC_KEY="${RUSTDESK_PUBLIC_KEY:-}"

case "${PUBLIC_HOST}" in
  *[!A-Za-z0-9.-]*|'')
    echo "PUBLIC_HOST is invalid" >&2
    exit 1
    ;;
esac

case "${API_SERVER}" in
  https://*|http://*) ;;
  *)
    echo "API_SERVER must start with http:// or https://" >&2
    exit 1
    ;;
esac

case "${RUSTDESK_PUBLIC_KEY}" in
  *[!A-Za-z0-9+/=_-]*)
    echo "RUSTDESK_PUBLIC_KEY contains unexpected characters" >&2
    exit 1
    ;;
esac

cat > /usr/share/nginx/html/runtime-config.js <<EOF
window.__RUSTDESK_CONFIG__ = Object.freeze({
  publicHost: "${PUBLIC_HOST}",
  rendezvousServer: "${PUBLIC_HOST}",
  relayServer: "${PUBLIC_HOST}",
  apiServer: "${API_SERVER}",
  publicKey: "${RUSTDESK_PUBLIC_KEY}"
});
EOF

chmod 0444 /usr/share/nginx/html/runtime-config.js
exec nginx -g 'daemon off;'
