import 'dart:convert';

import 'package:discovery_core/discovery_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('collects entries and subdomains, ignoring wildcards', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'crt.sh');
      return http.Response(
        jsonEncode([
          {
            'id': 42,
            'common_name': 'example.com',
            'issuer_name': 'C=US, O=Example CA',
            'name_value': 'example.com\nwww.example.com\n*.example.com',
            'not_before': '2024-01-01T00:00:00',
            'not_after': '2025-01-01T00:00:00',
          },
        ]),
        200,
      );
    });

    final ct = await CtClient(client: client).lookup('example.com');

    expect(ct.entryCount, 1);
    expect(ct.subdomains, {'www.example.com'});
    expect(ct.entries.first.issuerName, contains('Example CA'));
  });

  test('can skip browser-incompatible CT sources', () async {
    final hosts = <String>[];
    final client = MockClient((request) async {
      hosts.add(request.url.host);
      if (request.url.host == 'api.certspotter.com') {
        return http.Response(
          jsonEncode([
            {
              'id': '1',
              'dns_names': ['api.example.com']
            },
          ]),
          200,
        );
      }
      return http.Response('not expected', 500);
    });

    final ct = await CtClient(
      client: client,
      attempts: 1,
      tryCrtSh: false,
      timeout: const Duration(seconds: 1),
    ).lookup('example.com');

    expect(ct.subdomains, {'api.example.com'});
    expect(hosts, everyElement('api.certspotter.com'));
    expect(hosts, isNot(contains('crt.sh')));
  });

  test('does not stop on certificate entries without concrete subdomains',
      () async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.host);
      if (request.url.host == 'crt.sh') {
        return http.Response('bad gateway', 502);
      }
      if (request.url.host == 'api.certspotter.com') {
        return http.Response(
          jsonEncode([
            {
              'id': '1',
              'dns_names': ['example.com', '*.example.com'],
              'issuer': {'name': 'Example CA'},
            },
          ]),
          200,
        );
      }
      return http.Response('not expected', 500);
    });

    final ct = await CtClient(
      client: client,
      attempts: 1,
      timeout: const Duration(seconds: 1),
    ).lookup('example.com');

    expect(ct.source, 'Cert Spotter');
    expect(ct.subdomains, isEmpty);
    // Cert Spotter keeps paginating until it runs out of rows, so assert the
    // order it was reached in and the exact set of hosts contacted.
    expect(requests.first, 'crt.sh');
    expect(requests.toSet(), {'crt.sh', 'api.certspotter.com'});
  });

  test('falls back to Cert Spotter and follows pagination', () async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      if (request.url.host == 'crt.sh') {
        return http.Response('bad gateway', 502);
      }
      if (request.url.queryParameters['after'] == null) {
        return http.Response(
          jsonEncode([
            {
              'id': '1',
              'dns_names': ['api.example.com', '*.example.com'],
              'issuer': {'name': 'Example CA'},
              'not_before': '2024-01-01T00:00:00Z',
              'not_after': '2025-01-01T00:00:00Z',
            },
          ]),
          200,
          headers: {
            'link':
                '<https://api.certspotter.com/issuances?after=2>; rel="next"',
          },
        );
      }
      return http.Response(
        jsonEncode([
          {
            'id': '2',
            'dns_names': ['cdn.example.com'],
            'issuer': {'friendly_name': 'Example CA'},
            'not_before': '2024-01-01T00:00:00Z',
            'not_after': '2025-01-01T00:00:00Z',
          },
        ]),
        200,
      );
    });

    final ct = await CtClient(
      client: client,
      attempts: 1,
      timeout: const Duration(seconds: 1),
    ).lookup('example.com');

    expect(ct.entryCount, 2);
    expect(ct.subdomains, {'api.example.com', 'cdn.example.com'});
    expect(requests.where((url) => url.host == 'crt.sh'), hasLength(1));
    expect(
      requests.where((url) => url.host == 'api.certspotter.com'),
      hasLength(2),
    );
  });

  test('uses the last issuance id when the Link header is unavailable',
      () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (request.url.host == 'crt.sh') {
        return http.Response('bad gateway', 502);
      }
      final after = request.url.queryParameters['after'];
      if (after == null) {
        return http.Response(
          jsonEncode([
            {
              'id': '1',
              'dns_names': ['api.example.com']
            },
          ]),
          200,
        );
      }
      if (after == '1') {
        return http.Response(
          jsonEncode([
            {
              'id': '2',
              'dns_names': ['cdn.example.com']
            },
          ]),
          200,
        );
      }
      return http.Response('[]', 200);
    });

    final ct = await CtClient(
      client: client,
      attempts: 1,
      timeout: const Duration(seconds: 1),
    ).lookup('example.com');

    expect(ct.subdomains, {'api.example.com', 'cdn.example.com'});
    expect(calls, 4);
  });

  test('keeps Cert Spotter results when a later page is rate limited',
      () async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      if (request.url.host == 'crt.sh') {
        return http.Response('bad gateway', 502);
      }
      if (request.url.host == 'api.certspotter.com') {
        if (request.url.queryParameters['after'] == null) {
          return http.Response(
            jsonEncode([
              {
                'id': '1',
                'dns_names': ['api.example.com'],
                'issuer': {'name': 'Example CA'},
              },
            ]),
            200,
            headers: {
              'link':
                  '<https://api.certspotter.com/issuances?after=2>; rel="next"',
            },
          );
        }
        return http.Response('rate limited', 429);
      }
      return http.Response('not expected', 500);
    });

    final ct = await CtClient(
      client: client,
      attempts: 1,
      timeout: const Duration(seconds: 1),
    ).lookup('example.com');

    expect(ct.source, 'Cert Spotter');
    expect(ct.isPartial, isTrue);
    expect(ct.subdomains, {'api.example.com'});
    expect(requests.where((url) => url.host == 'api.certspotter.com'),
        hasLength(2));
  });

  test('stops Cert Spotter pagination when the quota is exhausted', () async {
    var certSpotterCalls = 0;
    final client = MockClient((request) async {
      if (request.url.host == 'crt.sh') {
        return http.Response('bad gateway', 502);
      }
      if (request.url.host == 'api.certspotter.com') {
        certSpotterCalls++;
        return http.Response(
          jsonEncode([
            {
              'id': '1',
              'dns_names': ['api.example.com']
            },
          ]),
          200,
          headers: {
            'link':
                '<https://api.certspotter.com/issuances?after=2>; rel="next"',
            'x-ratelimit-remaining': '0',
          },
        );
      }
      return http.Response('not expected', 500);
    });

    final ct = await CtClient(
      client: client,
      attempts: 1,
      timeout: const Duration(seconds: 1),
    ).lookup('example.com');

    expect(ct.isPartial, isTrue);
    expect(ct.subdomains, {'api.example.com'});
    expect(certSpotterCalls, 1);
  });

  test('retries then throws when both CT sources fail', () async {
    final hosts = <String>[];
    final client = MockClient((request) async {
      hosts.add(request.url.host);
      return http.Response('bad gateway', 502);
    });

    await expectLater(
      CtClient(client: client, attempts: 2, timeout: const Duration(seconds: 1))
          .lookup('example.com'),
      throwsA(isA<DiscoveryException>()),
    );
    expect(hosts, ['crt.sh', 'crt.sh', 'api.certspotter.com']);
  });
}
