import 'package:discovery_core/discovery_core.dart' show ExpiryReminder;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../alerts/pager_style.dart' show notificationIdFor;

const String _channelId = 'vigilant-core_expiry';
const String _channelName = 'Expiry reminders';

/// Schedules (and replaces) expiry reminders. Abstract so it can be faked in
/// tests while the planning stays in `discovery_core`.
abstract class ReminderScheduler {
  /// Replaces every previously scheduled reminder with [reminders]. Callers pass
  /// the full, capped, soonest-first set.
  Future<void> replaceAll(List<ExpiryReminder> reminders);

  Future<void> cancelAll();
}

/// The OS alarm surface the scheduler needs, isolated so the reconciliation in
/// [LocalReminderScheduler] is testable without the notification plugin.
abstract class ReminderAlarms {
  /// The ids of every alarm the OS still holds for this app.
  ///
  /// This is deliberately the OS's own answer rather than a locally kept set: an
  /// alarm outlives the process that created it, so no in-process record can
  /// describe what is still pending after a restart.
  Future<List<int>> pendingIds();

  /// Schedules [reminder] under [id], replacing any alarm already on that id.
  Future<void> schedule(int id, ExpiryReminder reminder);

  Future<void> cancel(int id);
}

/// [ReminderAlarms] backed by `flutter_local_notifications`.
class _PluginAlarms implements ReminderAlarms {
  _PluginAlarms(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<List<int>> pendingIds() async {
    final pending = await _plugin.pendingNotificationRequests();
    return pending.map((request) => request.id).toList(growable: false);
  }

  @override
  Future<void> schedule(int id, ExpiryReminder reminder) =>
      // Inexact scheduling avoids the SCHEDULE_EXACT_ALARM permission; a
      // day-granularity reminder does not need exact timing.
      _plugin.zonedSchedule(
        id: id,
        title: reminder.title,
        body: reminder.body,
        scheduledDate: tz.TZDateTime.from(reminder.fireAt, tz.local),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);
}

/// The real scheduler, backed by `flutter_local_notifications`.
class LocalReminderScheduler implements ReminderScheduler {
  /// The production scheduler, driving the notification plugin directly.
  factory LocalReminderScheduler({FlutterLocalNotificationsPlugin? plugin}) {
    final resolved = plugin ?? FlutterLocalNotificationsPlugin();
    return LocalReminderScheduler._(resolved, _PluginAlarms(resolved));
  }

  /// A scheduler over a caller-supplied [alarms], for tests. The notification
  /// plugin is never constructed or initialised.
  factory LocalReminderScheduler.withAlarms(ReminderAlarms alarms) =>
      LocalReminderScheduler._(null, alarms);

  /// [plugin] is null exactly when [alarms] was supplied, which is also the only
  /// case where there is no plugin to initialise.
  LocalReminderScheduler._(this._plugin, this._alarms);

  final FlutterLocalNotificationsPlugin? _plugin;
  final ReminderAlarms _alarms;
  bool _ready = false;

  Future<void> _ensureReady() async {
    if (_ready) return;

    final plugin = _plugin;
    if (plugin != null) {
      tzdata.initializeTimeZones();

      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      );
      await plugin.initialize(settings: settings);

      await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: 'Registration and certificate expiry reminders.',
              importance: Importance.defaultImportance,
              enableVibration: false,
            ),
          );
    }

    _ready = true;
  }

  @override
  Future<void> replaceAll(List<ExpiryReminder> reminders) async {
    await _ensureReady();

    final wanted = {for (final reminder in reminders) _idFor(reminder)};

    // Reconcile against the OS instead of a locally remembered set. Anything the
    // OS still holds that the new plan does not name is stale and would fire
    // unbidden. Asking the OS is what closes every path that used to leak an
    // alarm: a deleted monitor, a reminder that drifted out of its
    // 30/14/7/1-day window, a plan truncated by the pending-notification cap,
    // and a crash between scheduling and the next launch.
    for (final id in await _pendingIds()) {
      if (!wanted.contains(id)) await _alarms.cancel(id);
    }

    for (final reminder in reminders) {
      await _alarms.schedule(_idFor(reminder), reminder);
    }
  }

  @override
  Future<void> cancelAll() async {
    await _ensureReady();
    for (final id in await _pendingIds()) {
      await _alarms.cancel(id);
    }
  }

  /// The pending alarm ids, or empty where the platform cannot report them.
  ///
  /// Web has no alarm store, and a platform that has not implemented the query
  /// keeps the previous behaviour — rescheduling over the same deterministic ids
  /// replaces rather than duplicates — rather than failing the reschedule.
  Future<List<int>> _pendingIds() async {
    if (kIsWeb) return const [];
    try {
      return await _alarms.pendingIds();
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    } on UnimplementedError {
      return const [];
    }
  }

  static int _idFor(ExpiryReminder reminder) =>
      notificationIdFor('reminder:${reminder.id}');
}
