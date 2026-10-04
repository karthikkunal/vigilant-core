#!/usr/bin/env bash
# Reproducible-build check for vigilant-core.
#
# Builds the release APK twice from clean checkouts at the SAME absolute path
# (Flutter embeds the project path in libapp.so, so the path must match — this is
# how F-Droid builds) and compares:
#
#   * the whole-file hash, which includes the APK signing block — not
#     deterministic, and F-Droid signs the APK itself, so a mismatch here is
#     expected and harmless;
#   * the PAYLOAD hash — every archive entry, signature block excluded. This is
#     the meaningful, F-Droid-comparable result.
#
# Usage: scripts/repro-build.sh [work-dir]
set -uo pipefail

export PATH="$HOME/development/flutter/bin:$PATH"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
# Fixed timestamp so Gradle/AGP do not embed the current time.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-/tmp/opencode/vigilant-core-repro}"
DEST="$WORK/build-path"
OUT="$WORK/out"
mkdir -p "$OUT"
# Clear stale artifacts so a failed build cannot be compared against an old APK.
rm -f "$OUT"/app-release-*.apk

payload_hash() {
  local apk="$1"
  local dir
  dir="$(mktemp -d)"
  (cd "$dir" && unzip -q "$apk")
  # Hash every entry, ordered, so ordering differences do not matter.
  (cd "$dir" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) \
    | sha256sum | cut -d' ' -f1
  rm -rf "$dir"
}

for run in 1 2; do
  echo "=== run $run: clean checkout at $DEST ==="
  rm -rf "$DEST"
  mkdir -p "$DEST"
  tar -C "$SRC" \
    --exclude='./.git' \
    --exclude='./app/build' \
    --exclude='./app/.dart_tool' \
    --exclude='./app/android/.gradle' \
    --exclude='./packages/*/build' \
    --exclude='./packages/*/.dart_tool' \
    -cf - . | tar -C "$DEST" -xf -

  # Drop the Gradle build cache so a cached output cannot mask non-determinism.
  rm -rf "$HOME/.gradle/caches/build-cache-1"

  cd "$DEST/app"
  flutter pub get >/dev/null 2>&1
  if ! flutter build apk --release > "$OUT/build-$run.log" 2>&1; then
    echo "BUILD FAILED (run $run) — last lines:"
    tail -25 "$OUT/build-$run.log"
    exit 1
  fi
  tail -1 "$OUT/build-$run.log"

  apk="build/app/outputs/flutter-apk/app-release-unsigned.apk"
  [ -f "$apk" ] || apk="build/app/outputs/flutter-apk/app-release.apk"
  if [ ! -f "$apk" ]; then
    echo "no APK produced (run $run); looked for app-release*.apk"
    ls -1 build/app/outputs/flutter-apk/ 2>/dev/null
    exit 1
  fi
  cp "$apk" "$OUT/app-release-$run.apk"
  echo "artifact:  $(basename "$apk")"
  echo "whole:     $(sha256sum "$OUT/app-release-$run.apk" | cut -d' ' -f1)"
  echo "payload:   $(payload_hash "$OUT/app-release-$run.apk")"
done

whole1=$(sha256sum "$OUT/app-release-1.apk" | cut -d' ' -f1)
whole2=$(sha256sum "$OUT/app-release-2.apk" | cut -d' ' -f1)
payload1=$(payload_hash "$OUT/app-release-1.apk")
payload2=$(payload_hash "$OUT/app-release-2.apk")

echo
if [ "$payload1" = "$payload2" ]; then
  echo "PAYLOAD: IDENTICAL ($payload1)"
  if [ "$whole1" = "$whole2" ]; then
    echo "WHOLE FILE: IDENTICAL"
  else
    echo "WHOLE FILE: differs only in the signing block (expected; F-Droid re-signs)"
  fi
  exit 0
fi

echo "PAYLOAD: DIFFERENT"
cd "$OUT"
for run in 1 2; do
  rm -rf "u$run" && mkdir "u$run" && (cd "u$run" && unzip -q "../app-release-$run.apk")
done
echo "--- differing entries ---"
diff -qr u1 u2 | head -40
exit 1
