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
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_ROOT/Resources/Info.plist")
DMG_PATH="$DIST_DIR/EveryMacTool-${VERSION}-macOS-${ARCH}.dmg"

mkdir -p "$BUILD_DIR" "$DIST_DIR"
touch "$BUILD_DIR/.metadata_never_index"
rm -rf "$APP_BUNDLE" "$STAGING"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$STAGING"

# Apple introduced the Private Cloud Compute model API in a later SDK than the
# macOS 26 deployment SDK. Enable its code only when the selected SDK exposes it.
PCC_PROBE="$BUILD_DIR/pcc-api-probe.swift"
PCC_FLAGS=()
cat > "$PCC_PROBE" <<'SWIFT'
import FoundationModels
@available(macOS 27.0, *)
func probePrivateCloudComputeAPI() {
  let model = PrivateCloudComputeLanguageModel()
  _ = model.isAvailable
}
SWIFT
if /usr/bin/swiftc -module-cache-path "$BUILD_DIR/ModuleCache" -target "${ARCH}-apple-macosx${MIN_MACOS}" -framework FoundationModels -typecheck "$PCC_PROBE" >/dev/null 2>&1; then
  PCC_FLAGS=(-D EVERYMAC_HAS_PCC)
fi

/usr/bin/swiftc -parse-as-library -warnings-as-errors -O \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -target "${ARCH}-apple-macosx${MIN_MACOS}" \
  ${PCC_FLAGS[@]:-} \
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
rm -rf "$STAGING"
printf '\nBuilt app: %s\nInstaller: %s\n' "$APP_BUNDLE" "$DMG_PATH"
