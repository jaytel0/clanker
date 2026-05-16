#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CERT_PATH="${1:?usage: $0 path/to/developer_id_application.cer}"
KEY_PATH="${KEY_PATH:-$ROOT_DIR/.release-secrets/clanker-developer-id.key}"
KEYCHAIN="${SIGN_KEYCHAIN:-$ROOT_DIR/.release-secrets/clanker-signing.keychain-db}"
KEYCHAIN_PASSWORD_FILE="${SIGN_KEYCHAIN_PASSWORD_FILE:-$ROOT_DIR/.release-secrets/clanker-signing.keychain-password}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Jaytel Provence (N6S323FR6Q)}"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ ! -f "$CERT_PATH" ]]; then
  echo "error: certificate not found: $CERT_PATH" >&2
  exit 1
fi

if [[ ! -f "$KEY_PATH" ]]; then
  echo "error: private key not found: $KEY_PATH" >&2
  exit 1
fi

CERT_PEM="$TMP_DIR/developer-id.pem"
IDENTITY_P12="$TMP_DIR/developer-id.p12"
P12_PASSWORD="$(openssl rand -base64 24)"

mkdir -p "$(dirname "$KEYCHAIN_PASSWORD_FILE")"
if [[ ! -f "$KEYCHAIN_PASSWORD_FILE" ]]; then
  umask 077
  openssl rand -base64 32 >"$KEYCHAIN_PASSWORD_FILE"
fi
KEYCHAIN_PASSWORD="$(cat "$KEYCHAIN_PASSWORD_FILE")"

if /usr/bin/openssl x509 -inform DER -in "$CERT_PATH" -out "$CERT_PEM" 2>/dev/null; then
  :
else
  /usr/bin/openssl x509 -in "$CERT_PATH" -out "$CERT_PEM"
fi

rm -f "$KEYCHAIN"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"

keychains=()
found=0
while IFS= read -r keychain; do
  keychain="${keychain#    \"}"
  keychain="${keychain#\"}"
  keychain="${keychain%\"}"
  if [[ -n "$keychain" ]]; then
    keychains+=("$keychain")
    [[ "$keychain" == "$KEYCHAIN" ]] && found=1
  fi
done < <(security list-keychains -d user)

if [[ "$found" -eq 0 ]]; then
  security list-keychains -d user -s "$KEYCHAIN" "${keychains[@]}"
fi

openssl pkcs12 -export -legacy \
  -inkey "$KEY_PATH" \
  -in "$CERT_PEM" \
  -name "$SIGN_IDENTITY" \
  -out "$IDENTITY_P12" \
  -passout "pass:$P12_PASSWORD"

security import "$IDENTITY_P12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASSWORD" \
  -A \
  -T /usr/bin/codesign \
  -T /usr/bin/security

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN" >/dev/null

security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$SIGN_IDENTITY"
echo "Signing keychain: $KEYCHAIN"
