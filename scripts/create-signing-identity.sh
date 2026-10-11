#!/bin/bash
set -euo pipefail
# Creates a self-signed code signing identity in the login keychain. Accessibility
# permission follows the code signature, and this identity gives every local build
# the same designated requirement for ten years, so the grant survives rebuilds.
# An Apple Development certificate changes when Apple reissues it.
name="${STAGEHAND_SIGNING_IDENTITY:-Stagehand Local Code Signing}"
keychain="$(security default-keychain -d user | tr -d ' "')"

if security find-identity -v -p codesigning "$keychain" | grep -qF "\"$name\""; then
    printf 'Signing identity already exists: %s\n' "$name"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# An earlier run may have imported the identity before its trust prompt was answered.
if security find-identity -p codesigning "$keychain" | grep -qF "\"$name\""; then
    security find-certificate -c "$name" -p "$keychain" > "$work/cert.pem"
    security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"
    printf 'Trusted existing signing identity: %s\n' "$name"
    exit 0
fi
password="$(openssl rand -hex 16)"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$name" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
# The keychain reads only the older PKCS#12 algorithms.
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$password" -out "$work/identity.p12"
security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
# Trust it for code signing only. macOS asks for your password to change trust settings.
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"
printf 'Created signing identity: %s\n' "$name"
