import 'package:discovery_core/discovery_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vigilant-core/alerts/pager.dart';
import 'package:vigilant-core/alerts/pager_style.dart';
import 'package:vigilant-core/monitors/monitor_config.dart';
import 'package:vigilant-core/monitors/monitor_coordinator.dart';
import 'package:vigilant-core/monitors/monitor_repository.dart';
import 'package:vigilant-core/monitors/monitor_service.dart';
import 'package:vigilant-core/monitors/monitor_transfer.dart';
import 'package:vigilant-core/reminders/reminder_scheduler.dart';

class _MemoryStore implements MonitorStore {
  MonitorRepository repository = MonitorRepository();

  @override
  Future<MonitorRepository> load() async =>
      MonitorRepository.decode(repository.encode());

  @override
  Future<void> save(MonitorRepository value) async {
    repository = MonitorRepository.decode(value.encode());
  }
}

class _FakeService implements ServiceController {
  int starts = 0;
  int stops = 0;
  bool running = false;

  /// Set to have the service refuse, so a test can check that a switch which
  /// could not be moved does not claim it was.
  bool refuseToStart = false;
  bool refuseToStop = false;

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<void> start() async {
    if (refuseToStart) throw StateError('could not start');
    starts++;
    running = true;
  }

  @override
  Future<void> stop() async {
    if (refuseToStop) throw StateError('could not stop');
    stops++;
    running = false;
  }
}

class _FakePager implements Pager {
  final List<AlertIntent> delivered = [];
  final List<String> cleared = [];

  /// Settable so a test can exercise the path where the platform cannot page
  /// in the background. Defaults to true, which is the Android case.
  bool pageInBackground = true;

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
  }) async {
    delivered.add(intent);
  }

  @override
  Future<void> clear(String monitorId) async => cleared.add(monitorId);

  @override
  Future<bool> canPage() async => true;

  @override
  Future<bool> hasDndAccess() async => true;

  @override
  Future<bool> requestDndAccess() async => true;
}

class _FakeReminders implements ReminderScheduler {
  int calls = 0;
  List<ExpiryReminder> last = const [];

  @override
  Future<void> replaceAll(List<ExpiryReminder> reminders) async {
    calls++;
    last = reminders;
  }

  @override
  Future<void> cancelAll() async {}
}

MonitorCoordinator _buildCoordinator({
  required _MemoryStore store,
  required _FakeService service,
  _FakePager? pager,
  ReminderScheduler? reminders,
  List<int> codes = const [200],
}) {
  final queue = [...codes];
  return MonitorCoordinator(
    pager: pager ?? _FakePager(),
    store: store,
    service: service,
    reminders: reminders ?? _FakeReminders(),
    client: MockClient((_) async {
      final code = queue.isEmpty ? 200 : queue.removeAt(0);
      return http.Response('body', code);
    }),
  );
}

