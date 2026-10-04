import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vigilant-core/discovery/domain_report_view.dart';
import 'package:vigilant-core/discovery/drift_store.dart';
import 'package:vigilant-core/theme/vigilant-core_theme.dart';

void main() {
  group('InMemoryDriftStore', () {
    test('has no baseline for a domain it has never seen', () async {
      expect(await InMemoryDriftStore().baseline('example.com'), isNull);
    });

    test('round-trips a baseline', () async {
      final store = InMemoryDriftStore();
      final snapshot = DomainSnapshot(
        at: DateTime.utc(2026, 9, 27),
        facts: const {'dns.A': '192.0.2.1'},
      );

      await store.record('example.com', snapshot);

      expect((await store.baseline('example.com'))!.facts, {
        'dns.A': '192.0.2.1',
      });
    });

    test('keeps domains apart', () async {
      final store = InMemoryDriftStore();
      await store.record('a.example', _snapshot('1.1.1.1'));
      await store.record('b.example', _snapshot('2.2.2.2'));

      expect((await store.baseline('a.example'))!.facts['dns.A'], '1.1.1.1');
      expect((await store.baseline('b.example'))!.facts['dns.A'], '2.2.2.2');
    });

    test('forget drops only the named domain', () async {
      final store = InMemoryDriftStore();
      await store.record('a.example', _snapshot('1.1.1.1'));
      await store.record('b.example', _snapshot('2.2.2.2'));

      await store.forget('a.example');

      expect(await store.baseline('a.example'), isNull);
      expect(await store.baseline('b.example'), isNotNull);
    });
  });

  group('DriftRecorder', () {
    test('a first scan reports a kept baseline and no comparison', () async {
      final outcome = await DriftRecorder(InMemoryDriftStore())
          .compare(report: _report());

      expect(outcome.baselineRecorded, isTrue);
      expect(outcome.hasComparison, isFalse);
    });

    test('a first scan makes the second scan able to answer', () async {
      final store = InMemoryDriftStore();
      final recorder = DriftRecorder(store);

      await recorder.compare(report: _report());
      final second = await recorder.compare(
        report: _report(
          emailAuth: const EmailAuthInfo(dmarc: 'v=DMARC1; p=reject'),
        ),
      );

      expect(second.hasComparison, isTrue);
      expect(
        second.drift!.differences.map((d) => d.key),
        contains('email.dmarc'),
      );
    });

    test('reports no change when a repeat scan matches', () async {
      final store = InMemoryDriftStore();
      final recorder = DriftRecorder(store);

      await recorder.compare(report: _report());
      final second = await recorder.compare(report: _report());

      expect(second.hasComparison, isTrue);
      expect(second.drift!.hasChanges, isFalse);
    });

    test('a failing store costs history, not the scan', () async {
      final outcome = await DriftRecorder(_ExplodingStore())
          .compare(report: _report());

      expect(outcome.baselineRecorded, isFalse);
      expect(outcome.hasComparison, isFalse);
    });

    test(
      'a declining CT probe on the second scan is not reported as change',
      () async {
        final store = InMemoryDriftStore();
        final recorder = DriftRecorder(store);

        await recorder.compare(report: _report());
        final second = await recorder.compare(
          report: _report(includeCt: false, ct: null),
        );

        expect(second.drift!.differences, isEmpty);
      },
    );

    test('forget returns whether the baseline went away', () async {
      final store = InMemoryDriftStore();
      final recorder = DriftRecorder(store);
      await recorder.compare(report: _report());

      expect(await recorder.forget('example.com'), isTrue);
      expect(await store.baseline('example.com'), isNull);
      expect(
        await DriftRecorder(_ExplodingStore()).forget('example.com'),
        isFalse,
      );
    });
  });

  group('drift section', () {
    testWidgets('says nothing when there is neither drift nor a baseline', (
      tester,
    ) async {
      await tester.pumpWidget(_view(drift: null, isBaseline: false));
      expect(find.textContaining('First scan'), findsNothing);
      expect(find.textContaining('Changed since'), findsNothing);
    });

    testWidgets('tells the user a baseline was kept', (tester) async {
      await tester.pumpWidget(_view(drift: null, isBaseline: true));

      expect(find.text('First scan on this device'), findsOneWidget);
      expect(find.textContaining('Scan it again'), findsOneWidget);
    });

    testWidgets('leads with the changes worth acting on', (tester) async {
      final current = _report();
      // Start from the facts this scan actually produced, so the only
      // differences are the two under test rather than every other fact reading
      // as an addition.
      final before = Map<String, String>.from(snapshotFacts(current))
        // DMARC has been withdrawn since the last scan.
        ..['email.dmarc'] = 'v=DMARC1; p=none'
        // The address has moved.
        ..['dns.A'] = '198.51.100.9';

      final drift = diffReports(
        report: current,
        previous: DomainSnapshot(at: DateTime.utc(2026, 9, 1), facts: before),
      );
      expect(drift.differences, hasLength(2));

      await tester.pumpWidget(_view(drift: drift, isBaseline: false));

      expect(find.textContaining('Changed since'), findsOneWidget);
      expect(find.text('DMARC policy'), findsOneWidget);
      expect(find.text('1 of 2 change(s) worth acting on'), findsOneWidget);
      // The routine change is listed, but behind a collapsed header.
      expect(find.text('Addresses (A)'), findsNothing);
      expect(find.text('1 other change(s)'), findsOneWidget);
    });

    testWidgets('reports no change plainly', (tester) async {
      final drift = diffReports(
        report: _report(),
        previous: DomainSnapshot(
          at: DateTime.utc(2026, 9, 1),
          facts: snapshotFacts(_report()),
        ),
      );

      await tester.pumpWidget(_view(drift: drift, isBaseline: false));

      expect(find.textContaining('No change since'), findsOneWidget);
    });

    testWidgets('names the areas a partial scan did not compare', (
      tester,
    ) async {
      // A scan that answered nothing has nothing to claim, and must not say so
      // quietly — a reader who trusts "no change" has to know it was partial.
      final drift = diffReports(
        report: _report(includeCt: false, ct: null),
        previous: DomainSnapshot(
          at: DateTime.utc(2026, 9, 1),
          facts: const {'ct.subdomains': 'www.example.com'},
        ),
      );

      await tester.pumpWidget(_view(drift: drift, isBaseline: false));

      expect(find.textContaining('Not compared'), findsOneWidget);
      expect(find.textContaining('Certificate Transparency'), findsWidgets);
    });

    testWidgets('offers to forget the baseline when asked', (tester) async {
      var forgotten = false;
      await tester.pumpWidget(
        _view(drift: null, isBaseline: true, onForget: () => forgotten = true),
      );

      await tester.tap(find.text('Forget this baseline'));
      expect(forgotten, isTrue);
    });

    testWidgets('renders a removed value as removed, not as a blank', (
      tester,
    ) async {
      final drift = diffReports(
        report: _report(
          dns: const DnsRecordSet({
            'A': [
              DnsRecord(
                name: 'example.com',
                type: 'A',
                ttl: 300,
                data: '192.0.2.1',
              ),
            ],
          }),
        ),
        previous: DomainSnapshot(
          at: DateTime.utc(2026, 9, 1),
          facts: const {'dns.MX': '10 mail.example.com'},
        ),
      );

      await tester.pumpWidget(_view(drift: drift, isBaseline: false));

      expect(find.text('Mail exchangers'), findsOneWidget);
      expect(find.text('Removed: 10 mail.example.com'), findsOneWidget);
    });
  });
}

