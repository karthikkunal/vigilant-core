#!/usr/bin/env bash
# Generate a release keystore and app/android/key.properties.
#
# Both files are gitignored. Keep the keystore backed up and offline: losing it
# means you can no longer update an app already published under it.
#
# Usage: scripts/gen-keystore.sh [alias]
set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "$0")/../app/android" && pwd)"
KEYSTORE="$ANDROID_DIR/vigilant-core-release.jks"
PROPS="$ANDROID_DIR/key.properties"
ALIAS="${1:-vigilant-core}"

if [ -f "$KEYSTORE" ]; then
  echo "refusing to overwrite existing keystore: $KEYSTORE" >&2
  exit 1
fi

read -rsp "Keystore password: " STORE_PASS
echo
read -rsp "Confirm password: " STORE_PASS_CONFIRM
echo

if [ "$STORE_PASS" != "$STORE_PASS_CONFIRM" ]; then
  echo "passwords do not match" >&2
  exit 1
fi
if [ -z "$STORE_PASS" ]; then
  echo "password must not be empty" >&2
  exit 1
fi

keytool -genkeypair -v \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -storepass "$STORE_PASS" -keypass "$STORE_PASS" \
  -dname "CN=vigilant-core, OU=, O=, L=, ST=, C="

umask 077
cat > "$PROPS" <<EOF
storePassword=$STORE_PASS
keyPassword=$STORE_PASS
keyAlias=$ALIAS
storeFile=vigilant-core-release.jks
EOF
chmod 600 "$PROPS" "$KEYSTORE"

echo
echo "wrote:"
echo "  $KEYSTORE"
echo "  $PROPS"
echo
echo "Both are gitignored. Back them up somewhere safe and offline."
