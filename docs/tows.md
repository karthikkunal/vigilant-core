# vigilant-core — TOWS matrix

Composed from the state of the repository at tag `1.0.0` (`a3e2c0b`), before the first
store upload. Every claim is grounded in a file in this repo or in `docs/`; the
references are given so a later reader can re-derive the matrix when they go stale.

TOWS cross-maps the internal audit (Strengths/Weaknesses) against the external one
(Opportunities/Threats) into four kinds of strategy: **SO** use strengths to seize
opportunities, **ST** use strengths to counter threats, **WO** fix weaknesses via
opportunities, **WT** minimise weaknesses and threats.

## S / W / O / T

### Strengths

| # | Strength | Evidence |
|---|---|---|
| S1 | Clean split: discovery is pure Dart and testable with no device; only two native islands | `packages/discovery_core/`, `docs/architecture.md` §Why this shape |
| S2 | TLS **full chain** captured natively (Kotlin + Swift), parsed once in Dart — the v1 gate is actually built, and no X.509 logic is duplicated per platform | `packages/cert_chain/`, `docs/architecture.md` §cert_chain plugin |
| S3 | Alerting decision logic (`AlertEngine`, cadence, diffing) is pure Dart and unit-tested; only delivery and hosting are platform-bound | `docs/architecture.md` §Alerting pipeline |
| S4 | Reproducibility and supply-chain hygiene: double-build hash compare, `--enforce-lockfile`, srclib-pinned recipe, licence consistent everywhere | `scripts/repro-build.sh`, `docs/reproducible-builds.md`, `fdroid/dev.karthikkunal.vigilant-core.yml` |
| S5 | Local-first trust story: no account, no backend, device resolver on Android, privacy policy written | `README.md` §Local-first, `docs/privacy-policy.md` |
| S6 | Quality gates wired into the workflow: hooks run format + analyze + tests + a debug APK | `.githooks/`, `scripts/check.sh` |
| S7 | Honest state semantics: per-provider status, `stale` freshness, DNS resolver naming, degraded record-type reporting — a stale result is never shown as healthy | `docs/architecture.md` §Status and freshness |

### Weaknesses

| # | Weakness | Evidence |
|---|---|---|
| W1 | No hosted CI. The only automated gates for Dart are local git hooks, so "tests pass" is unverified by anyone but the author | `.gitlab-ci.yml` runs the Pages job and the release-readiness check; nothing runs format/analyze/test in CI |
| W2 | Asymmetric platform value: iOS gets reminders only (no paging, no guaranteed background run, 64-notification cap); web gets discovery only (no background, no crt.sh) | `docs/architecture.md` §iOS, §Web target |
| W3 | No shared dashboard and no export or sync — a monitor is stranded on one device | `README.md` §Who it's for |
| W4 | Best-effort under Doze and OEM power rules. A scheduler the OS has stopped looks exactly like a fleet that is simply quiet | `docs/architecture.md` §Status and freshness, §Android reliability |
| W5 | Play-restricted *by design* (full-screen intent, `specialUse`) — the headline feature cannot ship on the largest channel | `docs/architecture.md` §Pager contract |
| W6 | Bus factor 1, and `dev.karthikkunal.vigilant-core` is permanently locked at the first upload | `docs/fdroid.md` §Application id |
| W7 | Doc drift between the code and `docs/`. It was called on two stale blockers, and then got worse before it got better | blockers #8, #9, #10 and #11 all needed correcting; the recipe's `scanignore` was a hard build failure; the `1.0.0` tag named a commit that could not build; three `grep` commands in `docs/fdroid.md` were missing the `app/` prefix; `app/README.md` was still the Flutter template |

### Opportunities

| # | Opportunity | Evidence |
|---|---|---|
| O1 | F-Droid: no fee, privacy-aligned, and the recipe, `1.0.0` tag and public GitLab source are already in place | `fdroid/dev.karthikkunal.vigilant-core.yml`, `docs/fdroid.md` blockers #1-#7 |
| O2 | Play and iOS metadata already authored — a second channel costs policy work, not content | `app/fastlane/metadata/android/en-US/`, `app/fastlane/metadata/ios/en-US/` |
| O3 | The homelab / self-host / "services I depend on" audience is large and underserved by server-centric uptime tools | `README.md` §Who it's for |
| O4 | The web build is a zero-install trial surface: discovery is the hook, monitors are the retention | `docs/architecture.md` §Web target |
| O5 | `discovery_core` is a clean pure-Dart seam, publishable for other tooling later | `packages/discovery_core/` |

### Threats

| # | Threat | Evidence |
|---|---|---|
| T1 | Play review could reject or force removal of the pager's core APIs — a policy risk, not a code risk | `docs/architecture.md` §Pager contract |
| T2 | Public discovery providers (RDAP bootstrap, crt.sh, Cert Spotter, Cloudflare DoH) are single points of failure; rate limits silently degrade the headline feature | `docs/architecture.md` §Discovery sources |
| T3 | Upstream dependency churn: `flutter_foreground_task`, `flutter_local_notifications`, `basic_utils` — a breaking upgrade lands directly on the paging path | `app/pubspec.yaml`, `packages/cert_chain/pubspec.yaml` |
| T4 | Hosted competitors (Better Uptime, Hetrix Tools, Uptime Kuma) offer dashboards, webhooks and history that a local-only app structurally cannot | `README.md` §Who it's for |
| T5 | Android 15+ foreground-service tightening and iOS pressure erode the one differentiated capability | `docs/architecture.md` §Pager contract, §iOS |
| T6 | Scan-disclosure criticism: a domain sent to CT or RDAP is visible to third parties, and a privacy-forward app is held to a higher bar than a generic one | `README.md` §Local-first, `docs/privacy-policy.md` |

