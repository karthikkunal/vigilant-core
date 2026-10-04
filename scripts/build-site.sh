#!/usr/bin/env bash
# Build the static site published by the `pages` job in .gitlab-ci.yml.
#
# Two jobs are done by one script, because both are needed at the same URL and
# both must stay in step with a file in the repository:
#
#   1. The marketing page (site/index.html and the assets it references).
#   2. The privacy policy, which Google Play and the App Store both fetch and
#      read before accepting a build. docs/privacy-policy.md is the single
#      source of truth; this script only renders it.
#
# The output directory is disposable and gitignored. Everything authored lives
# in site/ and docs/, so there is no second copy of the site to drift.
#
# Usage: scripts/build-site.sh [output-dir]
#   default output-dir: public/
#
# To preview the result locally:
#   scripts/build-site.sh && python3 -m http.server -d public 8080
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/public}"
SITE="$ROOT/site"
POLICY="$ROOT/docs/privacy-policy.md"
SHOTS="$ROOT/app/fastlane/metadata/android/en-US/images/phoneScreenshots"

# Where the site is served from. Kept in one place because the canonical URLs,
# the sitemap and the store metadata all have to agree, and a mismatch here is
# the kind of thing only a reviewer notices once it is live.
SITE_URL="https://vigilant-core-9a0e4f.gitlab.io"