Widget _view({
  required DriftReport? drift,
  required bool isBaseline,
  VoidCallback? onForget,
}) {
  return MaterialApp(
    theme: buildvigilant-coreTheme(brightness: Brightness.light),
    home: Scaffold(
      body: SingleChildScrollView(
        child: DomainReportView(
          report: _report(),
          certificate: null,
          drift: drift,
          isBaseline: isBaseline,
          onForgetBaseline: onForget,
        ),
      ),
    ),
  );
}

DomainSnapshot _snapshot(String address) =>
    DomainSnapshot(at: DateTime.utc(2026, 9, 27), facts: {'dns.A': address});

DomainReport _report({
  DnsRecordSet? dns,
  EmailAuthInfo? emailAuth,
  CtInfo? ct,
  bool includeCt = true,
}) {
  return DomainReport(
    input: DomainInput.tryParse('example.com')!,
    fetchedAt: DateTime.utc(2026, 9, 27),
    registration: const RegistrationInfo(registrar: 'Example Registrar'),
    dns:
        dns ??
        const DnsRecordSet({
          'A': [
            DnsRecord(
              name: 'example.com',
              type: 'A',
              ttl: 300,
              data: '192.0.2.1',
            ),
          ],
          'MX': [
            DnsRecord(
              name: 'example.com',
              type: 'MX',
              ttl: 300,
              data: '10 mail.example.com',
            ),
          ],
        }),
    emailAuth: emailAuth ?? const EmailAuthInfo(spf: 'v=spf1 -all'),
    ct: ct ?? const CtInfo(entries: [], subdomains: {'www.example.com'}),
    http: const HttpFindings(statusCode: 200, hsts: 'max-age=31536000'),
    includeCt: includeCt,
  );
}

/// A store whose every operation fails, standing in for a device that will not
/// answer — the case drift must survive without taking the scan with it.
class _ExplodingStore implements DriftStore {
  @override
  Future<DomainSnapshot?> baseline(String host) async =>
      throw StateError('no storage');

  @override
  Future<void> record(String host, DomainSnapshot snapshot) async =>
      throw StateError('no storage');

  @override
  Future<void> forget(String host) async => throw StateError('no storage');
}
