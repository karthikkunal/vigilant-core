# vigilant-core — Architecture

## Decision log (summary)

- **Stack:** Flutter (Android + iOS + web from one codebase).
- **Local-first:** no vigilant-core backend, account, or push service. Discovery and scheduled checks originate on the user's device; requested domains are sent to the public discovery services listed below.
- **Alerting model:** two classes.
  1. *Expiry reminders* — scheduled local notifications, computed at discovery
     (expiry − 30/14/7/1 days). Fire even if the app never runs again. Both platforms.
  2. *Real-time paging* — Android only. Requires a foreground service and rich
     notifications. iOS v1 does not attempt this.
- **TLS full chain is a v1 gate** (missing intermediate, expired intermediate, wrong
  order). Implies one native plugin per platform (`cert_chain`).
- **Plugin method handlers must not block.** A `MethodChannel` call is delivered on
  the platform (main) thread, and both `cert_chain` implementations do blocking
  network I/O — a socket handshake on Android, a `URLSession` task plus a semaphore
  wait on iOS. Both therefore hand the work to a background queue and post the
  result back to the main thread, because `MethodChannel.Result` must be invoked
  there. On Android the alternative is not a slow scan but a hard
  `NetworkOnMainThreadException` for every call, which surfaces as a silently
  unavailable TLS panel rather than an error.
- **Identifier:** `dev.karthikkunal.vigilant-core` — baked into the published APK and
  cannot change after the first store upload.

## Why this shape

Discovery is pure HTTP/JSON/text work; it belongs in a pure-Dart package that is
unit-testable with no device (`discovery_core`). The only inherently platform-native
parts are:

- **TLS chain capture** — Dart's `SecureSocket` exposes only the leaf certificate.
- **Background execution + rich notifications** — the pager (main feature).

Both are isolated behind thin boundaries so the bulk of the app stays portable and
testable.

## Component boundaries

```
                    ┌──────────────────────────────┐
   domain in ─────▶ │  discovery_core (pure Dart)  │
                    │  RDAP · DoH · CT · headers    │
                    │  models · diffing · policy    │
                    └──────────────┬───────────────┘
                                   │ DomainReport
              ┌────────────────────┴────────────────────┐
              ▼                                         ▼
   ┌────────────────────┐                    ┌────────────────────┐
   │  cert_chain plugin │                    │  app UI (Flutter)  │
   │  Kotlin + Swift    │                    │  dashboard/detail  │
   │  leaf + chain      │                    └────────────────────┘
   └────────────────────┘                                │
                                                         ▼
                                          ┌────────────────────────────┐
                                          │  alerts/ — pager + reminders │
                                          │  Android service + channels  │
                                          │  iOS scheduled reminders     │
                                          └────────────────────────────┘
```

## Discovery sources

| Datum | Source | Notes |
|---|---|---|
| Registration expiry, registrar, status, NS | **RDAP** via IANA bootstrap | HTTPS/JSON; no CORS limits on native. Some ccTLDs lack RDAP → degrade honestly. |
| A / AAAA / MX / NS / TXT / CAA | **System resolver** on Android (`android.net.DnsResolver`); **DNS-over-HTTPS** (Cloudflare JSON) elsewhere | The platform resolver needs API 29, so `minSdk` is 29. iOS and the web have no public API for arbitrary record types, so they keep using DoH. On Android the device resolver is tried first and a scan falls back to DoH if it fails — see §Resolvers. |
| SPF / DMARC / DKIM / CAA | Derived from TXT + CAA over DoH | Pure parsing. |
| Subdomains + issuance | **crt.sh**, falling back to **Cert Spotter** | Both return real certificate metadata. If both fail the CT probe reports an error rather than degrading to a bare host list. |
| TLS leaf + chain | **Native TLS** (plugin) | Never the high-level HTTP client. |
| HSTS, redirect chain, header posture | Plain HTTPS with redirects disabled | Pure Dart. |
| TCP reachability | Dart `Socket.connect` | One explicit host/port; no port-range scanning. |
| HTTP body assertions | `checkHttpAssertions` | Literal contains/not-contains rules; status and latency still apply. |

The device contacts these services directly. vigilant-core does not proxy or persist discovery requests, but the selected domain or host is visible to each service it queries and to the monitored site or service.

