#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
BUILD_SYSTEM=(--build-system native)
BIN_DIR="$(swift build "${BUILD_SYSTEM[@]}" -c "$BUILD_CONFIGURATION" --show-bin-path 2>/dev/null)"
APP_DIR="${APP_DIR:-$ROOT_DIR/dist/Everything.app}"

swift build "${BUILD_SYSTEM[@]}" -c "$BUILD_CONFIGURATION" --product Everything
swift build "${BUILD_SYSTEM[@]}" -c "$BUILD_CONFIGURATION" --product es
swift build "${BUILD_SYSTEM[@]}" -c "$BUILD_CONFIGURATION" --product EverythingSDK

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Everything" "$APP_DIR/Contents/MacOS/Everything"
cp "$BIN_DIR/es" "$APP_DIR/Contents/MacOS/es"
cp "$BIN_DIR/libEverythingSDK.dylib" "$APP_DIR/Contents/MacOS/libEverythingSDK.dylib"
cp -R "$BIN_DIR/EverythingForMac_Everything.bundle" "$APP_DIR/Contents/Resources/"
cp "$ROOT_DIR/Sources/Everything/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "Bundled $APP_DIR"
