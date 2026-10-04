import 'package:discovery_core/discovery_core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime(2026, 1, 1, 12);

  test('one reminder per threshold, soonest first', () {
    final reminders = planExpiryReminders(
      subjectId: 'example.com',
      subjectName: 'example.com',
      registrationExpiry: DateTime(2026, 3, 1),
      now: now,
    );

    expect(reminders.map((r) => r.daysBefore), [30, 14, 7, 1]);
    expect(reminders.map((r) => r.kind).toSet(), {ExpiryKind.registration});
    expect(reminders.first.fireAt.isBefore(reminders.last.fireAt), isTrue);
  });

  test('reminders in the past are dropped', () {
    final reminders = planExpiryReminders(
      subjectId: 'example.com',
      subjectName: 'example.com',
      registrationExpiry: DateTime(2026, 1, 10),
      now: now,
    );

    // 30 and 14 days before are already past; 7 and 1 remain.
    expect(reminders.map((r) => r.daysBefore), [7, 1]);
  });

  test('registration and certificate reminders are interleaved by time', () {
    final reminders = planExpiryReminders(
      subjectId: 'example.com',
      subjectName: 'example.com',
      registrationExpiry: DateTime(2026, 3, 1),
      certificateExpiry: DateTime(2026, 2, 1),
      now: now,
    );

    expect(reminders, hasLength(8));
    for (var i = 1; i < reminders.length; i++) {
      expect(
        reminders[i].fireAt.isBefore(reminders[i - 1].fireAt),
        isFalse,
      );
    }
    expect(
      reminders.where((r) => r.kind == ExpiryKind.certificate),
      hasLength(4),
    );
  });

  test('the result is capped to the soonest reminders', () {
    final reminders = planExpiryReminders(
      subjectId: 'example.com',
      subjectName: 'example.com',
      registrationExpiry: DateTime(2026, 3, 1),
      certificateExpiry: DateTime(2026, 2, 1),
      maxScheduled: 3,
      now: now,
    );

    expect(reminders, hasLength(3));
    expect(reminders.last.fireAt.isBefore(DateTime(2026, 2, 1)), isTrue);
  });

  test('ids are stable and unique', () {
    final first = planExpiryReminders(
      subjectId: 'example.com',
      subjectName: 'example.com',
      registrationExpiry: DateTime(2026, 3, 1),
      now: now,
    );
    final second = planExpiryReminders(
      subjectId: 'example.com',
      subjectName: 'example.com',
      registrationExpiry: DateTime(2026, 3, 1),
      now: now.add(const Duration(days: 1)),
    );

    expect(first.map((r) => r.id).toSet(), hasLength(first.length));
    // The 30-day reminder may drop out, but surviving ids are identical.
    final survivors = second.map((r) => r.id).toSet();
    expect(survivors.difference(first.map((r) => r.id).toSet()), isEmpty);
  });

  test('no expiry dates means no reminders', () {
    final reminders = planExpiryReminders(
      subjectId: 'example.com',
      subjectName: 'example.com',
      now: now,
    );
    expect(reminders, isEmpty);
  });
}
