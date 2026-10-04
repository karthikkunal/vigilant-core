# vigilant-core

Local-first monitoring for websites and domains you own or depend on. vigilant-core helps individuals, operators, and organisations keep an eye on the sites and services that matter—from personal projects and homelabs to services maintained for work.

Enter a domain or subdomain and vigilant-core discovers its registration, TLS certificate (leaf + full chain), DNS and email-auth records, Certificate Transparency entries, HTTP/security headers, explicit TCP ports, and local body assertions—then alerts you when something breaks. Monitor details make the last check, provider, and stale state explicit. Every scan is also compared with the last one on this device, so a withdrawn DMARC record, a moved expiry, a new certificate issuer or a dropped mail exchanger shows up as a change instead of having to be noticed by eye. The site list can be copied to the clipboard and pasted back in, carrying addresses only, so a set of sites can be moved to another device or shared as plain text.

**No vigilant-core account or backend. Checks run on your device.** A scan is not offline: the domain or host you choose is sent to the public lookup services used for discovery (such as RDAP and Certificate Transparency). On Android, DNS is resolved by the device's own resolver rather than a public DNS-over-HTTPS service; iOS and the web build use one. Monitors then contact the selected site or service directly. vigilant-core itself does not store your monitor data on a server.

## Who it's for

vigilant-core is designed for people who maintain a personal website, side project, or homelab service, and for organisations that need a lightweight way for an operator to watch a small set of websites and services they own or depend on. Each device runs its own checks and keeps its own monitor data; this release does not provide a shared team dashboard or remote push.

## Status

Version 1.0.0. The F-Droid recipe builds, and the release APK it produces is
unsigned, ready for F-Droid to sign. See [`docs/architecture.md`](docs/architecture.md)
for the locked design and [`docs/fdroid.md`](docs/fdroid.md) for packaging.

## Layout

| Path | What |
|---|---|
| `app/` | Flutter app (Android + iOS). UI, Android pager, thin platform bridges. |
| `packages/discovery_core/` | Pure-Dart discovery engine (RDAP, DNS, CT, models, parsers, diffing). No Flutter. |
| `packages/cert_chain/` | Flutter plugin: native TLS chain capture (Kotlin + Swift). |
| `packages/system_dns/` | Flutter plugin: resolves DNS through the Android platform resolver. |
| `site/` | The marketing site, and the template the privacy page is rendered into. |
| `fdroid/` | F-Droid build recipe. |
| `scripts/` | Build and verification helpers. |
| `docs/` | Architecture, test plan, packaging and reproducibility notes. |

## Docs

- [`docs/architecture.md`](docs/architecture.md) — how the pieces fit together
- [`docs/tows.md`](docs/tows.md) — strategic TOWS matrix for the 1.0.0 release
- [`docs/manual-test-plan.md`](docs/manual-test-plan.md) — device verification
- [`docs/fdroid.md`](docs/fdroid.md) — F-Droid submission
- [`docs/reproducible-builds.md`](docs/reproducible-builds.md) — reproducible builds

## Website

The project's site is the marketing page, a live web build of the app, and
the published privacy policy, at <https://karthikkunal.github.io/vigilant-core/app/>. Two
CI jobs build it from `main`: `web` produces the Flutter web bundle, and
`pages` assembles the site around it.

```bash
scripts/build-site.sh                        # writes public/
scripts/check.sh site                        # build it and verify it
python3 -m http.server -d public 8080        # preview at localhost:8080
```

`site/` holds the authored pages; `public/` is generated and gitignored, so
there is only ever one copy of the site to edit. Two things are worth knowing
before changing it:

- **Edit `docs/privacy-policy.md`, not the published policy.** The rendered page
  at `privacy-policy.html` is produced from that file, and it is the URL in both
  store listings. `site/privacy.html` is only a template with a placeholder.
