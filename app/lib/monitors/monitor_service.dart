import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;

import '../alerts/pager.dart';
import 'monitor_repository.dart';
import 'monitor_runner.dart';
import 'monitor_status.dart';

/// Persists the repository in storage shared between the UI isolate and the
/// service isolate, using `flutter_foreground_task`'s SharedPreferences-backed
/// data API.
class PluginMonitorStore implements MonitorStore {
  const PluginMonitorStore();

  static const String _key = 'vigilant-core.repository.v1';

  @override
  Future<MonitorRepository> load() async {
    final raw = await FlutterForegroundTask.getData<String>(key: _key);
    return MonitorRepository.decode(raw ?? '');
  }

  @override
  Future<void> save(MonitorRepository repository) =>
      FlutterForegroundTask.saveData(key: _key, value: repository.encode());
}

/// Controls the foreground service. Abstracted so the coordinator is testable
/// without the plugin.
abstract class ServiceController {
  Future<bool> isRunning();
  Future<void> start();
  Future<void> stop();
}

/// Controls the Android foreground service that keeps checks — and therefore
/// pages — running while the app is closed.
class MonitorService implements ServiceController {
  const MonitorService();

  /// Must be called once, from the UI isolate, before [start].
  void init() {
    // The foreground-service plugin has no web implementation. Web monitors
    // remain persisted and can be checked while the app is open.
    if (kIsWeb) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'vigilant-core_service',
        channelName: 'vigilant-core monitoring',
        channelDescription: 'Runs checks on this device so pages arrive.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
      ),
    );
  }

  @override
  Future<bool> isRunning() => kIsWeb
      ? Future<bool>.value(false)
      : FlutterForegroundTask.isRunningService;

  @override
  Future<void> start() async {
    if (kIsWeb) return;
    final running = await FlutterForegroundTask.isRunningService;
    final result = running
        ? await FlutterForegroundTask.updateService(
            callback: startMonitorCallback,
          )
        : await FlutterForegroundTask.startService(
            serviceTypes: const [ForegroundServiceTypes.specialUse],
            notificationTitle: 'vigilant-core is monitoring',
            notificationText: 'Checks and pages run on this device.',
            callback: startMonitorCallback,
          );

    switch (result) {
      case ServiceRequestSuccess():
        return;
      case ServiceRequestFailure(:final error):
        throw StateError('Could not start monitoring service: $error');
    }
  }

  @override
  Future<void> stop() async {
    if (kIsWeb) return;
    await FlutterForegroundTask.stopService();
  }
}

/// Entry point for the service isolate.
@pragma('vm:entry-point')
void startMonitorCallback() {
  FlutterForegroundTask.setTaskHandler(MonitorTaskHandler());
}

/// Runs the due monitors on every service tick.
class MonitorTaskHandler extends TaskHandler {
  final MonitorStore _store = const PluginMonitorStore();

  Pager? _pager;
  http.Client? _client;
  MonitorRunner? _runner;
  bool _ticking = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    DartPluginRegistrant.ensureInitialized();
    _pager = LocalPager(
      requestPermissions: false,
      onAction: (actionId, monitorId) {
        unawaited(_handleAction(actionId, monitorId));
      },
      onBackgroundAction: (response) {
        unawaited(_handleAction(response.actionId ?? '', response.payload));
      },
    );
    await _pager!.initialize();
    _client = http.Client();
    _runner = MonitorRunner(pager: _pager!, client: _client);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // onRepeatEvent is synchronous, so the work is kicked off and guarded
    // against overlap rather than awaited here.
    unawaited(_tick());
  }

  Future<void> _handleAction(String actionId, String? monitorId) async {
    final runner = _runner;
    final pager = _pager;
    if (runner == null ||
        pager == null ||
        monitorId == null ||
        monitorId.isEmpty) {
      return;
    }

    try {
      final repository = await _store.load();
      final monitor = repository.byId(monitorId);
      if (monitor == null) return;

      final state = repository.stateFor(monitorId);
      final now = DateTime.now().toUtc();
      switch (actionId) {
        case 'ack':
          repository.setState(monitorId, runner.acknowledge(monitor, state));
          await pager.clear(monitorId);
          break;
        case 'mute':
          repository.setState(
            monitorId,
            runner.mute(state, now.add(const Duration(hours: 1))),
          );
          await pager.clear(monitorId);
          break;
        case 'recheck':
          final result = await runner.run(monitor, state, now: now);
          repository.setState(monitorId, result.state);
          repository.recordCheck(
            monitorId,
            result.verdict,
            provider: providerLabelFor(monitor),
          );
          break;
        default:
          return;
      }
      await _store.save(repository);
    } catch (_) {
      // A failed action is retried by the next user interaction or service tick.
    }
  }

  Future<void> _tick() async {
    if (_ticking) return;
    final runner = _runner;
    if (runner == null) return;
    _ticking = true;
    try {
      final repository = await _store.load();
      final now = DateTime.now().toUtc();

      // Recorded before the loop and saved after it, so a sweep that found
      // nothing due still counts as a sweep. Without this the app cannot tell
      // "no target is failing" from "the OS stopped scheduling us", which is
      // exactly the distinction a stale per-monitor timestamp hides.
      repository.lastSweepAt = now;

      for (final monitor in repository.enabledMonitors.toList(
        growable: false,
      )) {
        if (!repository.isDue(monitor, now)) continue;
        final result = await runner.run(
          monitor,
          repository.stateFor(monitor.id),
          now: now,
        );
        repository.setState(monitor.id, result.state);
        repository.recordCheck(
          monitor.id,
          result.verdict,
          provider: providerLabelFor(monitor),
        );
      }

      await _store.save(repository);
    } catch (_) {
      // A failed tick is retried on the next repeat; never crash the service.
    } finally {
      _ticking = false;
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _client?.close();
    _client = null;
    _runner = null;
  }
}
