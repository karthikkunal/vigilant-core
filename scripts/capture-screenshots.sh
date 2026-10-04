#!/usr/bin/env bash
# Capture Google Play phone screenshots from a booted Android emulator.
#
# Produces 24-bit PNGs at 1080x1920 (9:16, no alpha) directly into
# app/fastlane/metadata/android/en-US/images/phoneScreenshots/.
#
# Google Play requirements this script satisfies:
#   - 9:16 portrait, 1080x1920 (the recommended phone size)
#   - 24-bit PNG, no alpha channel
#   - 2-8 screenshots per device type (4+ recommended for featuring)
#   - max 8 MB per file
#
# The tap coordinates below are absolute pixels on a 1080x1920 screen and are
# tied to the current UI. If a screen moves, re-derive them by driving the app
# by hand and reading coordinates off a screencap; do not guess, because a
# missed tap silently produces a screenshot of the wrong screen.
#
# Usage:
#   scripts/capture-screenshots.sh <apk> [out-dir]
#
# Requires ANDROID_HOME (or ~/Android/Sdk) and an emulator on adb, or a device
# attached. Set ANDROID_SERIAL to target a specific device.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="${1:-$ROOT_DIR/app/build/app/outputs/flutter-apk/app-release.apk}"
OUT_DIR="${2:-$ROOT_DIR/app/fastlane/metadata/android/en-US/images/phoneScreenshots}"
PKG="dev.ranjithraj.vigilant-core"

: "${ANDROID_HOME:=$HOME/Android/Sdk}"
ADB="$ANDROID_HOME/platform-tools/adb"
EMU="$ANDROID_HOME/emulator/emulator"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

SERIAL="${ANDROID_SERIAL:-emulator-5554}"
A() { "$ADB" -s "$SERIAL" "$@"; }

