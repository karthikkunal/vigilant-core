/// What a reminder is about.
enum ExpiryKind { registration, certificate }

/// A single scheduled reminder.
class ExpiryReminder {
  const ExpiryReminder({
    required this.id,
    required this.subjectId,
    required this.subjectName,
    required this.kind,
    required this.daysBefore,
    required this.fireAt,
  });

  /// Stable id, so rescheduling replaces rather than duplicates.
  final String id;
  final String subjectId;
  final String subjectName;
  final ExpiryKind kind;
  final int daysBefore;

  /// The local-time instant to fire at.
  final DateTime fireAt;

  String get title => switch (kind) {
        ExpiryKind.registration =>
          '$subjectName expires in $daysBefore day${daysBefore == 1 ? '' : 's'}',
        ExpiryKind.certificate =>
          'Certificate for $subjectName expires in $daysBefore day${daysBefore == 1 ? '' : 's'}',
      };

  String get body => switch (kind) {
        ExpiryKind.registration =>
          'Renew the domain registration to avoid losing it.',
        ExpiryKind.certificate => 'Renew or replace the TLS certificate.',
      };
}

/// The default reminder thresholds, in days before expiry.
const List<int> defaultExpiryThresholds = <int>[30, 14, 7, 1];

/// Plans the reminders for one subject.
///
/// Two behaviours matter: instants already in the past are dropped, and the
/// result is capped to [maxScheduled] soonest — which is how the iOS limit of 64
/// pending local notifications is respected across all monitored domains.
List<ExpiryReminder> planExpiryReminders({
  required String subjectId,
  required String subjectName,
  DateTime? registrationExpiry,
  DateTime? certificateExpiry,
  List<int> thresholds = defaultExpiryThresholds,
  DateTime? now,
  int maxScheduled = 60,
  int fireHour = 9,
}) {
  final reference = now ?? DateTime.now();
  final reminders = <ExpiryReminder>[];

  void add(ExpiryKind kind, DateTime expiry) {
    final localExpiry = expiry.toLocal();
    for (final days in thresholds) {
      final day = localExpiry.subtract(Duration(days: days));
      final fireAt = DateTime(day.year, day.month, day.day, fireHour);
      if (!fireAt.isAfter(reference)) continue;
      reminders.add(
        ExpiryReminder(
          id: '$subjectId:${kind.name}:$days',
          subjectId: subjectId,
          subjectName: subjectName,
          kind: kind,
          daysBefore: days,
          fireAt: fireAt,
        ),
      );
    }
  }

  if (registrationExpiry != null) {
    add(ExpiryKind.registration, registrationExpiry);
  }
  if (certificateExpiry != null) {
    add(ExpiryKind.certificate, certificateExpiry);
  }

  reminders.sort((a, b) => a.fireAt.compareTo(b.fireAt));
  return reminders.length > maxScheduled
      ? reminders.sublist(0, maxScheduled)
      : reminders;
}
