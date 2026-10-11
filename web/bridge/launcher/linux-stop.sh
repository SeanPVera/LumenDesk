#!/bin/sh
set -eu
LUMENDESK_BUNDLE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$LUMENDESK_BUNDLE_DIR/runtime/node" "$LUMENDESK_BUNDLE_DIR/launcher/launch.mjs" --stop
