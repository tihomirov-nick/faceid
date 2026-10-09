#!/bin/bash
# Builds build/FaceID.app (universal: Apple Silicon + Intel).
#   VERSION=1.0.0 ./scripts/build_app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# A Command Line Tools SDK set in the environment may not match the Xcode compiler.
unset SDKROOT

APP_NAME="FaceID"
BUNDLE_ID="${BUNDLE_ID:-com.faceid.app}"
VERSION="${VERSION:-1.1.2}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
APP="$ROOT/build/$APP_NAME.app"
MODELS=(SFace)

# Signing. macOS remembers the camera and Accessibility permissions, and the keychain the apps it trusts, by the app's
# signature (its designated requirement). An ad-hoc signature changes with every build, so each rebuild would need the
# permissions granted again; a certificate keeps them, and FaceID's updater installs only a version signed with the same
# certificate. The identity: SIGN_IDENTITY from the environment, otherwise the project's own certificate
# "tihomirov-nick" (self-signed, no e-mail address inside), otherwise the first "Developer ID Application" or
# "Apple Development" certificate, otherwise ad-hoc. SIGN_IDENTITY="-" forces ad-hoc.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    # Without -v: a self-signed certificate counts as "not trusted", and -v would leave it out.
    if security find-identity -p codesigning 2>/dev/null | grep -q '"tihomirov-nick"'; then
        SIGN_IDENTITY="tihomirov-nick"
    else
        SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Developer ID Application/ {print $2; exit}')
        [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Apple Development/ {print $2; exit}')
        SIGN_IDENTITY="${SIGN_IDENTITY:--}"
    fi
fi

# 1. Models (converted ones are in git; scripts/fetch_models.sh rebuilds them)
for model in "${MODELS[@]}"; do
    [ -d "Resources/$model.mlpackage" ] || { ./scripts/fetch_models.sh; break; }
done

# 2. Compile (universal binary)
echo "==> swift build (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 --product "$APP_NAME" 2>&1 | grep -E "error|warning: unre|Build complete" || true
BIN="$ROOT/.build/out/Products/Release/$APP_NAME"
[ -x "$BIN" ] || BIN="$ROOT/.build/apple/Products/Release/$APP_NAME"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

# 3. Bundle
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ru.lproj" "$APP/Contents/Resources/en.lproj"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
strip -x "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
for model in "${MODELS[@]}"; do
    xcrun coremlcompiler compile "Resources/$model.mlpackage" "$APP/Contents/Resources" >/dev/null
    [ -d "$APP/Contents/Resources/$model.mlmodelc" ] || { echo "$model: compilation failed"; exit 1; }
done
cp Resources/LICENSE-sface.txt "$APP/Contents/Resources/"
# The classic green icon, which FaceID sets on its bundle when the user picks it in the settings (AppIcon.swift).
cp Resources/AppIconGreen.png "$APP/Contents/Resources/"

# Icon: a flat icon in the Icon Composer format (Resources/AppIcon.icon, drawn by scripts/make_icon.swift). actool
# turns it into Assets.car (the icon for macOS 26+, flat images for older systems) and AppIcon.icns.
xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$ROOT/build/icon-partial.plist" --output-format human-readable-text >/dev/null
[ -f "$APP/Contents/Resources/Assets.car" ] || { echo "icon compilation failed"; exit 1; }

# Interface languages: Russian strings are the keys in the code, English comes from Localizable.strings
# (scripts/l10n/make_strings.py builds it from scripts/l10n/en.json and stops if a translation is missing).
python3 scripts/l10n/make_strings.py >/dev/null
cp Resources/en.lproj/Localizable.strings "$APP/Contents/Resources/en.lproj/"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<STRINGS
CFBundleDisplayName = "$APP_NAME";
CFBundleName = "$APP_NAME";
NSCameraUsageDescription = "FaceID recognizes your face with the camera to unlock the Mac and lock it when you leave. Images never leave the Mac and are not saved";
NSHumanReadableCopyright = "FaceID — unlock your Mac with your face. Recognition: SFace (OpenCV Zoo, Apache 2.0)";
STRINGS
cat > "$APP/Contents/Resources/ru.lproj/InfoPlist.strings" <<STRINGS
CFBundleDisplayName = "$APP_NAME";
CFBundleName = "$APP_NAME";
NSCameraUsageDescription = "FaceID узнает ваше лицо камерой, чтобы разблокировать Mac и блокировать его, когда вы уходите. Изображения не покидают Mac и не сохраняются";
NSHumanReadableCopyright = "FaceID — разблокировка Mac лицом. Распознавание: SFace (OpenCV Zoo, Apache 2.0)";
STRINGS

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSCameraUsageDescription</key><string>FaceID recognizes your face with the camera to unlock the Mac and lock it when you leave. Images never leave the Mac and are not saved</string>
    <key>NSCameraReactionEffectGesturesEnabledDefault</key><false/>
    <key>NSHumanReadableCopyright</key><string>FaceID — unlock your Mac with your face. Recognition: SFace (OpenCV Zoo, Apache 2.0)</string>
</dict>
</plist>
PLIST
printf "APPL????" > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 4. Sign. The hardened runtime keeps other programs from injecting code into FaceID, which holds the login password.
# Apple's certificates carry an e-mail address in their name: the log shows only the part before ":".
echo "==> codesign (${SIGN_IDENTITY%%:*})"
xattr -cr "$APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
    TIMESTAMP=(--timestamp=none)
else
    TIMESTAMP=(--timestamp)
fi
codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements Resources/FaceID.entitlements --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "==> done: $APP ($(du -sh "$APP" | cut -f1))"
lipo -info "$APP/Contents/MacOS/$APP_NAME"
