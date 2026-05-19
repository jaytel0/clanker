#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Clanker"
BUNDLE_ID="dev.clanker.app"
MIN_SYSTEM_VERSION="14.0"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Jaytel Provence (N6S323FR6Q)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-clanker-notary}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-NH5ZQ992V7}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-1efb7cca-9219-4513-86b4-57fe29e496a7}"
NOTARY_SECRETS_REPO="${NOTARY_SECRETS_REPO:-jaytel0/secrets}"
NOTARY_SECRETS_SUBDIR="${NOTARY_SECRETS_SUBDIR:-clanker/.release-secrets}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
VERSION="$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALL_BUNDLE="/Applications/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ENTITLEMENTS="$ROOT_DIR/script/Clanker.entitlements"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-$ROOT_DIR/.release-secrets/clanker-signing.keychain-db}"
SIGN_KEYCHAIN_PASSWORD_FILE="${SIGN_KEYCHAIN_PASSWORD_FILE:-$ROOT_DIR/.release-secrets/clanker-signing.keychain-password}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-$SIGN_KEYCHAIN}"
TEMP_PATHS=()

cleanup() {
  if [[ "${#TEMP_PATHS[@]}" -eq 0 ]]; then
    return 0
  fi
  for path in "${TEMP_PATHS[@]}"; do
    rm -rf "$path"
  done
}
trap cleanup EXIT

is_release_mode() {
  case "$MODE" in
    --install|install|--release|release|--notarize|notarize)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_distribution_mode() {
  case "$MODE" in
    --release|release|--notarize|notarize)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

has_signing_identity() {
  if [[ -f "$SIGN_KEYCHAIN" ]]; then
    security find-identity -v -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -qF "$SIGN_IDENTITY"
  else
    security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"
  fi
}

require_developer_id_identity() {
  if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
    echo "error: distribution builds must use a Developer ID Application identity" >&2
    echo "       current identity: $SIGN_IDENTITY" >&2
    return 1
  fi
}

unlock_signing_keychain() {
  if [[ -f "$SIGN_KEYCHAIN" && -f "$SIGN_KEYCHAIN_PASSWORD_FILE" ]]; then
    local keychain
    local keychains=()
    local found=0

    while IFS= read -r keychain; do
      keychain="${keychain#    \"}"
      keychain="${keychain#\"}"
      keychain="${keychain%\"}"
      if [[ -n "$keychain" ]]; then
        keychains+=("$keychain")
        [[ "$keychain" == "$SIGN_KEYCHAIN" ]] && found=1
      fi
    done < <(security list-keychains -d user)

    if [[ "$found" -eq 0 ]]; then
      if [[ "${#keychains[@]}" -eq 0 ]]; then
        security list-keychains -d user -s "$SIGN_KEYCHAIN"
      else
        security list-keychains -d user -s "$SIGN_KEYCHAIN" "${keychains[@]}"
      fi
    fi

    security unlock-keychain -p "$(cat "$SIGN_KEYCHAIN_PASSWORD_FILE")" "$SIGN_KEYCHAIN"
  fi
}

strip_quarantine() {
  local bundle="$1"
  xattr -dr com.apple.quarantine "$bundle" >/dev/null 2>&1 || true
}

sign_app() {
  local bundle="$1"

  unlock_signing_keychain

  if ! has_signing_identity; then
    echo "error: signing identity not found: $SIGN_IDENTITY" >&2
    return 1
  fi

  if [[ -f "$SIGN_KEYCHAIN" ]]; then
    strip_quarantine "$bundle"
    codesign --force --deep --timestamp --options runtime \
      --entitlements "$ENTITLEMENTS" \
      --keychain "$SIGN_KEYCHAIN" \
      --sign "$SIGN_IDENTITY" \
      "$bundle"
  else
    strip_quarantine "$bundle"
    codesign --force --deep --timestamp --options runtime \
      --entitlements "$ENTITLEMENTS" \
      --sign "$SIGN_IDENTITY" \
      "$bundle"
  fi

  codesign --verify --deep --strict --verbose=2 "$bundle"
}

zip_app() {
  local app_path="$1"
  local zip_path="$2"
  local app_parent
  local app_name

  app_parent="$(dirname "$app_path")"
  app_name="$(basename "$app_path")"
  rm -f "$zip_path"
  (cd "$app_parent" && ditto -c -k --keepParent "$app_name" "$zip_path")
}

