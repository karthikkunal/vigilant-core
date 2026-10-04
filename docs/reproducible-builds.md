# Reproducible builds

Two independent builds of the same source should produce the same bytes. For a
Flutter app that is harder than for plain Android, so this document is explicit
about what is guaranteed and what is not.

## Why this is hard for a Flutter app

- **The Dart AOT snapshot embeds the project path.** `libapp.so` contains the
  absolute build directory (`strings libapp.so | grep dart_plugin_registrant`
  shows it). The same source built at two different paths produces different
  bytes. See [dart-lang/sdk#55282](https://github.com/dart-lang/sdk/issues/55282).
  **Consequence: reproducibility here means a fixed build path.** This is how
  F-Droid builds — twice, in the same container path — so it does not block the
  F-Droid badge.
- **The Flutter engine is prebuilt.** `libflutter.so` ships inside the SDK, so the
  Flutter version must be pinned for two builds to match.
- **The APK container itself is fine.** The Android Gradle Plugin zeroes ZIP
  timestamps, so archive metadata is deterministic.
- **The signature block is not reproducible.** Two builds produce a byte-identical
  payload; only the appended APK Signing Block differs. The meaningful comparison is
  therefore the **unsigned** APK — which is also what F-Droid signs and compares.

## What this project does

| Lever | Where |
|---|---|
| Committed lockfile + `--enforce-lockfile` | `app/pubspec.lock` (tracked; `.gitignore` no longer excludes it) |
| Pinned Flutter version | `fdroid/dev.karthikkunal.vigilant-core.yml` (`srclibs: flutter@3.47.5`) |
| Fixed timestamp | `SOURCE_DATE_EPOCH` set by `scripts/repro-build.sh` |
| Fixed build path | `scripts/repro-build.sh` rebuilds at the same path |
| Unsigned release output | `app/android/app/build.gradle.kts` — signing is optional and configured from `key.properties`; F-Droid signs the published APK itself |
| Build cache cleared between runs | `scripts/repro-build.sh` removes `~/.gradle/caches/build-cache-1` so a cached output cannot mask non-determinism |

## R8 and the resource shrinker

Flutter enables R8 for release builds (`isMinifyEnabled`, `isShrinkResources`); this
project now sets both explicitly and supplies
`app/android/app/proguard-rules.pro` with:

- keep rules for `com.dexterous.flutterlocalnotifications.**` — its notification
  models are serialised with Gson, which reflects over class and field names — plus
  its `ScheduledNotificationReceiver`, `ScheduledNotificationBootReceiver` and
  `ActionBroadcastReceiver`,
- keep rules for `com.pravera.flutter_foreground_task.**`,
- the standard reflective-Gson keeps (`Signature`, annotations, `TypeToken`).

**Resource shrinking also stripped the bundled alarm sound**, because the channel
references it by name at runtime and the shrinker cannot see the reference.
`app/android/app/src/main/res/raw/keep.xml` keeps `@raw/alarm`. Verify a release
build still contains it:

```bash
unzip -l build/app/outputs/flutter-apk/app-release.apk | grep -i 'res/.*\.wav'
unzip -p build/app/outputs/flutter-apk/app-release.apk resources.arsc | strings | grep -i alarm
```

R8 must itself stay deterministic: a non-deterministic R8 output is one of the
reasons the payload check can fail.

## Verifying

```bash
scripts/repro-build.sh
```

The script copies the repository twice to the *same* path (excluding build output
and `.git`), omits the build directory so the build is clean, builds
`flutter build apk --release`, and reports two hashes:

- **payload** — every archive entry, signature block excluded. This is the
  meaningful result, and what F-Droid compares.
- **whole file** — includes the APK signing block, which is not deterministic;
  F-Droid signs the APK itself, so a mismatch here is expected and harmless.

On a payload mismatch it unzips both APKs and lists the differing entries so the
offending artefact is visible.

To test a different Flutter version, change the pinned version and re-run — the two
runs should still match each other, but will differ from a run on another Flutter
version.

## Result

See the output of `scripts/repro-build.sh`. A passing run prints `IDENTICAL` and the
shared SHA-256; a failing run prints `DIFFERENT` and the first differing entries.

If it reports `DIFFERENT`, check, in order:

1. a Gradle build-cache hit (the script already clears the cache),
2. native library stripping (`packaging { jniLibs { keepDebugSymbols += "**/*.so" } }`
   in `app/android/app/build.gradle.kts`),
3. whether the two runs used a different `SOURCE_DATE_EPOCH`.

## Path dependence, explicitly

Because `libapp.so` embeds the path, **your build will not byte-match F-Droid's**
unless both use the same path and Flutter version. F-Droid's own two builds match
each other, which is what its reproducibility check compares. If you want a
developer-published APK to match F-Droid's, use the `/upstream/path` technique from
F-Droid's `templates/build-flutter.yml`.

## iOS

Not covered. iOS reproducibility also requires a fixed Xcode version and a matching
macOS toolchain, and cannot be verified from this environment.
