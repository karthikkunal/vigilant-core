import 'dart:convert';

import 'package:discovery_core/discovery_core.dart';

import 'monitor_config.dart';
import 'monitor_status.dart';

/// The persisted set of monitors, their alert state, and their last check
/// records. Serialises to a single JSON string; where it is written is the
/// app's choice, which keeps this testable without touching the filesystem.
///
/// [MonitorStore] is the persistence boundary, so tests can supply an
/// in-memory implementation.
abstract class MonitorStore {
  Future<MonitorRepository> load();
  Future<void> save(MonitorRepository repository);
}

class MonitorRepository {
  MonitorRepository({
    List<MonitorConfig>? monitors,
    Map<String, AlertState>? states,
    Map<String, DateTime>? lastChecked,
    Map<String, MonitorCheckRecord>? checks,
    this.lastSweepAt,
    this.monitoringPaused = false,
  }) : monitors = monitors ?? <MonitorConfig>[],
       states = states ?? <String, AlertState>{},
       lastChecked = lastChecked ?? <String, DateTime>{},
       checks = checks ?? <String, MonitorCheckRecord>{};

  final List<MonitorConfig> monitors;
  final Map<String, AlertState> states;
  final Map<String, DateTime> lastChecked;
  final Map<String, MonitorCheckRecord> checks;

  /// When the background service last ran a check sweep, in UTC.
  ///
  /// This is the one field that answers "did the scheduler actually run?".
  /// A monitor's own [lastChecked] entry cannot: a service the OS never
  /// scheduled, or one killed under Doze, leaves every per-monitor timestamp
  /// looking equally stale, which is indistinguishable from every target being
  /// down. Recording the sweep itself separates "nothing is wrong" from
  /// "nothing ran", and it is written even on a sweep where no monitor was
  /// due. Null means the sweep has never run on this device.
  DateTime? lastSweepAt;

  /// Whether the user has asked for background monitoring to stop.
  ///
  /// Without this there is no way to turn the service off: a monitor can be
  /// disabled, which stops it being checked, but the foreground service and its
  /// persistent notification stay. This is that switch, and it is persisted
  /// because a service that restarts on boot has to come back up respecting it.
  ///
  /// It is written only after the service call has actually succeeded, so this
  /// never says "stopped" for a service that is still running.
  bool monitoringPaused;

  AlertState stateFor(String id) => states[id] ?? AlertState.initial;

  MonitorCheckRecord? checkFor(String id) => checks[id];

  void setState(String id, AlertState state) => states[id] = state;

  void recordCheck(
    String id,
    CheckVerdict verdict, {
    required String provider,
  }) {
    final record = MonitorCheckRecord.fromVerdict(verdict, provider: provider);
    checks[id] = record;
    markChecked(id, record.checkedAt);
  }

  MonitorConfig? byId(String id) {
    for (final monitor in monitors) {
      if (monitor.id == id) return monitor;
    }
    return null;
  }

  Iterable<MonitorConfig> get enabledMonitors =>
      monitors.where((m) => m.enabled);

  /// Whether [monitor] is due for a check at [now], by its own cadence.
  bool isDue(MonitorConfig monitor, DateTime now) {
    final last = lastChecked[monitor.id];
    return last == null || now.difference(last) >= monitor.cadence;
  }

  void markChecked(String id, DateTime at) => lastChecked[id] = at;

  void upsert(MonitorConfig monitor) {
    final index = monitors.indexWhere((m) => m.id == monitor.id);
    if (index == -1) {
      monitors.add(monitor);
    } else {
      monitors[index] = monitor;
    }
  }

  void remove(String id) {
    monitors.removeWhere((m) => m.id == id);
    states.remove(id);
    lastChecked.remove(id);
    checks.remove(id);
  }

  Map<String, Object?> toJson() => {
    'monitors': monitors.map((m) => m.toJson()).toList(growable: false),
    'states': states.map((key, value) => MapEntry(key, value.toJson())),
    'lastChecked': lastChecked.map(
      (key, value) => MapEntry(key, value.toIso8601String()),
    ),
    'checks': checks.map((key, value) => MapEntry(key, value.toJson())),
    // Absent on documents written before the sweep existed, which decodes to
    // null and reads as "has never run" rather than failing.
    'lastSweepAt': lastSweepAt?.toIso8601String(),
    // Absent on documents written before the pause switch existed. A missing
    // key means the user never asked to stop, which is what those builds were
    // doing by default.
    'monitoringPaused': monitoringPaused,
  };

  String encode() => jsonEncode(toJson());

  factory MonitorRepository.decode(String source) {
    if (source.trim().isEmpty) return MonitorRepository();
    final json = (jsonDecode(source) as Map).cast<String, Object?>();

    final monitors = ((json['monitors'] as List?) ?? const [])
        .map((e) => MonitorConfig.fromJson((e as Map).cast<String, Object?>()))
        .toList();

    final states = <String, AlertState>{};
    final rawStates =
        (json['states'] as Map?)?.cast<String, Object?>() ?? const {};
    rawStates.forEach((key, value) {
      states[key] = AlertState.fromJson((value as Map).cast<String, Object?>());
    });

    final lastChecked = <String, DateTime>{};
    final rawChecked =
        (json['lastChecked'] as Map?)?.cast<String, Object?>() ?? const {};
    rawChecked.forEach((key, value) {
      final parsed = value == null ? null : DateTime.tryParse(value as String);
      if (parsed != null) lastChecked[key] = parsed;
    });

    final checks = <String, MonitorCheckRecord>{};
    final rawChecks =
        (json['checks'] as Map?)?.cast<String, Object?>() ?? const {};
    rawChecks.forEach((key, value) {
      final parsed = MonitorCheckRecord.fromJson(value);
      if (parsed != null) checks[key] = parsed;
    });

    return MonitorRepository(
      monitors: monitors,
      states: states,
      lastChecked: lastChecked,
      checks: checks,
      lastSweepAt: DateTime.tryParse('${json['lastSweepAt'] ?? ''}'),
      monitoringPaused: json['monitoringPaused'] == true,
    );
  }
}
