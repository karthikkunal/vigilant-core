import 'dart:convert';

import 'package:discovery_core/discovery_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  // A scan that falls back to a DoH service the user never chose has to name
  // it in the report, not just the protocol.
  test('sourceLabel names the endpoint that will answer', () {
    expect(
      DohClient().sourceLabel,
      'DNS-over-HTTPS · cloudflare-dns.com',
    );
    expect(
      DohClient(
        endpoint: Uri.parse('https://dns.example.com/dns-query'),
      ).sourceLabel,
      'DNS-over-HTTPS · dns.example.com',
    );
  });

  test('returns records grouped by type', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'cloudflare-dns.com');
      final type = request.url.queryParameters['type'];
      if (type == '16') {
        return http.Response(
          jsonEncode({
            'Answer': [
              {
                'name': 'example.com',
                'type': 16,
                'TTL': 300,
                'data': '"v=spf1 -all"'
              },
            ],
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'Answer': <Object>[]}), 200);
    });

    final set = await DohClient(client: client).lookup(
      'example.com',
      ['TXT', 'A'],
    );

    expect(set.ofType('TXT'), hasLength(1));
    expect(set.ofType('TXT').first.data, '"v=spf1 -all"');
    expect(set.ofType('A'), isEmpty);
  });

  test('rejects an unsupported record type', () async {
    final client = MockClient((request) async => http.Response('{}', 200));
    await expectLater(
      DohClient(client: client).query('example.com', 'PTR'),
      throwsA(isA<DiscoveryException>()),
    );
  });
}
