import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vigilant-core/alerts/pager.dart';
import 'package:vigilant-core/alerts/pager_style.dart';
import 'package:vigilant-core/monitors/monitor_config.dart';
import 'package:vigilant-core/monitors/monitor_coordinator.dart';
import 'package:vigilant-core/monitors/monitor_repository.dart';
import 'package:vigilant-core/monitors/monitor_service.dart';
import 'package:vigilant-core/monitors/monitors_screen.dart';
import 'package:vigilant-core/platform/android_power_status.dart';
import 'package:vigilant-core/reminders/reminder_scheduler.dart';

/// W4 was that the app could not tell "nothing is wrong" from "nothing ran".
/// These tests pin the line that makes the difference visible.
void main() {
  Future<void> pumpDashboard(
    WidgetTester tester, {
    required DateTime? sweptAt,
    MonitorRepository? seed,
  }) async {
    final store = _MemoryStore(seed ?? MonitorRepository());
    final coordinator = MonitorCoordinator(
      store: store,
      service: _FakeService(),
      pager: _FakePager(),
      reminders: _FakeReminders(),
      powerStatus: _FakePowerStatus(),
    );
    await tester.pumpWidget(
      MaterialApp(
        // The screen is a bare CustomScrollView; the shell supplies the
        // Scaffold, so the test has to as well or the chips have no Material
        // ancestor.
        home: Scaffold(
          body: MonitorsScreen(coordinator: coordinator, onAddMonitor: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  MonitorRepository withOneMonitor({DateTime? sweptAt, bool paused = false}) {
    final repository = MonitorRepository();
    repository.upsert(MonitorConfig.forDomain('example.com'));
    repository.lastSweepAt = sweptAt;
    repository.monitoringPaused = paused;
    return repository;
  }

  testWidgets('a monitor that has never been swept says so plainly', (
    tester,
  ) async {
    // "Everything looks good" next to a fleet that has never been checked is
    // the exact claim this line exists to block.
    await pumpDashboard(tester, sweptAt: null, seed: withOneMonitor());

    expect(
      find.text('No background check has run on this device yet.'),
      findsOneWidget,
    );
  });

  testWidgets('a recent sweep is reported quietly', (tester) async {
    await pumpDashboard(
      tester,
      sweptAt: DateTime.now().toUtc().subtract(const Duration(seconds: 30)),
      seed: withOneMonitor(
        sweptAt: DateTime.now().toUtc().subtract(const Duration(seconds: 30)),
      ),
    );

    expect(find.textContaining('Checked just now'), findsOneWidget);
    expect(find.textContaining('not scheduling it'), findsNothing);
  });

  testWidgets('a sweep that has not come round is called out, with the reason', (
    tester,
  ) async {
    // Stale per-monitor timestamps look identical whether the targets are down
    // or the OS stopped scheduling the service, so the line names the cause and
    // points at the setting that fixes it.
    await pumpDashboard(
      tester,
      sweptAt: DateTime.now().toUtc().subtract(const Duration(hours: 3)),
      seed: withOneMonitor(
        sweptAt: DateTime.now().toUtc().subtract(const Duration(hours: 3)),
      ),
    );

    expect(find.textContaining('Android is not scheduling it'), findsOneWidget);
    expect(find.textContaining('Battery optimisation'), findsOneWidget);
  });

  testWidgets('the sweep line is absent with no monitors', (tester) async {
    // With nothing to be stale, there is no sweep worth reporting.
    await pumpDashboard(tester, sweptAt: null);

    expect(find.text('Watch what matters'), findsOneWidget);
    expect(
      find.text('No background check has run on this device yet.'),
      findsNothing,
    );
  });

  testWidgets('a late sweep after the user turned monitoring off is not blamed '
      'on Android', (tester) async {
    // The user stopping the service and the OS refusing to schedule it look
    // identical in the data. Reporting "Android is not scheduling it" when the
    // user did it deliberately would send them to fix a setting that is fine.
    await pumpDashboard(
      tester,
      sweptAt: DateTime.now().toUtc().subtract(const Duration(hours: 3)),
      seed: withOneMonitor(
        sweptAt: DateTime.now().toUtc().subtract(const Duration(hours: 3)),
        paused: true,
      ),
    );

    expect(find.textContaining('Background monitoring is off'), findsOneWidget);
    expect(find.textContaining('Android is not scheduling it'), findsNothing);
    expect(find.textContaining('Battery optimisation'), findsNothing);
  });

  testWidgets('a recent sweep still reports that monitoring is off', (
    tester,
  ) async {
    // "Checked just now" would let a reader conclude monitoring is live. The
    // state the user needs is the one that is true now, not the last thing that
    // happened — and right after turning it off, the last sweep was thirty
    // seconds ago.
    await pumpDashboard(
      tester,
      sweptAt: DateTime.now().toUtc().subtract(const Duration(seconds: 30)),
      seed: withOneMonitor(
        sweptAt: DateTime.now().toUtc().subtract(const Duration(seconds: 30)),
        paused: true,
      ),
    );

    expect(find.textContaining('Background monitoring is off'), findsOneWidget);
    expect(find.textContaining('Checked just now'), findsNothing);
  });

  testWidgets('a paused device with no sweep yet still says none has run', (
    tester,
  ) async {
    // Never-run is never-run. The pause explains a missing future sweep, not a
    // missing past one.
    await pumpDashboard(
      tester,
      sweptAt: null,
      seed: withOneMonitor(paused: true),
    );

    expect(
      find.text('No background check has run on this device yet.'),
      findsOneWidget,
    );
  });
}

class _MemoryStore implements MonitorStore {
  _MemoryStore(this.repository);

  MonitorRepository repository;

  @override
  Future<MonitorRepository> load() async =>
      MonitorRepository.decode(repository.encode());

  @override
  Future<void> save(MonitorRepository value) async {
    repository = MonitorRepository.decode(value.encode());
  }
}

class _FakeService implements ServiceController {
  @override
  Future<bool> isRunning() async => true;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

class _FakePager implements Pager {
  @override
  bool get canPageInBackground => true;

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
  Future<bool> hasDndAccess() async => false;

  @override
  Future<bool> requestDndAccess() async => false;
}

class _FakeReminders implements ReminderScheduler {
  @override
  Future<void> replaceAll(List<ExpiryReminder> reminders) async {}

  @override
  Future<void> cancelAll() async {}
}

class _FakePowerStatus implements PowerStatusController {
  @override
  Future<bool?> isBatteryOptimizationIgnored() async => true;

  @override
  Future<bool> openBatteryOptimizationSettings() async => true;
}
