import 'package:discovery_core/discovery_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vigilant-core/alerts/pager_style.dart';
import 'package:vigilant-core/monitors/monitor_config.dart';
import 'package:vigilant-core/monitors/monitor_repository.dart';

void main() {
  test('forDomain builds a monitor from a bare domain', () {
    final monitor = MonitorConfig.forDomain('https://www.Example.com/path');
    expect(monitor.id, 'example.com');
    expect(monitor.url, 'https://example.com/');
    expect(monitor.name, 'example.com');
    expect(monitor.type, MonitorType.http);
  });

  test('forDomain keeps a subdomain visible in the monitor name', () {
    final monitor = MonitorConfig.forDomain('api.example.com');

    expect(monitor.id, 'api.example.com');
    expect(monitor.name, 'api.example.com');
    expect(monitor.url, 'https://api.example.com/');
  });

  test('forTcp builds an explicit host and port monitor', () {
    final monitor = MonitorConfig.forTcp('Example.COM', 5432);

    expect(monitor.type, MonitorType.tcp);
    expect(monitor.host, 'example.com');
    expect(monitor.port, 5432);
    expect(monitor.targetLabel, 'example.com:5432');
    expect(monitor.url, 'tcp://example.com:5432');
  });

  test('assertions and TCP settings round-trip through JSON', () {
    final monitor = MonitorConfig.forTcp(
      'example.com',
      5432,
      timeout: const Duration(seconds: 3),
    );
    final restored = MonitorConfig.fromJson(monitor.toJson());

    expect(restored.type, MonitorType.tcp);
    expect(restored.host, 'example.com');
    expect(restored.port, 5432);
    expect(restored.timeout, const Duration(seconds: 3));

    final http = MonitorConfig.forDomain(
      'example.com',
      assertions: const [ContentAssertion(value: 'healthy')],
    );
    final restoredHttp = MonitorConfig.fromJson(http.toJson());
    expect(restoredHttp.assertions, hasLength(1));
    expect(restoredHttp.assertions.single.value, 'healthy');
  });

  test('forUrl preserves an endpoint path for assertion checks', () {
    final monitor = MonitorConfig.forUrl(
      Uri.parse('https://example.com/health?probe=1'),
      assertions: const [ContentAssertion(value: 'healthy')],
    );

    expect(monitor.url, 'https://example.com/health?probe=1');
    expect(monitor.id, monitor.url);
    expect(monitor.assertions, hasLength(1));
  });

  test('config round-trips through JSON', () {
    final monitor = MonitorConfig.forDomain(
      'example.com',
      policy: const AlertPolicy(
        failureThreshold: 3,
        urgent: true,
        repeatInterval: Duration(minutes: 2),
      ),
      style: AlertStyle.urgent,
    );

    final restored = MonitorConfig.fromJson(monitor.toJson());

    expect(restored.id, monitor.id);
    expect(restored.url, monitor.url);
    expect(restored.policy.failureThreshold, 3);
    expect(restored.policy.urgent, isTrue);
    expect(restored.policy.repeatInterval, const Duration(minutes: 2));
    expect(restored.style.sound, AlertSound.alarm);
    expect(restored.style.vibration, AlertVibration.escalating);
  });

  test('legacy JSON remains an HTTP monitor', () {
    final monitor = MonitorConfig.fromJson({
      'id': 'example.com',
      'name': 'example.com',
      'url': 'https://example.com/',
      'cadenceMs': 300000,
      'latencyBudgetMs': 2500,
      'enabled': true,
    });

    expect(monitor.type, MonitorType.http);
    expect(monitor.timeout, const Duration(seconds: 10));
    expect(monitor.assertions, isEmpty);
  });

  test('copyWith edits policy and style but keeps identity', () {
    final monitor = MonitorConfig.forDomain('example.com');

    final edited = monitor.copyWith(
      name: 'Prod',
      cadence: const Duration(minutes: 15),
      policy: const AlertPolicy(urgent: true, failureThreshold: 3),
      style: AlertStyle.silent,
    );

    expect(edited.id, monitor.id);
    expect(edited.url, monitor.url);
    expect(edited.name, 'Prod');
    expect(edited.cadence, const Duration(minutes: 15));
    expect(edited.policy.urgent, isTrue);
    expect(edited.policy.failureThreshold, 3);
    expect(edited.style.sound, AlertSound.none);
    expect(edited.style.vibration, AlertVibration.none);
    expect(monitor.copyWith(expectedStatus: 204).expectedStatus, 204);
  });

  test('repository round-trips monitors and alert state', () {
    final repo = MonitorRepository();
    repo.upsert(
      MonitorConfig.forDomain(
        'example.com',
        policy: const AlertPolicy(urgent: true, failureThreshold: 2),
      ),
    );
    repo.upsert(MonitorConfig.forDomain('other.com'));
    repo.setState(
      'example.com',
      const AlertState(
        status: HealthStatus.down,
        consecutiveFailures: 2,
        acknowledged: true,
      ),
    );

    final restored = MonitorRepository.decode(repo.encode());

    expect(restored.monitors, hasLength(2));
    expect(restored.byId('example.com')!.policy.urgent, isTrue);
    expect(restored.byId('example.com')!.policy.failureThreshold, 2);
    expect(restored.stateFor('example.com').status, HealthStatus.down);
    expect(restored.stateFor('example.com').acknowledged, isTrue);
    expect(restored.stateFor('missing.com').status, HealthStatus.unknown);
  });

  test('decode of empty input is an empty repository', () {
    expect(MonitorRepository.decode('').monitors, isEmpty);
  });

  test('remove drops the monitor and its state', () {
    final repo = MonitorRepository();
    repo.upsert(MonitorConfig.forDomain('example.com'));
    repo.setState('example.com', const AlertState(status: HealthStatus.up));
    repo.markChecked('example.com', DateTime.utc(2026));
    repo.remove('example.com');
    expect(repo.monitors, isEmpty);
    expect(repo.stateFor('example.com').status, HealthStatus.unknown);
  });

  test('cadence gating via lastChecked survives a round-trip', () {
    final repo = MonitorRepository();
    final monitor = MonitorConfig.forDomain(
      'example.com',
      cadence: const Duration(minutes: 5),
    );
    final t0 = DateTime.utc(2026, 1, 1, 12);

    expect(repo.isDue(monitor, t0), isTrue);
    repo.markChecked(monitor.id, t0);
    expect(repo.isDue(monitor, t0.add(const Duration(minutes: 4))), isFalse);
    expect(repo.isDue(monitor, t0.add(const Duration(minutes: 5))), isTrue);

    final restored = MonitorRepository.decode(repo.encode());
    expect(
      restored.isDue(monitor, t0.add(const Duration(minutes: 1))),
      isFalse,
    );
  });

  group('last sweep', () {
    test('survives a round-trip', () {
      final repo = MonitorRepository();
      final swept = DateTime.utc(2026, 9, 27, 6, 30);
      repo.lastSweepAt = swept;

      final restored = MonitorRepository.decode(repo.encode());

      expect(restored.lastSweepAt, swept);
    });

    test('is absent on documents written before it existed', () {
      // A repository saved by an older build has no such key. It has to decode
      // to "never ran" rather than throwing, or the app would lose every
      // monitor the first time it is upgraded.
      final legacy = MonitorRepository.decode(
        '{"monitors":[],"states":{},"lastChecked":{},"checks":{}}',
      );

      expect(legacy.monitors, isEmpty);
      expect(legacy.lastSweepAt, isNull);
    });

    test('starts as null on a new repository', () {
      expect(MonitorRepository().lastSweepAt, isNull);
    });
  });

  group('monitoringPaused', () {
    test('round-trips', () {
      final repo = MonitorRepository()..monitoringPaused = true;

      expect(MonitorRepository.decode(repo.encode()).monitoringPaused, isTrue);
    });

    test('defaults to running', () {
      expect(MonitorRepository().monitoringPaused, isFalse);
    });

    test('a document written before the switch existed decodes as running', () {
      // Those builds could not turn the service off, so a missing key must not
      // read as "the user asked to stop".
      final legacy = MonitorRepository.decode(
        '{"monitors":[],"states":{},"lastChecked":{},"checks":{}}',
      );

      expect(legacy.monitoringPaused, isFalse);
    });

    test('a document with the key set to a non-boolean decodes as running', () {
      final odd = MonitorRepository.decode(
        '{"monitors":[],"states":{},"lastChecked":{},"checks":{},'
        '"monitoringPaused":"yes"}',
      );

      expect(odd.monitoringPaused, isFalse);
    });
  });
}