log() { printf 'build-site: %s\n' "$*"; }
die() { printf 'build-site: error: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- preflight --

command -v python3 >/dev/null 2>&1 || die "python3 is required (no third-party packages)"

[ -d "$SITE" ] || die "missing site/ directory"
[ -f "$POLICY" ] || die "missing $POLICY"
[ -f "$ROOT/scripts/markdown_to_html.py" ] || die "missing scripts/markdown_to_html.py"

# ImageMagick is optional. Without it the screenshots are copied at full size,
# which makes the page heavier but never wrong, so a runner that cannot install
# it still produces a working site.
if command -v magick >/dev/null 2>&1; then
  IMAGEMAGICK="magick"
elif command -v convert >/dev/null 2>&1; then
  IMAGEMAGICK="convert"
else
  IMAGEMAGICK=""
  log "ImageMagick not found; copying screenshots at source resolution"
fi

# WebP is not optional, because the pages reference .webp by name and a PNG
# fallback would publish broken images. ImageMagick usually delegates WebP
# encoding to the external cwebp binary, which is packaged separately on Alpine
# (libwebp-tools) and in some slim images is simply absent. Without this check
# that surfaces as "magick: delegate failed ... 'cwebp'", which is a miserable
# thing to debug from a CI log.
if [ -n "$IMAGEMAGICK" ]; then
  # `mktemp -d` with no template is the one form BusyBox and coreutils both
  # accept; `mktemp -t foo-XXXXXX.webp` is not (BusyBox requires the template
  # to end in the X's, so any suffix is an error).
  probe_dir="$(mktemp -d)"
  probe="$probe_dir/probe.webp"
  if ! "$IMAGEMAGICK" -size 2x2 xc:none -quality 82 "$probe" 2>/dev/null; then
    rm -rf "$probe_dir"
    die "cannot encode WebP. Install a WebP encoder for ImageMagick
       (Debian/Ubuntu: libwebp; Alpine: libwebp-tools), or remove ImageMagick
       from PATH to fall back to copying the PNGs."
  fi
  rm -rf "$probe_dir"
fi

# ------------------------------------------------------------------ output --

# Rebuild from scratch every time. A stale file left over from a previous run is
# how a deleted screenshot ends up published for a year.
rm -rf "$OUT"
mkdir -p "$OUT/assets" "$OUT/images/screenshots"

# ------------------------------------------------------------ static pages --

# privacy.html is a template, not a page: it carries a placeholder that the
# rendered policy replaces. Copying it as-is would publish a stub.
for page in index.html 404.html robots.txt sitemap.xml; do
  [ -f "$SITE/$page" ] || die "missing site/$page"
  cp "$SITE/$page" "$OUT/$page"
done

cp "$SITE/assets/site.css" "$OUT/assets/site.css"
cp "$SITE/assets/site.js" "$OUT/assets/site.js"
cp "$SITE/assets/favicon.svg" "$OUT/assets/favicon.svg"

log "copied static pages and assets"

# ----------------------------------------------------------- privacy policy --

POLICY_HTML="$(python3 "$ROOT/scripts/markdown_to_html.py" "$POLICY")"
[ -n "$POLICY_HTML" ] || die "the privacy policy rendered to an empty fragment"

python3 - "$SITE/privacy.html" "$OUT/privacy-policy.html" "$POLICY_HTML" <<'PY'
import sys

template_path, output_path, body = sys.argv[1], sys.argv[2], sys.argv[3]
marker = "<!-- vigilant-core:policy -->"

with open(template_path, encoding="utf-8") as handle:
    template = handle.read()

if marker not in template:
    sys.exit(f"privacy template is missing the {marker} placeholder")

with open(output_path, "w", encoding="utf-8") as handle:
    handle.write(template.replace(marker, body))
PY

# The rendered page links to this, and it is the file to point a reviewer at.
cp "$POLICY" "$OUT/privacy-policy.md"

log "rendered privacy-policy.html from docs/privacy-policy.md"

# -------------------------------------------------------------- screenshots --

# These are the same PNGs the Play listing uses, straight out of the repository,
# so the marketing page cannot drift from the store. They are downscaled to 720px
# (2x the largest on-page width) and re-encoded as WebP, which is visually
# indistinguishable here at a quarter of the weight: seven screenshots go from
# roughly 1.2 MB to about 280 KB.
shot_count=0
for shot in "$SHOTS"/*.png; do
  [ -e "$shot" ] || continue
  name="$(basename "$shot" .png)"
  target="$OUT/images/screenshots/$name.webp"

  if [ -n "$IMAGEMAGICK" ]; then
    "$IMAGEMAGICK" "$shot" -resize 720x -strip -quality 82 \
      -define webp:method=6 "$target"
  else
    cp "$shot" "$OUT/images/screenshots/$name.png"
  fi
  shot_count=$((shot_count + 1))
done

[ "$shot_count" -gt 0 ] || die "no screenshots found in $SHOTS"
# The whole captured set is published, not just the ones index.html currently
# references, so adding a gallery entry is a one-line HTML change. An unused
# file costs ~30 KB; discovering at build time that a screenshot you just added
# to a figure was never staged costs more.
log "published $shot_count screenshots"

# ------------------------------------------------------------------- images --

# The social card and the Apple touch icon are nice to have, not load-bearing:
# a missing font must not fail a build that would otherwise publish.
if [ -n "$IMAGEMAGICK" ]; then
  FONT=""
  for candidate in \
    "$(command -v fc-match >/dev/null 2>&1 && fc-match -f '%{file}' 'sans:bold' 2>/dev/null || true)" \
    /usr/share/fonts/TTF/DejaVuSans-Bold.ttf \
    /usr/share/fonts/dejavu/DejaVuSans-Bold.ttf \
    /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
  do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then FONT="$candidate"; break; fi
  done

  if [ -n "$FONT" ]; then
    # -depth 8 and png:color-type=2 are load-bearing, not decoration: without
    # them ImageMagick writes 16-bit RGBA, which turns a 51 KB social card into
    # a 144 KB one.
    "$IMAGEMAGICK" -size 1200x630 \
      "gradient:#0B1020-#16233D" \
      \( -background none "$SITE/assets/favicon.svg" -resize 96x96 \) \
      -gravity North -geometry +0+104 -composite \
      -font "$FONT" \
      -gravity North \
      -fill "#65A9FF" -pointsize 28 -annotate +0+232 "LOCAL-FIRST MONITORING" \
      -fill "#F4F7FC" -pointsize 92 -annotate +0+280 "vigilant-core" \
      -fill "#AAB7CB" -pointsize 38 -annotate +0+412 "Know the moment something you rely on breaks." \
      -fill "#43D6A4" -pointsize 32 -annotate +0+492 "No account.   No backend.   No tracking." \
      -depth 8 -strip -define png:color-type=2 -define png:compression-level=9 \
      "$OUT/assets/og.png" || log "warning: og.png generation failed"
    log "generated assets/og.png"
  else
    log "no usable font found; skipping og.png"
  fi

  # Rasterise the SVG mark for the iOS home-screen icon. Flattened onto the
  # brand background on purpose: Apple rejects a touch icon with an alpha
  # channel, and a transparent icon also renders as a black square on a dark
  # home screen. `-background none` has to precede the input, or the SVG
  # delegate paints an opaque white backdrop behind the rounded corners.
  if "$IMAGEMAGICK" -background none "$SITE/assets/favicon.svg" -resize 180x180 \
       -background '#0B1020' -flatten -depth 8 -strip \
       -define png:color-type=2 -define png:compression-level=9 \
       "$OUT/assets/icon-180.png" 2>/dev/null; then
    log "generated assets/icon-180.png"
  else
    # No SVG delegate (common on slim runners). Leave the file out rather than
    # write a corrupt PNG; the <link> is simply ignored.
    log "no SVG delegate; skipping assets/icon-180.png"
  fi
else
  log "ImageMagick not found; skipping og.png and icon-180.png"
fi

# ------------------------------------------------------------ web preview ---
#
# The Flutter web build is published under /app/ so the site can offer a real,
# interactive preview of the app rather than only pictures of it. It is
# optional: if app/build/web is absent the site still builds, and the marketing
# page simply has no trial link. The `build-web` CI job produces it.
#
# The web target is discovery only. There is no platform resolver in a browser
# and no foreground service, so it runs on DNS-over-HTTPS and cannot keep
# checking in the background -- the same limits the privacy policy documents
# for iOS and web. Say so on the page rather than implying otherwise.
WEB_SRC="$ROOT/app/build/web"
if [ -d "$WEB_SRC" ]; then
  mkdir -p "$OUT/app"
  # Compiled output: copy verbatim. The `.symbols` files are debugger symbol
  # maps that no browser fetches, and they are a third of the tree.
  (cd "$WEB_SRC" && tar --exclude='*.symbols' -cf - .) | (cd "$OUT/app" && tar -xf -)
  web_kb="$(du -sk "$OUT/app" | cut -f1)"
  log "published the web preview under /app (${web_kb} KB)"
else
  log "no app/build/web; skipping the web preview"
fi

# ------------------------------------------------------------------ verify --

# The Pages artifact is served as-is, so a wrong path is a 404 that no test
# would otherwise catch. Check every local reference in every generated page.
# app/ is skipped: it is compiled output, not a hand-authored page, so the
# h1/alt/anchor rules below do not apply to it.
python3 "$ROOT/scripts/check-site.py" "$OUT" "$SITE_URL" --skip app/

log "done -> $OUT"
