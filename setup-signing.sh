#!/bin/bash
# Creates a self-signed code-signing certificate so the Accessibility grant survives rebuilds.
#
# Why this is needed: macOS TCC identifies an ad-hoc signed app by the hash of its binary, so
# every rebuild looks like a brand new app and silently loses the permission. A stable signing
# identity makes the grant stick to the certificate + bundle id instead.
#
# Run this once, by hand:  ./setup-signing.sh
# It will ask for your login password when adding the certificate to your keychain.
# Remove it later with: ./setup-signing.sh --remove

set -euo pipefail
cd "$(dirname "$0")"

NAME="Notification Shade Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ "${1:-}" == "--remove" ]]; then
  sudo security delete-certificate -c "$NAME" "$KEYCHAIN" 2>/dev/null || true
  security delete-identity -c "$NAME" "$KEYCHAIN" 2>/dev/null || true
  echo "Removed '$NAME' from your keychain."
  exit 0
fi

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Identity '$NAME' already exists. Nothing to do."
  exit 0
fi

# Use the system LibreSSL, not a Homebrew OpenSSL 3.x. OpenSSL 3 writes PKCS#12 bundles with
# modern algorithms that macOS's `security import` cannot read ("MAC verification failed").
OPENSSL=/usr/bin/openssl

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate..."
"$OPENSSL" req -x509 -newkey rsa:2048 -keyout "$WORK/private.pem" -out "$WORK/cert.pem" \
  -days 3650 -nodes -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# A throwaway passphrase; `security import` rejects an empty one on some macOS versions.
P12PASS="shade-$$"
"$OPENSSL" pkcs12 -export -inkey "$WORK/private.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$P12PASS" -name "$NAME"

echo "==> Importing into your login keychain (allows /usr/bin/codesign to use it)..."
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign -A

echo "==> Marking it trusted for code signing..."
# User-domain trust, so this needs no sudo. macOS shows a dialog asking you to allow the
# change to your keychain — approve it. (The system-wide equivalent would be:
#   sudo security add-trusted-cert -d -r trustRoot -p codeSign \
#        -k /Library/Keychains/System.keychain cert.pem
# but that requires a password on a terminal, which is awkward to automate.)
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Done. './build.sh' will now sign with '$NAME'."
  echo "Grant Accessibility once more after the next install; it will stick from then on."
else
  echo "The identity was not picked up by codesign. Falling back to ad-hoc signing is fine —"
  echo "you will just have to re-grant Accessibility after each rebuild."
fi
