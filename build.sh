#!/bin/bash
# build.sh — template for a swiftc-built macOS app (copy from MakeGuess/timesheet-memory shape).
# Usage: bash build.sh                       (universal: arm64 + x86_64)
#        <APP>_ARCHES=arm64 bash build.sh    (fast, current Mac only)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Choir"                 # bundle display name (no spaces preferred)
BUNDLE_ID="com.makewaves.choir"  # must match Info.plist CFBundleIdentifier
VERSION=${CHOIR_VERSION:-"1.0"}
SOURCES=(Sources/*.swift)           # compile order doesn't matter to swiftc

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Run: xcode-select --install"; exit 1
fi

BUILD_DIR=$(mktemp -d); trap 'rm -rf "$BUILD_DIR"' EXIT
APP="$BUILD_DIR/$APP_NAME.app"

ARCHES=${CHOIR_ARCHES:-"arm64 x86_64"}
# CHOIR_FAST=1 skips optimisation: a debug loop measured in seconds, not minutes.
OPT=${CHOIR_FAST:+-Onone}; OPT=${OPT:--O}
BINARIES=()
for arch in $ARCHES; do
  binary="$BUILD_DIR/$APP_NAME-$arch"
  echo "Compiling ${arch}…"
  swiftc $OPT -parse-as-library -swift-version 5 \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    -target "$arch-apple-macos14.0" "${SOURCES[@]}" -o "$binary"
  BINARIES+=("$binary")
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ "${#BINARIES[@]}" -eq 1 ]; then cp "${BINARIES[0]}" "$APP/Contents/MacOS/$APP_NAME"
else lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"; fi

IDENTITY=${CHOIR_SIGN_IDENTITY:--}
if [ "$IDENTITY" = "-" ]; then
  codesign --force --deep --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

OUT_APP="$PWD/$APP_NAME.app"; rm -rf "$OUT_APP"; cp -R "$APP" "$OUT_APP"
echo "Built: $OUT_APP ($(lipo -archs "$OUT_APP/Contents/MacOS/$APP_NAME"))"

# Install where Finder and Spotlight look. CHOIR_NO_INSTALL=1 skips it.
if [ -z "${CHOIR_NO_INSTALL:-}" ]; then
  DEST="/Applications"; [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"; rm -rf "$DEST/$APP_NAME.app"; cp -R "$OUT_APP" "$DEST/$APP_NAME.app"
  echo "Installed: $DEST/$APP_NAME.app"
fi
# DMG: build a blank RW image, copy the app + /Applications symlink, detach, then
# hdiutil convert -format UDZO — 'hdiutil create -srcfolder' hits "Resource busy" on this Mac.
