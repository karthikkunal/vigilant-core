# discovery_core

Pure-Dart discovery engine for vigilant-core. Given a domain, it collects:

- **Registration** — expiry, registration date, registrar, status codes, nameservers (RDAP)
- **DNS** — A / AAAA / MX / NS / TXT / CAA (any injected `DnsClient`)
- **Email auth** — SPF, DMARC, DKIM selectors, CAA (parsed from the above)
- **Certificate Transparency** — issuance entries and discovered subdomains (crt.sh)
- **HTTP** — status, redirect chain, HSTS and security-header posture
- **TCP checks** — one explicit host/port connection with timeout and latency budget
- **HTTP assertions** — literal response-body `contains` / `not-contains` rules

`DohClient` is the default resolver. The `system_dns` package supplies a second
implementation backed by the Android platform resolver; both satisfy the same
`DnsClient` interface, and raw DNS responses are decoded here by
`parseDnsResponse` so no wire-format parsing is duplicated per platform.

Reports also expose per-provider status for RDAP, DNS, HTTP, and Certificate
Transparency, including partial or unavailable sources. A resolver that cannot
answer every requested type is reported as degraded, naming the types it could
not answer, rather than presenting them as absent records.

It has **no Flutter dependency**. HTTP checks use an injectable `http.Client`, and
TCP checks use Dart's standard socket API. Both paths run in the caller's process and are unit-testable;
the TCP check opens only the single user-specified port.

## Licence

Copyright (C) 2026 vigilant-core contributors.

This package is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See the repository [`LICENSE`](../../LICENSE) for the full text.

TLS certificate capture is deliberately *not* here — the high-level HTTP stack cannot
see the chain. That lives in the `cert_chain` plugin.