fail() { printf 'capture-screenshots: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

command -v "$ADB" >/dev/null || fail "adb not found under $ANDROID_HOME/platform-tools"
[ -f "$APK" ] || fail "APK not found: $APK (build one with: flutter build apk --release)"

mkdir -p "$OUT_DIR"

if ! A get-state >/dev/null 2>&1; then
  fail "no device on $SERIAL. Create and boot an AVD first:
  avdmanager create avd -n vigilant-core_api35 \\
    -k 'system-images;android-35;google_apis;x86_64' -d pixel_6
  emulator -avd vigilant-core_api35 -no-window -no-audio -gpu swiftshader_indirect &"
fi

note 'waiting for boot'
until [ "$(A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  printf '.'; sleep 5
done
printf ' ready\n'

# --- emulator prerequisites -------------------------------------------------
#
# Two things bite here, and both produce screenshots full of errors rather than
# a failure, so they are worth being explicit about.
#
# 1. A cold-booted emulator often comes up with no default route. `adb shell`
#    runs as the shell user and cannot add one, so escalate first. Without a
#    route the HTTP and RDAP probes fail.
#
# 2. netd's DNS proxy on the emulator answers A/AAAA only: every other record
#    type comes back "unsupported TYPE" and DnsResolver reports ETIMEDOUT. The
#    result is a report whose DNS and email-auth panels read "Unavailable",
#    which is both a bad screenshot and not what the app does on a real phone.
#    The fix is to point the app at a DNS-over-HTTPS endpoint, which is a
#    supported setting (Settings -> DNS resolver -> Custom DNS-over-HTTPS).
#    Set DOH_ENDPOINT below to override; the default is Cloudflare's public
#    resolver. Set it empty to leave the device resolver in place and accept
#    empty DNS panels.

A root >/dev/null 2>&1 || true
A wait-for-device >/dev/null 2>&1 || true
if ! A shell ip route | grep -q '^default'; then
  note 'adding default route (emulator NAT gateway)'
  A shell ip route add default via 10.0.2.2 dev eth0 >/dev/null 2>&1 ||
    A shell ip route add default via 10.0.2.2 dev wlan0 >/dev/null 2>&1 ||
    fail 'could not add a default route; discovery probes will fail'
fi

note 'forcing 1080x1920 (Play 9:16)'
A shell wm size 1080x1920
sleep 3

note "installing $APK"
# A previously installed build may be signed with a different key (a debug build,
# or a release keystore that has since been created), and adb refuses to upgrade
# across a signature change. Uninstall rather than failing the run.
if ! A install -r -g "$APK" >/dev/null 2>&1; then
  printf '    existing install is not upgradeable (different key) -- uninstalling\n'
  A uninstall "$PKG" >/dev/null 2>&1 || true
  A install -r -g "$APK" >/dev/null
fi
A shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
A shell am force-stop "$PKG"
A shell am start -n "$PKG/.MainActivity" >/dev/null
sleep 12

# The first launch raises a runtime-permission dialog that takes focus away from
# the app, and any tap meant for vigilant-core then lands on the system UI. Grant
# first, then dismiss anything already showing.
A shell input keyevent 4 >/dev/null 2>&1 || true
sleep 1
A shell am start -n "$PKG/.MainActivity" >/dev/null
sleep 8

shot() { # shot <index> <slug>
  local idx="$1" slug="$2" dest raw
  dest="$(printf '%s/%02d-%s.png' "$OUT_DIR" "$idx" "$slug")"
  raw="$(mktemp)"
  # `screencap -p` can return a buffered frame on a busy emulator, so settle
  # before capturing. A stale frame here is the difference between the right
  # screenshot and a plausible-looking wrong one.
  sleep 3
  A exec-out screencap -p > "$raw"
  flatten_png "$raw" "$dest"
  rm -f "$raw"
  printf '    %s\n' "$(basename "$dest")"
}

# `screencap -p` always writes RGBA, and Google Play rejects screenshots that
# carry an alpha channel (it treats transparency as a malformed asset). Compose
# the capture onto an opaque white background and re-encode as plain RGB.
flatten_png() { # flatten_png <src> <dest>
  python3 - "$1" "$2" <<'PY'
import sys
from PIL import Image
src, dest = sys.argv[1], sys.argv[2]
with Image.open(src) as im:
    im.load()
    if im.mode in ('RGBA', 'LA') or (im.mode == 'P' and 'transparency' in im.info):
        im = im.convert('RGBA')
        flat = Image.new('RGB', im.size, (255, 255, 255))
        flat.paste(im, mask=im.split()[3])
        im = flat
    elif im.mode != 'RGB':
        im = im.convert('RGB')
    im.save(dest, format='PNG', optimize=True)
PY
}

tap()   { A shell input tap "$1" "$2"; sleep "${3:-4}"; }
type_text() { A shell input text "$1"; sleep 1; }
back()  { A shell input keyevent 4; sleep 2; }
swipe_up()   { A shell input swipe 540 1500 540 620 300; sleep 3; }
swipe_down() { A shell input swipe 540 500 540 1500 250; sleep 2; }
clear_field() { for _ in $(seq 1 30); do A shell input keyevent 67; done; }

TAB_MONITORS=180; TAB_SCAN=540; TAB_SETTINGS=900; NAV_Y=1750

# --- 01 empty state ---------------------------------------------------------
note '01 empty state'
shot 01 home-empty-state

# --- 02 scan entry ----------------------------------------------------------
note '02 scan entry'
tap "$TAB_SCAN" "$NAV_Y" 5
shot 02 scan-entry

# --- resolver ---------------------------------------------------------------
# Set before the scan so the report below is fully populated. See the note at
# the top of this script for why.
if [ -n "${DOH_ENDPOINT:-https://cloudflare-dns.com/dns-query}" ]; then
  note "pointing the app at a DNS-over-HTTPS resolver (${DOH_ENDPOINT})"
  tap "$TAB_SETTINGS" "$NAV_Y" 5
  tap 152 1522 3                       # Custom DNS-over-HTTPS
  tap 500 1406 3                       # the endpoint field
  clear_field
  type_text "$DOH_ENDPOINT"
  back
  tap 918 920 6                        # the check button in the field
  tap "$TAB_SCAN" "$NAV_Y" 4
fi

# --- 03 discovery report ----------------------------------------------------
# wikipedia.org is used because it answers every probe the app offers (RDAP,
# DNS, CT, HTTP/HSTS, TLS chain) and its data is stable, so the screenshot does
# not go stale. Swap in your own domain if you prefer.
note '03 discovery report (wikipedia.org)'
tap 540 687 2                          # domain field
clear_field
type_text "wikipedia.org"
back
tap 540 1134 5                         # Run scan
printf '    waiting for probes'
for _ in $(seq 1 24); do printf '.'; sleep 5; done
printf '\n'

# The report is taller than the screen once a chain has been captured, so the
# scroll offsets below are tuned to the populated report.
swipe_up; swipe_up
shot 03 report-at-a-glance

# --- 04 TLS chain -----------------------------------------------------------
# The differentiator: subject, issuer, expiry, the intermediates the server
# actually presents, and the platform trust verdict. If this ever reads "Chain
# could not be captured" the cert_chain plugin has regressed -- see the
# platform-threading constraint in docs/architecture.md.
note '04 TLS certificate chain'
tap 955 866 3                          # collapse Registration
shot 04 tls-certificate-chain

# --- 05 provider status -----------------------------------------------------
note '05 provider status'
for _ in $(seq 1 6); do swipe_down; done
for _ in $(seq 1 6); do A shell input swipe 540 1500 540 500 250; sleep 2; done
shot 05 provider-status

# --- 06 add monitor ---------------------------------------------------------
# One form for every kind of monitor: vigilant-core infers whether the target is a
# website, a URL or a bare TCP port from what you type.
note '06 add monitor form'
tap "$TAB_MONITORS" "$NAV_Y" 5
tap 540 993 6                          # Add monitor
shot 06 add-monitor

# --- 07 settings ------------------------------------------------------------
# The Site list card is the reason this shot is worth taking: it is how a set of
# watched sites moves to another device.
note '07 settings'
tap "$TAB_SETTINGS" "$NAV_Y" 5
swipe_up; swipe_up
shot 07 settings

printf '\n==> done. Verify before uploading:\n'
python3 - "$OUT_DIR" <<'PY'
import glob, struct, sys, os
failed = False
for p in sorted(glob.glob(os.path.join(sys.argv[1], '*.png'))):
    d = open(p, 'rb').read()
    w, h = struct.unpack('>II', d[16:24])
    depth, ctype = d[24], d[25]
    name = os.path.basename(p)
    problems = []
    if (w, h) != (1080, 1920):
        problems.append(f'size {w}x{h} != 1080x1920')
    if ctype == 6:
        problems.append('has alpha channel (Play rejects)')
    if depth != 8:
        problems.append(f'bit depth {depth} != 8')
    if len(d) > 8 * 1024 * 1024:
        problems.append(f'{len(d)//1024//1024} MB > 8 MB')
    failed = failed or bool(problems)
    print(f'  {"FAIL" if problems else "ok  "} {name:28} {w}x{h} {len(d)//1024} KB'
          + (f'  <- {"; ".join(problems)}' if problems else ''))
sys.exit(1 if failed else 0)
PY
