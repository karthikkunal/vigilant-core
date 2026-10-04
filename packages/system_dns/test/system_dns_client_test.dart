import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:system_dns/system_dns.dart';

/// A platform that answers from a canned response instead of the real resolver.
class _FakePlatform extends SystemDnsPlatform {
  _FakePlatform({required this.supported, this.respond});

  final bool supported;
  final List<int> Function(String name, int type)? respond;

  final List<String> queries = <String>[];

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<List<int>> queryRaw(
    String name,
    int typeCode, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    queries.add('${DnsClient.typeName(typeCode) ?? typeCode} $name');
    final handler = respond;
    if (handler == null) {
      throw PlatformException(code: 'QUERY_FAILED', message: 'no fixture');
    }
    return handler(name, typeCode);
  }
}

/// Builds a minimal NOERROR response with a single answer.
Uint8List _response(int type, List<int> rdata, {String name = 'example.com'}) {
  final bytes = <int>[];
  void u16(int v) => bytes.addAll(<int>[(v >> 8) & 0xFF, v & 0xFF]);
  void u32(int v) => bytes.addAll(<int>[
    (v >> 24) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 8) & 0xFF,
    v & 0xFF,
  ]);
  void writeName(String value) {
    for (final label in value.split('.')) {
      bytes
        ..add(label.length)
        ..addAll(label.codeUnits);
    }
    bytes.add(0);
  }

  u16(0x1234);
  u16(0x8180);
  u16(1); // QDCOUNT
  u16(1); // ANCOUNT
  u16(0);
  u16(0);
  writeName(name);
  u16(type);
  u16(1);
  writeName(name);
  u16(type);
  u16(1);
  u32(300);
  u16(rdata.length);
  bytes.addAll(rdata);
  return Uint8List.fromList(bytes);
}

Uint8List _rcode(int code) {
  final bytes = <int>[];
  void u16(int v) => bytes.addAll(<int>[(v >> 8) & 0xFF, v & 0xFF]);
  u16(0x1234);
  u16(0x8180 | code);
  u16(1);
  u16(0);
  u16(0);
  u16(0);
  bytes.addAll(<int>[7, ...'example'.codeUnits, 3, ...'com'.codeUnits, 0]);
  u16(1);
  u16(1);
  return Uint8List.fromList(bytes);
}

void main() {
  group('isSupported', () {
    test('is true when the platform answers', () async {
      final client = SystemDnsClient(platform: _FakePlatform(supported: true));
      expect(await client.isSupported(), isTrue);
    });

    test('is false when the platform cannot answer', () async {
      final client = SystemDnsClient(platform: _FakePlatform(supported: false));
      expect(await client.isSupported(), isFalse);
    });

    test('is asked only once per client', () async {
      final client = SystemDnsClient(platform: _FakePlatform(supported: true));
      await client.isSupported();
      await client.isSupported();
      await client.isSupported();
      expect(await client.isSupported(), isTrue);
    });
  });

  group('supportedTypes', () {
    test('covers every type the engine asks for', () {
      final client = SystemDnsClient(platform: _FakePlatform(supported: true));
      expect(
        client.supportedTypes,
        containsAll(<String>['A', 'AAAA', 'NS', 'MX', 'TXT', 'CAA']),
      );
    });
  });

  group('query', () {
    test('decodes an A answer', () async {
      final client = SystemDnsClient(
        platform: _FakePlatform(
          supported: true,
          respond: (name, type) => _response(type, <int>[93, 184, 216, 34]),
        ),
      );

      final answers = await client.query('example.com', 'A');

      expect(answers, hasLength(1));
      expect(answers.single.type, 'A');
      expect(answers.single.data, '93.184.216.34');
    });

    test('decodes a TXT answer', () async {
      final client = SystemDnsClient(
        platform: _FakePlatform(
          supported: true,
          respond: (name, type) {
            const value = 'v=spf1 -all';
            return _response(type, <int>[value.length, ...value.codeUnits]);
          },
        ),
      );

      final answers = await client.query('example.com', 'TXT');

      expect(answers.single.data, 'v=spf1 -all');
    });

    test('decodes an MX answer', () async {
      final client = SystemDnsClient(
        platform: _FakePlatform(
          supported: true,
          respond: (name, type) {
            final exchange = <int>[
              4,
              ...'mail'.codeUnits,
              7,
              ...'example'.codeUnits,
              3,
              ...'com'.codeUnits,
              0,
            ];
            return _response(type, <int>[0, 10, ...exchange]);
          },
        ),
      );

      final answers = await client.query('example.com', 'MX');

      expect(answers.single.data, '10 mail.example.com');
    });

    test('returns nothing for NXDOMAIN rather than failing', () async {
      final client = SystemDnsClient(
        platform: _FakePlatform(
          supported: true,
          respond: (name, type) => _rcode(3),
        ),
      );

      expect(await client.query('nope.example.com', 'A'), isEmpty);
    });

    test('rejects a type the client does not model', () async {
      final client = SystemDnsClient(platform: _FakePlatform(supported: true));
      await expectLater(
        client.query('example.com', 'SRV'),
        throwsA(isA<DiscoveryException>()),
      );
    });

    test('reports a resolver fault rather than an absent record', () async {
      final client = SystemDnsClient(
        platform: _FakePlatform(
          supported: true,
          respond: (name, type) => _rcode(2), // SERVFAIL
        ),
      );

      await expectLater(
        client.query('example.com', 'A'),
        throwsA(
          isA<DiscoveryException>().having(
            (e) => e.toString(),
            'message',
            contains('rcode 2'),
          ),
        ),
      );
    });

    test('reports an undecodable response', () async {
      final client = SystemDnsClient(
        platform: _FakePlatform(
          supported: true,
          respond: (name, type) => Uint8List.fromList(<int>[1, 2, 3]),
        ),
      );

      await expectLater(
        client.query('example.com', 'A'),
        throwsA(
          isA<DiscoveryException>().having(
            (e) => e.toString(),
            'message',
            contains('could not be decoded'),
          ),
        ),
      );
    });

    test('surfaces a platform failure as a discovery error', () async {
      final client = SystemDnsClient(platform: _FakePlatform(supported: true));

      await expectLater(
        client.query('example.com', 'A'),
        throwsA(
          isA<DiscoveryException>().having(
            (e) => e.toString(),
            'message',
            contains('no fixture'),
          ),
        ),
      );
    });

    test('refuses to query when the platform is unsupported', () async {
      final client = SystemDnsClient(platform: _FakePlatform(supported: false));

      await expectLater(
        client.query('example.com', 'A'),
        throwsA(
          isA<DiscoveryException>().having(
            (e) => e.toString(),
            'message',
            contains('unavailable'),
          ),
        ),
      );
    });
  });

  test('names itself as the device resolver', () {
    final client = SystemDnsClient(platform: _FakePlatform(supported: true));
    expect(client.sourceLabel, 'Device resolver');
  });
}
