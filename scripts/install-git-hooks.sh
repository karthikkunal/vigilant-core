#!/usr/bin/env bash
# Install the versioned hooks in this repository's local Git configuration.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="$ROOT_DIR/.githooks"

if [[ ! -d "$HOOKS_DIR" ]]; then
  printf 'install-git-hooks: missing %s\n' "$HOOKS_DIR" >&2
  exit 1
fi

chmod +x \
  "$HOOKS_DIR/pre-commit" \
  "$HOOKS_DIR/pre-push" \
  "$ROOT_DIR/scripts/check.sh"
git -C "$ROOT_DIR" config --local core.hooksPath .githooks

printf 'Installed local Git hooks from %s\n' "$HOOKS_DIR"
printf '  pre-commit: formatting + analysis\n'
printf '  pre-push:   staged formatting + analysis + tests + debug APK build\n'
