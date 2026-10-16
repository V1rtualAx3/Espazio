#!/usr/bin/env bash
# Creates the self-signed code-signing identity used by CI builds (run once, on your Mac).
#
# Why: ad-hoc signed builds have a new identity at every build, so macOS treats each update as
# another app and asks again for Keychain access. Signing every build with the same certificate
# keeps the designated requirement stable: "Always allow" is then given once for good.
# It does not replace a Developer ID: Gatekeeper still shows the app as unidentified.
#
# Output (outside the repository): ~/.espazio-signing/espazio-signing.p12 and its password, to
# store as GitHub secrets MACOS_SIGNING_P12 (base64) and MACOS_SIGNING_PASSWORD.
set -euo pipefail

OPENSSL=/usr/bin/openssl   # LibreSSL: its PKCS#12 output is readable by `security import`
DIR="$HOME/.espazio-signing"
NAME="Espazio Self-Signed"
if [[ -e "$DIR/espazio-signing.p12" ]]; then
    echo "An identity already exists in $DIR (delete it to create a new one)." >&2
    exit 1
fi
mkdir -p "$DIR"
chmod 700 "$DIR"
cd "$DIR"
umask 077

cat > openssl.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

"$OPENSSL" req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
    -keyout key.pem -out cert.pem -config openssl.cnf 2>/dev/null
PASSWORD="$("$OPENSSL" rand -base64 24)"
"$OPENSSL" pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" \
    -out espazio-signing.p12 -passout "pass:$PASSWORD"
base64 < espazio-signing.p12 | tr -d '\n' > espazio-signing.p12.b64
printf '%s' "$PASSWORD" > password.txt
rm -f key.pem openssl.cnf

cat <<MSG
Identity created in $DIR.

Add two repository secrets (GitHub › Settings › Secrets and variables › Actions):
  MACOS_SIGNING_P12       contents of $DIR/espazio-signing.p12.b64
  MACOS_SIGNING_PASSWORD  contents of $DIR/password.txt

With the GitHub CLI:
  gh secret set MACOS_SIGNING_P12 < "$DIR/espazio-signing.p12.b64"
  gh secret set MACOS_SIGNING_PASSWORD < "$DIR/password.txt"

Keep $DIR private and backed up: a new certificate means one more Keychain prompt.
MSG
