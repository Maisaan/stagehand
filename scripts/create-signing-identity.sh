#!/bin/bash
set -euo pipefail
# Creates a self-signed code signing identity in the login keychain. Accessibility
# permission follows the code signature, and this identity gives every local build
# the same designated requirement for ten years, so the grant survives rebuilds.
# An Apple Development certificate changes when Apple reissues it.
#
# build-app.sh only prefers this identity once it is trusted for code signing
# (`security find-identity -v` lists it). Trusting it changes keychain trust
# settings, so macOS prompts for your login password.
name="${STAGEHAND_SIGNING_IDENTITY:-Stagehand Local Code Signing}"
keychain="$(security default-keychain -d user | tr -d ' "')"

trust_certificate() {
    printf 'Trusting "%s" for code signing. macOS will now ask for your login password.\n' "$name"
    if ! security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$1"; then
        printf 'The identity was not trusted. Run this script again to finish, or build-app.sh will fall back to another signature.\n' >&2
        exit 1
    fi
}

# `find-identity -v` lists only identities that are valid for the policy, so a
# trusted identity returns here. An imported but untrusted one does not match
# and is handled below.
if security find-identity -v -p codesigning "$keychain" | grep -qF "\"$name\""; then
    printf 'Signing identity already exists and is trusted: %s\n' "$name"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# An earlier run may have imported the identity before its trust prompt was answered.
# Without -v, find-identity also lists identities marked CSSMERR_TP_NOT_TRUSTED.
if security find-identity -p codesigning "$keychain" | grep -qF "\"$name\""; then
    printf 'Found an untrusted signing identity: %s\n' "$name"
    security find-certificate -c "$name" -p "$keychain" > "$work/cert.pem"
    trust_certificate "$work/cert.pem"
    printf 'Trusted existing signing identity: %s\n' "$name"
    printf 'build-app.sh now signs with it. Rebuild and grant Accessibility once more for the new signature.\n'
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
printf 'Imported signing identity: %s\n' "$name"
# Trust it for code signing only.
trust_certificate "$work/cert.pem"
printf 'Created signing identity: %s\n' "$name"
printf 'build-app.sh now signs with it. Rebuild and grant Accessibility once more for the new signature.\n'
