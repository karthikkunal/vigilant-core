# cert_chain

A Flutter plugin that captures the TLS certificate chain (leaf + intermediates) a
server actually presents.

## Licence

Copyright (C) 2026 vigilant-core contributors.

This package is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See [`LICENSE`](LICENSE) for the full text.

Dart's `SecureSocket` exposes only the leaf certificate, so full-chain inspection —
the signal that catches "looks fine in a browser, broken on Android" — is not
possible from the high-level HTTP stack. This plugin fills that gap.

## Usage

```dart
import 'package:cert_chain/cert_chain.dart';

final info = await CertChain.fetch('example.com');

info.leaf.subject;                  // CN
info.leaf.notAfter;                 // expiry
info.presentedIntermediates;        // intermediates the server sent
info.missingIntermediate;           // true when the server sent none
info.hasExpiredIntermediate(now);   // an intermediate has expired
info.trusted;                       // platform trust verdict (nullable)
```

## Design

Native returns **base64 DER + a trust verdict only**; all X.509 parsing happens once
in Dart (`basic_utils`), so no certificate logic is duplicated across Kotlin and
Swift. The parser is covered by a test against a real certificate fixture.

| Layer | Responsibility |
|---|---|
| Android (Kotlin) | `SSLContext` handshake; capture `session.peerCertificates` |
| iOS (Swift) | `URLSession` challenge → `SecTrustCopyCertificateChain` |
| Dart | Decode DER, parse, map to `CertificateInfo` |

An invalid or untrusted chain is still captured: a permissive trust manager on
Android (and cancelling the challenge on iOS) yields the presented chain regardless,
with trust reported separately.

## Testing

```bash
flutter test
```

The Android implementation compiles as part of the host app build; iOS requires
macOS to compile and validate.
