/// One Certificate Transparency log entry.
class CtEntry {
  const CtEntry({
    required this.id,
    required this.commonName,
    required this.issuerName,
    required this.nameValue,
    this.notBefore,
    this.notAfter,
  });

  final int id;
  final String commonName;
  final String issuerName;
  final String nameValue;
  final DateTime? notBefore;
  final DateTime? notAfter;

  /// Every name the certificate covers, split out of [nameValue].
  List<String> get names => nameValue
      .split('\n')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toList();
}

/// Certificate Transparency results for a domain.
class CtInfo {
  const CtInfo({
    required this.entries,
    required this.subdomains,
    this.source = 'crt.sh',
    this.isPartial = false,
  });

  final List<CtEntry> entries;

  /// Subdomains observed in public sources (excludes the base domain and wildcards).
  final Set<String> subdomains;

  /// The upstream source that supplied this result.
  final String source;

  /// Whether the source stopped before returning all available records.
  final bool isPartial;

  int get entryCount => entries.length;
}
