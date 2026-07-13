#!/bin/bash
# Creates (if needed) and trusts a local, self-signed code-signing certificate named
# ReclaimLocalSign in your login keychain.
#
# Why this exists: build.sh signs Reclaim.app with this identity instead of ad-hoc ("-")
# signing. Ad-hoc signatures are derived from the binary's own hash, so every rebuild looks
# like a "different app" to macOS — which means any one-time permission grants (e.g. the
# Background Items approval for the weekly LaunchAgent) would get reset on every rebuild too.
# A stable certificate-based identity fixes that, as long as the certificate is also
# *trusted*. This script does both: create the identity, and trust it for code signing.
#
# Everything here is scoped to your own login keychain — no sudo, no system-wide trust
# changes. Mirrors gokulmc/membar's setup-signing.sh (docs/IMPLEMENTATION.md locked decision:
# "setup-signing.sh creates the stable identity, same as membar").
#
# This script modifies your keychain and is meant to be run manually by you, once — it is
# never invoked automatically by build.sh or by any agent.
set -euo pipefail

IDENTITY_NAME="ReclaimLocalSign"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "${IDENTITY_NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
    echo "Certificate '${IDENTITY_NAME}' already exists in your login keychain."
else
    echo "==> Generating a local self-signed code-signing certificate"
    TMP=$(mktemp -d)
    trap 'rm -rf "${TMP}"' EXIT

    openssl req -x509 -newkey rsa:2048 -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" -days 3650 -nodes \
        -subj "/CN=${IDENTITY_NAME}" \
        -addext "keyUsage=digitalSignature" \
        -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1

    openssl pkcs12 -export -out "${TMP}/cert.p12" -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
        -passout pass:tempimportpass -legacy >/dev/null 2>&1 || \
    openssl pkcs12 -export -out "${TMP}/cert.p12" -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
        -passout pass:tempimportpass >/dev/null 2>&1

    echo "==> Importing it into your login keychain"
    security import "${TMP}/cert.p12" -k "${KEYCHAIN}" -P tempimportpass -T /usr/bin/codesign -A

    echo "==> Trusting it for code signing"
    security add-trusted-cert -p codeSign -k "${KEYCHAIN}" "${TMP}/cert.pem"

    echo "Done. '${IDENTITY_NAME}' is ready."
fi

echo "Run ./build.sh (or re-run it) to build and sign with this identity."
