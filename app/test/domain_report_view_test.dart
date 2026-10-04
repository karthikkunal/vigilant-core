import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vigilant-core/discovery/domain_report_view.dart';
import 'package:vigilant-core/theme/vigilant-core_theme.dart';

void main() {
  testWidgets('report view leads with a verdict and keeps details readable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final input = DomainInput.tryParse('example.com')!;
    final report = DomainReport(
      input: input,
      fetchedAt: DateTime.utc(2026, 1, 1),
      registration: RegistrationInfo(
        expiresAt: DateTime.utc(2026, 8, 1),
        registrar: 'Example Registrar',
      ),
      dns: DnsRecordSet({
        'A': [
          DnsRecord(
            name: 'example.com',
            type: 'A',
            ttl: 300,
            data: '192.0.2.1',
          ),
        ],
      }),
      emailAuth: const EmailAuthInfo(
        spf: 'v=spf1 -all',
        dmarc: 'v=DMARC1; p=none',
      ),
      http: const HttpFindings(statusCode: 200, hsts: 'max-age=31536000'),
      ct: const CtInfo(
        entries: [],
        subdomains: {'api.apps.example.com', 'cdn.example.com'},
        source: 'Cert Spotter',
      ),
    );

    List<String>? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildvigilant-coreTheme(brightness: Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DomainReportView(
              report: report,
              certificate: null,
              onWatchSubdomains: (domains) async => selected = domains,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Scan result'), findsOneWidget);
    expect(find.text('At a glance'), findsOneWidget);
    expect(find.text('Detailed checks'), findsOneWidget);
    expect(find.text('2 found'), findsOneWidget);
    expect(find.textContaining('Subdomains found'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
    expect(find.text('api.apps.example.com'), findsOneWidget);
    expect(find.text('Relative levels'), findsOneWidget);
    expect(find.text('Level 1 · 1 hosts'), findsOneWidget);
    expect(find.text('Level 2 · 1 hosts'), findsOneWidget);
    final branchTile = tester.widget<ListTile>(find.byType(ListTile).at(1));
    expect((branchTile.title! as Text).data, 'apps.example.com');

    await tester.ensureVisible(find.byType(Checkbox).first);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.ensureVisible(find.text('Add 1 to monitors'));
    await tester.tap(find.text('Add 1 to monitors'));
    await tester.pumpAndSettle();

    expect(selected, ['api.apps.example.com']);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildvigilant-coreTheme(brightness: Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DomainReportView(report: report, certificate: null),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Subdomains found · 2'), findsOneWidget);
    expect(
      find.text('Nested tree · Hosts found in public sources.'),
      findsOneWidget,
    );
  });

  testWidgets('nests deeper hosts below their shared parent', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final report = DomainReport(
      input: DomainInput.tryParse('example.com')!,
      fetchedAt: DateTime.utc(2026, 1, 1),
      ct: const CtInfo(
        entries: [],
        subdomains: {
          'api.apps.example.com',
          'cdn.apps.example.com',
          '120.corpus.example.com',
          '121.corpus.example.com',
        },
        source: 'Cert Spotter',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildvigilant-coreTheme(brightness: Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DomainReportView(report: report, certificate: null),
          ),
        ),
      ),
    );

    final apps = find.text('apps.example.com');
    final api = find.text('api.apps.example.com');
    final corpus = find.text('corpus.example.com');
    final oneTwenty = find.text('120.corpus.example.com');
    expect(apps, findsOneWidget);
    expect(api, findsOneWidget);
    expect(corpus, findsOneWidget);
    expect(oneTwenty, findsOneWidget);
    expect(tester.getTopLeft(api).dx, greaterThan(tester.getTopLeft(apps).dx));
    expect(
      tester.getTopLeft(oneTwenty).dx,
      greaterThan(tester.getTopLeft(corpus).dx),
    );
  });

  // The glance tiles used to sit in a GridView with a fixed mainAxisExtent and
  // a Spacer, so a larger text scale overflowed the card instead of growing it.
  testWidgets('glance tiles survive a large text scale', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final report = DomainReport(
      input: DomainInput.tryParse('example.com')!,
      fetchedAt: DateTime.utc(2026, 1, 1),
      registration: RegistrationInfo(
        expiresAt: DateTime.utc(2026, 8, 1),
        registrar: 'Example Registrar',
      ),
      dns: DnsRecordSet({
        'A': [
          DnsRecord(
            name: 'example.com',
            type: 'A',
            ttl: 300,
            data: '192.0.2.1',
          ),
        ],
      }),
      emailAuth: const EmailAuthInfo(
        spf: 'v=spf1 -all',
        dmarc: 'v=DMARC1; p=none',
      ),
      http: const HttpFindings(statusCode: 200, hsts: 'max-age=31536000'),
    );

    for (final scale in [1.0, 1.5, 2.0]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildvigilant-coreTheme(brightness: Brightness.light),
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: SingleChildScrollView(
                child: DomainReportView(report: report, certificate: null),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The tile keeps both its value and its explanation at any scale, and the
      // layout never overflows. 'HTTP 200' also appears in the HTTP detail
      // section, so the tile-only copy of the summary is the precise probe.
      expect(
        find.text('HTTPS responded successfully'),
        findsOneWidget,
        reason: 'tile detail missing at text scale $scale',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'layout failed at text scale $scale',
      );
    }
  });

  // A declined CT probe is not a failed one: a default scan must not report a
  // subdomain fault the user never asked to check for.
  testWidgets('an unrequested CT probe reads as skipped, not unavailable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final input = DomainInput.tryParse('example.com')!;
    DomainReport reportWith({required bool includeCt, CtInfo? ct}) =>
        DomainReport(
          input: input,
          fetchedAt: DateTime.utc(2026, 1, 1),
          registration: RegistrationInfo(expiresAt: DateTime.utc(2026, 8, 1)),
          http: const HttpFindings(statusCode: 200),
          includeCt: includeCt,
          ct: ct,
        );

    Future<void> pump(DomainReport report) => tester.pumpWidget(
      MaterialApp(
        theme: buildvigilant-coreTheme(brightness: Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DomainReportView(report: report, certificate: null),
          ),
        ),
      ),
    );

    // Scoped to the subdomains tile: TLS, email auth, and DNS also render
    // "Unavailable" in this fixture, which is not what is under test here.
    Finder subdomainsTile = find.ancestor(
      of: find.text('SUBDOMAINS'),
      matching: find.byType(Card),
    );

    // Not requested: neutral wording, and no invented fault.
    await pump(reportWith(includeCt: false));
    await tester.pump();
    expect(find.text('Not scanned'), findsOneWidget);
    expect(find.text('Subdomain discovery was not requested'), findsOneWidget);
    expect(
      find.descendant(of: subdomainsTile, matching: find.text('Unavailable')),
      findsNothing,
    );
    expect(find.text('Not requested for this scan'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Requested but empty: still a real gap, so the fault wording stays.
    await pump(reportWith(includeCt: true));
    await tester.pump();
    expect(
      find.descendant(of: subdomainsTile, matching: find.text('Unavailable')),
      findsOneWidget,
    );
    expect(find.text('Transparency data was not available'), findsOneWidget);
    expect(find.text('Not requested for this scan'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // The tree used to live in a height-capped inner ListView, which won the
  // vertical drag gesture and trapped the user inside the card.
  testWidgets('dragging the subdomain tree scrolls the page', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final report = DomainReport(
      input: DomainInput.tryParse('example.com')!,
      fetchedAt: DateTime.utc(2026, 1, 1),
      registration: RegistrationInfo(expiresAt: DateTime.utc(2026, 8, 1)),
      http: const HttpFindings(statusCode: 200),
      ct: CtInfo(
        entries: const [],
        subdomains: {for (var i = 0; i < 40; i++) 'host$i.example.com'},
        source: 'Cert Spotter',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildvigilant-coreTheme(brightness: Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DomainReportView(
              report: report,
              certificate: null,
              onWatchSubdomains: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The tree list shares the page's scroll view: it must not be able to
    // scroll on its own, or it wins the vertical drag and traps the user.
    final tree = tester.widget<ListView>(find.byType(ListView));
    expect(tree.physics, isA<NeverScrollableScrollPhysics>());

    await tester.ensureVisible(find.text('host0.example.com'));
    await tester.pumpAndSettle();

    final page = find.byType(Scrollable).first;
    final before = tester.state<ScrollableState>(page).position.pixels;
    expect(
      before,
      greaterThan(0),
      reason: 'page should have scrolled to reveal the tree',
    );

    await tester.drag(find.text('host0.example.com'), const Offset(0, -220));
    await tester.pumpAndSettle();

    expect(
      tester.state<ScrollableState>(page).position.pixels,
      greaterThan(before),
      reason: 'the drag was captured instead of scrolling the page',
    );
  });
}
