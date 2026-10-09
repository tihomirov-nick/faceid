#!/bin/bash
# Builds the app and packs it into dist/FaceID-<version>.dmg
#   VERSION=1.0.0 ./scripts/make_dmg.sh
# The DMG is meant for other people and for FaceID's own updates, so it is signed with the project's certificate
# "tihomirov-nick": no e-mail address inside (an "Apple Development" certificate would put yours into every copy), and
# the updater of a copy signed with it installs every later version signed with it. Without the certificate the DMG is
# signed ad-hoc, and such a copy can never update itself. Another identity: pass SIGN_IDENTITY explicitly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.1.1}"
export VERSION
if [ -z "${SIGN_IDENTITY:-}" ]; then
    # Without -v: a self-signed certificate counts as "not trusted", and -v would leave it out.
    if security find-identity -p codesigning 2>/dev/null | grep -q '"tihomirov-nick"'; then
        SIGN_IDENTITY="tihomirov-nick"
    else
        SIGN_IDENTITY="-"
        {
            echo "!!!"
            echo "!!! The certificate \"tihomirov-nick\" is not in the keychain: the DMG is signed ad-hoc."
            echo "!!! A copy installed from it can never update itself, and every new version loses the camera and"
            echo "!!! Accessibility permissions and the keychain. Restore the certificate (README, \"Подпись\") and run again."
            echo "!!!"
        } >&2
    fi
fi
export SIGN_IDENTITY

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
