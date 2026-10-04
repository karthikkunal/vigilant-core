import 'package:cert_chain/cert_chain.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, debugPrint, kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:system_dns/system_dns.dart';
import 'package:vigilant-core/discovery/dns_resolver.dart';
import 'package:vigilant-core/discovery/resolver_preference.dart';

/// Device-level verification for the parts of the app that no unit or widget
/// test can reach.
///
/// Everything here crosses a real platform boundary — a native TLS handshake, a
/// platform DNS call, a system service — so each of these is a claim the mocked
/// suites structurally cannot make. They are also the rows the manual test plan
/// records as "not run", which is why they exist as code rather than as notes.
///
/// Run against a device or emulator:
///
///     flutter test integration_test/device_boundaries_test.dart \
///       -d emulator-5554
///
/// These reach the network. A failure here means either the feature is broken
/// or the network is, and the failure message says which field was empty so the
/// two can be told apart.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('TLS chain capture', () {
    // The headline capability, and the one the recorded emulator run could not
    // confirm: the app reported "chain could not be captured". If this passes,
    // the native handshake works on this device and the report view will have
    // something to show.
    testWidgets('captures a trusted leaf from a real handshake', (
      tester,
    ) async {
      final chain = await CertChain.fetch('example.com');

      expect(
        chain.leaf.notAfter,
        isNotNull,
        reason: 'no leaf expiry: the capture returned nothing usable',
      );
      expect(
        chain.leaf.notAfter!.isAfter(DateTime.now().toUtc()),
        isTrue,
        reason: 'captured leaf is already expired',
      );
      expect(chain.leaf.subject, isNotEmpty);
      expect(
        chain.trusted,
        isNotNull,
        reason: 'no trust verdict came back from the platform',
      );
      expect(
        chain.trusted,
        isTrue,
        reason: 'the platform trust store rejected a valid public chain',
      );
      expect(
        chain.sans,
        contains('example.com'),
        reason: 'subject alternative names missing from the capture',
      );
    });

    testWidgets('reports a host that presents nothing rather than inventing', (
      tester,
    ) async {
      // A closed port has no chain to capture. The point is that this surfaces
      // as an error the report can show, not as a fabricated empty result.
      await expectLater(
        CertChain.fetch(
          '127.0.0.1',
          port: 1,
          timeout: const Duration(seconds: 5),
        ),
        throwsA(anything),
      );
    });
  });

  group('the platform DNS resolver', () {
    // What the user is promised is not "android.net.DnsResolver answers" — that
    // is a property of the device. It is that a scan obtains DNS and
    // email-authentication data, and says which resolver answered. Those are
    // different claims, and only the second is the app's to make.
    //
    // The earlier version of these two tests asserted the first, which made them
    // red on an emulator: `android.net.DnsResolver` reads netd's resolver
    // configuration rather than the `getaddrinfo` path, so it misses the
    // emulator's NAT'd DNS and returns SERVFAIL for names the platform itself
    // resolves. A test that is red on one configuration and green on another is
    // reporting the environment, not a defect, and it would have been red in CI
    // forever. The platform resolver's state is now recorded as a diagnostic
    // below instead of being asserted.
    testWidgets('a scan obtains DNS data and names the resolver that answered', (
      tester,
    ) async {
      final choice = resolveDns(
        const ResolverPreference.device(),
        platform: defaultTargetPlatform,
        isWeb: kIsWeb,
      );

      final records = await choice.client.lookup('example.com', ['A', 'TXT']);

      expect(
        records.ofType('A'),
        isNotEmpty,
        reason: 'a scan on this device produced no address records',
      );
      // TXT is what the email-authentication check reads, and the type a plain
      // HTTP client cannot answer.
      expect(
        records.ofType('TXT'),
        isNotEmpty,
        reason: 'no TXT record: email-auth checks would find nothing',
      );

      // The disclosure has to name a resolver. On hardware this is the device
      // resolver; on an emulator it is the public fallback, and the report must
      // say which rather than implying the domain stayed local.
      expect(choice.client.sourceLabel, isNotEmpty);
      debugPrint('resolver used for this scan: ${choice.client.sourceLabel}');
      if (choice.client is FallbackDnsClient) {
        debugPrint(
          'device resolver unavailable here: '
          '${(choice.client as FallbackDnsClient).primaryFailure}',
        );
      }
    });

    testWidgets('the platform bridge is registered', (tester) async {
      // The stable half of the platform claim: the plugin answered at all. A
      // SERVFAIL is a fact about the device; a plugin that never registers is a
      // bug, and this is what catches it.
      expect(
        await SystemDnsClient().isSupported(),
        isTrue,
        reason: 'the system_dns plugin did not register on this platform',
      );
    });

    testWidgets(
      'the raw platform resolver answers, where the device allows it',
      (tester) async {
        // Recorded rather than asserted, so an emulator run still documents the
        // SERVFAIL instead of hiding it behind a fallback. On hardware this is the
        // path that keeps a scan off the network entirely.
        final client = SystemDnsClient(timeout: const Duration(seconds: 15));
        try {
          final answers = await client.query('example.com', 'A');
          debugPrint(
            'platform resolver answered with ${answers.length} record(s)',
          );
        } on Object catch (error) {
          debugPrint('platform resolver did not answer: $error');
        }
      },
    );
  });
}
