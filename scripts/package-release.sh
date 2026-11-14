#!/usr/bin/env bash
# Builds a universal CcinnStarRocks.app and packages it for a GitHub release.
#
#   scripts/package-release.sh 1.0.0
#
# Produces in ./dist:
#   CcinnStarRocks-<version>.dmg            drag-to-Applications disk image
#   CcinnStarRocks-<version>-macOS.zip      zipped app bundle
#   SHA256SUMS.txt                      checksums of the above
set -euo pipefail

VERSION="${1:?usage: scripts/package-release.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="CcinnStarRocks"

CCINNSTARROCKS_VERSION="$VERSION" "$ROOT/scripts/build-app.sh" --universal

cd "$DIST"
rm -f "$APP_NAME-$VERSION.dmg" "$APP_NAME-$VERSION-macOS.zip" SHA256SUMS.txt

ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME-$VERSION-macOS.zip"

STAGING="$(mktemp -d)/$APP_NAME"
mkdir -p "$STAGING"
cp -R "$APP_NAME.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$APP_NAME-$VERSION.dmg" >/dev/null
rm -rf "$(dirname "$STAGING")"

shasum -a 256 "$APP_NAME-$VERSION.dmg" "$APP_NAME-$VERSION-macOS.zip" > SHA256SUMS.txt
echo "Release artifacts in $DIST:"
cat SHA256SUMS.txt