## TOWS Matrix

|  | **Opportunities** | **Threats** |
|---|---|---|
| **Strengths** | **SO — Maxi-Maxi**<br>**SO1** Ship F-Droid first and lead with the reproducibility story (S4, S5 × O1). `repro-build.sh` plus a hash comparison, GPL and no-backend is a pitch no hosted tool can make.<br>**SO2** Anchor store copy on the full TLS chain and honest per-provider status, not on "uptime" (S2, S7 × O2). Chain capture is exactly what a dashboard cannot show.<br>**SO3** Extract and publish `discovery_core` as a standalone Dart package once app usage stabilises (S1, S4 × O5). | **ST — Maxi-Mini**<br>**ST1** Make provider degradation a first-class visible state, so a crt.sh outage reads "CT unavailable" and never "no subdomains" (S7 × T2). Extend the existing per-provider status to errors-as-states.<br>**ST2** Lock the dependency set: `--enforce-lockfile` is already in the recipe, so add a scheduled `pub outdated` sweep and let upstream churn (T3) surface before it breaks paging.<br>**ST3** Treat no-backend plus reproducible builds as the durable answer to hosted competitors (S4, S5 × T4), and publish the double-build hash as evidence in the listing. |
| **Weaknesses** | **WO — Mini-Maxi**<br>**WO1** Add `.gitlab-ci.yml` mirroring `.githooks/pre-push` — format, analyze, test, debug APK — so "tests pass" is a claim anyone can check (W1 × O1).<br>**WO2** Make Play a deliberate tiered channel: pager on F-Droid, discovery plus reminders on Play, with an explicit feature-comparison note (W5 × O2). This converts a rejection risk into channel strategy.<br>**WO3** Use the web build as the top of the funnel, linked from F-Droid and both store listings, framed as "inspect anywhere, page on Android" (W2, W3 × O4). | **WT — Mini-Mini**<br>**WT1** Surface the privacy model *in-app* — which service sees which domain, on which platform — not only in `docs/privacy-policy.md` (W7 × T6).<br>**WT2** Freeze platform scope before the identifier is locked: iOS real-time paging and team dashboards stay out of v1 (W6 × T4, T5). Cheap to defer now, a schema rewrite after upload.<br>**WT3** Put the release checklist on every version bump — re-run the `docs/fdroid.md` blocker table and the `git grep 'com\.example'` check (W7 × T1), so open blockers cannot rot into a submission failure. |

## Next steps

| # | Action | Effort | Status |
|---|---|---|---|
| 1 | Run `fdroid build --verbose --latest dev.karthikkunal.vigilant-core` against an `fdroiddata` fork and submit the recipe | 1-3 h plus F-Droid queue | **build verified** — 59.7 MB unsigned APK from `462bc7d`; submission not filed |
| 2 | Add `.gitlab-ci.yml` running the same commands as `.githooks/pre-push` (WO1) | ~1 h | **partly** — Pages and the release check are in CI; format/analyze/test are not, so W1 stands |
| 3 | Close `docs/fdroid.md` blockers #10 and #11 | ~30 min | **done**, and `scripts/check-release.sh` now guards both |

Blockers #8 (screenshots) and #9 (`NonFreeNet`) were closed first. #8 was doc
drift: seven device-resolution screenshots were already committed. #9 was
resolved before it was ever raised: the F-Droid build is Android-only, the
default resolver on Android is the device's own, and the DoH endpoint is
user-namable rather than inherited, so the anti-feature does not apply.

**The audit then turned up more drift, which is the point of W7.** The recipe's
`scanignore` was a hard build failure rather than a warning, the `1.0.0` tag
named a commit that could not build, and three documented `grep` commands were
missing the `app/` prefix. All fixed, and recorded in [`fdroid.md`](fdroid.md).

## What changed after the audit

| Item | Response |
|---|---|
| W4 — no guarantee the check ran | `MonitorRepository.lastSweepAt` records each service sweep, written before the per-monitor loop so a sweep with nothing due still counts. The dashboard states it, and when a sweep is over five minutes overdue it says Android is not scheduling the work and points at Settings. See `docs/architecture.md` §Status and freshness. |
| W7 — doc drift | Fixed the drift listed above, and added `scripts/check-release.sh` so it cannot recur silently: placeholders, stale application id, recipe/tag agreement, privacy URL reachability, changelog TODOs, broken relative links. It runs on `pre-push`, and each check was verified to fail when its condition is violated. |
| Three duplicated add flows | One `AddMonitorScreen` whose target resolution is a pure, tested function. The report-view "Monitor this domain" path is deliberately kept: adding a scanned domain is a different job, since the scan already holds the expiry dates. |
