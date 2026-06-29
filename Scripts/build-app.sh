#!/bin/bash
# Builds ProcPin and packages it into a double-clickable .app bundle.
#
# Usage: ./Scripts/build-app.sh
# Output: build/ProcPin.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="ProcPin"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp ".build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"

# App icon (generate if missing).
if [ ! -f "Icon.icns" ] && command -v swift >/dev/null; then
    echo "==> Generating app icon"
    swift Scripts/make-icon.swift >/dev/null 2>&1 || true
    iconutil -c icns build/AppIcon.iconset -o Icon.icns 2>/dev/null || true
fi
if [ -f "Icon.icns" ]; then
    cp "Icon.icns" "$RES_DIR/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.procpin.app</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "   (codesign skipped)"

echo "==> Done: $APP_DIR"
echo "    Run with: open \"$APP_DIR\""
