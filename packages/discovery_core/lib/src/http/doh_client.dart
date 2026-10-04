import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/errors.dart';
import '../models/dns_records.dart';
import 'dns_client.dart';

/// A DNS-over-HTTPS client using the JSON API.
///
/// A DoH endpoint is a third-party service, so the default is a named constant
/// rather than a bare literal in the constructor: it stays greppable, and
/// callers that care which service sees their queries pass [endpoint]
/// explicitly. The app passes the device resolver on platforms that have one
/// (see the `system_dns` package) and only reaches for [defaultEndpoint] when
/// the user has not chosen a resolver and the platform offers none.
class DohClient extends DnsClient {
  DohClient({
    http.Client? client,
    Uri? endpoint,
    super.timeout = const Duration(seconds: 15),
  })  : _client = client ?? http.Client(),
        _endpoint = endpoint ?? defaultEndpoint;

  /// Cloudflare's JSON API. Free to use, but a free service rather than free
  /// software, so a scan that reaches it discloses the queried name to a third
  /// party.
  static final Uri defaultEndpoint = Uri.parse(
    'https://cloudflare-dns.com/dns-query',
  );

  final http.Client _client;
  final Uri _endpoint;

  @override
  Set<String> get supportedTypes => DnsClient.typeCodes.keys.toSet();

  /// Names the endpoint that will answer, not just the protocol. A scan that
  /// falls back to a DoH service the user never chose has to say which one, at
  /// the point the disclosure happens rather than only in settings.
  @override
  String get sourceLabel => 'DNS-over-HTTPS · ${_endpoint.host}';

  /// Queries a single record [type] for [name].
  @override
  Future<List<DnsRecord>> query(String name, String type) async {
    final code = DnsClient.typeCodes[type];
    if (code == null) {
      throw DiscoveryException('Unsupported DNS type: $type');
    }
    final uri = _endpoint.replace(
      queryParameters: {'name': name, 'type': '$code'},
    );
    final response = await _client.get(
      uri,
      headers: const {'accept': 'application/dns-json'},
    ).timeout(timeout);
    if (response.statusCode != 200) {
      throw DiscoveryException('DoH $type $name: HTTP ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final answers = (body['Answer'] as List<dynamic>?) ?? const [];
    return answers.map((answer) {
      final map = answer as Map<String, dynamic>;
      return DnsRecord(
        name: (map['name'] as String?) ?? name,
        type: type,
        ttl: (map['TTL'] as int?) ?? 0,
        data: (map['data'] as String?) ?? '',
      );
    }).toList(growable: false);
  }

  @override
  void close() => _client.close();
}
