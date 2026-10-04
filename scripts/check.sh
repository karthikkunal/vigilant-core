#!/usr/bin/env bash
# Run the local quality checks used by the git hooks.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-full}"

usage() {
  cat <<'EOF'
Usage: scripts/check.sh [mode]

Modes:
  pre-commit  Check staged Dart formatting and analyze every Dart package
  pre-push    Check staged formatting, analyze, test, build the APK and the site
  full        Check all Dart formatting, analyze, test, build APK and site
  format      Check formatting for all Dart source directories
  analyze     Run the Dart/Flutter analyzers
  test        Run the Dart/Flutter test suites
  build       Build the debug Android APK
  site        Build the website and verify every local reference in it
  release     Check release readiness (see scripts/check-release.sh)
EOF
}

fail() {
  printf 'check: %s\n' "$*" >&2
  exit 1
}

# Match the SDK location used by scripts/repro-build.sh when Flutter is not
# already available in the caller's PATH.
ensure_dart() {
  if ! command -v dart >/dev/null 2>&1; then
    local flutter_bin="${HOME:-}/development/flutter/bin"
    if [[ -x "$flutter_bin/dart" ]]; then
      export PATH="$flutter_bin:${PATH:-}"
    else
      fail "Dart is not on PATH. Install the Flutter SDK or add its bin directory."
    fi
  fi
  command -v dart >/dev/null 2>&1 || fail "Dart is not on PATH."
}

ensure_flutter() {
  if ! command -v flutter >/dev/null 2>&1; then
    local flutter_bin="${HOME:-}/development/flutter/bin"
    if [[ -x "$flutter_bin/flutter" ]]; then
      export PATH="$flutter_bin:${PATH:-}"
    else
      fail "Flutter is not on PATH. Install Flutter or add its bin directory."
    fi
  fi
  command -v flutter >/dev/null 2>&1 || fail "Flutter is not on PATH."
}

format_all() {
  printf '\n==> Checking Dart formatting\n'
  dart format --output=none --set-exit-if-changed \
    "$ROOT_DIR/app/lib" \
    "$ROOT_DIR/app/test" \
    "$ROOT_DIR/packages/discovery_core/lib" \
    "$ROOT_DIR/packages/discovery_core/test" \
    "$ROOT_DIR/packages/discovery_core/example" \
    "$ROOT_DIR/packages/cert_chain/lib" \
    "$ROOT_DIR/packages/cert_chain/test" \
    "$ROOT_DIR/packages/system_dns/lib" \
    "$ROOT_DIR/packages/system_dns/test"
}

format_staged() {
  # Keep the fast commit hook focused on the change being committed. The full
  # mode below can be used to check repository-wide formatting debt.
  local files=()
  local file

  while IFS= read -r file; do
    case "$file" in
      *.dart)
        if [[ -f "$ROOT_DIR/$file" ]]; then
          files+=("$ROOT_DIR/$file")
        fi
        ;;
    esac
  done < <(git -C "$ROOT_DIR" diff --cached --name-only --diff-filter=ACMR)

  if [[ "${#files[@]}" -eq 0 ]]; then
    printf '\n==> No staged Dart files; skipping formatting check\n'
    return
  fi

  printf '\n==> Checking formatting for staged Dart files\n'
  dart format --output=none --set-exit-if-changed "${files[@]}"
}

analyze_all() {
  # The Dart/Flutter analyzer is the project's linter and static type checker.
  printf '\n==> Analyzing Flutter app\n'
  (cd "$ROOT_DIR/app" && flutter analyze)

  printf '\n==> Analyzing discovery_core\n'
  (cd "$ROOT_DIR/packages/discovery_core" && dart analyze)

  printf '\n==> Analyzing cert_chain\n'
  (cd "$ROOT_DIR/packages/cert_chain" && flutter analyze)

  printf '\n==> Analyzing system_dns\n'
  (cd "$ROOT_DIR/packages/system_dns" && flutter analyze)
}

test_all() {
  printf '\n==> Testing Flutter app\n'
  (cd "$ROOT_DIR/app" && flutter test)

  printf '\n==> Testing discovery_core\n'
  (cd "$ROOT_DIR/packages/discovery_core" && dart test)

  printf '\n==> Testing cert_chain\n'
  (cd "$ROOT_DIR/packages/cert_chain" && flutter test)

  printf '\n==> Testing system_dns\n'
  (cd "$ROOT_DIR/packages/system_dns" && flutter test)
}

build_all() {
  printf '\n==> Building debug Android APK\n'
  (cd "$ROOT_DIR/app" && flutter build apk --debug)
}

build_site() {
  # Cheap, and the only automated check the site has: it builds the pages
  # artifact and verifies every local reference in it resolves. Needs no
  # Flutter toolchain, so it also runs in the Pages CI job.
  printf '\n==> Building the website\n'
  "$ROOT_DIR/scripts/build-site.sh" "$ROOT_DIR/public"
}

# Guards the things that rot silently between releases: unfilled store
# placeholders, a stale application id, a recipe that no longer pins the tagged
# commit, an unreachable privacy policy, and documentation pointing at files
# that have moved. No toolchain and no network required, apart from one
# best-effort HEAD request to the privacy URL.
check_release() {
  printf '\n==> Checking release readiness\n'
  "$ROOT_DIR/scripts/check-release.sh"
}

case "$MODE" in
  -h|--help|help)
    usage
    ;;
  pre-commit)
    ensure_dart
    ensure_flutter
    format_staged
    analyze_all
    ;;
  pre-push)
    ensure_dart
    ensure_flutter
    format_staged
    analyze_all
    test_all
    build_all
    build_site
    check_release
    ;;
  full|all)
    ensure_dart
    ensure_flutter
    format_all
    analyze_all
    test_all
    build_all
    build_site
    check_release
    ;;
  format)
    ensure_dart
    format_all
    ;;
  analyze)
    ensure_dart
    ensure_flutter
    analyze_all
    ;;
  test)
    ensure_dart
    ensure_flutter
    test_all
    ;;
  build)
    ensure_flutter
    build_all
    ;;
  site)
    build_site
    ;;
  release)
    check_release
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
