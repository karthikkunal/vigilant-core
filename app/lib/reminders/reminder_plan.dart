import 'package:discovery_core/discovery_core.dart';

import '../monitors/monitor_repository.dart';

/// Plans every reminder across all monitors, capped to the soonest
/// [maxScheduled] so the iOS pending-notification limit is never exceeded.
List<ExpiryReminder> planRemindersForRepository(
  MonitorRepository repository, {
  DateTime? now,
  int maxScheduled = 60,
}) {
  final reminders = <ExpiryReminder>[];
  for (final monitor in repository.monitors) {
    reminders.addAll(
      planExpiryReminders(
        subjectId: monitor.id,
        subjectName: monitor.name,
        registrationExpiry: monitor.registrationExpiry,
        certificateExpiry: monitor.certificateExpiry,
        now: now,
        maxScheduled: maxScheduled,
      ),
    );
  }

  reminders.sort((a, b) => a.fireAt.compareTo(b.fireAt));
  return reminders.length > maxScheduled
      ? reminders.sublist(0, maxScheduled)
      : reminders;
}
