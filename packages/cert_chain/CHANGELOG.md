## 0.0.1

* Initial release: captures the TLS certificate chain a server presents, leaf
  plus intermediates, which Dart's `SecureSocket` does not expose.
* The handshake and the chain are captured natively (Kotlin on Android,
  `URLSession`/`SecTrust` on iOS) and parsed once in Dart, so there is one
  implementation of the X.509 reading rather than one per platform.
* Native work runs off the platform main thread and posts its result back,
  because a `MethodChannel.Result` must be invoked on the main thread and
  blocking it there is a hard failure on Android, not a slow scan.
