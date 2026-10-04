/// Thrown when a probe cannot complete (transport failure, bad response, or an
/// unusable input). The engine catches these per-probe so a partial report can
/// still be returned.
class DiscoveryException implements Exception {
  const DiscoveryException(this.message);

  final String message;

  @override
  String toString() => 'DiscoveryException: $message';
}
