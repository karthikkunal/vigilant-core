# Manual test plan — Android pager

The pager, the background service, and chain capture need a real device. This plan
verifies the parts that cannot be covered by unit tests.

Everything here is **Android** (package `dev.karthikkunal.vigilant-core`). iOS is out of
scope for v1 paging.

## Prerequisites

- An Android phone (API 26+), USB debugging on, `adb` working.
- The debug APK: `app/build/app/outputs/flutter-apk/app-debug.apk`
  (build with `flutter build apk --debug`).
- A target that stays up: `example.com` is fine.

## Build and install

```bash
cd app
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Useful while testing:

```bash
adb logcat -s flutter            # app logs
adb shell dumpsys notification | grep -i vigilant-core   # channels
adb shell dumpsys deviceidle force-idle     # force Doze
adb shell dumpsys deviceidle unforce
```

## Test matrix

| # | Test | Steps | Expected |
|---|---|---|---|
| 1 | Notification permission | First tap that pages (see #2) | System prompts; allow it. If denied, no page arrives |
| 2 | Test page — delivery | Open app → tap the **bell** action | Full-screen red page with looping sound + vibration, **Acknowledge / Mute 1h / Re-check** actions |
| 3 | Channels provisioned | `adb shell dumpsys notification \| grep -i vigilant-core` | Nine channels `wt_<severity>_<sound>_<vibration>` |
| 4 | Watch a domain | Discover `example.com` → tap **add_alert** ("Watch this domain") | Snackbar "Watching example.com"; a persistent "vigilant-core is monitoring" notification appears |
| 5 | Monitors screen | Home → **list_alt** | `example.com` listed, status dot, "checked just now", enabled switch on |
| 6 | Check now (up) | Monitors → **bolt** on `example.com` | Status goes green; no page |
| 7 | Down page | Turn on airplane mode → **Check now** | Check fails; red **down** page: escalating sound + vibration. (Turn airplane mode back on afterward) |
| 8 | Urgent repeat | Leave it down (default policy is non-urgent, so set an urgent monitor first — see below) | Repeat page every `repeatInterval` until acknowledged |
| 9 | Acknowledge | Tap **Acknowledge** on a down page | Repeats stop; the row shows "acknowledged" |
| 10 | Mute 1h | Re-trigger a page → tap **Mute 1h** | Page clears; row shows "muted" for an hour |
| 11 | Re-check | Tap **Re-check** | Immediate check; status updates |
| 12 | Recovery | Restore network → **Check now** | Recovery notification; status returns green |
| 13 | Background cadence | Add a monitor at a short cadence, lock the phone, wait | Checks continue (persistent notification stays); page still arrives when locked |
| 14 | Reboot | Restart the phone | Service restarts (persistent notification returns) without opening the app |
| 15 | Background action (app killed) | Swipe the app away, then trigger a page and tap **Acknowledge** | Acknowledgement persists: reopen the app and the row shows "acknowledged" |
| 16 | Remove | Monitors → **delete** | Monitor disappears; page cleared |
| 17 | Copy the site list | Settings → **Site list** → **Copy list** | Snackbar reports how many were copied; the clipboard holds one address per line and nothing else |
| 18 | Import into a device that already has one of them | Paste the copied list → **Import list** | Preview names what will be added and what is already here; sites already present are left untouched |
| 19 | Import something that is not a list | Put ordinary prose on the clipboard → **Import list** | Snackbar explains no line named a watchable site; no monitor is added |
| 20 | Backing out of a preview | **Import list** → **Cancel** | Nothing is added |

## Adding monitors: websites, sockets and body rules

One form covers all three. What it checks is inferred from the target line and
whether any body rules are filled in, and the resolved target is shown under the
field as you type, so confirm it before saving.

| # | Test | Steps | Expected |
|---|---|---|---|
| 21 | Add a website | Monitors → **Add monitor** → enter `example.com` | The banner reads *Website*; the monitor is stored under the bare host and returns healthy |
| 22 | Infer a website on a port | Enter `example.com:8080` with no scheme | The banner reads *Website* with port 8080, **not** TCP. Switch **Check** to *TCP port* to get a socket |
| 23 | Add a TCP monitor | Monitors → **Add monitor** → set **Check** to *TCP port* → enter `127.0.0.1` and a listening test port | Monitor is stored as `tcp://…`, shows a TCP card, and **Check now** returns healthy |
| 24 | TCP via the scheme | Enter `tcp://127.0.0.1:<port>` and leave **Check** on *Work it out* | Same result as #23; the `tcp://` prefix is unambiguous without touching the selector |
| 25 | TCP without a port | Set **Check** to *TCP port* and enter a host with no port | Rejected with a message asking for a port; nothing is saved |
| 26 | Add body rules | Enter a URL returning known text, then **Add rule** | Rules are saved and evaluated locally; the banner reports the rule count |
| 27 | Rules and a socket together | Add a rule, then switch **Check** to *TCP port* | Rejected, and the rule is **not** silently dropped |
| 28 | Unsupported scheme | Enter `ftp://files.example.com` | Rejected, pointing at http(s) and tcp; never silently checked as host `ftp` |
| 29 | Plain website keeps the bare-host id | Add `https://example.com` here, having also added `example.com` from a scan | One monitor, not two |
| 30 | TCP failure | Stop the test listener or enter a closed port | The monitor returns a down verdict and pages according to its alert policy |
| 31 | Assertion failure | Add a required string absent from the response | The verdict is down with an `Assertion failed` reason |
| 32 | Assertion recovery | Restore the expected response and check again | Recovery alert/state transition follows the existing AlertEngine policy |
| 33 | Monitor freshness | Check a short-cadence monitor, then wait past its cadence plus the five-minute grace | The row/detail view shows **Stale**, the last check time, and the last known result; **Check now** refreshes it |
| 34 | Background sweep visibility | With monitors present, look under the header summary | A line reports when the background service last swept, e.g. *Checked just now*. It is a separate fact from any monitor's own freshness |
| 35 | Sweep never ran | Clear app data, add a monitor, and open the dashboard before a sweep has happened | *No background check has run on this device yet* — not *Everything looks good* |
| 36 | Sweep overdue | Revoke the battery-optimization exemption and wait | After five minutes the line says Android is not scheduling it and points at Settings |
| 37 | Provider visibility | Run a domain scan and expand **Provider status** | RDAP, DNS, HTTP, and CT each show Healthy, Partial, Down, Unknown, or Skipped with source detail. DNS names the resolver that answered — "System resolver" on Android, "DNS-over-HTTPS" on iOS and web |
| 38 | Android reliability guidance | Open Settings → **Android background reliability** | The card reports the battery-optimization state and opens the system settings; the state refreshes after returning |

