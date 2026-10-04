import 'dart:convert';

import 'package:discovery_core/discovery_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Client _routingClient({bool ctFails = false}) {
  return MockClient((request) async {
    switch (request.url.host) {
      case 'data.iana.org':
        return http.Response(
          jsonEncode({
            'services': [
              [
                ['com'],
                ['https://rdap.registry.example/'],
              ],
            ],
          }),
          200,
        );
      case 'rdap.registry.example':
        return http.Response(
          jsonEncode({
            'events': [
              {
                'eventAction': 'expiration',
                'eventDate': '2027-08-13T04:00:00Z'
              },
            ],
            'status': ['client transfer prohibited'],
            'nameservers': [
              {'ldhName': 'NS1.EXAMPLE.COM'},
            ],
            'entities': [
              {
                'roles': ['registrar'],
                'vcardArray': [
                  'vcard',
                  [
                    ['fn', <String, String>{}, 'text', 'Example Registrar'],
                  ],
                ],
              },
            ],
          }),
          200,
        );
      case 'cloudflare-dns.com':
        final type = request.url.queryParameters['type'];
        final name = request.url.queryParameters['name'];
        if (type == '16' && name == 'example.com') {
          return http.Response(
            jsonEncode({
              'Answer': [
                {'name': name, 'type': 16, 'TTL': 300, 'data': '"v=spf1 -all"'},
              ],
            }),
            200,
          );
        }
        if (type == '16' && name == '_dmarc.example.com') {
          return http.Response(
            jsonEncode({
              'Answer': [
                {
                  'name': name,
                  'type': 16,
                  'TTL': 300,
                  'data': '"v=DMARC1; p=reject"',
                },
              ],
            }),
            200,
          );
        }
        if (type == '1') {
          return http.Response(
            jsonEncode({
              'Answer': [
                {'name': name, 'type': 1, 'TTL': 300, 'data': '93.184.216.34'},
              ],
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'Answer': <Object>[]}), 200);
      case 'crt.sh':
        if (ctFails) return http.Response('bad gateway', 502);
        return http.Response(
          jsonEncode([
            {
              'id': 1,
              'common_name': 'example.com',
              'issuer_name': 'C=US, O=Test CA',
              'name_value': 'example.com\nwww.example.com',
              'not_before': '2024-01-01T00:00:00',
              'not_after': '2025-01-01T00:00:00',
            },
          ]),
          200,
        );
      case 'example.com':
        return http.Response(
          'ok',
          200,
          headers: {'strict-transport-security': 'max-age=31536000'},
        );
      default:
        return http.Response('not found', 404);
    }
  });
}

DiscoveryEngine _engine(http.Client client, {bool webMode = false}) =>
    DiscoveryEngine(
      dns: DohClient(client: client),
      rdap: RdapClient(client: client),
      ct: CtClient(client: client, attempts: 1),
      http: HttpProbe(client: client),
      webMode: webMode,
    );

void main() {
  test('assembles a full report across every probe', () async {
    final report = await _engine(_routingClient()).discover('example.com');

    expect(report.input.registrable, 'example.com');
    expect(report.registration?.registrar, 'Example Registrar');
    expect(report.emailAuth?.hasSpf, isTrue);
    expect(report.emailAuth?.hasDmarc, isTrue);
    expect(report.dns.ofType('A'), hasLength(1));
    expect(report.ct?.subdomains, {'www.example.com'});
    expect(report.http?.statusCode, 200);
    expect(report.http?.hasHsts, isTrue);
    expect(report.errors, isEmpty);
    expect(report.isPartial, isFalse);
    expect(
      report.providerStatuses
          .firstWhere((status) => status.name == 'RDAP')
          .status,
      ProviderHealth.healthy,
    );
    expect(
      report.providerStatuses
          .firstWhere((status) => status.name == 'Certificate Transparency')
          .status,
      ProviderHealth.healthy,
    );
  });

  test('skips the direct HTTP probe in web mode', () async {
    final report = await _engine(
      _routingClient(),
      webMode: true,
    ).discover('example.com');

    // The web-safe engine avoids cross-origin requests to arbitrary targets.
    // The shared routing client would return an HTTP response if the probe ran.
    expect(report.http, isNull);
    expect(
      report.providerStatuses
          .firstWhere((status) => status.name == 'HTTP target')
          .status,
      ProviderHealth.skipped,
    );
  });

  test('keeps the report usable when one probe fails', () async {
    final report = await _engine(_routingClient(ctFails: true)).discover(
      'example.com',
    );

    expect(report.registration?.registrar, 'Example Registrar');
    expect(report.http?.statusCode, 200);
    expect(report.isPartial, isTrue);
    expect(report.errors.map((e) => e.probe), contains('ct'));
    expect(
      report.providerStatuses
          .firstWhere((status) => status.name == 'Certificate Transparency')
          .status,
      ProviderHealth.down,
    );
  });

  test('throws for input that is not a domain', () async {
    await expectLater(
      _engine(_routingClient()).discover('not a domain'),
      throwsA(isA<DiscoveryException>()),
    );
  });

  test('reports the resolver that answered as the DNS source', () async {
    final report = await _engine(_routingClient()).discover('example.com');

    // The host is named, not just the protocol: a scan that reached a
    // DNS-over-HTTPS service has to say which one.
    expect(
      report.providerStatuses
          .firstWhere((status) => status.name == 'DNS')
          .source,
      contains('DNS-over-HTTPS'),
    );
    expect(
      report.providerStatuses
          .firstWhere((status) => status.name == 'DNS')
          .source,
      contains('cloudflare-dns.com'),
    );
  });

  group('a resolver that cannot answer every type', () {
    /// Stands in for a platform resolver limited to address records.
    DnsClient addressOnly() => _PartialDnsClient();

    test('is reported as degraded rather than clean', () async {
      final engine = DiscoveryEngine(
        dns: addressOnly(),
        rdap: RdapClient(client: _routingClient()),
        ct: CtClient(client: _routingClient(), attempts: 1),
        webMode: true,
      );

      final report = await engine.discover('example.com');
      final status =
          report.providerStatuses.firstWhere((entry) => entry.name == 'DNS');

      expect(status.status, ProviderHealth.degraded);
      expect(status.detail, contains('TXT'));
      expect(status.detail, contains('MX'));
      expect(status.source, 'Test resolver');
    });

    test('never queries the types it cannot answer', () async {
      final client = _PartialDnsClient();
      final engine = DiscoveryEngine(
        dns: client,
        rdap: RdapClient(client: _routingClient()),
        ct: CtClient(client: _routingClient(), attempts: 1),
        webMode: true,
      );

      await engine.discover('example.com');

      expect(client.requested, isNot(contains('TXT')));
      expect(client.requested, isNot(contains('MX')));
      expect(client.requested, contains('A'));
    });
  });
}

/// A resolver that answers address records only, used to prove the engine
/// reports the gap instead of presenting an unqueried type as absent.
class _PartialDnsClient extends DnsClient {
  final List<String> requested = <String>[];

  @override
  Set<String> get supportedTypes => const {'A', 'AAAA'};

  @override
  String get sourceLabel => 'Test resolver';

  @override
  Future<List<DnsRecord>> query(String name, String type) async {
    requested.add(type);
    if (type == 'A') {
      return <DnsRecord>[
        const DnsRecord(
            name: 'example.com', type: 'A', ttl: 300, data: '192.0.2.1'),
      ];
    }
    return const <DnsRecord>[];
  }
}
