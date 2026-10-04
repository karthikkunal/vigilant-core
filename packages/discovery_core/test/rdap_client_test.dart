import 'dart:convert';

import 'package:discovery_core/discovery_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('parses registration data from RDAP', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'data.iana.org') {
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
      }
      if (request.url.host == 'rdap.registry.example') {
        expect(request.url.path, '/domain/example.com');
        return http.Response(
          jsonEncode({
            'events': [
              {
                'eventAction': 'expiration',
                'eventDate': '2027-08-13T04:00:00Z'
              },
              {
                'eventAction': 'registration',
                'eventDate': '1995-08-14T04:00:00Z'
              },
            ],
            'status': ['client transfer prohibited'],
            'nameservers': [
              {'ldhName': 'NS1.EXAMPLE.COM'},
              {'ldhName': 'NS2.EXAMPLE.COM'},
            ],
            'entities': [
              {
                'roles': ['registrar'],
                'vcardArray': [
                  'vcard',
                  [
                    ['version', <String, String>{}, 'text', '4.0'],
                    ['fn', <String, String>{}, 'text', 'Example Registrar'],
                  ],
                ],
              },
            ],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    final info = await RdapClient(client: client).lookup(
      DomainInput.tryParse('example.com')!,
    );

    expect(info, isNotNull);
    expect(info!.expiresAt, DateTime.utc(2027, 8, 13, 4));
    expect(info.registeredAt, DateTime.utc(1995, 8, 14, 4));
    expect(info.registrar, 'Example Registrar');
    expect(info.nameservers, ['ns1.example.com', 'ns2.example.com']);
    expect(info.hasRiskStatus, isFalse);
    expect(info.daysUntilExpiry(DateTime.utc(2027, 8, 12, 4)), 1);
  });

  test('returns null when the TLD has no RDAP service', () async {
    final client = MockClient((request) async {
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
    });

    final info = await RdapClient(client: client).lookup(
      DomainInput.tryParse('example.zz')!,
    );
    expect(info, isNull);
  });

  test('flags a risk status', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'data.iana.org') {
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
      }
      return http.Response(
        jsonEncode({
          'status': ['pending delete'],
          'events': <Object>[],
          'nameservers': <Object>[],
          'entities': <Object>[],
        }),
        200,
      );
    });

    final info = await RdapClient(client: client).lookup(
      DomainInput.tryParse('example.com')!,
    );
    expect(info!.hasRiskStatus, isTrue);
  });
}
