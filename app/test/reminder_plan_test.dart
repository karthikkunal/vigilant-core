import 'package:flutter_test/flutter_test.dart';
import 'package:vigilant-core/monitors/monitor_config.dart';
import 'package:vigilant-core/monitors/monitor_repository.dart';
import 'package:vigilant-core/reminders/reminder_plan.dart';

void main() {
  final now = DateTime(2026, 1, 1, 12);

  test('plans reminders across monitors, soonest first', () {
    final repository = MonitorRepository();
    repository.upsert(
      MonitorConfig.forDomain(
        'a.com',
        registrationExpiry: DateTime(2026, 3, 1),
      ),
    );
    repository.upsert(
      MonitorConfig.forDomain(
        'b.com',
        registrationExpiry: DateTime(2026, 2, 1),
      ),
    );

    final reminders = planRemindersForRepository(repository, now: now);

    expect(reminders, hasLength(8));
    for (var i = 1; i < reminders.length; i++) {
      expect(reminders[i].fireAt.isBefore(reminders[i - 1].fireAt), isFalse);
    }
  });

  test('caps the total to the soonest reminders', () {
    final repository = MonitorRepository();
    for (var i = 0; i < 20; i++) {
      repository.upsert(
        MonitorConfig.forDomain(
          'd$i.com',
          registrationExpiry: DateTime(2026, 6, 1),
        ),
      );
    }

    // 20 monitors x 4 thresholds = 80, capped to 60 for the iOS limit.
    expect(planRemindersForRepository(repository, now: now), hasLength(60));
  });

  test('monitors without expiry dates contribute nothing', () {
    final repository = MonitorRepository();
    repository.upsert(MonitorConfig.forDomain('a.com'));
    expect(planRemindersForRepository(repository, now: now), isEmpty);
  });

  test('expiry dates survive a repository round-trip', () {
    final repository = MonitorRepository();
    repository.upsert(
      MonitorConfig.forDomain(
        'a.com',
        registrationExpiry: DateTime.utc(2027, 8, 13),
        certificateExpiry: DateTime.utc(2026, 11, 2),
      ),
    );

    final restored = MonitorRepository.decode(repository.encode());
    final monitor = restored.byId('a.com')!;
    expect(monitor.registrationExpiry, DateTime.utc(2027, 8, 13));
    expect(monitor.certificateExpiry, DateTime.utc(2026, 11, 2));
  });
}
