# system_dns

Resolves DNS through the device's own resolver instead of a public
DNS-over-HTTPS service.

On Android this uses `android.net.DnsResolver`, which answers over whichever
network the system is already using. A discovery scan therefore no longer
discloses the queried domain to a third-party resolver on that platform.

## How it works

`android.net.DnsResolver` exposes structured data only for A/AAAA, so this
plugin calls `rawQuery` and returns the raw DNS response bytes over the method
channel. Decoding happens once in Dart via `parseDnsResponse` in
`discovery_core`, matching how `cert_chain` keeps X.509 parsing in one place.

## Platform support

Android only. iOS and the web have no public API for arbitrary record types —
`getaddrinfo` answers A/AAAA alone — so DNS-over-HTTPS remains in use there.
`SystemDnsClient.isSupported()` reports `false` on those platforms so the app
can substitute a DoH client rather than present a resolver fault as an absent
record.

## Requirements

Android API 29 or newer, which is where `DnsResolver` was introduced. The app's
`minSdk` is raised to match.

## Licence

GPL-3.0-or-later.
