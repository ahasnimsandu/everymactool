#!/bin/bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
MIN_MACOS="26.0"
BUILD_DIR="$APP_ROOT/build"
APP_BUNDLE="$BUILD_DIR/EveryMacTool.app"
CONTENTS="$APP_BUNDLE/Contents"
STAGING="$BUILD_DIR/dmg-root"
DIST_DIR="$APP_ROOT/dist"
DMG_PATH="$DIST_DIR/EveryMacTool-1.0.0-macOS-${ARCH}.dmg"

mkdir -p "$BUILD_DIR" "$DIST_DIR"
rm -rf "$APP_BUNDLE" "$STAGING"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$STAGING"

/usr/bin/swiftc -parse-as-library -warnings-as-errors -O \
  -target "${ARCH}-apple-macosx${MIN_MACOS}" \
  -framework SwiftUI -framework AppKit -framework IOKit \
  -framework CoreGraphics -framework Charts -framework FoundationModels \
  "$APP_ROOT/Sources/EveryMacTool.swift" \
  -o "$CONTENTS/MacOS/EveryMacTool"
cp "$APP_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$APP_ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

cp -R "$APP_BUNDLE" "$STAGING/EveryMacTool.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_PATH"
/usr/bin/hdiutil create -volname "EveryMacTool" -srcfolder "$STAGING" \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH"
printf '\nBuilt app: %s\nInstaller: %s\n' "$APP_BUNDLE" "$DMG_PATH"
