#!/bin/bash
# Builds the app and packs it into dist/FaceID-<version>.dmg
#   VERSION=1.0.0 ./scripts/make_dmg.sh
# The DMG is meant for other people, so it is signed ad-hoc by default: an "Apple Development" certificate would
# put your e-mail address into every copy. With a Developer ID certificate pass SIGN_IDENTITY explicitly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.0.0}"
export VERSION
export SIGN_IDENTITY="${SIGN_IDENTITY:--}"

./scripts/build_app.sh

STAGE="$ROOT/build/dmg"
DMG="$ROOT/dist/FaceID-$VERSION.dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$ROOT/dist"
cp -R "$ROOT/build/FaceID.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/Как установить.txt" "$ROOT/docs/How to install.txt" "$STAGE/"

rm -f "$DMG"
echo "==> creating $DMG"
hdiutil create -volname "FaceID $VERSION" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
if [ "$SIGN_IDENTITY" != "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
fi
hdiutil verify "$DMG" >/dev/null && echo "==> verified"
echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
