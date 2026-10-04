import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vigilant-core/alerts/pager.dart';
import 'package:vigilant-core/alerts/pager_style.dart';
import 'package:vigilant-core/discovery/resolver_preference.dart';
import 'package:vigilant-core/main.dart';
import 'package:vigilant-core/monitors/list_clipboard.dart';
import 'package:vigilant-core/monitors/monitor_config.dart';
import 'package:vigilant-core/monitors/monitor_coordinator.dart';
import 'package:vigilant-core/monitors/monitor_repository.dart';
import 'package:vigilant-core/monitors/monitor_service.dart';
import 'package:vigilant-core/reminders/reminder_scheduler.dart';

/// A coordinator with no plugin dependencies, so widget tests can reach states
/// that depend on persisted data. The default coordinator reads through
/// `FlutterForegroundTask`, which never resolves under `flutter test` and leaves
/// the dashboard on a spinner forever.
MonitorCoordinator _offlineCoordinator({
  List<MonitorConfig> monitors = const [],
  bool pageInBackground = true,
}) => MonitorCoordinator(
  store: _MemoryStore(monitors),
  service: const _NoService(),
  pager: _StubPager(pageInBackground),
  reminders: _NoReminders(),
  resolverStore: InMemoryResolverStore(),
);

class _MemoryStore implements MonitorStore {
  _MemoryStore([List<MonitorConfig>? monitors]) : _monitors = [...?monitors];

  /// A save replaces the contents rather than aliasing the list the repository
  /// handed out.
  final List<MonitorConfig> _monitors;

  @override
  Future<MonitorRepository> load() async =>
      MonitorRepository(monitors: [..._monitors]);

  @override
  Future<void> save(MonitorRepository repository) async {
    _monitors
      ..clear()
      ..addAll(repository.monitors);
  }
}

class _NoService implements ServiceController {
  const _NoService();

  @override
  Future<bool> isRunning() async => false;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

class _NoReminders implements ReminderScheduler {
  @override
  Future<void> replaceAll(List<ExpiryReminder> reminders) async {}

  @override
  Future<void> cancelAll() async {}
}

/// In-memory stand-in for the clipboard.
///
/// The real one is a platform channel, and awaiting a channel with no handler
/// behind it under `flutter test` hangs the test rather than failing it, so the
/// list flow is driven through this instead.
class _FakeClipboard implements ListClipboard {
  String? text;

  @override
  Future<void> write(String value) async => text = value;

  @override
  Future<String?> read() async => text;
}

class _StubPager implements Pager {
  _StubPager(this.pageInBackground);

  final bool pageInBackground;

  @override
  bool get canPageInBackground => pageInBackground;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> deliver(
    AlertIntent intent, {
    required String monitorId,
    required String monitorName,
    required AlertStyle style,
  }) async {}

  @override
  Future<void> clear(String monitorId) async {}

  @override
  Future<bool> canPage() async => true;

  @override
  Future<bool> hasDndAccess() async => true;

