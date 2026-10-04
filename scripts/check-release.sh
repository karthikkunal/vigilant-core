#!/usr/bin/env bash
# Release-readiness checks: the things that rot silently between releases.
#
# Every check here corresponds to a real failure that reached a release
# candidate before it was caught, so each one is a guard against a repeat rather
# than a style preference:
#
#   1. A `REPLACE` placeholder left in store metadata ships a broken listing.
#   2. A `com.example` identifier cannot be fixed after the first store upload.
#   3. A recipe pinning a commit other than the tagged one builds a different
#      1.0.0 than the tag advertises, and `UpdateCheckMode: Tags` then tracks a
#      build nobody can reproduce.
#   4. A privacy URL on the wrong host 404s, and both stores reject the build.
#   5. A `TODO` in a package changelog means the published description of a
#      shipped version was never written.
#   6. A relative link to a renamed file is documentation drift, which is how
#      this repository ended up pointing at three buttons that no longer exist.
#
# Needs no Flutter toolchain and touches no network, so it is cheap enough for
# the pre-push hook. Run directly with scripts/check-release.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

failures=0

fail() {
  printf 'release-check: %s\n' "$*" >&2
  failures=$((failures + 1))
}

pass() {
  printf '  ok  %s\n' "$*"
}

printf '==> Store metadata placeholders\n'
if leftovers="$(grep -rIn REPLACE \
  app/fastlane/metadata/ packages/cert_chain/ios/ \
  --exclude=README.md 2>/dev/null)" && [[ -n "$leftovers" ]]; then
  fail "REPLACE placeholders are still present:"
  printf '%s\n' "$leftovers" >&2
else
  pass "no REPLACE placeholders"
fi

printf '==> Application identifier\n'
# -I skips binary files, and the cache directories are excluded because they are
# gitignored and can still hold an applicationId from before the rename, which
# says nothing about what this tree builds. The non-empty test matters: grep
# reports a match on stderr for binary files, so without it a suppressed
# message could fail this check with nothing to show for it.
if leftovers="$(grep -rIn 'com\.example' app packages fdroid \
  --exclude-dir=build --exclude-dir=.dart_tool --exclude-dir=.gradle \
  --exclude-dir=.pub-cache 2>/dev/null)" && [[ -n "$leftovers" ]]; then
  fail "com.example identifiers are still present:"
  printf '%s\n' "$leftovers" >&2
else
  pass "no com.example identifiers"
fi

printf '==> Recipe pins the tagged commit\n'
recipe="fdroid/dev.ranjithraj.vigilant-core.yml"
if [[ ! -f "$recipe" ]]; then
  fail "$recipe is missing"
else
  version="$(sed -n 's/^CurrentVersion: *//p' "$recipe" | tr -d "'\" " | head -1)"
  pinned="$(sed -n 's/^ *commit: *//p' "$recipe" | head -1)"
  if [[ -z "$version" || -z "$pinned" ]]; then
    fail "could not read CurrentVersion/commit from $recipe"
  elif ! git rev-parse --verify --quiet "refs/tags/$version" >/dev/null; then
    fail "tag $version does not exist locally; fetch tags or create it"
  else
    tagged="$(git rev-parse "$version^{commit}")"
    if [[ "$pinned" == "$tagged" ]]; then
      pass "$recipe pins $version ($pinned)"
    else
      fail "recipe pins $pinned but tag $version is $tagged"
      printf '        the tag is what UpdateCheckMode: Tags follows\n' >&2
    fi
  fi
fi

printf '==> Privacy policy URL\n'
privacy="app/fastlane/metadata/ios/en-US/privacy_url.txt"
if [[ ! -f "$privacy" ]]; then
  fail "$privacy is missing"
else
  url="$(tr -d '[:space:]' < "$privacy")"
  case "$url" in
    https://*.example.com/*|https://*REPLACE*)
      fail "privacy_url.txt is still a placeholder: $url"
      ;;
    https://*)
      pass "privacy_url.txt is $url"
      # Reachability is the one check that needs the network, so it is a
      # warning: a laptop with no connection should not fail a local commit.
      if command -v curl >/dev/null 2>&1; then
        code="$(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 20 "$url" || echo 000)"
        case "$code" in
          2*|3*) pass "privacy policy resolves ($code)" ;;
          000) printf '  warn could not reach %s (offline?)\n' "$url" >&2 ;;
          *) fail "privacy policy does not resolve: $url returned $code" ;;
        esac
      fi
      ;;
    *)
      fail "privacy_url.txt is not an https URL: $url"
      ;;
  esac
fi

printf '==> Package changelogs\n'
if leftovers="$(grep -rIn 'TODO' packages/*/CHANGELOG.md 2>/dev/null)" \
  && [[ -n "$leftovers" ]]; then
  fail "unwritten changelog entries:"
  printf '%s\n' "$leftovers" >&2
else
  pass "no TODOs in package changelogs"
fi

printf '==> Documentation links\n'
# Relative markdown links only. Anchors, absolute URLs and mailto are skipped.
# The file is read in the loop body rather than piped from a helper subshell, so
# that $f is still set where the link is resolved.
missing=0
for f in README.md docs/*.md app/README.md app/fastlane/metadata/README.md; do
  [[ -f "$f" ]] || continue
  while IFS= read -r target; do
    case "$target" in
      ''|'#'*|http://*|https://*|mailto:*) continue ;;
    esac
    # Strip the anchor, then resolve against the file's own directory.
    clean="${target%%#*}"
    [[ -z "$clean" ]] && continue
    if [[ ! -e "$(dirname "$f")/$clean" ]]; then
      printf '  broken  %s -> %s\n' "$f" "$target" >&2
      missing=$((missing + 1))
    fi
  done < <(grep -oE '\]\([^)]+\)' "$f" 2>/dev/null | sed 's/^](//; s/)$//' || true)
done
if [[ "$missing" -gt 0 ]]; then
  fail "$missing documentation link(s) point at files that do not exist"
else
  pass "all relative documentation links resolve"
fi

if [[ "$failures" -gt 0 ]]; then
  printf 'release-check: %d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'release-check: all checks passed\n'
