/// Health of a monitored target.
enum HealthStatus {
  /// No check has produced a verdict yet.
  unknown,

  /// Responding within its latency budget.
  up,

  /// Responding, but slower than its budget.
  degraded,

  /// Not responding, or responding incorrectly.
  down,
}

/// One check result, fed into the alert engine.
class CheckVerdict {
  const CheckVerdict({
    required this.status,
    required this.at,
    this.latencyMs,
    this.reason,
  });

  final HealthStatus status;
  final DateTime at;
  final int? latencyMs;

  /// Human-readable cause, carried into the alert.
  final String? reason;

  static CheckVerdict up(DateTime at, {int? latencyMs}) =>
      CheckVerdict(status: HealthStatus.up, at: at, latencyMs: latencyMs);

  static CheckVerdict degraded(DateTime at, {int? latencyMs, String? reason}) =>
      CheckVerdict(
        status: HealthStatus.degraded,
        at: at,
        latencyMs: latencyMs,
        reason: reason,
      );

  static CheckVerdict down(DateTime at, {String? reason, int? latencyMs}) =>
      CheckVerdict(
        status: HealthStatus.down,
        at: at,
        latencyMs: latencyMs,
        reason: reason,
      );
}
