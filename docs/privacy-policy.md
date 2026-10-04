# vigilant-core — Privacy Policy

**Effective date:** 26 September 2026
**Applies to:** vigilant-core for Android and vigilant-core for iOS, version 1.0.0 and later.

This document is published at <https://vigilant-core-9a0e4f.gitlab.io/privacy-policy.html>,
which is the URL in the store listings. The source of truth is
[`docs/privacy-policy.md`](privacy-policy.md) in the project repository; regenerate
the published page with `scripts/build-site.sh`.

---

## The short version

vigilant-core has **no account, no backend, and no server of ours**. Your monitors,
scan history, and settings stay on your device. The app contains **no analytics,
no advertising, no crash reporting, and no third-party tracking SDKs**.

A scan is **not** offline, though. The domain or host you type is sent to public
third-party lookup services so they can answer the question, and your monitors
then connect to the site or service you chose. Those third parties see the
requests. Section 3 lists exactly who.

---

## 1. Who we are

vigilant-core is free software released under the GNU General Public License,
version 3 or later. It is developed in the open; the source, issue tracker, and
commit history for the exact build you install are linked from its store listing.

- **Contact:** `karthikkunal@riseup.net`
- **Website / source:** <https://gitlab.com/karthikkunal/vigilant-core>

If you cannot reach us, opening an issue on the project's issue tracker is the
fastest route to a maintainer.

---

## 2. What we collect: nothing

The vigilant-core developers collect **no personal data, no usage data, and no
diagnostics**. Specifically, the app:

- creates no account and never asks you to sign in;
- sends nothing to any vigilant-core-controlled server, because there is none;
- embeds no analytics, advertising, attribution, or crash-reporting SDK;
- does not read your contacts, photos, files, location, microphone, camera,
  clipboard, or advertising identifier;
- does not sell, rent, or share anything with anyone.

Because we operate no server, we cannot see your data even in principle. Your
data is not exposed to us.

## 3. What leaves your device, and to whom

vigilant-core can only answer questions about a domain by asking someone who
already knows the answer. When you run a discovery scan, the **domain string you
entered** is sent to the following public services:

| Service | What it is asked for | Operator |
|---|---|---|
| `data.iana.org` | RDAP bootstrap registry (which RDAP server to use) | IANA / ICANN |
| A registry-specific RDAP host | Registration expiry, registrar, status, nameservers | The relevant domain registry (e.g. Verisign, RIPE NCC) |
| `cloudflare-dns.com` | DNS-over-HTTPS: A, AAAA, MX, NS, TXT, CAA records. **Not used on Android.** | Cloudflare |
| `crt.sh` | Certificate Transparency issuance history | crt.sh (Comodo / Sectigo) |
| `api.certspotter.com` | Certificate Transparency issuance history | Cert Spotter (DigiCert) |

The RDAP host is chosen at runtime from the IANA bootstrap, so the exact list of
registries contacted depends on the top-level domain you scanned.

### DNS on Android

On Android, DNS is resolved by the device's own resolver through
`android.net.DnsResolver`, which asks whichever DNS server the system is already
configured to use. No DNS query is sent to vigilant-core or to a resolver operator
on our behalf, so the domain you scan is not disclosed to Cloudflare or any other
DNS-over-HTTPS provider on that platform.

Those queries still reach your configured DNS server and its upstream providers,
which is inherent to using DNS. The scan screen's provider status names the
resolver that answered.

iOS and the web builds have no public API for querying arbitrary DNS record
types, so they continue to use the DNS-over-HTTPS service above.

Each of these services sees your IP address, the domain queried, and the
timestamp, and each has its own retention and logging practices. **Review those
policies before scanning a domain whose existence you need to keep private.**
Several of them (notably `crt.sh`) publish their query logs publicly.

Discovery also opens a TLS connection to the scanned domain itself, on port 443,
to read the certificate it presents. That connection goes to the domain's own
server, not to a third party.

### What monitors contact

Once you add a monitor, vigilant-core connects **directly to the site or service you
configured** — the host, and optionally the port or URL, that you entered:

- a **domain monitor** re-runs discovery against the services listed above;
- a **TCP monitor** opens a TCP connection to your chosen `host:port`;
- an **assertion monitor** issues an HTTP request to your chosen URL.

These are ordinary requests from your device to a server you already point the
app at, on the cadence you set. They carry your IP address, as any request to
that server would.

### Local-only processing

Parsing, comparison, expiry arithmetic, and every alert decision happen on your
device. Nothing you scan is sent to an AI service, a code-execution service, or
anywhere else.

## 4. What is stored, and where

All persistent state is written to **private app storage on your device only**
(Android: the app's `SharedPreferences`; iOS: the app's container). It is not
written to shared storage, not uploaded, and not readable by other apps.