notary_key_path() {
  if [[ -n "${NOTARY_KEY_PATH:-}" && -f "$NOTARY_KEY_PATH" ]]; then
    printf '%s\n' "$NOTARY_KEY_PATH"
    return 0
  fi

  local key_name="AuthKey_${NOTARY_KEY_ID}.p8"
  local candidates=(
    "$ROOT_DIR/.release-secrets/$key_name"
    "$ROOT_DIR/../secrets/$NOTARY_SECRETS_SUBDIR/$key_name"
    "$HOME/Developer/personal/secrets/$NOTARY_SECRETS_SUBDIR/$key_name"
    "$HOME/Developer/secrets/$NOTARY_SECRETS_SUBDIR/$key_name"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v gh >/dev/null 2>&1; then
    local clone_dir
    clone_dir="$(mktemp -d "/tmp/${APP_NAME}-secrets.XXXXXX")"
    TEMP_PATHS+=("$clone_dir")
    if gh repo clone "$NOTARY_SECRETS_REPO" "$clone_dir" >/dev/null 2>&1; then
      candidate="$clone_dir/$NOTARY_SECRETS_SUBDIR/$key_name"
      if [[ -f "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi

  return 1
}

notary_profile_is_available() {
  if [[ -f "$NOTARY_KEYCHAIN" ]]; then
    unlock_signing_keychain
    xcrun notarytool history \
      --keychain-profile "$NOTARY_PROFILE" \
      --keychain "$NOTARY_KEYCHAIN" \
      >/dev/null 2>&1
  else
    xcrun notarytool history \
      --keychain-profile "$NOTARY_PROFILE" \
      >/dev/null 2>&1
  fi
}

submit_notarization() {
  local zip_path="$1"

  if notary_profile_is_available; then
    if [[ -f "$NOTARY_KEYCHAIN" ]]; then
      unlock_signing_keychain
      xcrun notarytool submit "$zip_path" \
        --keychain-profile "$NOTARY_PROFILE" \
        --keychain "$NOTARY_KEYCHAIN" \
        --wait \
        --timeout 30m
    else
      xcrun notarytool submit "$zip_path" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --timeout 30m
    fi
    return
  fi

  local key_path
  if ! key_path="$(notary_key_path)"; then
    echo "error: no notary profile or App Store Connect API key found" >&2
    return 1
  fi

  xcrun notarytool submit "$zip_path" \
    --key "$key_path" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait \
    --timeout 30m
}

notarize_app() {
  local app_path="$1"

  if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "Skipping notarization because SKIP_NOTARIZE=1"
    return 0
  fi

  local zip_path
  zip_path="$(mktemp -t "${APP_NAME}-notary")"
  rm -f "$zip_path"
  zip_path="$zip_path.zip"
  TEMP_PATHS+=("$zip_path")

  zip_app "$app_path" "$zip_path"
  submit_notarization "$zip_path"
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  spctl --assess --type execute --verbose=4 "$app_path"
}

install_bundle_preserving_container() {
  local source_bundle="$1"
  local target_bundle="$2"

  if [[ -d "$target_bundle" ]]; then
    mkdir -p "$target_bundle"
    rm -rf "$target_bundle/Contents"
    cp -R "$source_bundle/Contents" "$target_bundle/Contents"
  else
    cp -R "$source_bundle" "$target_bundle"
  fi
}

if is_distribution_mode; then
  require_developer_id_identity
  unlock_signing_keychain
  if ! has_signing_identity; then
    echo "error: signing identity not found: $SIGN_IDENTITY" >&2
    exit 1
  fi
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -f "[c]odex app-server --listen ws://127.0.0.1:41241" >/dev/null 2>&1 || true

# Release for install/release modes, debug otherwise.
if is_release_mode; then
  BUILD_FLAGS="-c release"
else
  BUILD_FLAGS=""
fi

swift build --package-path "$ROOT_DIR" $BUILD_FLAGS
BUILD_BIN_DIR="$(swift build --package-path "$ROOT_DIR" $BUILD_FLAGS --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"

# Preserve the .app directory itself so macOS privacy/TCC metadata attached to
# the bundle container is not discarded on every rebuild.
mkdir -p "$APP_BUNDLE"
rm -rf "$APP_CONTENTS"
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

# Copy app icon.
if [[ -f "$ROOT_DIR/Sources/Clanker/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Sources/Clanker/Resources/AppIcon.icns" "$APP_CONTENTS/Resources/AppIcon.icns"
fi

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
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Clanker uses Apple Events to bring the selected terminal window to the front.</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>Clanker uses Accessibility to raise the exact terminal window for the selected session.</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign the bundle so macOS can track Accessibility permissions by signing
# identity rather than binary hash. Release modes require Developer ID signing
# because they are intended for distribution and notarization.
if is_release_mode; then
  sign_app "$APP_BUNDLE"
elif has_signing_identity; then
  sign_app "$APP_BUNDLE"
else
  echo "warning: signing identity not found; skipping codesign"
fi

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
    install_bundle_preserving_container "$APP_BUNDLE" "$INSTALL_BUNDLE"
    sign_app "$INSTALL_BUNDLE"
    if [[ "${NOTARIZE_INSTALL:-1}" == "1" ]]; then
      notarize_app "$INSTALL_BUNDLE"
    fi
    /usr/bin/open -n "$INSTALL_BUNDLE"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --release|release|--notarize|notarize)
    RELEASE_DIR="$ROOT_DIR/release"
    mkdir -p "$RELEASE_DIR"
    RELEASE_APP="$RELEASE_DIR/$APP_NAME.app"
    RELEASE_ZIP="$RELEASE_DIR/$APP_NAME-$VERSION.zip"
    rm -rf "$RELEASE_APP"
    cp -R "$APP_BUNDLE" "$RELEASE_APP"

    sign_app "$RELEASE_APP"
    notarize_app "$RELEASE_APP"
    zip_app "$RELEASE_APP" "$RELEASE_ZIP"

    echo "Release built: $RELEASE_ZIP"
    ;;
  *)
    echo "usage: $0 [run|install|release|notarize|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