The web build cannot read crt.sh's response cross-origin, so `CtClient` is built with `tryCrtSh: false` and Cert Spotter is the only CT source available in a browser.

## Resolvers

`resolveDns` turns a stored preference into a `DnsClient`. The device resolver is
the default on Android because it is the only choice that keeps the queried name
off the network — and the integration suite found it is not reliable everywhere.
`android.net.DnsResolver` reads netd's resolver configuration rather than the
`getaddrinfo` path, so on an emulator it returns SERVFAIL for names the platform
itself resolves. Selecting it on platform alone meant a scan on such a device
lost its DNS and email-authentication data with nothing to recover from.

`FallbackDnsClient` tries the device resolver first and falls back to the public
DoH endpoint when it fails. The constraints on it are deliberate:

- **Device resolver only.** A user who named a custom endpoint chose that
  service, and silently substituting a different one would override an explicit
  privacy decision. That path still surfaces its error.
- **Latched after the first failure.** A scan makes one bulk `lookup` plus seven
  DMARC/DKIM `query` calls. Retrying a broken resolver seven more times would add
  seven timeouts and repeat the disclosure for the same result.
- **Disclosed where it happens.** `sourceLabel` names the resolver that actually
  answered, and the engine puts that in the scan's DNS provider status. A scan
  never implies it stayed local when it did not.

This is why the Settings promise is about what is *tried first* rather than a
guarantee that no third party is contacted. The disclosure lands in the report,
at the point the query happened.

The remaining gap is the one no amount of app code closes: whether the device
resolver works on a given handset is a property of that handset. The integration
suite records the platform resolver's raw outcome as a diagnostic rather than
asserting it, because a test that is red on an emulator and green on hardware is
reporting the environment, not a defect.

## Web target

The web build supports discovery, subdomain selection, and local monitor configuration. The Android foreground service is unavailable in a browser, so web monitors are persisted for manual or in-app checks rather than background checks.

## Pager contract (Android, main feature)

- Foreground service, `foregroundServiceType="specialUse"` (not `dataSync` — 6h/day cap).
- One `NotificationChannel` per `(sound × vibration × severity)`; channels are immutable
  once created.
- Escalation: re-post an ongoing, un-swipeable notification every N minutes until
  acknowledged; stop for that outage only; re-arm on recovery.
- Actions: Ack / Mute / Re-check.
- Full-screen intent + `CATEGORY_ALARM` for locked-screen wake.
- DND bypass requires notification-policy access; requested in onboarding.
- Survives reboot via `BOOT_COMPLETED` + `START_STICKY`.
- **Play restriction:** full-screen intent and `specialUse` are F-Droid-friendly but
  Play-restricted. Ship F-Droid first.

## iOS (v1)

- Expiry reminders only: `zonedSchedule` at discovery; recompute the rolling window on
  each app open (iOS keeps only the 64 soonest pending notifications).
- Interruption level: time-sensitive. Critical alerts require an Apple entitlement —
  out of scope.
- No custom vibration (platform limitation), no foreground service, no guaranteed
  background checks.

## cert_chain plugin

Dart's `SecureSocket` exposes only the **leaf** certificate, so the chain is
captured natively and parsed once in Dart.

**Wire format** — method channel `cert_chain`, method `fetch`:

```
request:  { host: String, port: int, timeoutMs: int }
response: { "trusted": bool, "certs": ["<base64 DER>", ...] }   // leaf first
```

- **Android** (`CertChainPlugin.kt`): `SSLContext` handshake. A real handshake is
  attempted first for the trust verdict; if it fails, a permissive
  `X509TrustManager` re-captures whatever the server presented, so an invalid
  chain is still reported. `endpointIdentificationAlgorithm` is cleared so a
  hostname mismatch does not prevent capture.
- **iOS** (`CertChainPlugin.swift`): `URLSession` authentication challenge →
  `SecTrustCopyCertificateChain` (iOS 15+) with a `SecTrustGetCertificateAtIndex`
  fallback; trust from `SecTrustEvaluateWithError`.
- **Dart** (`certificate_parser.dart`): decodes each base64 DER and parses it with
  `basic_utils` into `CertificateInfo`. One parser, testable against a real
  certificate fixture, so no X.509 logic is duplicated per platform.

