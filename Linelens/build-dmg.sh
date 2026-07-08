#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Linelens.app"
DMG_NAME="Linelens.dmg"
STAGE_APP="$PROJECT_DIR/.build/$APP_NAME"
OUT_DMG="$PROJECT_DIR/$DMG_NAME"

echo "Building and staging ${APP_NAME}..."
"$PROJECT_DIR/build-install.sh" >/dev/null

[ -d "$STAGE_APP" ] || { echo "Staged app not found at $STAGE_APP" >&2; exit 1; }

echo "Packaging ${DMG_NAME}..."
rm -f "$OUT_DMG"
create-dmg \
  --volname "Linelens" \
  --window-size 500 320 \
  --icon-size 100 \
  --icon "$APP_NAME" 125 160 \
  --app-drop-link 375 160 \
  --hide-extension "$APP_NAME" \
  "$OUT_DMG" \
  "$STAGE_APP" \
  || true

[ -f "$OUT_DMG" ] || { echo "✗ DMG creation failed" >&2; exit 1; }

echo "Created $OUT_DMG"