void main() {
  test('copy then import moves the list to a second device', () async {
    final store = _MemoryStore();
    final service = _FakeService();
    final coordinator = _buildCoordinator(
      store: store,
      service: service,
      pager: _FakePager(),
    );

    await coordinator.addDomain('example.com');
    await coordinator.addTcp('db.example.com', 5432);

    // The document is nothing but addresses.
    final document = await coordinator.exportMonitors();
    expect(document.trim().split('\n'), ['example.com', 'db.example.com:5432']);

    // A second device starts empty and adds them from that list alone.
    final target = _buildCoordinator(
      store: _MemoryStore(),
      service: _FakeService(),
      pager: _FakePager(),
    );
    final preview = await target.previewImport(document);
    expect(preview.additions, hasLength(2));
    expect(preview.alreadyPresent, 0);

    final result = await target.importMonitors(document);
    expect(result.additions, hasLength(2));

    final restored = await target.load();
    expect(
      restored.monitors.map((m) => m.id),
      containsAll(['example.com', 'tcp://db.example.com:5432']),
    );
  });

  test('a copied list carries no settings from this device', () async {
    final store = _MemoryStore();
    final service = _FakeService();
    final coordinator = _buildCoordinator(
      store: store,
      service: service,
      pager: _FakePager(),
    );

    await coordinator.updateMonitor(
      MonitorConfig.forDomain('example.com').copyWith(
        cadence: const Duration(minutes: 45),
        registrationExpiry: DateTime.utc(2028, 6, 1),
        certificateExpiry: DateTime.utc(2027, 1, 15),
        policy: const AlertPolicy(failureThreshold: 4, urgent: true),
        style: const AlertStyle(sound: AlertSound.alarm),
      ),
    );

    // Only the address, so nothing about how it is watched is written down.
    expect((await coordinator.exportMonitors()).trim(), 'example.com');

    // And a restore starts from this app's defaults, not the old device's.
    final target = _buildCoordinator(
      store: _MemoryStore(),
      service: _FakeService(),
      pager: _FakePager(),
    );
    await target.importMonitors(await coordinator.exportMonitors());

    final restored = (await target.load()).byId('example.com')!;
    expect(restored.cadence, const Duration(minutes: 5));
    expect(restored.registrationExpiry, isNull);
    expect(restored.certificateExpiry, isNull);
    expect(restored.policy.urgent, isFalse);
    expect(restored.style.sound, AlertSound.notification);
  });

  test('import leaves monitors already on the device untouched', () async {
    final store = _MemoryStore();
    final service = _FakeService();
    final coordinator = _buildCoordinator(
      store: store,
      service: service,
      pager: _FakePager(),
    );

    // Tuned locally after the backup was taken elsewhere.
    await coordinator.updateMonitor(
      MonitorConfig.forDomain('example.com')
          .copyWith(cadence: const Duration(minutes: 30)),
    );
    await coordinator.addDomain('new.example.com');

    // A pasted list naming two sites already here and one that is not.
    const document = 'example.com\nnew.example.com\nelsewhere.example.com';

    final result = await coordinator.importMonitors(document);
    expect(result.additions.map((m) => m.id), ['elsewhere.example.com']);
    expect(result.alreadyPresent, 2);

    final after = await coordinator.load();
    expect(
      after.byId('example.com')!.cadence,
      const Duration(minutes: 30),
      reason: 'a backup must not overwrite local tuning',
    );
    expect(after.byId('elsewhere.example.com'), isNotNull);
  });

  test('import adds a monitor that is missing and keeps the rest', () async {
    final store = _MemoryStore();
    final service = _FakeService();
    final coordinator = _buildCoordinator(
      store: store,
      service: service,
      pager: _FakePager(),
    );
    await coordinator.addDomain('kept.example.com');

    const document = 'kept.example.com\nrestored.example.com';

    final result = await coordinator.importMonitors(document);
    expect(result.additions.map((m) => m.id), ['restored.example.com']);
    expect(result.alreadyPresent, 1);

    final after = await coordinator.load();
    expect(after.monitors, hasLength(2));
    expect(after.byId('restored.example.com'), isNotNull);
  });

  test('importing an unusable document changes nothing', () async {
    final store = _MemoryStore();
    final service = _FakeService();
    final coordinator = _buildCoordinator(
      store: store,
      service: service,
      pager: _FakePager(),
    );
    await coordinator.addDomain('example.com');

    expect(
      () => coordinator.importMonitors('my vigilant-core is on fire'),
      throwsA(isA<MonitorTransferException>()),
    );
    // The failed import must not have committed a partial write.
    expect((await coordinator.load()).monitors, hasLength(1));
  });

  test('addDomain stores a monitor and starts the service', () async {
    final store = _MemoryStore();
    final service = _FakeService();
    final coordinator = _buildCoordinator(
      store: store,
      service: service,
      pager: _FakePager(),
    );

    await coordinator.addDomain('example.com');

    expect(service.starts, 1);
    final repo = await coordinator.load();
    expect(repo.monitors, hasLength(1));
    expect(repo.monitors.single.id, 'example.com');
  });

  // Bulk subdomain adds share the registrable domain's RDAP result, so the
  // registration expiry has to survive persistence for every host added.
  // Certificate expiry is per-host and must stay unknown rather than inherit
  // the scanned host's chain.
  test(
    'addDomain persists shared registration expiry but no TLS expiry',
    () async {
      final store = _MemoryStore();
      final service = _FakeService();
      final coordinator = _buildCoordinator(
        store: store,
        service: service,
        pager: _FakePager(),
      );

      final expires = DateTime.utc(2027, 3, 2);
      for (final host in ['api.example.com', 'cdn.example.com']) {
        await coordinator.addDomain(host, registrationExpiry: expires);
      }

      final repo = await coordinator.load();
      expect(repo.monitors, hasLength(2));
      for (final host in ['api.example.com', 'cdn.example.com']) {
        final monitor = repo.byId(host);
        expect(monitor, isNotNull, reason: '$host was not stored');
        expect(monitor!.registrationExpiry, expires);
        expect(monitor.certificateExpiry, isNull);
      }

      // The expiry is what the dashboard's reminder and warning logic reads, so
      // it has to be a real, comparable value after a reload.
      final reloaded = (await coordinator.load()).byId('api.example.com')!;
      expect(
        reloaded.registrationExpiry!
            .difference(DateTime.utc(2026, 9, 26))
            .inDays,
        greaterThan(0),
      );
    },
  );

  test('addTcp stores an explicit TCP target', () async {
    final store = _MemoryStore();
    final service = _FakeService();
    final coordinator = _buildCoordinator(
      store: store,
      service: service,
      pager: _FakePager(),
    );

    await coordinator.addTcp('127.0.0.1', 5432);

    final monitor = (await coordinator.load()).byId('tcp://127.0.0.1:5432');
    expect(monitor, isNotNull);
    expect(monitor!.type, MonitorType.tcp);
    expect(monitor.port, 5432);
    expect(service.starts, 1);
  });

  test('addHttpAssertions stores URL assertions', () async {
    final store = _MemoryStore();
    final coordinator = _buildCoordinator(
      store: store,
      service: _FakeService(),
      pager: _FakePager(),
    );

    await coordinator.addHttpAssertions(
      Uri.parse('https://example.com/health'),
      assertions: const [ContentAssertion(value: 'healthy')],
    );

    final monitor = (await coordinator.load()).byId(
      'https://example.com/health',
    );
    expect(monitor, isNotNull);
    expect(monitor!.assertions, hasLength(1));
    expect(monitor.assertions.single.value, 'healthy');
  });

  test('addHttpAssertions rejects empty assertion text', () async {
    final store = _MemoryStore();
    final service = _FakeService();
    final coordinator = _buildCoordinator(
      store: store,
      service: service,
      pager: _FakePager(),
    );

    await expectLater(
      coordinator.addHttpAssertions(
        Uri.parse('https://example.com/health'),
        assertions: const [ContentAssertion(value: '  ')],
      ),
      throwsArgumentError,
    );
    expect((await coordinator.load()).monitors, isEmpty);
    expect(service.starts, 0);
  });

  test('checkNow records the verdict and pages on failure', () async {
    final store = _MemoryStore();
    final pager = _FakePager();
    final coordinator = _buildCoordinator(
      store: store,
      service: _FakeService(),
      pager: pager,
      codes: [503],
    );
    await coordinator.addDomain('example.com');

    final result = await coordinator.checkNow('example.com');

    expect(result, isNotNull);
    expect(result!.verdict.status, HealthStatus.down);
    expect(pager.delivered.single.kind, AlertKind.down);
    expect(
      (await coordinator.load()).stateFor('example.com').status,
      HealthStatus.down,
    );
  });

  test('ack action records the acknowledgement', () async {
    final store = _MemoryStore();
    final pager = _FakePager();
    final coordinator = _buildCoordinator(
      store: store,
      service: _FakeService(),
      pager: pager,
      codes: [503],
    );
    await coordinator.addDomain('example.com');
    await coordinator.checkNow('example.com');

    await coordinator.handleAction('ack', 'example.com');

    final repo = await coordinator.load();
    expect(repo.stateFor('example.com').acknowledged, isTrue);
    expect(pager.cleared, contains('example.com'));
  });

  test('mute action sets a mute window and clears the page', () async {
    final store = _MemoryStore();
    final pager = _FakePager();
    final coordinator = _buildCoordinator(
      store: store,
      service: _FakeService(),
      pager: pager,
      codes: [503],
    );
    await coordinator.addDomain('example.com');
    await coordinator.checkNow('example.com');

    await coordinator.handleAction('mute', 'example.com');

    final state = (await coordinator.load()).stateFor('example.com');
    expect(state.mutedUntil, isNotNull);
    expect(state.mutedUntil!.isAfter(DateTime.now().toUtc()), isTrue);
  });

  test('remove drops the monitor and clears its page', () async {
    final store = _MemoryStore();
    final pager = _FakePager();
    final coordinator = _buildCoordinator(
      store: store,
      service: _FakeService(),
      pager: pager,
    );
    await coordinator.addDomain('example.com');

    await coordinator.remove('example.com');

    expect((await coordinator.load()).monitors, isEmpty);
    expect(pager.cleared, contains('example.com'));
  });

  test('setEnabled toggles a monitor', () async {
    final store = _MemoryStore();
    final coordinator = _buildCoordinator(
      store: store,
      service: _FakeService(),
      pager: _FakePager(),
    );
    await coordinator.addDomain('example.com');

    await coordinator.setEnabled('example.com', false);

    expect((await coordinator.load()).byId('example.com')!.enabled, isFalse);
  });

  test('reschedules expiry reminders on add and remove', () async {
    final store = _MemoryStore();
    final reminders = _FakeReminders();
    final coordinator = _buildCoordinator(
      store: store,
      service: _FakeService(),
      pager: _FakePager(),
      reminders: reminders,
    );

    await coordinator.addDomain(
      'example.com',
      registrationExpiry: DateTime.now().add(const Duration(days: 90)),
    );
    expect(reminders.calls, greaterThan(0));
    expect(reminders.last, isNotEmpty);

    await coordinator.remove('example.com');
    expect(reminders.last, isEmpty);
  });

  test('updateMonitor persists policy and style edits', () async {
    final store = _MemoryStore();
    final coordinator = _buildCoordinator(
      store: store,
      service: _FakeService(),
      pager: _FakePager(),
    );
    await coordinator.addDomain('example.com');

    final monitor = (await coordinator.load()).byId('example.com')!;
    await coordinator.updateMonitor(
      monitor.copyWith(
        policy: const AlertPolicy(urgent: true, failureThreshold: 3),
        style: AlertStyle.silent,
        cadence: const Duration(minutes: 15),
      ),
    );

    final saved = (await coordinator.load()).byId('example.com')!;
    expect(saved.policy.urgent, isTrue);
    expect(saved.policy.failureThreshold, 3);
    expect(saved.style.sound, AlertSound.none);
    expect(saved.cadence, const Duration(minutes: 15));
  });

  group('addHttp', () {
    test('stores a plain uptime monitor when given no body rules', () {
      // The unified add screen routes a bare website here, so this is the path
      // that has to work with an empty rule list.
      final store = _MemoryStore();
      final service = _FakeService();
      final coordinator = MonitorCoordinator(
        store: store,
        service: service,
        pager: _FakePager(),
        reminders: _FakeReminders(),
      );

      coordinator.addHttp(Uri.parse('https://example.com/status')).then((_) {
        final saved = store.repository.byId('https://example.com/status');
        expect(saved, isNotNull);
        expect(saved!.assertions, isEmpty);
        expect(service.starts, 1);
      });
    });

    test('stores body rules when given them', () {
      final store = _MemoryStore();
      final coordinator = MonitorCoordinator(
        store: store,
        service: _FakeService(),
        pager: _FakePager(),
        reminders: _FakeReminders(),
      );

      coordinator
          .addHttp(
            Uri.parse('https://example.com/health'),
            assertions: [const ContentAssertion(value: 'Service healthy')],
          )
          .then((_) {
            final saved = store.repository.byId('https://example.com/health');
            expect(saved!.assertions, hasLength(1));
          });
    });

    test('rejects a blank rule without persisting or starting the service', () {
      final store = _MemoryStore();
      final service = _FakeService();
      final coordinator = MonitorCoordinator(
        store: store,
        service: service,
        pager: _FakePager(),
        reminders: _FakeReminders(),
      );

      expect(
        () => coordinator.addHttp(
          Uri.parse('https://example.com'),
          assertions: [const ContentAssertion(value: '   ')],
        ),
        throwsArgumentError,
      );
      expect(store.repository.monitors, isEmpty);
      expect(service.starts, 0);
    });
  });

  group('background monitoring switch', () {
    test('turning it off stops the service and persists the choice', () async {
      final store = _MemoryStore();
      final service = _FakeService();
      final coordinator = _buildCoordinator(store: store, service: service);
      await coordinator.addDomain('example.com');
      expect(service.running, isTrue);

      expect(await coordinator.setMonitoringPaused(true), isTrue);

      expect(service.running, isFalse);
      expect(service.stops, 1);
      expect(store.repository.monitoringPaused, isTrue);
      expect(coordinator.monitoringPaused.value, isTrue);
    });

    test('turning it back on starts the service again', () async {
      final store = _MemoryStore();
      final service = _FakeService();
      final coordinator = _buildCoordinator(store: store, service: service);
      await coordinator.addDomain('example.com');
      await coordinator.setMonitoringPaused(true);
      final startsBefore = service.starts;

      expect(await coordinator.setMonitoringPaused(false), isTrue);

      expect(service.running, isTrue);
      expect(service.starts, startsBefore + 1);
      expect(store.repository.monitoringPaused, isFalse);
    });

    test('adding a monitor while off does not start the service', () async {
      // The interaction that matters: an add is the one path that used to start
      // the service unconditionally, so a pause has to survive it.
      final store = _MemoryStore();
      final service = _FakeService();
      final coordinator = _buildCoordinator(store: store, service: service);
      await coordinator.addDomain('example.com');
      await coordinator.setMonitoringPaused(true);
      final startsBefore = service.starts;

      await coordinator.addDomain('example.org');
      await coordinator.importMonitors('example.net');

      expect(service.starts, startsBefore);
      expect(service.running, isFalse);
      // The monitors are still saved — stopping is about checking, not keeping.
      expect(store.repository.monitors, hasLength(3));
    });

    test('unpausing and then adding starts the service', () async {
      final store = _MemoryStore();
      final service = _FakeService();
      final coordinator = _buildCoordinator(store: store, service: service);
      await coordinator.setMonitoringPaused(true);
      await coordinator.setMonitoringPaused(false);
      final startsBefore = service.starts;

      await coordinator.addDomain('example.com');

      expect(service.starts, startsBefore + 1);
    });

    test('a service that refuses to stop is not recorded as stopped', () async {
      final store = _MemoryStore();
      final service = _FakeService()..refuseToStop = true;
      final coordinator = _buildCoordinator(store: store, service: service);
      await coordinator.addDomain('example.com');

      expect(await coordinator.setMonitoringPaused(true), isFalse);

      // The preference is the user's intent, but it must never claim a state the
      // service is not actually in.
      expect(store.repository.monitoringPaused, isFalse);
      expect(coordinator.monitoringPaused.value, isFalse);
    });

    test(
      'a service that refuses to start is not recorded as running',
      () async {
        final store = _MemoryStore();
        final service = _FakeService();
        final coordinator = _buildCoordinator(store: store, service: service);
        await coordinator.setMonitoringPaused(true);

        service.refuseToStart = true;
        expect(await coordinator.setMonitoringPaused(false), isFalse);
        expect(store.repository.monitoringPaused, isTrue);
      },
    );

    test('a stored pause is re-applied on startup', () async {
      // The reboot case: the service comes back on its own, and the pause has to
      // be re-applied or turning monitoring off would last one boot.
      final store = _MemoryStore();
      final service = _FakeService();
      final first = _buildCoordinator(store: store, service: service);
      await first.addDomain('example.com');
      await first.setMonitoringPaused(true);

      // A fresh process: same store, a service the OS has restarted.
      final restarted = _FakeService()..running = true;
      final second = _buildCoordinator(store: store, service: restarted);
      await second.syncMonitoringPreference();

      expect(restarted.running, isFalse);
      expect(second.monitoringPaused.value, isTrue);
    });

    test(
      'a service that died while unpaused is brought back on startup',
      () async {
        final store = _MemoryStore();
        final service = _FakeService();
        await _buildCoordinator(
          store: store,
          service: service,
        ).addDomain('example.com');

        final dead = _FakeService();
        final second = _buildCoordinator(store: store, service: dead);
        await second.syncMonitoringPreference();

        expect(dead.running, isTrue);
        expect(second.monitoringPaused.value, isFalse);
      },
    );

    test(
      'startup does not start a service when nothing is being watched',
      () async {
        final store = _MemoryStore();
        final service = _FakeService();

        await _buildCoordinator(
          store: store,
          service: service,
        ).syncMonitoringPreference();

        expect(service.starts, 0);
      },
    );

    test(
      'a platform that refuses is not reported as a stopped service',
      () async {
        final store = _MemoryStore();
        final coordinator = _buildCoordinator(
          store: store,
          service: _FakeService()..refuseToStop = true,
        );
        store.repository.monitoringPaused = true;

        // Startup must not throw, and must not claim the preference moved.
        await coordinator.syncMonitoringPreference();
        expect(coordinator.monitoringPaused.value, isTrue);
      },
    );
  });
}
