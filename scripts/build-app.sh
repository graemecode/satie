#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Satie"
DISPLAY_NAME="Satie"
BUNDLE_ID="com.strangechances.Satie"
TEAM_ID="6KM3577ETV"
VERSION="2.4.0"
BUILD_NUM="11"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
CASK_FILE="$ROOT_DIR/Casks/satie.rb"

DO_INSTALL=false
DO_DMG=false
DO_NOTARIZE=false
SKIP_TESTS=false

for arg in "$@"; do
  case "$arg" in
    --install) DO_INSTALL=true ;;
    --dmg) DO_DMG=true ;;
    --notarize) DO_NOTARIZE=true; DO_DMG=true ;;
    --release) DO_NOTARIZE=true; DO_DMG=true ;;
    --skip-tests) SKIP_TESTS=true ;;
    *) echo "Unknown flag: $arg (supported: --install, --dmg, --notarize, --release, --skip-tests)" >&2; exit 1 ;;
  esac
done

cd "$ROOT_DIR"

if [[ "$SKIP_TESTS" == "false" ]]; then
  echo "==> Running unit tests (AcousticCoreTests)..."
  swift test
fi

echo "==> Building $APP_NAME $VERSION (release)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "ERROR: Built binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
strip -x "$MACOS_DIR/$APP_NAME" || true

echo "==> Compiling Metal shaders -> default.metallib..."
TMP_AIR="$BUILD_DIR/Shaders.air"
xcrun metal -O2 -c "$ROOT_DIR/Sources/AcousticCircuit/Renderer/Shaders.metal" -o "$TMP_AIR"
xcrun metallib "$TMP_AIR" -o "$RES_DIR/default.metallib"
rm -f "$TMP_AIR"

echo "==> Generating AppIcon.icns..."
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT_DIR/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Writing Info.plist..."
cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUM</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.music</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Graeme Boy. All rights reserved.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Satie taps your Mac's system audio output locally in real time to auto-duck focus soundscapes during calls or music and drive 120Hz Metal visualizations. Zero audio is recorded or transmitted.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Satie optionally reads the current track title and playback position from Apple Music, Spotify, or Chrome to display Now Playing controls.</string>
</dict>
</plist>
EOF

# Resolve signing identity: prefer Developer ID Application for public distribution, else personal Apple Development
DEV_ID_HASH="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | grep "$TEAM_ID" | head -n1 | awk '{print $2}' || true)"
if [[ -z "$DEV_ID_HASH" ]]; then
  DEV_ID_HASH="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -n1 | awk '{print $2}' || true)"
fi

SIGN_ID="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" ]]; then
  if [[ -n "$DEV_ID_HASH" ]]; then
    SIGN_ID="$DEV_ID_HASH"
  elif [[ "$DO_NOTARIZE" == "true" ]]; then
    echo "ERROR: --notarize / --release requires a 'Developer ID Application' certificate in Keychain." >&2
    echo "  Create one in Xcode -> Settings -> Accounts -> Manage Certificates -> '+' -> Developer ID Application" >&2
    exit 1
  elif security find-identity -v -p codesigning 2>/dev/null | grep -q "1C95CB6D82FA56568116F614ED341B513B3B041E"; then
    SIGN_ID="1C95CB6D82FA56568116F614ED341B513B3B041E"
  else
    SIGN_ID="-"
  fi
fi

echo "==> Code signing $APP_BUNDLE (identity: $SIGN_ID)..."
if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force --deep --sign - "$APP_BUNDLE"
elif [[ "$DO_NOTARIZE" == "true" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP_BUNDLE"
else
  codesign --force --deep --options runtime --timestamp=none --sign "$SIGN_ID" "$APP_BUNDLE"
fi

codesign --verify --deep --strict "$APP_BUNDLE"
echo "==> Verified bundle: $APP_BUNDLE ($(du -sh "$APP_BUNDLE" | awk '{print $1}'))"

if [[ "$DO_DMG" == "true" ]]; then
  DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
  STAGING="$BUILD_DIR/dmg-staging"
  echo "==> Creating DMG installer: $DMG_PATH..."
  rm -rf "$STAGING" "$DMG_PATH"
  mkdir -p "$STAGING"
  cp -R "$APP_BUNDLE" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
  rm -rf "$STAGING"

  if [[ "$DO_NOTARIZE" == "true" ]]; then
    NOTARY_PROFILE="${NOTARY_PROFILE:-acoustic-notary}"
    echo "==> Signing DMG..."
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG_PATH"

    echo "==> Submitting to Apple Notarization (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "==> Stapling notarization ticket to DMG and app bundle..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"

    echo "==> Verifying Gatekeeper acceptance..."
    spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH"
  fi

  DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  echo "==> DMG ready: $DMG_PATH ($(du -sh "$DMG_PATH" | awk '{print $1}'), sha256: $DMG_SHA)"

  if [[ -f "$CASK_FILE" ]]; then
    sed -i '' -E "s/sha256 \"[^\"]+\"/sha256 \"$DMG_SHA\"/" "$CASK_FILE"
    echo "==> Updated Homebrew Cask SHA-256 in $CASK_FILE"
  fi
fi

if [[ "$DO_INSTALL" == "true" ]]; then
  DEST="/Applications/$APP_NAME.app"
  echo "==> Gracefully quitting any running instance..."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
  sleep 0.6

  echo "==> Installing to $DEST..."
  rm -rf "$DEST"
  cp -R "$APP_BUNDLE" "$DEST"
  codesign --verify --deep --strict "$DEST"

  echo "==> Launching $DEST..."
  open "$DEST"
fi

echo "==> All done."