TCP checks intentionally target one explicit host/port; they are not a
port-range scanner. Assertion checks are literal body rules and do not execute
user code. A domain added from a scan is still monitored from the report view,
which is a different job from typing a target by hand.

## Turning background monitoring off

These cover the master switch in Settings → **Background monitoring**, and what
the dashboard is allowed to say afterwards. The distinction being checked is the
one that is invisible in the stored data: a monitor the user stopped and a
monitor Android stopped scheduling look identical, so the app has to be told
apart by its own record.

| # | Test | Steps | Expected |
|---|---|---|---|
| 39 | Switch is present and reports state | Settings → **Background monitoring** | An **On** pill while the service runs. The card is absent on iOS and web, which have no service to stop |
| 40 | Turning it off stops the service | Tap **Turn monitoring off** | The pill reads **Off**; `adb shell dumpsys activity services dev.karthikkunal.vigilant-core` returns `(nothing)`; the persistent "vigilant-core is monitoring" notification is gone |
| 41 | The dashboard does not blame Android | On the Monitors screen, after #40 | The sweep line says background monitoring is off and points at Settings. It must **not** say "Android is not scheduling it" or mention battery optimisation |
| 42 | A recent sweep still reports "off" | Immediately after #40, while the last sweep is seconds old | Still reports that monitoring is off. "Checked just now" would imply monitoring is live |
| 43 | Adding a monitor does not restart it | With monitoring off, add a monitor | The monitor is saved and listed; the service stays stopped. This is the path that used to start it unconditionally |
| 44 | Foreground checks still work | With monitoring off, tap **Check now** on a monitor | The check runs and the status updates. Stopping is about the background, not about checking |
| 45 | It survives a reboot | Reboot the phone, then open the app | The service does not come back. A service that restarts on boot must respect the switch |
| 46 | Turning it back on | Tap **Turn monitoring back on** | The pill reads **On**, the persistent notification returns, and `dumpsys` shows the service running |
| 47 | A monitor added while off is then checked | Add a monitor while off (#43), then turn it back on (#46) | The service sweeps it on its own cadence and the dashboard reports the sweep |

If a page ever arrives while the switch reads **Off**, the preference has been
recorded as stopped for a service that is still running — the two states have
drifted apart, and that is a bug in the switch rather than in the OS.

## Change between scans

Drift compares a scan with the previous scan of the same domain on this device.
There is nothing to compare on a first scan, so the interesting cases are the
second and third scan. Run these on a domain you can actually change.

| # | Test | Steps | Expected |
|---|---|---|---|
| 48 | First scan records a baseline | Scan a domain never scanned on this device | The card reads *First scan on this device* and says scanning again will show what changed. No change list |
| 49 | An unchanged rescan says so | Scan the same domain again immediately | *No change since …* with the date. Not an empty change list |
| 50 | A real change is reported | Change something you control — add a TXT record, or a DMARC record — then rescan | The change is named in plain language with a before → after value, not a raw key |
| 51 | Actionable changes come first | Produce both a security-relevant change and ordinary churn if you can | The notable change is listed; ordinary churn sits behind a collapsed "N other change(s)" header |
| 52 | Declining CT is not a removal | Scan once **with** subdomains, then rescan **without** ticking the subdomain box | **No** list of removed subdomains. A probe that was not asked for cannot have deleted anything, and this is the case most likely to be got wrong |
| 53 | Uncompared areas are named | Rescan with a probe likely to fail | The card lists what it did not compare, e.g. *Not compared: the TLS certificate* |
| 54 | The chain is compared | Renew or replace the certificate on a domain you control, then rescan | The issuer or expiry change is reported under the certificate area |
| 55 | Forgetting the baseline | Tap **Forget this baseline** | A snackbar confirms; the next scan reads as a first scan again, with no comparison |
| 56 | Domains are independent | Scan a second domain, then rescan the first | The second domain's scan is a first scan; the first domain still compares against its own baseline |
| 57 | Baselines are bounded | Scan more than 50 distinct domains | The oldest is forgotten, and no scan slows down or fails. The store is capped per device |

Drift is scan-time only. It does **not** page, and it does not run on the
background cadence — so a change that happens while the app is closed is noticed
on the next scan, not before. That is a deliberate limit, not a missing feature;
see `docs/architecture.md` §Change between scans for why a background drift
check would cost a full discovery probe on every sweep, for every domain.

## Recorded run — 2026-09-25

Environment: Android 15 / API 35 Google APIs x86_64 emulator (`emulator-5554`),
debug APK, Flutter 3.47.5. The emulator was used instead of a physical phone.
Build verification: `flutter build apk --debug` passed; `flutter analyze` passed;
`flutter test` passed (24 tests).

| # | Result | Evidence / notes |
|---|---|---|
| 1 | **PASS** | Android displayed the notification permission prompt on the first page attempt; **Allow** was accepted. |
| 2 | **PARTIAL** | The bell action delivered a heads-up page titled `example.com is down` with `Acknowledge`, `Mute 1h`, and `Re-check` actions. Sound, vibration, and locked-screen full-screen behavior were not verified. |
| 3 | **PASS** | `adb shell dumpsys notification` showed all nine `wt_<severity>_<sound>_<vibration>` channels. |
| 4 | **FAIL (service)** | `example.net` and `example.org` were accepted and produced `Watching …` snackbars, but no persistent `vigilant-core is monitoring` notification appeared; `dumpsys activity services dev.karthikkunal.vigilant-core` returned `(nothing)`. Monitor persistence passed; foreground-service startup did not. |
| 5 | **PASS** | The Monitors screen showed both `example.net` and `example.org` with enabled switches. After the checks below, both showed `Up · checked just now`. |
| 6 | **PASS** | **Check now** on both domains returned `Up · checked just now`; no page was emitted. |
| 7–16 | **NOT RUN** | Network-failure, lock-screen cadence, reboot, background-action, and remove flows were not exercised in this run. |
| R1–R4 | **NOT RUN** | Expiry-reminder scheduling was not exercised. |

### Additional observations

- Domain discovery for `example.com` completed and returned registration, DNS, and
  email-authentication data.
- The emulator reported `chain could not be captured` for the native TLS chain.
  **Superseded** — see "Recorded run — integration tests" below, where the chain
  is captured successfully. The capture in this run was against a scan flow that
  reported the failure rather than aborting, which is the behaviour the manual
  row asked for; the capture itself works.
- A transient Android System UI “isn’t responding” dialog appeared during the
  first emulator boot and was dismissed; it was not an app test failure.
- The #4 service issue is addressed in the fix verification below.

## Fix verification — 2026-09-25

The Android foreground-service declaration and release network permission were
fixed after the recorded run.

| Check | Result | Evidence |
|---|---|---|
| Foreground service | **PASS** | The debug APK declares `com.pravera.flutter_foreground_task.service.ForegroundService` as `specialUse` with the required subtype property. After reinstall, `dumpsys activity services dev.karthikkunal.vigilant-core` shows the service running. |
| Persistent service notification | **PASS** | `dumpsys notification` shows the ongoing `vigilant-core is monitoring` notification on `vigilant-core_service`. |
| Service start error handling | **PASS** | `MonitorService.start()` now passes `ForegroundServiceTypes.specialUse` and throws on `ServiceRequestFailure` instead of reporting a false success. |
| Release network permission | **PASS** | `flutter build apk --release` succeeds, and the release manifest includes `android.permission.INTERNET`. |
| Regression checks | **PASS** | `flutter analyze` passes and all 31 Flutter tests pass. |

### Not yet run

Rows **1–38** and **R1–R4** carry the results above. Rows **39–57** — the
background-monitoring switch and scan drift — were added with those features.

Some of them now have device evidence, from the integration suite rather than a
person working through this document. Where the two disagree, the integration
suite is the fresher record.

| Rows | State | Covered by |
|---|---|---|
| 1–16 | partly run, see the recorded run | unit + widget tests |
| 17–20 | not run | widget tests |
| 21–38 | not run | unit + widget tests |
| 39–40 | **verified on emulator** — service starts, reports running, stops | `background_service_test.dart` |
| 41–42 | not run | — |
| **43** | **verified on emulator** — adding a monitor does not start a service switched off | `background_service_test.dart` |
| 44 | verified on emulator — a check still runs while monitoring is off | `background_service_test.dart` |
| 45 | not run — needs a real reboot, which an emulator test cannot do | — |
| 46–47 | not run | coordinator tests with a fake service |
| 48–57 | not run | `discovery_core` diff tests + widget tests |

Still unverified on device, and worth being explicit about:

- **Row 45, reboot.** The suite proves a stored pause is re-applied on startup.
  It cannot prove the *boot* path, because a test cannot reboot the device it is
  running on.
- **Rows 48–57, drift.** No unit or widget test can show that a second scan
  really does read the first, or that a changed certificate is really seen.
- **Rows 1 and 2, page delivery.** The integration suite deliberately suppresses
  the notification-permission dialog, so nothing in it can show a page being
  displayed. That needs a person to grant the permission.

## Recorded run — integration tests

Environment: Android 15 / API 35 Google APIs x86_64 emulator, debug build,
Flutter 3.47.5. Run with:

```bash
flutter test integration_test/background_service_test.dart -d <device>
flutter test integration_test/device_boundaries_test.dart  -d <device>
```

| Area | Result | Notes |
|---|---|---|
| TLS chain capture — trusted leaf | **PASS** | A real handshake returns a leaf, a trust verdict, and SANs containing the host |
| TLS chain capture — host presenting nothing | **PASS** | Surfaces as an error rather than a fabricated empty chain |
| Service start / running / stop | **PASS** | `isRunning()` agrees with the platform after each call |
| Adding a monitor does not start a stopped service | **PASS** | Row 43. The switch is authoritative, not advisory |
| Check while monitoring is off | **PASS** | Row 44. Stopping is about the background, not about checking |
| Monitor round-trip through the real plugin store | **PASS** | Expiry and the copied site list both survive |
| Resolver preference defaults to the device resolver | **PASS** | A first run does not disclose to a third party |
| Device resolver answers a real query | **environment** | SERVFAIL on the emulator: `android.net.DnsResolver` reads netd's resolver configuration rather than the `getaddrinfo` path, so it misses the emulator's NAT'd DNS. Probably an emulator limitation, but not confirmable without hardware |

That last row is why a scan now falls back to a public resolver when the device
resolver fails, and names the service it used in the report. See
`docs/architecture.md` §Resolvers.

### Running these unattended

The service tests pass `requestPermissions: false` to `LocalPager`. That
suppresses the `POST_NOTIFICATIONS` dialog and nothing else — channel
provisioning still runs, so the plugin is exercised for real. It is necessary
because nothing on an unattended emulator can dismiss that dialog, and with the
prompt enabled `initialize()` never returned, hanging every test that added a
monitor.

The cost is that this suite cannot show a page being displayed. To test that,
pre-grant the permission and keep the prompt on:

```bash
adb shell pm grant dev.karthikkunal.vigilant-core android.permission.POST_NOTIFICATIONS
```

Channel *counts* are still checked with `dumpsys` rather than from Dart, because
the plugin exposes no way to enumerate what the platform created.

### Making a monitor urgent (for #8)

The default policy is non-urgent. To exercise urgent paging, temporarily make the
default urgent in `MonitorConfig.forDomain` (or pass an urgent `AlertPolicy` from
`_watch` in `lib/main.dart`), rebuild, and re-install. Note this in any bug report.

### Forcing down/recovery without waiting for the cadence

Use **Check now** rather than waiting for the service tick. Toggling airplane mode
or Wi-Fi produces a transport error (down); restoring it produces a 2xx (recovery).
Network toggles affect every monitor at once.

## Expiry reminders

Reminders are scheduled at 09:00 local on the 30/14/7/1 days before an expiry, and
the whole set is recomputed on every launch (the rolling window).

| # | Test | Steps | Expected |
|---|---|---|---|
| R1 | Reminders are planned | Watch a domain whose registration expires within ~120 days | A **silent "Expiry reminders" channel** exists, distinct from the paging channels |
| R2 | Nothing fires immediately | Watch, then wait a minute | No notification — reminders are only for future dates |
| R3 | Cap holds | Watch many domains | At most 60 reminders are pending (the iOS limit is 64) |
| R4 | Recomputed on change | Remove a monitor with reminders | Its reminders are gone from the scheduled set |

Firing itself is impractical to wait for. Inspect the scheduled set instead:

```bash
adb shell dumpsys alarm | grep -i vigilant-core
adb shell dumpsys notification | grep -i "Expiry reminders"
```

## Pass criteria

- #2 shows sound, vibration, and a full-screen page on a locked screen.
- #7 produces a **down** page and #12 a **recovery** notification.
- #9 stops repeats, #10 silences for an hour, #11 checks immediately.
- #13 still pages while the phone is locked; #15 acknowledges with the app dead.
- #14 restarts the service after a reboot.

## Known limitations (not failures)

- **Cadence is best-effort below Doze.** The service repeats every 60s but Android
  may defer work; monitor cadence gates on `lastChecked`.
- **Battery optimisation must be off** for reliable paging. If pages are missing,
  check the app's battery setting (Settings → Apps → vigilant-core → Battery →
  Unrestricted). vigilant-core's Android settings card can open this screen and
  reports whether the app is currently exempt.
