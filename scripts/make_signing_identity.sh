#!/bin/zsh
# Creates a local, self-signed code-signing identity for Pixora in its own keychain inside the project
# (.signing/), so every rebuild is signed by the same identity. macOS then recognises each new build as the
# same app and doesn't ask for the keychain password again. Ad-hoc signatures change with every build, which
# is what triggers that prompt.
#
# Nothing is added to the login keychain and no system trust settings are changed. The identity is only good
# for signing this app on this Mac. Delete .signing/ to remove it.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="$PWD/.signing"
KC="$DIR/pixora-signing.keychain-db"
NAME="Pixora Local Signing"
if [[ -f "$KC" ]]; then echo "✓ signing identity already exists ($KC)"; exit 0; fi

mkdir -p "$DIR"; chmod 700 "$DIR"
KCPASS="$(openssl rand -hex 24)"
P12PASS="$(openssl rand -hex 16)"
print -r -- "$KCPASS" > "$DIR/keychain-password"; chmod 600 "$DIR/keychain-password"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$P12PASS"

security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"            # no auto-lock timeout
security unlock-keychain -p "$KCPASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
echo "✓ created signing identity “$NAME” in $KC"
