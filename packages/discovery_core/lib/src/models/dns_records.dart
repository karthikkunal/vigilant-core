/// One DNS answer.
class DnsRecord {
  const DnsRecord({
    required this.name,
    required this.type,
    required this.ttl,
    required this.data,
  });

  final String name;
  final String type;
  final int ttl;
  final String data;

  @override
  String toString() => '$type $name -> $data';
}

/// A set of DNS records grouped by type (A, AAAA, MX, NS, TXT, CAA, ...).
class DnsRecordSet {
  const DnsRecordSet(this.byType);

  final Map<String, List<DnsRecord>> byType;

  static const DnsRecordSet empty = DnsRecordSet({});

  List<DnsRecord> ofType(String type) => byType[type] ?? const [];

  Iterable<String> get types => byType.keys;
}