- **Full-screen intent** is restricted on Android 14+ for Play distribution; it
  works when sideloaded (F-Droid path).
- **DND bypass requires an explicit grant.** Until it is given (Monitors → the
  "Do Not Disturb bypass is off" banner → **Allow**), Do Not Disturb silences
  urgent pages. Once granted, critical channels carry the bypass.
- **iOS has no guaranteed background monitor cadence.** TCP and HTTP assertion
  checks run when the app is active or on a permitted foreground invocation;
  expiry reminders remain the only scheduled iOS notification contract in v1.
- **Private/local TCP targets may require an OS network permission.** A future
  Android release can require an explicit local-network grant, and iOS applies
  its own local-network privacy rules. Public TCP targets remain the baseline
  Android/iOS path.
- Alarm channels use the bundled `res/raw/alarm.wav`. A channel's sound is
  immutable once created, so if you change the asset, uninstall before
  reinstalling or the old sound persists.
- A monitor's pages share one group key, so repeats update in place rather than
  stacking.
- **The Android device resolver is not reliable on every device.** It has been
  observed returning SERVFAIL on an emulator. A scan now falls back to a public
  DNS-over-HTTPS service when that happens and names it in the DNS provider
  status, so a scan is never silently narrower than it claims — but on such a
  device the domain does reach a third party, and the Settings copy says the
  device resolver is *tried first* rather than promising it is always used. A
  custom endpoint is never substituted this way. See `docs/architecture.md`
  §Resolvers.
- **The integration suite cannot show a page being displayed.** It suppresses the
  notification-permission dialog so it can run unattended, which means rows 1
  and 2 stay manual. Pre-granting the permission re-enables them.
- **Reboot is not covered by any automated test.** A test cannot reboot the
  device it runs on, so the boot path of the pause preference is manual row 45.

## Reporting a problem

Capture:

```bash
adb logcat -d -s flutter > vigilant-core-logcat.txt
adb shell dumpsys notification | grep -i vigilant-core > channels.txt
adb shell dumpsys deviceidle > doze.txt
```

Include the Android version, the OEM, and whether the app was foreground, background
or killed when it happened.