- **The gallery reuses the Play screenshots** in
  `app/fastlane/metadata/android/en-US/images/phoneScreenshots/`, so the site
  cannot drift from the store listing. They are downscaled and re-encoded as
  WebP at build time; the originals are never modified.
- **The app preview at `/app/` is the compiled web bundle**, copied in
  verbatim. `check-site.py` skips that subtree: it is generated output, so the
  one-`<h1>` and `alt` rules for hand-written pages do not apply to it.

### The web build is discovery only

A browser has no platform DNS resolver and no foreground service, so the web
build resolves over DNS-over-HTTPS and stops checking when the tab closes.
Monitors, background checks and pages are Android and iOS. The site says so
next to the preview link rather than letting anyone find out by waiting for an
alert that cannot come.

The build needs `python3` to render the policy, and ImageMagick with a WebP
encoder to process the images. On Debian/Ubuntu that is `imagemagick` plus
`libwebp`; on Alpine, which is what the `pages` job uses, it is `imagemagick`
plus `libwebp-tools` and `librsvg`. There is no Node toolchain and no package
install. If ImageMagick is missing entirely the site still builds, with the
screenshots copied at source size and no social card.

The site is served at the root of its Pages host, so paths are `/assets/…` and
not `/vigilant-core/assets/…`. The older `karthikkunal.gitlab.io/vigilant-core/` form
308-redirects to it and still works, but it is not what the canonical URLs, the
sitemap, or the store metadata point at.

## Local checks

Install the versioned Git hooks for this checkout:

```bash
scripts/install-git-hooks.sh
```

The local hooks run the same checks used by the project:

- `pre-commit` checks formatting for staged Dart files and runs the app, package, and
  plugin analyzers (linting and static type checking).
- `pre-push` checks staged formatting, runs analysis and all Dart/Flutter tests, then
  builds a debug Android APK, verifies the website, and runs the release-readiness check.
- `scripts/check.sh full` runs the complete check, including a formatting check over all
  Dart sources.

`scripts/check.sh release` is the guard against the things that rot silently between
releases: unfilled store-metadata placeholders, a stale application id, a recipe that
no longer pins the tagged commit, an unreachable privacy policy URL, unwritten
changelog entries, and documentation links pointing at files that have moved. It needs
no toolchain, so it is cheap enough to run on every push. Run it on its own with
`scripts/check-release.sh`.

The fast hook checks only staged Dart files, so existing repository-wide formatting
issues do not block unrelated commits; use `full` for a whole-tree check. Tests and
the APK build run on `pre-push` to keep commit latency low.

`git commit --no-verify` and `git push --no-verify` remain available when an intentional
one-off bypass is needed.

## Reproducible builds

```bash
scripts/repro-build.sh
```

Builds the release APK twice from clean checkouts at the same path and compares
hashes. See [`docs/reproducible-builds.md`](docs/reproducible-builds.md).

## Signing a release

```bash
scripts/gen-keystore.sh            # creates app/android/vigilant-core-release.jks + key.properties
flutter build apk --release
```

Both files are gitignored; back them up offline. F-Droid signs its own builds, so a
keystore is only needed for APKs you distribute yourself. See
[`docs/fdroid.md`](docs/fdroid.md#signing).

## Targets

- **Android** (main): real-time paging — foreground service, per-monitor notification
  channels (sound × vibration × severity), escalation until acknowledged, and a
  switch in Settings to turn background monitoring off entirely (a stopped
  service survives a reboot, and the dashboard says so rather than blaming
  Android). DNS is resolved by the device's own resolver
  (`android.net.DnsResolver`), so a scan does not disclose the domain to a
  public DNS-over-HTTPS service. Requires Android 10 (API 29) or newer.
- **iOS**: expiry reminders (scheduled local notifications) + on-open discovery. No
  real-time paging in v1.
- **Both**: expiry reminders scheduled at discovery time (rolling window).

## Licence

vigilant-core is free software licensed under the GNU General Public License, version 3 or (at your option) any later version. See [`LICENSE`](LICENSE) for the full text.
