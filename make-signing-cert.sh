#!/bin/bash
# Creates a stable self-signed code-signing identity, so TCC permissions survive
# rebuilds on a Mac with no Apple developer certificate.
#
# Why this is needed: TCC keys permissions on the code signature's designated
# requirement. Ad-hoc signing produces `cdhash H"..."`, the hash of the binary, so every
# rebuild looks like a different app and Accessibility and Input Monitoring must be
# granted again. Any real certificate produces a requirement based on the certificate
# instead, which does not change when the code does.
#
# This certificate cannot be used for distribution. It is for local development only.
set -euo pipefail

CERT_NAME="${STATION_CERT_NAME:-Station Development}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Signing identity \"$CERT_NAME\" already exists. Nothing to do."
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate"
# codeSigning EKU is required or codesign will refuse the identity.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$CERT_NAME/O=Station/C=US" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# macOS security(1) cannot read OpenSSL 3's default PKCS#12 encoding and fails with
# "MAC verification failed during PKCS12 import". The legacy 3DES/SHA-1 parameters are
# required, not merely preferred.
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout pass:station \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1 2>/dev/null

echo "==> Importing into the login keychain"
# -T authorises codesign to use the key without prompting each time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P station \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "==> Trusting it for code signing"
# Needed or the identity is not "valid" for signing and codesign cannot find it.
# User trust domain, so no sudo and no system-wide change.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Created signing identity:"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    echo
    echo "Now run ./build-app.sh — it will pick this up automatically."
    echo "Grant permissions once; they should survive future rebuilds."
    echo
    echo "If macOS asks for keychain access while signing, choose Always Allow."
else
    echo "Certificate was created but is not usable for code signing."
    echo "Open Keychain Access, find \"$CERT_NAME\", and set its trust for"
    echo "Code Signing to \"Always Trust\"."
    exit 1
fi
