import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/errors.dart';
import '../models/ct_entry.dart';

/// Certificate Transparency lookups with a resilient fallback.
///
/// These services are third-party (not servers of ours). crt.sh is frequently
/// slow or returns 502 under load, so the client falls back to Cert Spotter
/// before surfacing a probe error.
///
/// Both remaining sources return real certificate metadata, so a successful
/// lookup always carries issuance history rather than a bare host list.
class CtClient {
  CtClient({
    http.Client? client,
    Uri? endpoint,
    Uri? fallbackEndpoint,
    this.tryCrtSh = true,
    this.timeout = const Duration(seconds: 30),
    this.attempts = 2,
  })  : _client = client ?? http.Client(),
        _endpoint = endpoint ?? Uri.parse('https://crt.sh/'),
        _fallbackEndpoint = fallbackEndpoint ??
            Uri.parse('https://api.certspotter.com/v1/issuances');

  final http.Client _client;
  final Uri _endpoint;
  final Uri _fallbackEndpoint;

  /// Whether to query crt.sh. Disabled in browser builds, which cannot read its
  /// response cross-origin.
  final bool tryCrtSh;
  final Duration timeout;
  final int attempts;

  static const _maxFallbackPages = 10;

  Future<CtInfo> lookup(String domain) async {
    Object? primaryError;
    CtInfo? certificateInfo;
    if (tryCrtSh) {
      final uri = _endpoint.replace(
        queryParameters: {'q': '%.$domain', 'output': 'json'},
      );
      for (var attempt = 1; attempt <= attempts; attempt++) {
        try {
          final response = await _client.get(
            uri,
            headers: const {'accept': 'application/json'},
          ).timeout(timeout);
          if (response.statusCode == 200) {
            final parsed = _parse(response.body, domain);
            if (parsed.entries.isNotEmpty) certificateInfo = parsed;
            // Root and wildcard-only entries are not useful for this feature;
            // fall through to Cert Spotter when no concrete name is found.
            if (parsed.subdomains.isNotEmpty) {
              return parsed;
            }
            primaryError = const DiscoveryException(
              'crt.sh returned no certificate records',
            );
            break;
          }
          primaryError =
              DiscoveryException('crt.sh: HTTP ${response.statusCode}');
        } catch (error) {
          primaryError = error;
        }
        if (attempt < attempts) {
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        }
      }
    }

    Object? certSpotterError;
    try {
      final certSpotter = await _lookupCertSpotter(domain);
      if (certSpotter.entries.isNotEmpty) certificateInfo = certSpotter;
      if (certSpotter.subdomains.isNotEmpty) {
        return certSpotter;
      }
      certSpotterError = const DiscoveryException(
        'Cert Spotter returned no certificate records',
      );
    } catch (error) {
      certSpotterError = error;
    }

    if (certificateInfo != null) return certificateInfo;
    throw DiscoveryException(
      'Certificate Transparency lookup failed '
      '(${_errorText(primaryError)}; Cert Spotter: '
      '${_errorText(certSpotterError)})',
    );
  }

  Future<CtInfo> _lookupCertSpotter(String domain) async {
    final entries = <CtEntry>[];
    final subdomains = <String>{};
    Uri? next = _certSpotterUri(domain);
    String? previousAfter;

    for (var page = 0; page < _maxFallbackPages && next != null; page++) {
      http.Response response;
      try {
        response = await _client.get(
          next,
          headers: const {'accept': 'application/json'},
        ).timeout(timeout);
      } catch (_) {
        // A later page can be rate-limited or briefly unavailable. Keep the
        // names already collected instead of discarding a useful first page.
        if (entries.isNotEmpty) break;
        rethrow;
      }
      if (response.statusCode != 200) {
        if (entries.isNotEmpty) break;
        throw DiscoveryException(
          'Cert Spotter: HTTP ${response.statusCode}',
        );
      }

      final List<dynamic> rows;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is! List) {
          if (entries.isNotEmpty) break;
          throw const DiscoveryException('Cert Spotter returned invalid JSON');
        }
        rows = decoded;
      } catch (_) {
        if (entries.isNotEmpty) break;
        rethrow;
      }
      _mergeCertSpotterRows(rows, domain, entries, subdomains);

