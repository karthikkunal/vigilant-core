import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/domain_input.dart';
import '../core/errors.dart';
import '../models/registration.dart';

/// Looks up domain registration data via RDAP, using the IANA bootstrap to
/// find each registry's server.
class RdapClient {
  RdapClient({
    http.Client? client,
    Uri? bootstrapUrl,
    this.timeout = const Duration(seconds: 20),
  })  : _client = client ?? http.Client(),
        _bootstrapUrl =
            bootstrapUrl ?? Uri.parse('https://data.iana.org/rdap/dns.json');

  final http.Client _client;
  final Uri _bootstrapUrl;
  final Duration timeout;

  Map<String, Uri>? _services;

  Future<Map<String, Uri>> _bootstrap() async {
    final cached = _services;
    if (cached != null) return cached;

    final response = await _client.get(_bootstrapUrl).timeout(timeout);
    if (response.statusCode != 200) {
      throw DiscoveryException('RDAP bootstrap: HTTP ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final services = (body['services'] as List<dynamic>?) ?? const [];

    final map = <String, Uri>{};
    for (final service in services) {
      final pair = service as List<dynamic>;
      final tlds = (pair[0] as List<dynamic>).cast<String>();
      final urls = (pair[1] as List<dynamic>).cast<String>();
      if (urls.isEmpty) continue;
      final raw = urls.first;
      final base = Uri.parse(raw.endsWith('/') ? raw : '$raw/');
      for (final tld in tlds) {
        map[tld.toLowerCase()] = base;
      }
    }
    return _services = map;
  }

  /// Returns registration data, or `null` when the TLD has no RDAP service.
  Future<RegistrationInfo?> lookup(DomainInput input) async {
    final services = await _bootstrap();
    final tldLabel = input.host.split('.').last;
    final base = services[tldLabel];
    if (base == null) return null;

    final uri = base.resolve('domain/${input.registrable}');
    final response = await _client.get(
      uri,
      headers: const {'accept': 'application/rdap+json'},
    ).timeout(timeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw DiscoveryException(
          'RDAP ${input.registrable}: HTTP ${response.statusCode}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return _parse(body, base.toString());
  }

  RegistrationInfo _parse(Map<String, dynamic> body, String source) {
    DateTime? expiresAt;
    DateTime? registeredAt;
    DateTime? lastChangedAt;

    for (final event in (body['events'] as List<dynamic>?) ?? const []) {
      final map = event as Map<String, dynamic>;
      final action = (map['eventAction'] as String?)?.toLowerCase();
      final date = DateTime.tryParse((map['eventDate'] as String?) ?? '');
      switch (action) {
        case 'expiration':
          expiresAt = date;
        case 'registration':
          registeredAt = date;
        case 'last changed':
          lastChangedAt = date;
      }
    }

    final statuses = ((body['status'] as List<dynamic>?) ?? const [])
        .cast<String>()
        .toList(growable: false);

    final nameservers = <String>[];
    for (final ns in (body['nameservers'] as List<dynamic>?) ?? const []) {
      final map = ns as Map<String, dynamic>;
      final name = (map['ldhName'] as String?)?.toLowerCase();
      if (name != null && name.isNotEmpty) nameservers.add(name);
    }

    return RegistrationInfo(
      expiresAt: expiresAt,
      registeredAt: registeredAt,
      lastChangedAt: lastChangedAt,
      registrar: _registrar(body),
      statuses: statuses,
      nameservers: nameservers,
      source: source,
    );
  }

  String? _registrar(Map<String, dynamic> body) {
    for (final entity in (body['entities'] as List<dynamic>?) ?? const []) {
      final map = entity as Map<String, dynamic>;
      final roles =
          ((map['roles'] as List<dynamic>?) ?? const []).cast<String>();
      if (!roles.map((r) => r.toLowerCase()).contains('registrar')) continue;

      final vcard = map['vcardArray'];
      if (vcard is List && vcard.length >= 2 && vcard[1] is List) {
        for (final field in vcard[1] as List<dynamic>) {
          if (field is List && field.isNotEmpty && field[0] == 'fn') {
            return field.length > 3 ? field[3] as String? : null;
          }
        }
      }
    }
    return null;
  }

  void close() => _client.close();
}
