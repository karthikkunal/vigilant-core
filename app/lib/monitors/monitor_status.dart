import 'package:discovery_core/discovery_core.dart';

import 'monitor_config.dart';

/// The user-facing state of a monitor, including freshness.
///
/// [HealthStatus] describes the last probe result. A monitor can have a known
/// last result while that result is too old to trust as current, so freshness
/// is kept separate here rather than changing alert-engine semantics.
enum MonitorStatus { healthy, degraded, down, unknown, stale, paused }

extension MonitorStatusPresentation on MonitorStatus {
  String get label => switch (this) {
    MonitorStatus.healthy => 'Healthy',
    MonitorStatus.degraded => 'Responding slowly',
    MonitorStatus.down => 'Down',
    MonitorStatus.unknown => 'Unknown',
    MonitorStatus.stale => 'Stale',
    MonitorStatus.paused => 'Paused',
  };

  bool get needsAttention =>
      this == MonitorStatus.degraded ||
      this == MonitorStatus.down ||
      this == MonitorStatus.stale;
}

/// The last completed check and enough context to explain its freshness.
class MonitorCheckRecord {
  const MonitorCheckRecord({
    required this.status,
    required this.checkedAt,
    required this.provider,
    this.reason,
    this.latencyMs,
  });

  final HealthStatus status;
  final DateTime checkedAt;

  /// The target/source that answered the check, e.g. `Website target`.
  final String provider;
  final String? reason;
  final int? latencyMs;

  factory MonitorCheckRecord.fromVerdict(
    CheckVerdict verdict, {
    required String provider,
  }) => MonitorCheckRecord(
    status: verdict.status,
    checkedAt: verdict.at.toUtc(),
    provider: provider,
    reason: verdict.reason,
    latencyMs: verdict.latencyMs,
  );

  Map<String, Object?> toJson() => {
    'status': status.name,
    'checkedAt': checkedAt.toUtc().toIso8601String(),
    'provider': provider,
    'reason': reason,
    'latencyMs': latencyMs,
  };

  static MonitorCheckRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    final checkedAt = DateTime.tryParse(value['checkedAt'] as String? ?? '');
    if (checkedAt == null) return null;
    final statusName = value['status'] as String?;
    final status = HealthStatus.values.firstWhere(
      (candidate) => candidate.name == statusName,
      orElse: () => HealthStatus.unknown,
    );
    return MonitorCheckRecord(
      status: status,
      checkedAt: checkedAt.toUtc(),
      provider: value['provider'] as String? ?? 'Unknown provider',
      reason: value['reason'] as String?,
      latencyMs: (value['latencyMs'] as num?)?.toInt(),
    );
  }
}

/// Human-readable source name for a monitor's direct check.
String providerLabelFor(MonitorConfig monitor) =>
    monitor.isTcp ? 'TCP target' : 'Website target';

/// A monitor is stale after one cadence plus a five-minute scheduling grace.
Duration staleAfterFor(MonitorConfig monitor) =>
    monitor.cadence + const Duration(minutes: 5);

/// Resolves the current user-facing state from the last check and the clock.
MonitorStatus monitorStatusFor({
  required MonitorConfig monitor,
  required AlertState state,
  required MonitorCheckRecord? check,
  required DateTime? lastChecked,
  required DateTime now,
}) {
  if (!monitor.enabled) return MonitorStatus.paused;

  final checkedAt = check?.checkedAt ?? lastChecked;
  if (checkedAt == null) return MonitorStatus.unknown;
  if (now.difference(checkedAt) >= staleAfterFor(monitor)) {
    return MonitorStatus.stale;
  }

  return switch (check?.status ?? state.status) {
    HealthStatus.up => MonitorStatus.healthy,
    HealthStatus.degraded => MonitorStatus.degraded,
    HealthStatus.down => MonitorStatus.down,
    HealthStatus.unknown => MonitorStatus.unknown,
  };
}
