#!/bin/bash
# Builds ProcPin.app and packages it into a distributable DMG.
#
# Usage: ./Scripts/make-dmg.sh [version]
# Output: build/ProcPin-<version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-1.0.0}"
APP_NAME="ProcPin"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
STAGE_DIR="$BUILD_DIR/dmg-stage"

# 1. Build the .app bundle.
./Scripts/build-app.sh

# 2. Stage a folder with the app + an Applications shortcut.
echo "==> Staging DMG contents"
rm -rf "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$STAGE_DIR"
cp -R "$APP_DIR" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

# 3. Build a compressed DMG.
echo "==> Creating $DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$STAGE_DIR"
echo "==> Done: $DMG_PATH"
ls -lh "$DMG_PATH"

# 4. Also produce a .zip of the app for in-app auto-update.
ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION-mac.zip"
echo "==> Creating $ZIP_PATH"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
ls -lh "$ZIP_PATH"
