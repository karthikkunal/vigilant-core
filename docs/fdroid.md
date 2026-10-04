# F-Droid packaging

Everything needed to submit vigilant-core to F-Droid is in this repository. The final
check is `fdroid build`, run against a fork of `fdroiddata` — an F-Droid build needs
the `fdroidserver` environment and F-Droid's own toolchain.

## Application id

`dev.karthikkunal.vigilant-core`. This is baked into the published APK and **cannot change
after the first store upload**. It lives in:

| File | Field |
|---|---|
| `app/android/app/build.gradle.kts` | `namespace`, `applicationId` |
| `app/android/app/src/main/kotlin/dev/karthikkunal/vigilant-core/MainActivity.kt` | `package` |
| `app/ios/Runner.xcodeproj/project.pbxproj` | `PRODUCT_BUNDLE_IDENTIFIER` |
| `app/linux/CMakeLists.txt` | `APPLICATION_ID` |

The `cert_chain` plugin uses a separate namespace, `dev.karthikkunal.cert_chain`, in its
`pubspec.yaml`, `android/build.gradle.kts`, and `AndroidManifest.xml`.

Verify nothing is left behind after any change:

```bash
git grep -n 'com\.example' -- app packages fdroid   # expect no hits
```

## Blockers to clear first

| # | Blocker | Status |
|---|---|---|
| 1 | Application id must not be `com.example.*` | **Done** — `dev.karthikkunal.vigilant-core` |
| 2 | Recipe `AuthorName`, `AuthorEmail`, `WebSite`, `SourceCode`, `IssueTracker`, `Repo` | **Done** — but `IssueTracker` 404s until the project has an issue, see [below](#placeholders-in-store-metadata) |
| 3 | Licence must match across recipe, pubspecs, and `LICENSE` | **Done** — `GPL-3.0-or-later` everywhere |
| 4 | Public source repo F-Droid can clone | **Done** — `gitlab.com/karthikkunal/vigilant-core` (created, `origin` configured) |
| 5 | Recipe `commit` must name the tagged 1.0.0 commit | **Done** — `462bc7d`, the commit tagged `1.0.0` |
| 6 | A `1.0.0` git tag must exist (`UpdateCheckMode: Tags`) | **Done** — pushed, and it names the commit the recipe builds |
| 7 | First push of the history to `origin` | **Done** — `main` on `gitlab.com/karthikkunal/vigilant-core` |
| 8 | At least one store screenshot | **Done** — 7 device-resolution PNGs, see below |
| 9 | `NonFreeNet` anti-feature risk | **Done** — not applicable, see below |
| 10 | `REPLACE` placeholders in `fastlane/metadata/` and `cert_chain.podspec` | **Done** — see below |
| 11 | Privacy policy hosted at a public URL | **Done, pending one GitLab setting** — see below |

### Screenshots

F-Droid renders the app page from `fastlane` metadata and will hold a submission with no
screenshot. Captured device-resolution PNGs (1080x1920, inside F-Droid's 320-3840 px
bounds) are committed at:

```
app/fastlane/metadata/android/en-US/images/phoneScreenshots/
```

| File | Shows |
|---|---|
| `01-home-empty-state.png` | Empty dashboard |
| `02-scan-entry.png` | Domain entry |
| `03-report-at-a-glance.png` | Discovery report |
| `04-tls-certificate-chain.png` | TLS leaf + full chain |
| `05-provider-status.png` | Per-provider scan status |
| `06-monitors-list.png` | Monitor list |
| `07-settings.png` | Settings |

Regenerate after a UI change with `scripts/capture-screenshots.sh`.

### Placeholders in store metadata

All `REPLACE` markers are filled. `app/fastlane/metadata/README.md` records each
value and the state behind it; the contact details come from the same place as the
recipe's `AuthorEmail`.

| File | Value |
|---|---|
| `app/fastlane/metadata/copyright.txt` | `2026 Ranjith Raj` |
| `app/fastlane/metadata/ios/en-US/privacy_url.txt` | `https://vigilant-core-9a0e4f.gitlab.io/privacy-policy.html` |
| `app/fastlane/metadata/ios/en-US/support_url.txt` | `https://gitlab.com/karthikkunal/vigilant-core` |
| `app/fastlane/metadata/ios/en-US/marketing_url.txt` | `https://gitlab.com/karthikkunal/vigilant-core` |
| `packages/cert_chain/ios/cert_chain.podspec` (`homepage`, `author`) | the project URL and `karthikkunal@riseup.net` |

Find any new leftovers with:

```bash
grep -rn REPLACE app/fastlane/metadata/ packages/cert_chain/ios/ --exclude=README.md
```

`--exclude=README.md` is needed because `app/fastlane/metadata/README.md`
documents this very check and would otherwise always match.

`support_url.txt` points at the project homepage rather than the issue tracker
because `https://gitlab.com/karthikkunal/vigilant-core/-/issues` currently returns
**404**: GitLab serves a 404 for an empty issue list to a visitor who is not
signed in, and the project has no issues yet. `…/-/issues.atom` returns 200 with
zero entries, so Issues is enabled and public — the first issue makes the HTML
page resolve, after which `support_url.txt` should point back at the tracker.
The recipe's `IssueTracker` field already names the tracker, which F-Droid
reviewers will follow, so open an issue before submitting.

### Privacy policy

`docs/privacy-policy.md` is the source of truth, with its contact placeholders
filled. It is published by `scripts/build-site.sh` as the `pages` job in
`.gitlab-ci.yml`, which renders it to a static page at:

```
https://vigilant-core-9a0e4f.gitlab.io/privacy-policy.html
```

**Resolved.** GitLab Pages is enabled and the policy resolves publicly at the
URL above, verified with an unauthenticated `curl` (HTTP 200). The `pages` job
in `.gitlab-ci.yml` rebuilds it on every push to `main`.

Two things about that URL are easy to get wrong:

- The project has a **unique Pages domain**, so the site is served at the root
  of `vigilant-core-9a0e4f.gitlab.io`, not under a `/vigilant-core/` path. The older
  `karthikkunal.gitlab.io/vigilant-core/privacy-policy.html` 308-redirects there and
  still resolves, but the store metadata should carry the final URL.
- The project's Pages access level is **`enabled`** (everyone with access), not
  `public`. gitlab.com rejects `public` here with "Pages access level is not
  allowed for the project visibility level". On a public project `enabled` is
  what makes the site reachable without signing in; `private` returns a
  redirect to `projects.gitlab.io/auth` and both stores would reject the build.

The policy is rendered to real HTML by `scripts/markdown_to_html.py`, which is
stdlib-only because the Pages runner ships no Markdown converter. The same
content is also published verbatim as `privacy-policy.md` beside it.

### NonFreeNet

**Not applicable. Resolved — no anti-feature should be applied.**

vigilant-core uses third-party lookup services: `data.iana.org` (RDAP bootstrap),
per-registry RDAP endpoints, `crt.sh` (with Cert Spotter as fallback), and — only
where no platform resolver exists, or when the user names one — a
DNS-over-HTTPS resolver. `crt.sh` and the RDAP bootstrap are free software
services; a public DoH resolver is a free service but not free software, so the
question is whether `NonFreeNet` applies.

F-Droid defines it as *"promotes or depends **entirely on** a non-libre network
service"*, and it is a disclosure label rather than a bar to inclusion — hundreds
of apps in the main repository carry it. Three facts settle it here:

1. **The F-Droid build is Android-only.** The recipe builds an APK, so the iOS
   and web code paths are not compiled into it at all. The remaining DoH paths
   live in code this artifact does not contain.
2. **Android does not reach a third party by default.** Since `a3e2c0b`, the
   tagged 1.0.0 commit, `resolveDns` returns `SystemDnsClient` — the device's own
   `android.net.DnsResolver` — for the default `ResolverMode.device`, and reports
   `usesThirdParty: false`. Raising `minSdk` to 29, where `DnsResolver` was
   introduced, is what makes this possible.
3. **The DoH endpoint is user-namable, not inherited.** `ResolverMode.custom`
   takes any `https://` endpoint, the device mode is the default, and a plaintext
   URL is rejected on decode. The choice is surfaced in settings *and* in the
   scan's provider status, so a scan never implies it stayed local when it did
   not. This was the fix this section used to call "if F-Droid still flags it" —
   it is already shipped.

So vigilant-core does not depend entirely on a non-libre network service, and does
not promote one. Expect F-Droid to accept the app unflagged.

**If a maintainer still flags it:** the answer is the user-configurable resolver
described above, not a rewrite. It already exists, so the response is to point at
`app/lib/discovery/resolver_preference.dart` and the DNS settings section of
`app/lib/settings/settings_screen.dart`.

## What is already in place

| Item | Location |
|---|---|
| Store description | `app/fastlane/metadata/android/en-US/` |
| Changelog (versionCode 1) | `app/fastlane/metadata/android/en-US/changelogs/1.txt` |
| Build recipe | `fdroid/dev.karthikkunal.vigilant-core.yml` |
| Licence | `LICENSE` (GPL-3.0 text; package metadata declares GPL-3.0-or-later) |
| Lockfile | `app/pubspec.lock`, committed for `--enforce-lockfile` |

`fastlane/` must sit under the Flutter project root because the recipe sets
`subdir: app`.

## The recipe

`fdroid/dev.karthikkunal.vigilant-core.yml` follows F-Droid's `templates/build-flutter.yml`
using the **srclib** method (Flutter pulled by F-Droid) rather than a git submodule.

Key fields:

- `subdir: app` — the Flutter project is not at the repository root; the local
  `packages/discovery_core` and `packages/cert_chain` path dependencies resolve from
  the repository root, which F-Droid checks out in full.
- `srclibs: - flutter@3.47.5` — must match the Flutter used to generate
  `pubspec.lock`, or `pub get --enforce-lockfile` fails.
- `output: build/app/outputs/flutter-apk/app-release.apk` — named without
  `-unsigned` even though the artifact is unsigned. A clean F-Droid checkout has no
  `key.properties`, so `build.gradle.kts` leaves `signingConfig` null and Gradle emits
  `app-release-unsigned.apk`; the Flutter tool then copies it to `app-release.apk`
  regardless. Verified on a clean worktree: the APK has no `META-INF` signature
  entries, so F-Droid can sign it and the unsigned payload stays reproducible.
- `VercodeOperation: ['%c + 1']` — the version code is the `+N` in `pubspec.yaml` and
  increments by one per release. The upstream template's `%c * 10 + 1` would skip
  codes under this scheme.
- `scanignore` / `scandelete` — Flutter's downloaded Dart tools and the pub cache
  contain binaries that are not part of the app.
- `UpdateCheckData` reads `version:` from `pubspec.yaml` (relative to `subdir`).
- `scanignore` / `scandelete` — see the scanner section below. The short version:
  these paths are relative to the **build directory root**, so they carry the
  `subdir` prefix, and `$$flutter$$` is **not** substituted in them.

### The source scanner and `$$flutter$$`

fdroidserver scans the source tree for binaries and non-free code *before* it
builds, and a `scanignore` or `scandelete` entry that matches nothing is a
**hard error**, not a warning:

```
ERROR: Could not build app <appid>: Some glob paths did not match any files/dirs:
$$flutter$$/bin/cache
```

`$$srclib$$` substitution happens only in `prebuild` and `build`. The scanner
reads these fields through `common.getpaths_map()`, which is a bare
`glob.glob()` over the build directory — no substitution, so a `$$flutter$$`
entry can never match. `getpaths_map()` raises on the first field that fails, so
a bad `scanignore` masks a bad `scandelete`.

The correct entry for a `subdir: app` Flutter build is just the pub cache:

```yaml
    scandelete:
      - app/.pub-cache
```

Nothing is needed for the Flutter srclib itself: with `srclibs`, the SDK is
checked out to `build/srclib/flutter`, **outside** the app's source tree, so the
Dart tools it downloads are never scanned. The upstream template's
`scanignore: .flutter/bin/cache` belongs to the *submodule* method, where
Flutter lives inside the source tree — the two methods are mutually exclusive and
the template says so.

`prebuild` and `build` both run with the working directory set to
`<build dir>/<subdir>`, which is why `output: build/app/outputs/...` is correct
despite `subdir: app`: it is relative to the Flutter project root, not to the
build directory.

If the build log asks for an NDK version, add e.g. `ndk: r27c` under the build.

## Signing

There are three signing situations:

| Situation | Who signs |
|---|---|
| Build from source for F-Droid | **F-Droid** signs with its own key. Do not provide a keystore. |
| A release APK you distribute yourself (GitHub, Play) | **You**, with your own release keystore |
| A local `flutter run --release` / debug build | Flutter falls back to the debug key |

For your own release builds:

```bash
scripts/gen-keystore.sh          # creates app/android/vigilant-core-release.jks + key.properties
flutter build apk --release
```

`app/android/build.gradle.kts` reads `key.properties` when it exists and otherwise
builds without a release signing config. `key.properties` and the keystore are
gitignored (`key.properties`, `*.jks`); see `app/android/key.properties.example` for
the shape.

Verify what a build was signed with:

```bash
$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk
```

**Keep the keystore offline and backed up.** Losing it means you can no longer
update an app already published under it. Never reuse F-Droid's key, and never
commit either file.

Signing does not affect the reproducible payload: the signature block is appended
after the archive and is compared separately — see
[`reproducible-builds.md`](reproducible-builds.md).

## Anti-features

- **No ads, no tracking, no Google Play Services.**
- **No `NonFreeNet`** — the Android build resolves DNS through the device and
  offers a user-named DoH endpoint, so it neither depends entirely on nor
  promotes a non-libre network service. Rationale and code references in the
  [`NonFreeNet`](#nonfreenet) section above.

## Submitting

1. Fork `https://gitlab.com/fdroid/fdroiddata`.
2. Copy `fdroid/dev.karthikkunal.vigilant-core.yml` to
   `metadata/dev.karthikkunal.vigilant-core.yml`.
3. Add a changelog entry per `versionCode` (`fastlane` is read from the app repo, so
   this is only needed for versions the recipe pins).
4. Open a merge request. If you would rather not maintain the recipe, file a
   **Request For Packaging** issue instead and a maintainer will write it.

## Validating

```bash
git clone https://gitlab.com/fdroid/fdroiddata
cd fdroiddata
# add metadata/dev.karthikkunal.vigilant-core.yml, then:
fdroid build --verbose --latest dev.karthikkunal.vigilant-core
```

### Verified locally

Built successfully with `fdroidserver` 2.4.5 against commit `462bc7d`
(27 September 2026):

```
INFO: Successfully built version 1.0.0 of dev.karthikkunal.vigilant-core
      from 462bc7d83402de0281c76ff2fb049c2aef101389
DEBUG: Checking build/dev.karthikkunal.vigilant-core/app/build/app/outputs/flutter-apk/app-release.apk
INFO: 1 build succeeded
```

| Check | Result |
|---|---|
| Artifact | `app-release.apk`, 59,729,757 bytes |
| Signature | **unsigned** — zero `META-INF/*.RSA\|SF\|MF` entries, so F-Droid can sign it itself |
| Package | `dev.karthikkunal.vigilant-core`, `versionName 1.0.0`, `versionCode 1` |
| ABIs | `arm64-v8a`, `armeabi-v7a`, `x86_64` (a single fat APK) |
| Entry timestamps | all `1981-01-01` (the ZIP epoch), i.e. normalised, as reproducibility requires |

Three things this run confirmed in the recipe rather than in prose:

- `output:` is resolved against `<build dir>/<subdir>`, so
  `build/app/outputs/flutter-apk/app-release.apk` is correct despite `subdir: app`.
- `prebuild` and `build` both run with the working directory set to
  `<build dir>/<subdir>`, so neither needs a `cd`.
- The source scanner accepts `scandelete: [app/.pub-cache]`. The previous
  `scanignore: [$$flutter$$/bin/cache]` was a hard error — see below.

One cosmetic issue the artifact exposed, unrelated to packaging: the manifest
sets `android:label="vigilant-core"` as a lowercase literal with no
`res/values/strings.xml`, so the launcher shows `vigilant-core` while the F-Droid
listing says `vigilant-core` (from `AutoName`). Worth aligning before release.

### Local setup that is easy to get wrong

Verified against `fdroidserver` 2.4.5.

| Gotcha | What happens | Do this |
|---|---|---|
| `fdroid init` writes into the **current directory** | `config.yml`, `keystore.p12` and `repo/` land in your project root and show up as untracked files | Run it from a scratch directory, then point the config at real paths |
| Running `fdroid` **inside** the `fdroiddata` checkout | `fdroiddata/config.yml` shadows your user config, and it is a CI template with `keystore: {env: keystore}` — so it resolves to `None` and `fdroid update` dies with `TypeError: ... path should be string ... not NoneType` | Either run from **outside** the checkout, or replace `fdroiddata/config.yml` with a minimal local one |
| `fdroid update -c` and `fdroid build` read `./metadata/` | They call `metadata.read_metadata()`, which globs `metadata/*.yml` **relative to the current directory**. There is no config key for this | Run both commands from the checkout that contains `metadata/` and `srclibs/` |
| Config `repo:` entries are ignored | Nothing in fdroidserver reads a `repo:` key from `config.yml` | Don't bother; the metadata directory is what matters |
| The `repo:` block is **YAML, not ConfigParser** | `[[repo]]` followed by `name:` is a YAML scanner error | If you do write one: `repo:` then a `- name:` / `    url:` list |
| A `web:` key on the repo | fdroidserver treats it as a web-served repo and demands `serverwebroot` | Omit `web` and `apkurl` for local metadata-only use |
| Repo `url` as a bare local path | Not relevant — fdroidserver reads `./metadata/`, not a configured repo | — |
| The recipe is not **committed** in your fork | Only matters for CI, where fdroiddata is cloned fresh. Locally the working tree is read directly, so an untracked `.yml` is fine | Check `index-v2.json` for the appid before building |
| `apksigner not found` | fdroidserver cannot sign or verify APKs | Put `$ANDROID_HOME/build-tools/<v>` on `PATH`, and confirm `sdk_path` is set |
| Default scratch space | `tmp_dir` defaults to `/tmp/build`; a Flutter + Gradle + SDK build outgrows a small `/tmp` (a tmpfs) | Set `tmp_dir` to a roomy path — the fixed-path property reproducibility needs is preserved |
| `config.yml` permissions | `unsafe permissions on 'config.yml'` | `chmod 600 config.yml` |
| An absolute `repo_icon` | fdroidserver joins it as `repo/icons/<value>`, so an absolute path becomes `repo/icons//home/...` and index generation dies with `FileNotFoundError` | `repo_icon:` takes a **bare filename**; put the image in `repo/icons/` |
| An unrelated upstream `.yml` is malformed | One bad app in `fdroiddata` can abort the whole scan (for example a `CRITICAL` regex failure on someone else's Bitcoin address) | `fdroid update -c -W ignore` |

### A note on srclib versions

`srclibs: - flutter@3.47.5` does **not** refer to a list in `fdroiddata`.
`srclibs/flutter.yml` is only two lines:

```yaml
RepoType: git
Repo: https://github.com/flutter/flutter.git
```

`getsrclib()` resolves the version as a **git ref** in that repository
(`vcs.gotorevision(ref)`), so `flutter@3.47.5` means "check out the `3.47.5`
tag of flutter/flutter" — and `flutter@stable` means the `stable` branch.
Confirmed present upstream:

```
$ git ls-remote --tags https://github.com/flutter/flutter.git | grep 3.47.5
6a19cca56475dbfba1478ee68d7bd0c2ef891da1  refs/tags/3.47.5
```

A wrong version therefore fails at srclib checkout, not at recipe parse, and
still must match the SDK that generated `pubspec.lock` or
`pub get --enforce-lockfile` fails.

A JDK mismatch is also worth ruling out early: `fdroidserver` 2.4.5 runs on the
Java 17 that `scripts/repro-build.sh` already pins, so export the same
`JAVA_HOME` for both.

The first build downloads the Flutter SDK and is slow. Common failures and fixes:

| Symptom | Cause |
|---|---|
| `pub get --enforce-lockfile` fails | Flutter srclib version differs from the lockfile — align `srclibs` |
| `output` not found | `subdir`/`output` mismatch |
| Scanner finds binaries | add the offending path to `scanignore`/`scandelete` |
| Requests an NDK version | add `ndk:` to the build |

## A note on reproducibility

Flutter's Dart AOT snapshot embeds the **absolute build path**, so reproducible here
means a **fixed build path** — which is what F-Droid does (it builds twice in the
same container path). Beyond that, pin the Flutter version so the prebuilt engine
matches. See [`reproducible-builds.md`](reproducible-builds.md) and
`scripts/repro-build.sh`.

F-Droid publishes a build even without byte-for-byte reproducibility; only the
reproducible badge requires matching builds. If you also publish your own APK and
want it to match F-Droid's, use the `/upstream/path` technique from
`templates/build-flutter.yml`.
