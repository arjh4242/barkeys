#!/bin/bash
set -euo pipefail

APP_NAME="BarKeys"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$SCRIPT_DIR/build/$APP_NAME.app"
STAGING_DIR="$SCRIPT_DIR/build/dmg_staging"
DMG_PATH="$SCRIPT_DIR/build/$APP_NAME.dmg"

if [ ! -d "$APP_PATH" ]; then
    echo "Byg først appen med ./build.sh"
    exit 1
fi

rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
cp -r "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "Lavet: $DMG_PATH"
