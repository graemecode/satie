#!/usr/bin/env bash
# Satie Lab: listen to each world on the real engine and leave feedback (Lab/feedback.jsonl).
# Builds build/Satie Lab.app (developer-only, never shipped) and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product SatieLab
BIN="$(swift build -c release --show-bin-path)/SatieLab"
APP="build/Satie Lab.app"
BUILD="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- Sources || echo "+changes")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SatieLab"
# SwiftPM resource bundle (samples, localization) sits beside the binary
cp -R "$(dirname "$BIN")"/*.bundle "$APP/Contents/MacOS/" 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.strangechances.SatieLab</string>
  <key>CFBundleName</key><string>Satie Lab</string>
  <key>CFBundleDisplayName</key><string>Satie Lab</string>
  <key>CFBundleExecutable</key><string>SatieLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>SatieLabBuild</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
pkill -f "Satie Lab.app/Contents/MacOS/SatieLab" 2>/dev/null || true
open "$APP"
