import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vigilant-core/discovery/dns_resolver.dart';
import 'package:vigilant-core/discovery/resolver_preference.dart';

/// The device resolver is the privacy-preserving default and is not reliable
/// everywhere: `android.net.DnsResolver` reads netd's resolver configuration
/// rather than the `getaddrinfo` path, and on an emulator it returns SERVFAIL for
/// names the platform itself resolves. Selecting it on platform alone meant a
/// scan there lost its DNS and email-authentication data with no recovery.
void main() {
  group('the device resolver path falls back', () {
    test(
      'a working device resolver is used and nothing is disclosed',
      () async {
        final primary = _FakeClient(
          label: 'Device resolver',
          answer: 'primary',
        );
        final fallback = _FakeClient(
          label: 'DNS-over-HTTPS · resolver.test',
          answer: 'fallback',
        );
        final client = FallbackDnsClient(primary: primary, fallback: fallback);

        final answers = await client.query('example.com', 'A');

        expect(answers.single.data, 'primary');
        expect(primary.calls, 1);
        expect(
          fallback.calls,
          0,
          reason: 'a working resolver needs no fallback',
        );
        expect(client.didFallBack, isFalse);
        expect(client.sourceLabel, 'Device resolver');
      },
    );

    test('a failing device resolver is replaced and the report says so', () async {
      final primary = _FakeClient(
        label: 'Device resolver',
        failWith: 'SERVFAIL: no answer from netd',
      );
      final fallback = _FakeClient(
        label: 'DNS-over-HTTPS · resolver.test',
        answer: 'fallback',
      );
      final client = FallbackDnsClient(primary: primary, fallback: fallback);

      final answers = await client.query('example.com', 'A');

      expect(answers.single.data, 'fallback');
      expect(client.didFallBack, isTrue);
      expect(client.primaryFailure, contains('SERVFAIL'));
      // The disclosure happens where the query happened, not only in settings.
      expect(client.sourceLabel, contains('resolver.test'));
      expect(client.sourceLabel, contains('device resolver unavailable'));
    });

    test('the failure latches, so one scan does not disclose seven times', () async {
      // A scan makes one bulk lookup plus seven DMARC/DKIM lookups. Retrying a
      // broken resolver each time would add timeouts and repeat the disclosure
      // for the same result.
      final primary = _FakeClient(
        label: 'Device resolver',
        failWith: 'SERVFAIL',
      );
      final fallback = _FakeClient(label: 'DNS-over-HTTPS · resolver.test');
      final client = FallbackDnsClient(primary: primary, fallback: fallback);

      for (var i = 0; i < 8; i++) {
        await client.query('example.com', 'TXT');
      }

      expect(primary.calls, 1, reason: 'the broken resolver was retried');
      expect(fallback.calls, 8);
    });

    test('a fallback that also fails surfaces its error', () async {
      // Recovering from the device resolver is a best effort. If the public
      // service is down too, the engine needs the real error to report DNS as
      // down, rather than an empty answer presented as "no records".
      final client = FallbackDnsClient(
        primary: _FakeClient(label: 'Device resolver', failWith: 'SERVFAIL'),
        fallback: _FakeClient(label: 'resolver.test', failWith: 'HTTP 503'),
      );

      await expectLater(
        client.query('example.com', 'A'),
        throwsA(
          isA<DiscoveryException>().having(
            (e) => e.message,
            'message',
            contains('503'),
          ),
        ),
      );
    });

    test('only record types both resolvers model are claimed', () {
      final client = FallbackDnsClient(
        primary: _FakeClient(
          label: 'Device resolver',
          supported: {'A', 'TXT', 'MX'},
        ),
        fallback: _FakeClient(label: 'resolver.test', supported: {'A', 'TXT'}),
      );

      expect(client.supportedTypes, {'A', 'TXT'});
    });

    test('closing reaches both resolvers', () {
      final primary = _FakeClient(label: 'Device resolver');
      final fallback = _FakeClient(label: 'resolver.test');
      FallbackDnsClient(primary: primary, fallback: fallback).close();

      expect(primary.closed, isTrue);
      expect(fallback.closed, isTrue);
    });
  });

  group('resolveDns', () {
    test('the device choice on Android is backed by a fallback', () {
      final choice = resolveDns(
        const ResolverPreference.device(),
        platform: TargetPlatform.android,
        isWeb: false,
      );

      // Not third-party as a *selection*: the device resolver is tried first,
      // and the report names anything used instead.
      expect(choice.usesThirdParty, isFalse);
      expect(choice.label, 'Device resolver');
      expect(choice.client, isA<FallbackDnsClient>());
    });

    test('a custom endpoint is never silently replaced', () {
      // The user named that service. Substituting a different one would
      // override an explicit privacy decision, so this path must not wrap.
      final choice = resolveDns(
        ResolverPreference.custom(
          Uri.parse('https://dns.example.com/dns-query'),
        ),
        platform: TargetPlatform.android,
        isWeb: false,
      );

      expect(choice.client, isNot(isA<FallbackDnsClient>()));
      expect(choice.usesThirdParty, isTrue);
      expect(choice.label, 'dns.example.com');
    });

    test(
      'platforms without a device resolver go straight to the public one',
      () {
        for (final platform in [
          TargetPlatform.iOS,
          TargetPlatform.macOS,
          TargetPlatform.windows,
          TargetPlatform.linux,
        ]) {
          final choice = resolveDns(
            const ResolverPreference.device(),
            platform: platform,
            isWeb: false,
          );
          expect(
            choice.client,
            isNot(isA<FallbackDnsClient>()),
            reason: '$platform has no platform resolver to fall back from',
          );
          expect(choice.usesThirdParty, isTrue);
        }
      },
    );

    test('the browser has no socket to fall back to', () {
      final choice = resolveDns(
        const ResolverPreference.device(),
        platform: TargetPlatform.android,
        isWeb: true,
      );

      expect(choice.client, isNot(isA<FallbackDnsClient>()));
      expect(choice.usesThirdParty, isTrue);
    });
  });
}

class _FakeClient implements DnsClient {
  _FakeClient({
    required this.label,
    this.answer = 'answer',
    this.failWith,
    Set<String>? supported,
  }) : supportedTypes = supported ?? DnsClient.typeCodes.keys.toSet();

  final String label;

  /// The record data this client returns, so a test can tell which one answered.
  final String answer;

  final String? failWith;
  @override
  final Set<String> supportedTypes;
  @override
  final Duration timeout = const Duration(seconds: 15);

  int calls = 0;
  bool closed = false;

  @override
  String get sourceLabel => label;

  @override
  Future<List<DnsRecord>> query(String name, String type) async {
    calls++;
    final failure = failWith;
    if (failure != null) throw DiscoveryException(failure);
    return [DnsRecord(name: name, type: type, ttl: 300, data: answer)];
  }

  @override
  Future<DnsRecordSet> lookup(String name, List<String> types) async {
    final byType = <String, List<DnsRecord>>{};
    for (final type in types) {
      final records = await query(name, type);
      if (records.isNotEmpty) byType[type] = records;
    }
    return DnsRecordSet(byType);
  }

  @override
  void close() => closed = true;
}
