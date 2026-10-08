#!/bin/bash
# Publishes a GitHub release: builds dist/FaceID-<version>.dmg from the committed code, checks that the app inside is
# signed with the project's certificate "tihomirov-nick" (installed copies update only to a version signed with it),
# tags v<version>, pushes main and the tag, then publishes the release with the DMG attached.
#   VERSION=1.1.0 NOTES=~/notes-1.1.0.md ./scripts/release.sh     (keep the notes file outside the repo)
# git goes through the remote's deploy key (git@github-faceid:..., see ~/.ssh/config). The release API needs a
# fine-grained token of tihomirov-nick with Contents: Read and write on this repo, kept in the Keychain (account
# tihomirov-nick, service TOKEN_SERVICE, by default github-faceid-token). gh's own login is a different account and is
# not used. Without such a token the script stops before the build. Safe to re-run: an existing tag on HEAD and an
# existing (draft) release are reused.
set -euo pipefail

VERSION="${VERSION:?set VERSION, e.g. VERSION=1.1.0}"
NOTES="${NOTES:?set NOTES to a Markdown file with the release notes}"
[ -f "$NOTES" ] || { echo "no notes file: $NOTES"; exit 1; }
NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="tihomirov-nick/faceid"
SERVICE="${TOKEN_SERVICE:-github-faceid-token}"
CERT="tihomirov-nick"
TAG="v$VERSION"
DMG="dist/FaceID-$VERSION.dmg"

# 1. The release must match committed code on main
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "switch to main first"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit or stash changes first (untracked files count too)"; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
    echo "$TAG already points to another commit"; exit 1
fi

# 2. The certificate: a release signed otherwise would never reach the installed copies (their updater refuses it).
# Without -v: a self-signed certificate counts as "not trusted", and -v would leave it out.
security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT\"" || {
    echo "the certificate \"$CERT\" is not in the keychain (README, \"Подпись\": how to restore it from the backup)"; exit 1
}
# awk reads to the end: stopping early would break the pipe, and with pipefail the script would quit silently.
LEAF="$(security find-certificate -c "$CERT" -Z 2>/dev/null | awk '/SHA-1 hash:/ && !done {print tolower($3); done = 1}')"

# 3. Token, checked by creating the draft release before anything is built or pushed
TOKEN="$(security find-generic-password -a tihomirov-nick -s "$SERVICE" -w 2>/dev/null)" || TOKEN=""
[ -n "$TOKEN" ] || { echo "no GitHub token in the Keychain (account tihomirov-nick, service $SERVICE)"; exit 1; }
gh_() { GH_TOKEN="$TOKEN" gh "$@"; }
if ! gh_ release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh_ release create "$TAG" --repo "$REPO" --draft --title "FaceID $VERSION" --notes-file "$NOTES" >/dev/null || {
        echo "the token from Keychain service $SERVICE can't create releases in $REPO"
        echo "(it needs Contents: Read and write on this repo; nothing was built or pushed)"
        exit 1
    }
fi

# 4. Build (build_app.sh regenerates Localizable.strings, which is tracked)
SIGN_IDENTITY="$CERT" VERSION="$VERSION" ./scripts/make_dmg.sh
[ -z "$(git status --porcelain)" ] || { echo "the build changed tracked files, commit them and run again:"; git status --short; exit 1; }

# 5. The app inside the DMG: this version, intact, signed with the certificate itself (its name and its hash)
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >/dev/null
APP="$MOUNT/FaceID.app"
problem=""
[ -d "$APP" ] || problem="no FaceID.app in $DMG"
if [ -z "$problem" ]; then
    built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    authority="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !done {print $2; done = 1}')"
    requirement="$(codesign -d -r- "$APP" 2>&1 | grep '^designated' || true)"
    if [ "$built" != "$VERSION" ]; then
        problem="the app in $DMG is version $built, not $VERSION"
    elif ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
        problem="the app in $DMG has a broken signature"
    elif [ "$authority" != "$CERT" ] || [[ "$requirement" != *"certificate leaf = H\"$LEAF\""* ]]; then
        # Apple's certificates carry an e-mail address in their name: only the part before ":" is shown.
        signer="${authority:-ad-hoc}"
        problem="the app in $DMG is not signed with \"$CERT\" (signed by: ${signer%%:*})"
    fi
fi
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet || true
rmdir "$MOUNT" 2>/dev/null || true
[ -z "$problem" ] || { echo "$problem; nothing was tagged or pushed"; exit 1; }
echo "==> $DMG: FaceID $VERSION signed with \"$CERT\""

# 6. Tag and push
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "FaceID $VERSION"
git push origin main "$TAG"

# 7. Attach the DMG and publish
gh_ release upload "$TAG" "$DMG" --repo "$REPO" --clobber
gh_ release edit "$TAG" --repo "$REPO" --draft=false --title "FaceID $VERSION" --notes-file "$NOTES"
echo "==> https://github.com/$REPO/releases/tag/$TAG"
