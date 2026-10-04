import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/material.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:system_dns/system_dns.dart' show SystemDnsClient;
import 'package:vigilant-core/discovery/dns_resolver.dart';
import 'package:vigilant-core/discovery/resolver_preference.dart';

/// `Uri.https` is not a const constructor, so the custom endpoint is built once
/// here rather than inline.
final Uri _customEndpoint = Uri.https('dns.example.com', '/dns-query');

void main() {
  group('ResolverPreference.decode', () {
    test('an absent setting yields the device resolver', () {
      expect(
        ResolverPreference.decode(null).mode,
        ResolverMode.device,
        reason: 'first run must not fall back to a third-party resolver',
      );
      expect(ResolverPreference.decode('   ').mode, ResolverMode.device);
    });

    test('round-trips a custom endpoint', () {
      final original = ResolverPreference.custom(_customEndpoint);
      final decoded = ResolverPreference.decode(original.encode());
      expect(decoded.mode, ResolverMode.custom);
      expect(decoded.endpoint, original.endpoint);
    });

    test('rejects a plaintext endpoint so queries stay encrypted', () {
      final decoded = ResolverPreference.decode(
        '{"mode":"custom","endpoint":"http://dns.example.com/dns-query"}',
      );
      expect(
        decoded.mode,
        ResolverMode.device,
        reason: 'an http endpoint would send queries in the clear',
      );
      expect(decoded.endpoint, isNull);
    });

    test('falls back to the device resolver on corrupt payloads', () {
      for (final raw in [
        'not json',
        '[]',
        '{"mode":"custom"}',
        '{"mode":"custom","endpoint":"not a url"}',
      ]) {
        expect(
          ResolverPreference.decode(raw).mode,
          ResolverMode.device,
          reason: 'a bad setting must not brick discovery: $raw',
        );
      }
    });
  });

  group('resolveDns', () {
    const device = ResolverPreference.device();
    final custom = ResolverPreference.custom(_customEndpoint);

    test('device mode on Android stays on the device', () {
      final choice = resolveDns(
        device,
        platform: TargetPlatform.android,
        isWeb: false,
      );

      // The device resolver is tried first, with a public endpoint behind it as a
      // recovery path. Asserting the wrapper rather than the inner client keeps
      // this test about the guarantee — that device mode does not go straight to
      // a third party — instead of about which class does the asking. The
      // fallback's own behaviour is covered in `dns_fallback_test.dart`.
      expect(choice.client, isA<FallbackDnsClient>());
      expect(
        (choice.client as FallbackDnsClient).primary,
        isA<SystemDnsClient>(),
        reason: 'the device resolver must be tried before any public service',
      );
      expect(choice.label, 'Device resolver');
      expect(
        choice.usesThirdParty,
        isFalse,
        reason: 'no third party should see scanned domains by default',
      );
    });

    test('device mode off Android falls back and says so', () {
      for (final platform in [
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
      ]) {
        final choice = resolveDns(device, platform: platform, isWeb: false);
        expect(choice.client, isA<DohClient>(), reason: '$platform');
        expect(choice.usesThirdParty, isTrue, reason: '$platform');
        expect(choice.label, contains('fallback'), reason: '$platform');
      }
    });

    test('device mode in a browser falls back', () {
      final choice = resolveDns(
        device,
        platform: TargetPlatform.android,
        isWeb: true,
      );
      expect(choice.client, isA<DohClient>());
      expect(choice.usesThirdParty, isTrue);
    });

    test('custom mode uses the named endpoint on every platform', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        final choice = resolveDns(custom, platform: platform, isWeb: false);
        expect(choice.client, isA<DohClient>(), reason: '$platform');
        expect(choice.label, 'dns.example.com');
        expect(choice.usesThirdParty, isTrue, reason: '$platform');
      }
    });

    test('a custom endpoint is honoured in a browser too', () {
      final choice = resolveDns(
        custom,
        platform: TargetPlatform.android,
        isWeb: true,
      );
      expect(choice.client, isA<DohClient>());
      expect(choice.label, 'dns.example.com');
    });
  });

  group('resolverFallbackReason', () {
    test('is empty when the device resolver is actually used', () {
      expect(
        resolverFallbackReason(
          const ResolverPreference.device(),
          platform: TargetPlatform.android,
          isWeb: false,
        ),
        isEmpty,
      );
    });

    test('explains itself when a fallback is in play', () {
      expect(
        resolverFallbackReason(
          const ResolverPreference.device(),
          platform: TargetPlatform.iOS,
          isWeb: false,
        ),
        contains('no public resolver API'),
      );
      expect(
        resolverFallbackReason(
          const ResolverPreference.device(),
          platform: TargetPlatform.android,
          isWeb: true,
        ),
        contains('browser'),
      );
    });

    test('says nothing for an explicit custom endpoint', () {
      expect(
        resolverFallbackReason(
          ResolverPreference.custom(_customEndpoint),
          platform: TargetPlatform.iOS,
          isWeb: false,
        ),
        isEmpty,
      );
    });
  });
}