| Stored | Why |
|---|---|
| Your monitor list (host, port/URL, cadence, thresholds, sound/vibration/quiet-hours settings, enabled state) | To run checks and alert you |
| The most recent check result per monitor (status, latency, error, timestamp) | To show "last checked" and detect stale results |
| Discovered report data for a domain you scanned | To render the report you are looking at |
| Notification permission state | To avoid re-prompting |
| Scheduled expiry reminders (30/14/7/1 days out) | So reminders fire even if you never reopen the app |

Deleting the app deletes all of it. There is no server-side copy and therefore no
account deletion flow — uninstalling is the complete erasure path. On Android
you can also clear it from **Settings → Apps → vigilant-core → Storage → Clear
data**.

### Copying your list out

**Settings → Site list** can copy your watched addresses to the clipboard, and
can read a list of addresses from it to add them.

That list contains **only addresses** — hostnames, IP addresses, and where they
are needed, a port or a full URL. It does not contain your cadence, latency
budget, failure thresholds, alert sounds, vibration or quiet-hours settings, or
any check result. Nothing is uploaded: the clipboard is the only destination, it
is the operating system's own buffer rather than vigilant-core storage, and control
of what leaves the device is yours — whatever you paste that list into is
something you chose.

Reading a list writes those addresses into the app's private storage as ordinary
monitors, each on the default settings, so treat a pasted list as you would treat
any other input.

## 5. Permissions, and why each is needed

| Permission | Why vigilant-core needs it |
|---|---|
| `INTERNET` | Perform discovery lookups and reach the hosts you monitor. |
| `POST_NOTIFICATIONS` (Android 13+) | Deliver alert pages and expiry reminders. Without it, no alerts. |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SPECIAL_USE` (Android) | Keep checking while the app is closed, which is the point of a pager. The service shows a persistent, non-dismissible notification. |
| `VIBRATE` | Vibrate on an alert page, per your per-monitor setting. |
| `USE_FULL_SCREEN_INTENT` (Android) | Raise a full-screen alert for an urgent page. On Android 14+ this is a special-access permission; if you revoke it, alerts still arrive as ordinary heads-up notifications. |
| `WAKE_LOCK` | Keep the CPU awake long enough to finish a check cycle and deliver a page. |
| `RECEIVE_BOOT_COMPLETED` | Restart monitoring after a reboot, so checks resume without you opening the app. |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (Android) | Optional. Lets you exempt vigilant-core from Doze so cadence-based checks stay on time. vigilant-core works without it, but Android may delay checks while the device is idle. |

vigilant-core does **not** request location, camera, microphone, contacts, storage,
or phone permissions. It does not use Bluetooth or NFC.

## 6. Notifications and sounds

Alerts are delivered as local notifications. Sound and vibration are chosen per
monitor, and a bundled alarm tone ships with the app — no audio is downloaded.
A bundled alarm sound exists so alerting still works with no network.

## 7. Children's privacy

vigilant-core is intended for adults and for organisations. It is not directed at
children, and because we collect nothing and operate no server, we do not knowingly
hold data from anyone, including children.

## 8. Third-party services and their own policies

The services in section 3 are operated by third parties, not by the vigilant-core
developers. Their use is subject to **their** terms and privacy policies:

- IANA / ICANN (RDAP bootstrap) — <https://www.iana.org/help/example-domain>
- Cloudflare DNS-over-HTTPS — <https://www.cloudflare.com/privacypolicy/>
- crt.sh — <https://crt.sh/>
- Cert Spotter (DigiCert) — <https://www.digicert.com/legal/privacy-policy>

As the operator of an app distributed through Google Play and the App Store, we
are required to disclose that these third parties receive the domain you query.
That disclosure is section 3 of this policy.

## 9. Security

Because all state is local and no credentials are involved, the main risks are
device-level. We ask for no passwords, and store no secrets. Release builds are
code-signed; Android release builds are minified and shrunk. We cannot guarantee
absolute security, and we do not transmit data that would be worth stealing,
because there is no transmission path to us.

## 10. Your choices and control

- **Stop all network use:** the app makes no requests until you scan or add a
  monitor. Revoking the `INTERNET` permission at the OS level makes it inert.
- **Delete everything:** uninstall the app, or clear its storage.
- **Withdraw a domain from monitoring:** remove the monitor, or disable it. To
  stop discovery entirely, remove the app.
- **Withdraw a domain from third-party logs:** you must contact those services
  directly; we have no ability to do so on your behalf.

## 11. Changes to this policy

If this policy changes materially, the new version will be published at the same
URL with an updated effective date, and the app's store listing will be updated.
Material changes will also be noted in the release notes.

## 12. Licence and source

The app is free software under the **GNU General Public License, version 3 or
later**. The full licence text is bundled in the app and published alongside the
source. You may copy, modify, and redistribute it under that licence, and — because
it is copyleft — if you distribute a modified version you must pass on the same
freedom and keep the licence.

---

*This policy covers the vigilant-core mobile apps. It does not cover the
third-party services listed in section 3, which have their own policies.*
