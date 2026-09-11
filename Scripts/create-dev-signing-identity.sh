#!/usr/bin/env bash
# Creates a self-signed code-signing certificate in the login keychain so local
# development builds keep a stable code identity across rebuilds.
#
# macOS TCC (Accessibility, Screen & System Audio Recording, Automation, ...)
# stores grants against an app's designated requirement. An ad-hoc signature's
# designated requirement is the cdhash of that exact binary, so every rebuild
# looks like a brand-new app and every permission has to be granted again.
# Signing with any real certificate changes the requirement to
#   identifier "com.barut.OmniWM" and certificate leaf = H"<cert hash>"
# which is identical for every build, so the grants persist.
#
# Usage:
#   ./Scripts/create-dev-signing-identity.sh [common-name]
#
# The default common name is "OmniWM Dev", which package-app.sh's dev mode
# picks up automatically. Override with OMNIWM_SIGNING_IDENTITY if you use a
# different name. The trust step opens a macOS authentication dialog; that is
# the only prompt and it runs once.
set -euo pipefail

COMMON_NAME="${1:-OmniWM Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if security find-identity -v -p codesigning "$KEYCHAIN" | grep -qF "\"$COMMON_NAME\""; then
  echo "A valid code-signing identity named \"$COMMON_NAME\" already exists in $KEYCHAIN."
  echo "Nothing to do. Run './Scripts/package-app.sh debug dev' to use it."
  exit 0
fi

cat >"$WORK_DIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no

[ dn ]
CN = $COMMON_NAME

[ ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "Generating self-signed code-signing certificate \"$COMMON_NAME\" (valid 10 years)..."
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -config "$WORK_DIR/openssl.cnf" \
  -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" >/dev/null 2>&1

# A throwaway export password is required by the PKCS#12 format; it never leaves this script.
P12_PASSWORD="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy \
  -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
  -name "$COMMON_NAME" -passout "pass:$P12_PASSWORD" -out "$WORK_DIR/identity.p12" 2>/dev/null \
  || openssl pkcs12 -export \
    -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -name "$COMMON_NAME" -passout "pass:$P12_PASSWORD" -out "$WORK_DIR/identity.p12"

echo "Importing into $KEYCHAIN (codesign is allowed to use the key without prompting)..."
security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN" -f pkcs12 \
  -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "Marking the certificate as trusted for code signing (macOS will ask for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK_DIR/cert.pem"

echo
if security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "\"$COMMON_NAME\""; then
  echo
  echo "Done. Development builds will now sign as \"$COMMON_NAME\"."
  if [ "$COMMON_NAME" != "OmniWM Dev" ]; then
    echo "Because you chose a custom name, export OMNIWM_SIGNING_IDENTITY=\"$COMMON_NAME\" before packaging."
  fi
  echo
  echo "Next steps:"
  echo "  1. ./Scripts/package-app.sh debug dev   (or: make run)"
  echo "  2. Grant Accessibility and Screen & System Audio Recording one more time."
  echo "     Remove the stale ad-hoc OmniWM entries in System Settings > Privacy & Security first if they linger."
  echo "  3. Rebuild freely; the grants now survive rebuilds."
else
  echo "error: the identity was imported but is not reported as valid for code signing." >&2
  echo "Open Keychain Access, find \"$COMMON_NAME\" in the login keychain, and set Trust > Code Signing to Always Trust." >&2
  exit 1
fi