Native code is deliberately tiny; all interpretation lives in the tested Dart path.
`CertificateInfo.missingIntermediate` and `hasExpiredIntermediate()` are the v1
chain gate signals.

## Alerting pipeline

```
MonitorConfig                     target type, cadence, timeout, policy, style
      │
      ▼
MonitorTaskHandler                flutter_foreground_task, 60s repeat, boot + wake lock
      │  loads MonitorRepository (SharedPreferences, shared across isolates)
      ▼
MonitorRunner ── checkUptime / checkHttpAssertions / checkTcp ──▶  CheckVerdict
      │
      ▼
AlertEngine                       pure: threshold, cooldown, repeat, urgent,
      │                           quiet hours, mute, acknowledge
      │  AlertIntent
      ▼
LocalPager                        channel per (sound × vibration × severity)
      │                           full-screen intent, ongoing, tone, vibration
      ▼
actions: Ack · Mute 1h · Re-check ──▶ MonitorCoordinator.handleAction
      │
      ▼
MonitorRepository                 alert state persisted
```

Two isolates share one JSON document through `PluginMonitorStore`:

- **UI isolate** — `MonitorCoordinator` (add/remove/enable/check-now, action handling).
- **Service isolate** — `MonitorTaskHandler` (runs due monitors on each tick).

`onRepeatEvent` is synchronous, so ticks are fire-and-forget with an overlap guard.
A page action fired while the app is not running is handled by
`notificationActionBackground` (`@pragma('vm:entry-point')`), which applies Ack/Mute
directly to the store and registers plugins itself. Re-check needs the runner and so
is foreground-only.

All decision logic (`AlertEngine`, cadence, diffing) is pure Dart and unit-tested;
only delivery, the service host, and chain capture are platform-bound.

## Status and freshness

The repository persists three related pieces of information for each monitor:

- `AlertState` — the incident/alert state used by the paging policy.
- `MonitorCheckRecord` — the last raw verdict, timestamp, latency, and direct
  check-source label (for example, `Website target` or `TCP target`).

It also persists one repository-wide value: `lastSweepAt`, the moment the
foreground service last ran a check sweep. This exists because per-monitor
freshness cannot answer the question a user actually has. A service the OS
stopped scheduling, and a fleet where every target is down, produce the same
picture: every monitor equally stale. Recording the sweep separates "nothing is
wrong" from "nothing ran", which is the difference between a dashboard that is
quietly useless and one that is honestly reporting. The service writes it before
the per-monitor loop, so a sweep that found nothing due still counts, and a
repository written before the field existed decodes it as `null` — "never run" —
rather than failing.

The UI derives the user-facing `MonitorStatus` from those values. A monitor is
`healthy`, `degraded`, `down`, or `unknown` from its latest result, and becomes
`stale` after one cadence plus a five-minute scheduling grace. A stale result is
not presented as a current healthy result. The dashboard and detail view
periodically re-evaluate freshness and reload the shared repository. Discovery
reports also expose per-provider status for RDAP, DNS, the HTTP
target, and Certificate Transparency so partial or unavailable sources are
visible. The DNS status names the resolver that answered, and is reported as
*degraded* — naming the record types it could not answer — when the resolver in
use supports fewer types than the scan requested.

Android settings can query and request the battery-optimization exemption. The
UI explains that even an exemption cannot guarantee execution under Doze or OEM
power rules.

Because that guarantee cannot be made, the dashboard also states the last sweep
(see `lastSweepAt` above) and, when a sweep is more than five minutes overdue,
says that Android is not scheduling the work and points at Settings. The app
never lets an unverified scheduler imply that everything is fine.

## Turning background monitoring off

Disabling a monitor stops that one being checked. It does not stop the service:
the foreground service and its persistent notification are separate and outlive
it, so before this existed there was no way to end them short of uninstalling or
force-stopping the app.

`MonitorRepository.monitoringPaused` is that switch, and `Settings → Background
monitoring` (Android only, because the service only exists there) is its
control. Three things make it honest:

- **`_commit` respects it.** Adding a monitor used to start the service
  unconditionally, which would have undone the pause silently. It no longer does,
  and channels are still provisioned so a later start can deliver immediately.
