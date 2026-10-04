/// Registration data from RDAP.
class RegistrationInfo {
  const RegistrationInfo({
    this.expiresAt,
    this.registeredAt,
    this.lastChangedAt,
    this.registrar,
    this.statuses = const [],
    this.nameservers = const [],
    this.source,
  });

  final DateTime? expiresAt;
  final DateTime? registeredAt;
  final DateTime? lastChangedAt;
  final String? registrar;
  final List<String> statuses;
  final List<String> nameservers;

  /// The RDAP base URL that answered.
  final String? source;

  int? daysUntilExpiry(DateTime now) => expiresAt?.difference(now).inDays;

  /// A status code that means the domain is at risk of deletion or transfer.
  ///
  /// RDAP status values are space-separated (`pending delete`), so they are
  /// normalised before matching.
  bool get hasRiskStatus => statuses.any((s) {
        final l = s.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
        return l.contains('pendingdelete') ||
            l.contains('redemption') ||
            l.contains('clienthold') ||
            l.contains('serverhold');
      });
}
