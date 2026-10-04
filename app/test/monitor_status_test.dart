import 'package:discovery_core/discovery_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vigilant-core/monitors/monitor_config.dart';
import 'package:vigilant-core/monitors/monitor_repository.dart';
import 'package:vigilant-core/monitors/monitor_status.dart';

void main() {
  final monitor = MonitorConfig.forDomain(
    'example.com',
    cadence: const Duration(minutes: 5),
  );
  final now = DateTime.utc(2026, 1, 1, 12);

  test('maps the latest check to healthy, down, and unknown', () {
    final healthy = MonitorCheckRecord(
      status: HealthStatus.up,
      checkedAt: now,
      provider: 'Website target',
    );
    final down = MonitorCheckRecord(
      status: HealthStatus.down,
      checkedAt: now,
      provider: 'Website target',
    );

    expect(
      monitorStatusFor(
        monitor: monitor,
        state: AlertState.initial,
        check: healthy,
        lastChecked: now,
        now: now,
      ),
      MonitorStatus.healthy,
    );
    expect(
      monitorStatusFor(
        monitor: monitor,
        state: const AlertState(status: HealthStatus.down),
        check: down,
        lastChecked: now,
        now: now,
      ),
      MonitorStatus.down,
    );
    expect(
      monitorStatusFor(
        monitor: monitor,
        state: AlertState.initial,
        check: null,
        lastChecked: null,
        now: now,
      ),
      MonitorStatus.unknown,
    );
  });

  test('marks an old result stale after cadence plus grace', () {
    final check = MonitorCheckRecord(
      status: HealthStatus.up,
      checkedAt: now.subtract(const Duration(minutes: 10)),
      provider: 'Website target',
    );

    expect(
      monitorStatusFor(
        monitor: monitor,
        state: const AlertState(status: HealthStatus.up),
        check: check,
        lastChecked: check.checkedAt,
        now: now,
      ),
      MonitorStatus.stale,
    );
  });

  test('keeps degraded and paused states distinct', () {
    final check = MonitorCheckRecord(
      status: HealthStatus.degraded,
      checkedAt: now,
      provider: 'Website target',
    );
    expect(
      monitorStatusFor(
        monitor: monitor,
        state: const AlertState(status: HealthStatus.degraded),
        check: check,
        lastChecked: now,
        now: now,
      ),
      MonitorStatus.degraded,
    );
    expect(
      monitorStatusFor(
        monitor: monitor.copyWith(enabled: false),
        state: const AlertState(status: HealthStatus.up),
        check: check,
        lastChecked: now,
        now: now,
      ),
      MonitorStatus.paused,
    );
  });

  test('persists the provider and last result with the repository', () {
    final repository = MonitorRepository();
    repository.recordCheck(
      monitor.id,
      CheckVerdict.up(now, latencyMs: 120),
      provider: providerLabelFor(monitor),
    );

    final restored = MonitorRepository.decode(repository.encode());
    final check = restored.checkFor(monitor.id);

    expect(check, isNotNull);
    expect(check!.provider, 'Website target');
    expect(check.status, HealthStatus.up);
    expect(check.latencyMs, 120);
    expect(restored.lastChecked[monitor.id], now);
  });

  test('removing a monitor removes its check record', () {
    final repository = MonitorRepository();
    repository.recordCheck(
      monitor.id,
      CheckVerdict.down(now),
      provider: providerLabelFor(monitor),
    );

    repository.remove(monitor.id);

    expect(repository.checkFor(monitor.id), isNull);
    expect(repository.lastChecked[monitor.id], isNull);
  });
}
