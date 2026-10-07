#!/bin/bash
# Checks the sudo path without touching sudo: builds a test copy of pam_faceid (config file owned by you instead of
# root), starts the development build of FaceID with FACEID_SUDO_TEST=1 (accepts a client that is not sudo) and
# lets a small program call the module the way sudo does. With no face set up, FaceID answers DENY; the point is
# that the module finds FaceID, trusts its signature and passes the messages through.
#   ./scripts/test_pam.sh [timeout=<seconds>]      → DENY from FaceID ("no face set up"), PAM_AUTH_ERR
#   IMPOSTOR=1 ./scripts/test_pam.sh               → the module does not trust the socket, PAM_IGNORE
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset SDKROOT SSH_CONNECTION SSH_CLIENT SSH_TTY
TMP="$(mktemp -d)"
trap 'kill $APP_PID 2>/dev/null || true; rm -rf "$TMP"' EXIT

swift build --product FaceID 2>&1 | grep -E "error|Build complete" || true
APP_BIN="$ROOT/.build/debug/FaceID"
# The development build listens in "FaceID Debug", away from the installed app.
xcrun clang -dynamiclib -O2 -Wall -Wextra -DFACEID_TEST_CONFIG="\"$TMP/pam.conf\"" \
    -DFACEID_TEST_SOCKET="\"Library/Application Support/FaceID Debug/sudo.sock\"" -o "$TMP/pam_faceid_test.so" \
    PAM/pam_faceid.c -lpam -framework Security -framework CoreFoundation
xcrun clang -O2 -Wall -o "$TMP/pam_harness" scripts/test/pam_harness.c -lpam

# The module trusts exactly this build of FaceID. IMPOSTOR=1 makes it expect another app: the module must then
# refuse to talk to the socket (PAM_IGNORE), as it would with a program posing as FaceID.
REQUIREMENT=$(codesign -d -r- "$APP_BIN" 2>&1 | sed -n 's/^#* *designated => //p')
[ "${IMPOSTOR:-0}" = 1 ] && REQUIREMENT='cdhash H"0000000000000000000000000000000000000000"'

printf 'requirement=%s\n' "$REQUIREMENT" > "$TMP/pam.conf"
chmod 644 "$TMP/pam.conf"
echo "requirement: $REQUIREMENT"

FACEID_SUDO_TEST=1 FACEID_QUIT_AFTER=60 "$APP_BIN" >/dev/null 2>&1 &
APP_PID=$!
sleep 2
"$TMP/pam_harness" "$TMP/pam_faceid_test.so" debug "$@"
