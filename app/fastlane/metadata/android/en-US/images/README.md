# Store screenshots

Play phone screenshots live in
`metadata/android/en-US/images/phoneScreenshots/`. They are generated, not
hand-drawn — see `scripts/capture-screenshots.sh` at the repository root.

## Regenerating

```bash
# 1. A release APK (screenshots must show the real release UI)
cd app && flutter build apk --release

# 2. Boot an emulator at 1080x1920
avdmanager create avd -n vigilant-core_api35 \
  -k 'system-images;android-35;google_apis;x86_64' -d pixel_6
emulator -avd vigilant-core_api35 -no-window -no-audio -gpu swiftshader_indirect &

# 3. Capture
scripts/capture-screenshots.sh
```

The script installs the APK, drives the UI, waits for real probe results, and
writes 24-bit PNGs at 1080x1920. It verifies size, bit depth, alpha channel, and
the 8 MB cap at the end, and prints a pass/fail line per file.

## The captured set

| File | Screen |
|---|---|
| `01-home-empty-state.png` | Monitors tab, nothing watched yet |
| `02-scan-entry.png` | Scan entry with the local-first disclosure |
| `03-report-at-a-glance.png` | Scan result header + "At a glance" summary grid |
| `04-tls-certificate-chain.png` | TLS panel: subject, issuer, presented chain, platform trust |
| `05-provider-status.png` | Per-source health (RDAP, DoH, HTTP target, CT) |
| `06-add-monitor.png` | The single add-monitor form, which infers the check type from the target |
| `07-settings.png` | Settings: local-first statement and system access |

`04` matters most: TLS chain capture is the feature most monitors do not have,
and that panel is only populated when the native `cert_chain` plugin actually
completes a handshake. If it ever reads "Chain could not be captured", the
plugin has regressed — see the platform-threading constraint in
`docs/architecture.md`.

`03`, `04` and `05` need a **populated** report, which the script reaches by
scanning `wikipedia.org` and waiting for the probes. A report captured before
the DNS answers arrive shows "Unavailable" in the DNS and email-auth panels,
which misrepresents the app: a real phone resolves those fine.

That is also why the script points the app at a DNS-over-HTTPS resolver before
scanning. The emulator's own DNS proxy answers A/AAAA only — every other record
type comes back `unsupported TYPE` — so on the device resolver the panels are
permanently empty. Set `DOH_ENDPOINT=` (empty) to skip that and accept the gap.

## Constraints these files satisfy

| Requirement | Value |
|---|---|
| Aspect ratio | 9:16 portrait |
| Resolution | 1080 x 1920 |
| Format | 24-bit PNG, **no alpha channel** |
| Max size | 8 MB per file |
| Count | 2-8 (4+ recommended for Play featuring) |

Play accepts 320-3840 px per side. Do not letterbox, add device frames, or
round the corners — Play rejects rounded or transparent screenshots. Capture
raw `screencap` output for this reason.

## Why `wikipedia.org`

The report screenshots use `wikipedia.org` because it answers every probe the
app offers — RDAP registration data, DNS-over-HTTPS, Certificate Transparency,
HTTP/HSTS, and the TLS chain — and its data is stable enough that the screenshot
does not go stale between a capture and a review. Substituting your own domain
is fine and arguably better for a listing, but pick one that resolves all
probes, or the report screenshots will show degraded panels.

The scan is **not** offline: it contacts that domain plus the public lookup
services. `scripts/capture-screenshots.sh` therefore also repairs the emulator's
default route, which is sometimes missing after a fresh boot and would
otherwise produce screenshots full of probe errors.

## iOS screenshots

None are included, and that is deliberate: **App Store screenshots must be
captured from an iOS simulator or a real iPhone**, and Apple rejects
screenshots taken from another platform or from a resized Android capture.
They have to be produced on macOS with Xcode:

```bash
# on macOS, with the project checked out
flutter build ios --simulator
xcrun simctl boot "iPhone 16 Pro"
xcrun simctl install booted build/ios/iphonesimulator/Runner.app
xcrun simctl launch  booted dev.karthikkunal.vigilant-core
# then capture each screen and place the PNGs in:
#   fastlane/screenshots/ios/en-US/
```

Required App Store sizes are 6.9" (1320 x 2868) and 6.5" (1242 x 2688) for
iPhone; one size is enough to submit. `fastlane deliver` reads screenshots from
`fastlane/screenshots/<platform>/<locale>/`, **not** from `metadata/`, so the
iOS screenshots live in a separate top-level tree.

Because iOS has no foreground pager in this release, the iOS screenshots should
show discovery, expiry reminders, and the monitor list — not alert pages.
