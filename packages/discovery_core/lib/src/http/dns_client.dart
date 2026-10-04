import '../core/errors.dart';
import '../models/dns_records.dart';

/// A source that can answer DNS questions for the discovery engine.
///
/// Two implementations exist: [DohClient], which asks a public resolver over
/// HTTPS, and the platform resolver exposed by the `system_dns` package, which
/// asks the device's own resolver. They are interchangeable so the engine can
/// prefer whichever is available without changing what it reports.
abstract class DnsClient {
  DnsClient({this.timeout = const Duration(seconds: 15)});

  /// RR type codes for the record types vigilant-core asks about.
  ///
  /// Shared so every client and the platform bridge agree on the numbering.
  static const Map<String, int> typeCodes = <String, int>{
    'A': 1,
    'NS': 2,
    'CNAME': 5,
    'SOA': 6,
    'MX': 15,
    'TXT': 16,
    'AAAA': 28,
    'CAA': 257,
  };

  static const Map<int, String> _typeNames = <int, String>{
    1: 'A',
    2: 'NS',
    5: 'CNAME',
    6: 'SOA',
    15: 'MX',
    16: 'TXT',
    28: 'AAAA',
    257: 'CAA',
  };

  /// The name for an RR type code, or `null` for a type vigilant-core does not model.
  static String? typeName(int code) => _typeNames[code];

  final Duration timeout;

  /// The record types this client can answer on the current platform.
  ///
  /// The engine drops anything outside this set and reports the gap in the DNS
  /// provider status rather than presenting an absent record as a real answer.
  Set<String> get supportedTypes;

  /// A short label naming the resolver, shown as the provider source.
  String get sourceLabel;

  /// Queries a single record [type] and returns the answers, possibly empty.
  ///
  /// Throws [DiscoveryException] when the query fails for a reason other than
  /// the name not existing, so callers can tell "no such record" from "no
  /// answer available".
  Future<List<DnsRecord>> query(String name, String type);

  /// Queries every type in [types] concurrently and returns the non-empty
  /// results grouped by type.
  Future<DnsRecordSet> lookup(String name, List<String> types) async {
    final byType = <String, List<DnsRecord>>{};
    await Future.wait(types.map((type) async {
      final records = await query(name, type);
      if (records.isNotEmpty) byType[type] = records;
    }));
    return DnsRecordSet(byType);
  }

  void close() {}
}
