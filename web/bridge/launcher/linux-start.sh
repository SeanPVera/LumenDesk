#!/bin/sh
set -eu
LUMENDESK_BUNDLE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "${1:-}" = "--smoke-test" ]; then
  exec "$LUMENDESK_BUNDLE_DIR/runtime/node" "$LUMENDESK_BUNDLE_DIR/launcher/launch.mjs" --smoke-test
fi
mkdir -p "$HOME/.lumendesk"
umask 077
"$LUMENDESK_BUNDLE_DIR/runtime/node" "$LUMENDESK_BUNDLE_DIR/launcher/launch.mjs" --desktop > "$HOME/.lumendesk/bridge-launcher.log" 2>&1 < /dev/null &
