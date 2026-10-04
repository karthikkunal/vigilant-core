/// One certificate in a presented TLS chain.
class ChainCertificate {
  const ChainCertificate({
    required this.subject,
    required this.issuer,
    this.notBefore,
    this.notAfter,
    this.isCa = false,
    this.fingerprintSha256,
  });

  final String subject;
  final String issuer;
  final DateTime? notBefore;
  final DateTime? notAfter;
  final bool isCa;
  final String? fingerprintSha256;

  bool isExpired(DateTime now) => notAfter?.isBefore(now) ?? false;

  int? daysRemaining(DateTime now) => notAfter?.difference(now).inDays;
}

/// The leaf certificate plus the chain the server actually presented.
class CertificateInfo {
  const CertificateInfo({
    required this.leaf,
    this.chain = const [],
    this.sans = const [],
    this.presentedIntermediates = 0,
    this.trusted,
  });

  final ChainCertificate leaf;
  final List<ChainCertificate> chain;
  final List<String> sans;

  /// How many intermediates the server sent (excluding the leaf).
  final int presentedIntermediates;

  /// Whether the platform trust store accepted the chain. Null when unknown.
  final bool? trusted;

  int? daysRemaining(DateTime now) => leaf.daysRemaining(now);

  /// A chain that verified locally but presented no intermediate is the classic
  /// "green in a browser, broken on Android" misconfiguration.
  bool get missingIntermediate => presentedIntermediates == 0;

  /// Any non-leaf certificate in the presented chain that has expired.
  bool hasExpiredIntermediate(DateTime now) =>
      chain.any((c) => c.isExpired(now));
}
