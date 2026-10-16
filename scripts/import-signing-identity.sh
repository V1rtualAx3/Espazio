#!/usr/bin/env bash
# CI: imports the self-signed identity from MACOS_SIGNING_P12 / MACOS_SIGNING_PASSWORD into a
# temporary keychain and exports CODESIGN_IDENTITY for the next steps. Without the secrets, builds
# stay ad-hoc signed (each version then asks again for Keychain access).
set -euo pipefail

if [[ -z "${MACOS_SIGNING_P12:-}" || -z "${MACOS_SIGNING_PASSWORD:-}" ]]; then
    echo "::notice::No signing identity configured: ad-hoc signing (see scripts/create-signing-identity.sh)."
    exit 0
fi

WORK="$RUNNER_TEMP/signing"
KEYCHAIN="$WORK/espazio.keychain-db"
KEYCHAIN_PASSWORD="$(/usr/bin/openssl rand -base64 24)"
mkdir -p "$WORK"
printf '%s' "$MACOS_SIGNING_P12" | base64 --decode > "$WORK/identity.p12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$MACOS_SIGNING_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

# LibreSSL (/usr/bin/openssl) reads the PKCS#12 written by create-signing-identity.sh as is.
/usr/bin/openssl pkcs12 -in "$WORK/identity.p12" -passin "pass:$MACOS_SIGNING_PASSWORD" -nokeys -clcerts \
    | /usr/bin/openssl x509 -outform PEM > "$WORK/cert.pem"
# Trust it for code signing on this runner so codesign accepts the identity.
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$WORK/cert.pem"
SHA1="$(/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
rm -f "$WORK/identity.p12"

security find-identity -v -p codesigning "$KEYCHAIN"
echo "CODESIGN_IDENTITY=$SHA1" >> "$GITHUB_ENV"
echo "Signing with the self-signed identity $SHA1."
