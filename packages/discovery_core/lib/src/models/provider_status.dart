/// Availability of one external discovery source or direct probe.
enum ProviderHealth { healthy, degraded, down, unknown, skipped }

/// The result of one named provider/probe, including the source that answered.
class ProviderStatus {
  const ProviderStatus({
    required this.name,
    required this.status,
    this.source,
    this.detail,
  });

  final String name;
  final ProviderHealth status;
  final String? source;
  final String? detail;
}
