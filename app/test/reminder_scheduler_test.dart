import 'package:discovery_core/discovery_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vigilant-core/reminders/reminder_scheduler.dart';

import 'package:vigilant-core/alerts/pager_style.dart' show notificationIdFor;

/// Models the OS alarm store. Ids persist until cancelled, independently of
/// whichever process scheduled them, which is the property the scheduler has to
/// cope with.
class _FakeAlarms implements ReminderAlarms {
  final Set<int> pending = <int>{};
  final List<ExpiryReminder> scheduled = <ExpiryReminder>[];
  final List<int> cancelled = <int>[];

  @override
  Future<List<int>> pendingIds() async => pending.toList(growable: false);

  @override
  Future<void> schedule(int id, ExpiryReminder reminder) async {
    pending.add(id);
    scheduled.add(reminder);
  }

  @override
  Future<void> cancel(int id) async {
    pending.remove(id);
    cancelled.add(id);
  }
}

/// A platform that cannot report pending alarms, so reconciliation is skipped.
class _UnreportableAlarms extends _FakeAlarms {
  @override
  Future<List<int>> pendingIds() async =>
      throw UnimplementedError('no alarm store on this platform');
}

int _idFor(ExpiryReminder reminder) =>
    notificationIdFor('reminder:${reminder.id}');

ExpiryReminder _reminder({
  String subject = 'example.com',
  ExpiryKind kind = ExpiryKind.certificate,
  int daysBefore = 30,
  DateTime? fireAt,
}) => ExpiryReminder(
  id: '$subject:${kind.name}:$daysBefore',
  subjectId: subject,
  subjectName: subject,
  kind: kind,
  daysBefore: daysBefore,
  fireAt: fireAt ?? DateTime(2027, 1, 1, 9),
);

void main() {
  group('LocalReminderScheduler', () {
    test('schedules every reminder in the plan', () async {
      final alarms = _FakeAlarms();
      final reminders = [_reminder(daysBefore: 30), _reminder(daysBefore: 7)];

      await LocalReminderScheduler.withAlarms(alarms).replaceAll(reminders);

      expect(alarms.pending, {_idFor(reminders[0]), _idFor(reminders[1])});
      expect(alarms.scheduled, reminders);
    });

    test('cancels an alarm orphaned by a deleted monitor after a restart', () async {
      final alarms = _FakeAlarms();
      final reminder = _reminder();

      // A previous launch scheduled this alarm.
      await LocalReminderScheduler.withAlarms(alarms).replaceAll([reminder]);
      expect(alarms.pending, hasLength(1));

      // The monitor was then deleted. A fresh scheduler stands in for the next
      // process, which inherits the alarm but knows nothing about it.
      await LocalReminderScheduler.withAlarms(alarms).replaceAll(const []);

      expect(alarms.pending, isEmpty);
      expect(alarms.cancelled, [_idFor(reminder)]);
    });

    test('cancels a reminder that drifted out of the expiry window', () async {
      final alarms = _FakeAlarms();
      final stale = _reminder(daysBefore: 30);
      final kept = _reminder(daysBefore: 7);

      await LocalReminderScheduler.withAlarms(alarms).replaceAll([stale, kept]);
      alarms.cancelled.clear();

      // The 30-day reminder no longer plans; the 7-day one still does.
      await LocalReminderScheduler.withAlarms(alarms).replaceAll([kept]);

      expect(alarms.cancelled, [_idFor(stale)]);
      expect(alarms.pending, {_idFor(kept)});
    });

    test('cancels reminders dropped by the pending-notification cap', () async {
      final alarms = _FakeAlarms();
      final beyondCap = _reminder(subject: 'a.example', daysBefore: 1);
      final withinCap = _reminder(subject: 'b.example', daysBefore: 1);

      await LocalReminderScheduler.withAlarms(alarms)
          .replaceAll([beyondCap, withinCap]);
      alarms.cancelled.clear();

      // The cap truncated the plan, so the surplus alarm is not rescheduled.
      await LocalReminderScheduler.withAlarms(alarms).replaceAll([withinCap]);

      expect(alarms.cancelled, [_idFor(beyondCap)]);
      expect(alarms.pending, {_idFor(withinCap)});
    });

    test(
      'leaves still-planned alarms alone rather than churning them',
      () async {
        final alarms = _FakeAlarms();
        final reminders = [_reminder(daysBefore: 30), _reminder(daysBefore: 7)];

        await LocalReminderScheduler.withAlarms(alarms).replaceAll(reminders);
        alarms.cancelled.clear();
        final scheduledBefore = alarms.scheduled.length;

        await LocalReminderScheduler.withAlarms(alarms).replaceAll(reminders);

        expect(alarms.cancelled, isEmpty);
        expect(alarms.scheduled, hasLength(scheduledBefore + reminders.length));
        expect(alarms.pending, hasLength(reminders.length));
      },
    );

    test('cancelAll clears alarms inherited from a previous process', () async {
      final alarms = _FakeAlarms();
      await LocalReminderScheduler.withAlarms(alarms)
          .replaceAll([_reminder(daysBefore: 30), _reminder(daysBefore: 14)]);

      await LocalReminderScheduler.withAlarms(alarms).cancelAll();

      expect(alarms.pending, isEmpty);
    });

    test(
      'still reschedules when the platform cannot report pending alarms',
      () async {
        final alarms = _UnreportableAlarms();
        final reminder = _reminder();

        await LocalReminderScheduler.withAlarms(alarms).replaceAll([reminder]);

        expect(alarms.scheduled, [reminder]);
        expect(alarms.pending, {_idFor(reminder)});
      },
    );
  });
}