      final after = _nextAfter(response.headers['link'], rows);
      if (after == null || after == previousAfter) {
        next = null;
        break;
      }
      previousAfter = after;
      next = _certSpotterUri(domain, after: after);
      if (_rateLimitExhausted(response)) break;
    }

    return CtInfo(
      entries: entries,
      subdomains: subdomains,
      source: 'Cert Spotter',
      isPartial: next != null,
    );
  }

  void _mergeCertSpotterRows(
    List<dynamic> rows,
    String domain,
    List<CtEntry> entries,
    Set<String> subdomains,
  ) {
    final suffix = '.$domain';
    for (final row in rows) {
      if (row is! Map) continue;
      final map = row.cast<String, dynamic>();
      final rawNames = map['dns_names'];
      if (rawNames is! List) continue;
      final names = rawNames
          .whereType<String>()
          .map((name) => name.trim().toLowerCase())
          .where((name) => name.isNotEmpty)
          .toList(growable: false);
      if (names.isEmpty) continue;

      final id = int.tryParse('${map['id']}') ?? 0;
      final issuer = map['issuer'];
      final issuerMap = issuer is Map ? issuer.cast<String, dynamic>() : null;
      final issuerName = issuerMap == null
          ? 'Cert Spotter'
          : (issuerMap['name'] ?? issuerMap['friendly_name'] ?? 'Cert Spotter')
              .toString();
      final commonName = names.firstWhere(
        (name) => !name.startsWith('*.'),
        orElse: () => names.first,
      );
      entries.add(
        CtEntry(
          id: id,
          commonName: commonName,
          issuerName: issuerName,
          nameValue: names.join('\n'),
          notBefore: DateTime.tryParse('${map['not_before']}'),
          notAfter: DateTime.tryParse('${map['not_after']}'),
        ),
      );

      for (final name in names) {
        if (name.startsWith('*.') || name == domain || !name.endsWith(suffix)) {
          continue;
        }
        subdomains.add(name);
      }
    }
  }

  Uri _certSpotterUri(String domain, {String? after}) {
    final query = <String>[
      'domain=${Uri.encodeQueryComponent(domain)}',
      'include_subdomains=true',
      'expand=dns_names',
      'expand=issuer',
      if (after != null) 'after=${Uri.encodeQueryComponent(after)}',
    ].join('&');
    return _fallbackEndpoint.replace(query: query);
  }

  bool _rateLimitExhausted(http.Response response) =>
      int.tryParse(response.headers['x-ratelimit-remaining'] ?? '') == 0;

  String? _nextAfter(String? linkHeader, List<dynamic> rows) {
    if (linkHeader != null) {
      final match = RegExp(r'(?:[?&])after=([^&>]+)').firstMatch(linkHeader);
      if (match != null) {
        try {
          return Uri.decodeComponent(match.group(1)!);
        } catch (_) {
          // Fall back to the response body's final issuance ID.
        }
      }
    }

    // `Link` is not exposed to browser clients by every CORS implementation.
    // The API also documents the last issuance ID as the pagination cursor.
    if (rows.isEmpty || rows.last is! Map) return null;
    final id = (rows.last as Map)['id'];
    return id == null ? null : '$id';
  }

  CtInfo _parse(String body, String domain) {
    final rows = jsonDecode(body) as List<dynamic>;
    final entries = <CtEntry>[];
    final subdomains = <String>{};
    final suffix = '.$domain';

    for (final row in rows) {
      final map = row as Map<String, dynamic>;
      final nameValue = (map['name_value'] as String?) ?? '';
      entries.add(CtEntry(
        id: (map['id'] as num?)?.toInt() ?? 0,
        commonName: (map['common_name'] as String?) ?? '',
        issuerName: (map['issuer_name'] as String?) ?? '',
        nameValue: nameValue,
        notBefore: DateTime.tryParse((map['not_before'] as String?) ?? ''),
        notAfter: DateTime.tryParse((map['not_after'] as String?) ?? ''),
      ));

      for (final name in nameValue.split('\n')) {
        final n = name.trim().toLowerCase();
        if (n.isEmpty || n.startsWith('*.')) continue;
        if (n == domain || !n.endsWith(suffix)) continue;
        subdomains.add(n);
      }
    }

    return CtInfo(
      entries: entries,
      subdomains: subdomains,
      source: 'crt.sh',
    );
  }

  String _errorText(Object? error) => error?.toString() ?? 'unknown error';

  void close() => _client.close();
}
