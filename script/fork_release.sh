#!/usr/bin/env bash
set -euo pipefail

# Fork: builds a distributable HopUsage.app and wraps it in a DMG, with no Apple Developer account.
# The app is a universal binary (arm64 + x86_64) and is ad-hoc signed: Apple Silicon refuses to run an
# unsigned binary, and an ad-hoc signature needs no certificate. It is NOT notarized, so macOS
# quarantines the download; the release notes tell people how to lift that. No Sparkle feed, no iCloud
# profile, and no dSYM upload, since the updater, iCloud Sync, and telemetry are switched off in the
# fork. `script/release.sh` is the original's Developer ID pipeline and is not used here.
#
# Runs in CI (.github/workflows/fork-release.yml) and locally. This script does NOT push anything.
#
# Optional env:
#   HOPUSAGE_VERSION   human version (CFBundleShortVersionString). Default: the FORK_VERSION file,
#                      e.g. 0.7.16-fork.0.8.0.
#   HOPUSAGE_BUILD     CFBundleVersion. Default: git commit count.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

HOPUSAGE_VERSION="${HOPUSAGE_VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/FORK_VERSION")}"
[ -n "$HOPUSAGE_VERSION" ] || { echo "FORK_VERSION is empty and HOPUSAGE_VERSION is not set" >&2; exit 1; }

APP_NAME="OpenUsage"      # SwiftPM product / binary name
APP_DISPLAY="HopUsage"    # user-facing app name
BUNDLE_ID="com.holovin-local.hopusage"
MIN_SYSTEM_VERSION="15.0"
VERSION="$HOPUSAGE_VERSION"
BUILD="${HOPUSAGE_BUILD:-$(git rev-list --count HEAD)}"

# Its own folder, so a release build never replaces the dev bundle `build_and_run.sh` keeps in dist/.
DIST_DIR="$ROOT_DIR/dist/fork-release"
APP_BUNDLE="$DIST_DIR/$APP_DISPLAY.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_DISPLAY"
CLI_BINARY="$APP_HELPERS/hopusage"
DMG_PATH="$DIST_DIR/$APP_DISPLAY-$VERSION.dmg"

echo "==> building $APP_DISPLAY $VERSION ($BUILD) — universal (arm64 + x86_64)"
# Both arch slices in one go; SwiftPM lipo-merges them into .build/apple/Products/Release.
swift build -c release --arch arm64 --arch x86_64 --product OpenUsage
swift build -c release --arch arm64 --arch x86_64 --product openusage-cli
BUILD_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
BUILD_CLI_BINARY="$BUILD_DIR/openusage-cli"
[ -x "$BUILD_BINARY" ] || { echo "missing built binary: $BUILD_BINARY" >&2; exit 1; }
[ -x "$BUILD_CLI_BINARY" ] || { echo "missing built CLI: $BUILD_CLI_BINARY" >&2; exit 1; }

echo "==> staging $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_CLI_BINARY" "$CLI_BINARY"
chmod +x "$APP_BINARY" "$CLI_BINARY"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CLI_BINARY"
# Fail loudly if the build ever silently regresses to a single arch.
for binary in "$APP_BINARY" "$CLI_BINARY"; do
  lipo -archs "$binary" | grep -q "x86_64" && lipo -archs "$binary" | grep -q "arm64" \
    || { echo "Expected a universal (arm64 + x86_64) binary, got: $(lipo -archs "$binary") for $binary" >&2; exit 1; }
done

# SwiftPM stamps the deployment target (macOS 15) as the linked SDK, which makes AppKit fall back to
# the legacy control look. Restamp the sdk to 26.0 and keep minos, same as the original's release.sh.
echo "==> stamping linked SDK 26.0 for Liquid Glass controls (minos stays $MIN_SYSTEM_VERSION)"
vtool -set-build-version macos "$MIN_SYSTEM_VERSION" 26.0 -replace -output "$APP_BINARY.tmp" "$APP_BINARY"
mv "$APP_BINARY.tmp" "$APP_BINARY"
chmod +x "$APP_BINARY"
if vtool -show-build "$APP_BINARY" | grep -q "sdk 15.0"; then
  echo "SDK restamp failed: $APP_BINARY still reports sdk 15.0" >&2
  exit 1
fi

shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done
shopt -u nullglob

# The app icon is committed prebuilt (script/compile_icon.sh): actool on GitHub's runners can't compile
# the Icon Composer `.icon`.
[ -f "$ROOT_DIR/assets/AppIcon.prebuilt/Assets.car" ] \
  || { echo "missing assets/AppIcon.prebuilt/Assets.car — run script/compile_icon.sh" >&2; exit 1; }
echo "==> installing prebuilt app icon"
cp "$ROOT_DIR/assets/AppIcon.prebuilt/Assets.car" "$APP_RESOURCES/Assets.car"
[ -f "$ROOT_DIR/assets/AppIcon.prebuilt/AppIcon.icns" ] \
  && cp "$ROOT_DIR/assets/AppIcon.prebuilt/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"

# No SUFeedURL / SUPublicEDKey (updater off) and no NSUbiquitousContainers (iCloud Sync off).
cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_DISPLAY</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_DISPLAY</string>
  <key>CFBundleDisplayName</key><string>$APP_DISPLAY</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc ("-") signatures, inside out. No hardened runtime: it only matters for notarization, and its
# library validation would refuse to load an ad-hoc signed Sparkle.framework. Sparkle is still embedded
# because the binary links it, even though the updater never starts.
"$ROOT_DIR/script/embed_sparkle.sh" "$APP_BUNDLE" "$APP_BINARY" "-"
codesign --force --sign - "$CLI_BINARY"
echo "==> signing app (ad-hoc)"
# Not --deep: the Sparkle framework is signed above and must keep that signature.
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> building $DMG_PATH"
STAGE="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$STAGE/$APP_DISPLAY.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_DISPLAY" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGE"

echo "==> done"
echo "    DMG: $DMG_PATH"
