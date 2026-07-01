#!/bin/bash
# One-time setup: create a STABLE self-signed code-signing identity for
# StreamTalk so macOS Accessibility / Local Network grants survive rebuilds.
#
# ad-hoc signing (codesign --sign -) produces a new cdhash on every build, so
# TCC treats each rebuild as a "new app" and re-prompts. Signing with a fixed
# certificate keeps the designated requirement stable → grant once, done.
#
# Everything lives in an isolated keychain; undo with:
#   security delete-keychain ~/Library/Keychains/streamtalk-signing.keychain-db
set -euo pipefail

NAME="StreamTalk Self-Signed"
KC="$HOME/Library/Keychains/streamtalk-signing.keychain-db"
PW="streamtalk"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
    echo "==> identity '$NAME' already exists in $KC — nothing to do"
    exit 0
fi

echo "==> generating self-signed code-signing certificate"
cat > "$TMP/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $NAME
[ v3 ]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf"
# -legacy: OpenSSL 3's default PKCS12 encryption/MAC is too new for macOS's
# `security import`; legacy PBE (3DES + SHA1 MAC) is what Security can verify.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout "pass:$PW" -name "$NAME"

echo "==> creating isolated signing keychain"
security create-keychain -p "$PW" "$KC" 2>/dev/null || true
security set-keychain-settings "$KC"            # no auto-lock timeout
security unlock-keychain -p "$PW" "$KC"

echo "==> importing identity + trusting for code signing"
security import "$TMP/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign -A
# Trust the cert for code signing so it counts as a valid signing identity.
security add-trusted-cert -p codeSign -k "$KC" "$TMP/cert.pem" 2>/dev/null || true
# Let codesign use the private key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null

echo "==> adding signing keychain to the search list"
EXISTING=$(security list-keychains -d user | sed 's/[[:space:]]*"//; s/"$//')
if ! security list-keychains -d user | grep -q "streamtalk-signing"; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s $EXISTING "$KC"
fi

echo "==> done. Available code-signing identities:"
security find-identity -v -p codesigning
