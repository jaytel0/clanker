#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AgentNotch"
BUNDLE_ID="dev.agentnotch.app"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALL_BUNDLE="/Applications/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -f "codex app-server --listen ws://127.0.0.1:41241" >/dev/null 2>&1 || true

swift build --package-path "$ROOT_DIR"
BUILD_BIN_DIR="$(swift build --package-path "$ROOT_DIR" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# Copy any SPM-generated resource bundles next to the binary into the
# app's Resources/ directory. Without this step, `Bundle.module` works in
# `swift run` (which leaves resources alongside the binary) but fails in
# the packaged .app, breaking icon/asset loading.
mkdir -p "$APP_CONTENTS/Resources"
shopt -s nullglob
for bundle in "$BUILD_BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_CONTENTS/Resources/"
done
shopt -u nullglob

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Agent Notch uses Apple Events to bring the selected terminal window to the front.</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>Agent Notch uses Accessibility to raise the exact terminal window for the selected session.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --install|install)
    rm -rf "$INSTALL_BUNDLE"
    cp -R "$APP_BUNDLE" "$INSTALL_BUNDLE"
    /usr/bin/open -n "$INSTALL_BUNDLE"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--install]" >&2
    exit 2
    ;;
esac