  @override
  Future<bool> requestDndAccess() async => true;
}

/// Advances a few frames without settling.
///
/// The monitors tab re-evaluates on a 30s timer, so once that much simulated
/// time has passed `pumpAndSettle` never returns. A couple of frames is enough
/// for a dialog or a snackbar to appear.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Scrolls [finder] into view, waits for the scroll to actually finish, and taps
/// it.
///
/// Both halves matter. `ensureVisible` starts an animation that the fixed
/// [_settle] wait can cut short, and it can leave a widget flush with the
/// viewport edge, where the hit test lands on whatever is painted there instead.
/// Settling properly and letting the target come to rest mid-screen is also
/// what a person does, so these tests stop depending on how much Settings
/// happens to have above them.
Future<void> _tapInView(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await _settle(tester);
}

void main() {
  // The site list is the only way to move targets between devices, so the whole
  // flow has to be reachable, and a mistaken paste has to be reversible.
  testWidgets('copying and importing the site list', (tester) async {
    final source = _offlineCoordinator(
      monitors: [
        MonitorConfig.forDomain('example.com'),
        MonitorConfig.forTcp('db.example.com', 5432),
      ],
    );
    final clipboard = _FakeClipboard();
    await tester.pumpWidget(
      // Distinct keys: vigilant-coreApp keeps its coordinator in a late final, so
      // reusing the State would carry the first coordinator into the second app.
      vigilant-coreApp(
        key: const ValueKey('source'),
        coordinator: source,
        clipboard: clipboard,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Settings'));
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.text('Site list'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Site list'), findsOneWidget);

    // Export puts the document on the clipboard.
    await _tapInView(tester, find.widgetWithText(OutlinedButton, 'Copy list'));
    // A plain list of addresses, and nothing else.
    expect(clipboard.text!.trim().split('\n'), [
      'example.com',
      'db.example.com:5432',
    ]);

    // Import into a device with nothing on it offers a preview before applying.
    final target = _offlineCoordinator();
    // The same clipboard, standing in for a second device being handed the list.
    await tester.pumpWidget(
      vigilant-coreApp(
        key: const ValueKey('target'),
        coordinator: target,
        clipboard: clipboard,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Settings'));
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.text('Site list'),
      300,
      scrollable: find.byType(Scrollable).last,
    );

    // Scrolling the "Site list" heading into view is not enough: the button sits
    // below it, and how far below depends on the cards above it.
    await _tapInView(
      tester,
      find.widgetWithText(OutlinedButton, 'Import list'),
    );

    expect(find.text('Add 2 sites?'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('db.example.com:5432'), findsOneWidget);

    // Backing out changes nothing.
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect((await target.load()).monitors, isEmpty);

    // Confirming applies exactly what was previewed.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Import list'));
    await _settle(tester);
    await tester.tap(find.text('Add 2'));
    await _settle(tester);

    final restored = await target.load();
    expect(restored.monitors, hasLength(2));
    expect(restored.byId('example.com'), isNotNull);
    expect(restored.byId('tcp://db.example.com:5432'), isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('importing a list that is already here says so', (tester) async {
    final coordinator = _offlineCoordinator(
      monitors: [MonitorConfig.forDomain('example.com')],
    );
    final clipboard = _FakeClipboard()
      ..text = await coordinator.exportMonitors();
    await tester.pumpWidget(
      vigilant-coreApp(coordinator: coordinator, clipboard: clipboard),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Settings'));
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.text('Site list'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await _tapInView(
      tester,
      find.widgetWithText(OutlinedButton, 'Import list'),
    );

    // No dialog, because there is nothing to confirm.
    expect(find.textContaining('Add '), findsNothing);
    expect(
      find.text('Every site in that list is already on this device.'),
      findsOneWidget,
    );
    expect((await coordinator.load()).monitors, hasLength(1));
  });

  testWidgets('importing prose explains itself instead of failing silently', (
    tester,
  ) async {
    final coordinator = _offlineCoordinator();
    final clipboard = _FakeClipboard()..text = 'my vigilant-core is on fire';
    await tester.pumpWidget(
      vigilant-coreApp(coordinator: coordinator, clipboard: clipboard),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Settings'));
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.text('Site list'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await _tapInView(
      tester,
      find.widgetWithText(OutlinedButton, 'Import list'),
    );

    expect(
      find.text('None of those lines name a site vigilant-core can watch.'),
      findsOneWidget,
    );
    expect((await coordinator.load()).monitors, isEmpty);
  });

  testWidgets('navigation exposes the scan flow', (tester) async {
    await tester.pumpWidget(const vigilant-coreApp());

    expect(find.text('vigilant-core'), findsOneWidget);
    expect(find.text('Monitors'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
    await tester.tap(find.text('Scan'));
    await _settle(tester);

    expect(find.text('Scan a website or domain'), findsOneWidget);
    expect(find.text('Domain'), findsOneWidget);
    expect(find.text('Scan subdomains'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
  });

  // The pre-scan explainer previews the scan that will actually run. Promising
  // Certificate Transparency while the probe is opt-out claims a check the scan
  // skips, and the whole point of the opt-in is that the probe is not free.
  testWidgets('the pre-scan explainer mirrors the subdomain option', (
    tester,
  ) async {
    await tester.pumpWidget(const vigilant-coreApp());
    await tester.tap(find.text('Scan'));
    await _settle(tester);

    expect(find.text('What gets checked'), findsOneWidget);
    expect(find.text('Certificate Transparency'), findsNothing);

    await tester.ensureVisible(find.text('Scan subdomains'));
    await tester.tap(find.text('Scan subdomains'));
    await _settle(tester);

    expect(find.text('Certificate Transparency'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings remains usable on a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const vigilant-coreApp());
    await tester.tap(find.text('Settings'));
    await _settle(tester);

    // The DNS resolver card sits above the access card, so "System access" is
    // below the fold on a 320px-wide screen. The property under test is that
    // every settings section stays reachable, not where the fold happens to be.
    await tester.scrollUntilVisible(
      find.text('System access'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await _settle(tester);
    expect(find.text('System access'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Developer tools'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await _settle(tester);
    expect(find.text('Developer tools'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the resolver card offers a device default', (tester) async {
    await tester.pumpWidget(const vigilant-coreApp());
    await tester.tap(find.text('Settings'));
    await _settle(tester);

    expect(find.text('DNS resolver'), findsOneWidget);
    // "Device resolver" appears twice on purpose: once as the status pill and
    // once as the radio title, so assert the selectable control itself.
    expect(
      find.widgetWithText(RadioListTile<ResolverMode>, 'Device resolver'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(RadioListTile<ResolverMode>, 'Custom DNS-over-HTTPS'),
      findsOneWidget,
    );
    // The endpoint field only appears once a custom resolver is chosen, and no
    // third-party resolver is in play until then.
    expect(find.textContaining('Third-party resolver'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  // Where there is no platform resolver, the device option falls back to a
  // DNS-over-HTTPS service. The card must not claim otherwise in the same breath
  // as disclosing the fallback.
  testWidgets(
    'the device resolver does not promise privacy it cannot deliver',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await tester.pumpWidget(const vigilant-coreApp());
      await tester.tap(find.text('Settings'));
      await _settle(tester);

      // The fallback is disclosed, by name.
      expect(find.textContaining('Third-party resolver'), findsOneWidget);
      expect(find.textContaining('cloudflare-dns.com'), findsWidgets);

      // So the device option must not simultaneously promise the opposite.
      expect(
        find.text('Recommended. No third party is contacted.'),
        findsNothing,
      );
      expect(
        find.widgetWithText(RadioListTile<ResolverMode>, 'Device resolver'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // Cleared here as well as in tearDown: the binding asserts foundation
      // debug variables are unset before tearDowns run.
      debugDefaultTargetPlatformOverride = null;
    },
  );

  // Off Android there is no foreground service, so no incident page can ever be
  // delivered. Reporting "Ready to deliver incident pages" there promises a
  // capability the platform does not have.
  testWidgets('settings does not promise paging where none is possible', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(const vigilant-coreApp());
    await tester.tap(find.text('Settings'));
    await _settle(tester);

    // The access card sits below the fold, and sliver children are not mounted
    // until they are scrolled into view.
    await tester.scrollUntilVisible(
      find.text('System access'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await _settle(tester);

    expect(find.text('Ready to deliver incident pages'), findsNothing);
    expect(find.text('Not available'), findsOneWidget);
    expect(
      find.text('No background monitoring on this platform'),
      findsOneWidget,
    );

    // DND bypass is an Android concept, so the row is not offered elsewhere.
    expect(find.text('Critical pages'), findsNothing);
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
  });

  // The empty dashboard sits directly under the header, so centring it in the
  // remaining viewport strands the call to action behind a large void.
  testWidgets('the empty dashboard sits near the header, not mid-void', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(vigilant-coreApp(coordinator: _offlineCoordinator()));
    // Not pumpAndSettle: the dashboard re-evaluates on a 30s timer, so the
    // frame scheduler never reaches a settled state.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The header tagline is directly above the call to action.
    final header = tester.getTopLeft(
      find.text('Local-first website & domain monitoring'),
    );
    final call = tester.getTopLeft(find.text('Watch what matters'));

    // Close under the header rather than floating in the middle of the screen,
    // which is what centring the sliver did.
    expect(call.dy - header.dy, lessThan(220));
    expect(call.dy, lessThan(915 * 0.55));
    // And no dead headline is left describing an empty tower.
    expect(find.text('Your vigilant-core is ready'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