- **It is written only after the service call succeeds.** A platform that refuses
  to stop leaves the preference alone and reports the failure, so the stored flag
  never says "stopped" for a service that is still running.
- **It is re-applied on startup.** The service restarts on boot without asking, so
  `syncMonitoringPreference` runs from the shell: a stored pause is re-asserted,
  and a service that died while unpaused is brought back.

The dashboard's sweep line distinguishes the two reasons a sweep is late. A
monitor the user stopped and a monitor Android stopped scheduling produce the
same stored state, so reporting "Android is not scheduling it" after the user
deliberately turned monitoring off would send them to fix a setting that is
already correct. When paused, the line names the user's own decision instead.

## Adding monitors

There is one creation form, not one per kind of monitor. What a monitor checks
is decided by `resolveMonitorTarget` in
[`app/lib/monitors/monitor_target.dart`](../app/lib/monitors/monitor_target.dart)
from the target line and whether any body rules were filled in, and the resolved
target is shown under the field as the user types. An explicit choice in the
form outranks the text, because a monitor quietly checking the wrong thing is
worse than one that asks.

The inference lives in a pure function with its own tests rather than inside the
widget, because it is the only part of the form with a decision in it. The
consequences are already in the model: `MonitorType` is just `{http, tcp}`, an
assertion monitor is an `http` monitor with a non-empty `assertions` list, and
`MonitorRunner` dispatches on `isTcp` / `assertions.isNotEmpty` / neither. So
the form needs no branches of its own beyond choosing which coordinator method to
call.

A target that resolves to a plain website with no port, path or rules is created
through the same path as a domain added from a scan, so both produce a monitor
keyed by the bare host. Ids are the dedup key, and a monitor keyed
`https://example.com` would otherwise sit beside one keyed `example.com` for the
same site.

A domain added from a scan report is still added from the report. That is a
different job from typing a target by hand — the scan already has the
registration and certificate expiry — so it keeps its own entry point.

## Change between scans

A scan flattens its report into comparable facts (`snapshotFacts`) and compares
them with the last scan of the same domain, kept on the device
(`DriftStore`). The report shows what changed, leading with the changes worth
acting on and listing ordinary churn — addresses, subdomains, log entry counts —
behind a collapsed header.

This is deliberately **not** part of the monitor path. `MonitorRunner` still
dispatches only on `checkUptime` / `checkHttpAssertions` / `checkTcp`. A
background drift check would mean running RDAP, DNS, seven DKIM lookups, CT and
an HTTP probe on every sweep, on a cadence, forever, for every watched domain.
Scans are user-initiated, so diffing them costs nothing extra and stays
inspectable. A drift *alert* would need that background cost to be worth
paying, and it is not yet.

Two rules keep the comparison honest, and both exist because the naive version
of this feature reports changes that never happened:

- **A scan only claims a change where it looked.** `observedAreas` reports which
  of `registration`, `dns`, `email`, `ct`, `http` and `cert` a scan actually
  answered, and `diffReports` discards every difference outside that set.
  `snapshotFacts` omits a key when the underlying datum is absent, and absence
  means two different things: the answer was "nothing there", or the probe never
  ran. Without the gate, declining the Certificate Transparency probe on the
  second scan would erase every `ct.*` fact from the first and report a mass
  removal of subdomains. A resolver that cannot answer every requested type is
  already reported as a degraded DNS provider, and it is not allowed to
  manufacture diffs either.
- **The chain is passed in, not read from the report.** The discovery engine
  never sets `report.certificate` — capture is the platform plugin's job — so
  `snapshotFacts` takes the `CertificateInfo` as an argument. Without it the TLS
  posture would be the one part of a scan that could never be compared.

A first scan records a baseline and says so, because there is genuinely nothing
to have changed yet. The two cases are reported separately: "this is the first
time, and the baseline was kept" may be shown as a promise that scanning again
will say something, while "this device would not store one" may not. Baselines
are capped per device and can be dropped from the report, because a list of
domains the device is holding on to is itself something the user should be able
to erase.

## Non-goals (v1)

- Remote push (would require a backend).
- OCSP/CRL revocation checking.
- Real-time paging on iOS.
- Alerting on drift (see above — the comparison is scan-time and inspectable).
