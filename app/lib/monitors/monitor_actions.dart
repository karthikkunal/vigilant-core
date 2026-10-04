import 'dart:async';
import 'dart:ui';

import 'package:discovery_core/discovery_core.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../alerts/pager_style.dart';
import 'monitor_service.dart';

/// Applies a page action (Acknowledge / Mute) to persisted state.
///
/// Runs in the notification action's background isolate when the app is not
/// running, so it must be a top-level function and must register plugins itself.
@pragma('vm:entry-point')
void notificationActionBackground(NotificationResponse response) {
  DartPluginRegistrant.ensureInitialized();
  unawaited(applyNotificationAction(response.actionId ?? '', response.payload));
}

/// Applies a page action to the stored repository. Safe to call from either
/// isolate; a missing monitor or unknown action is ignored.
Future<void> applyNotificationAction(String actionId, String? monitorId) async {
  if (monitorId == null || monitorId.isEmpty) return;
  const store = PluginMonitorStore();
  try {
    final repository = await store.load();
    final monitor = repository.byId(monitorId);
    if (monitor == null) return;

    const engine = AlertEngine();
    final state = repository.stateFor(monitorId);

    if (actionId == 'ack') {
      repository.setState(monitorId, engine.acknowledge(state));
    } else if (actionId == 'mute') {
      repository.setState(
        monitorId,
        engine.mute(
          state,
          DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
      );
    } else {
      // 'recheck' needs the runner, which is only available in the foreground.
      return;
    }

    await FlutterLocalNotificationsPlugin().cancel(
      id: notificationIdFor(monitorId),
    );
    await store.save(repository);
  } catch (_) {
    // An action that cannot be applied must never crash the isolate.
  }
}
