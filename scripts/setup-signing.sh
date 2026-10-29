#!/usr/bin/env bash
# Creates a self-signed "Pauta Dev" code-signing identity in the login keychain.
# A stable signature keeps Keychain access and privacy permissions (mic, screen
# recording) across rebuilds; ad-hoc signatures change on every build.
set -euo pipefail

NAME="Pauta Dev"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "Identity \"$NAME\" already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out "$TMP/cert.p12" -passout pass:pauta -name "$NAME" 2>/dev/null

security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db \
    -P pauta -T /usr/bin/codesign -T /usr/bin/security
echo "Created identity \"$NAME\"."
