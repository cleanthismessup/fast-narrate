#!/bin/bash
# Creates a stable self-signed code-signing certificate "Fast Narrate Dev" in your login keychain.
# Run once. Builds signed with it keep the same identity, so macOS permissions
# (Accessibility, Screen Recording) survive rebuilds.
set -euo pipefail

NAME="Fast Narrate Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "'$NAME' already exists. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > cert.cnf <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Fast Narrate Dev
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf >/dev/null 2>&1
PW="$(openssl rand -hex 16)"
LEGACY=""
openssl pkcs12 -help 2>&1 | grep -q -- "-legacy" && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -inkey key.pem -in cert.pem -name "$NAME" -out fn.p12 -passout "pass:$PW"

security import fn.p12 -k "$KEYCHAIN" -P "$PW" -T /usr/bin/codesign -T /usr/bin/security
echo "Trusting the certificate for code signing (macOS will ask for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem

echo
security find-identity -v -p codesigning | grep "$NAME" && echo "Done: '$NAME' is ready."
