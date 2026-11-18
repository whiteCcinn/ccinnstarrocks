#!/usr/bin/env bash
# Builds CcinnStarRocks.app (release, ad-hoc signed) into ./dist.
#
#   scripts/build-app.sh                 # build dist/CcinnStarRocks.app for this Mac's architecture
#   scripts/build-app.sh --universal     # Apple silicon + Intel
#   scripts/build-app.sh --open          # build and launch
#   CCINNSTARROCKS_VERSION=1.2.3 scripts/build-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CcinnStarRocks"
BUNDLE_ID="io.github.whiteccinn.ccinnstarrocks"
VERSION="${CCINNSTARROCKS_VERSION:-1.3.3}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ICON="$ROOT/Resources/AppIcon.icns"

ARCH_ARGS=()
OPEN_AFTER=false
for argument in "$@"; do
  case "$argument" in
    --universal) ARCH_ARGS=(--arch arm64 --arch x86_64) ;;
    --open) OPEN_AFTER=true ;;
    *) echo "unknown option: $argument" >&2; exit 1 ;;
  esac
done

cd "$ROOT"
swift build -c release --product "$APP_NAME" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR="$(swift build -c release --show-bin-path ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"})"

if [[ ! -f "$ICON" ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
  mkdir -p "$ROOT/Resources"
  iconutil -c icns "$ICONSET" -o "$ICON"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>CcinnStarRocks — a native StarRocks client</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "$OPEN_AFTER" == true ]]; then
  open "$APP"
fi
