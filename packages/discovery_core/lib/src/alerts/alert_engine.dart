import 'alert_policy.dart';
import 'alert_state.dart';
import 'health.dart';

/// The decide-what-to-alert state machine. Pure and deterministic: given the
/// previous state, a verdict and a clock, it returns the new state and the
/// alerts to deliver. No Android, no iOS, no I/O.
class AlertEngine {
  const AlertEngine();

  AlertOutcome evaluate({
    required AlertState state,
    required CheckVerdict verdict,
    required AlertPolicy policy,
    required DateTime now,
  }) {
    final intents = <AlertIntent>[];
    final wasDown = state.status == HealthStatus.down;
    final wasDegraded = state.status == HealthStatus.degraded;

    final failures =
        verdict.status == HealthStatus.down ? state.consecutiveFailures + 1 : 0;
    final degraded = verdict.status == HealthStatus.degraded
        ? state.consecutiveDegraded + 1
        : 0;

    // A down verdict only becomes an outage once the threshold is met; until
    // then the previous status stands, so a single blip changes nothing.
    final HealthStatus effective;
    if (verdict.status == HealthStatus.down) {
      effective = failures >= policy.failureThreshold
          ? HealthStatus.down
          : state.status;
    } else {
      effective = verdict.status;
    }

    var lastDown = state.lastDownAlertAt;
    var lastRepeat = state.lastRepeatAt;
    var acknowledged = state.acknowledged;
    final lastChange = effective != state.status ? now : state.lastChangeAt;

    final muted = state.isMutedAt(now);

    // Entering down.
    if (effective == HealthStatus.down && !wasDown) {
      acknowledged = false;
      if (!muted &&
          _cooldownElapsed(now, lastDown, policy.cooldown) &&
          _quietAllows(now, policy, policy.urgent)) {
        intents.add(AlertIntent(
          kind: AlertKind.down,
          at: now,
          urgent: policy.urgent,
          reason: verdict.reason,
        ));
        lastDown = now;
        lastRepeat = now;
      }
    }

    // Leaving down.
    if (wasDown && effective != HealthStatus.down) {
      acknowledged = false;
      if (policy.notifyOnRecovery &&
          !muted &&
          _quietAllows(now, policy, false)) {
        intents.add(AlertIntent(
          kind: AlertKind.recovery,
          at: now,
          reason: verdict.reason,
        ));
      }
    }

    // Degraded has its own track, independent of down.
    if (policy.notifyOnDegraded) {
      if (effective == HealthStatus.degraded && !wasDegraded) {
        if (!muted && _quietAllows(now, policy, false)) {
          intents.add(AlertIntent(
            kind: AlertKind.degraded,
            at: now,
            reason: verdict.reason,
          ));
        }
      } else if (wasDegraded && effective == HealthStatus.up) {
        if (!muted && _quietAllows(now, policy, false)) {
          intents.add(AlertIntent(kind: AlertKind.degradedRecovery, at: now));
        }
      }
    }

    // Repeat while down, until acknowledged.
    if (effective == HealthStatus.down &&
        !acknowledged &&
        (policy.urgent || policy.repeatWhileDown)) {
      final base = lastRepeat ?? lastDown ?? lastChange ?? now;
      if (now.difference(base) >= policy.repeatInterval &&
          !muted &&
          _quietAllows(now, policy, policy.urgent)) {
        intents.add(AlertIntent(
          kind: AlertKind.down,
          at: now,
          urgent: policy.urgent,
          repeat: true,
          reason: verdict.reason,
        ));
        lastRepeat = now;
      }
    }

    return AlertOutcome(
      AlertState(
        status: effective,
        consecutiveFailures: failures,
        consecutiveDegraded: degraded,
        lastDownAlertAt: lastDown,
        lastRepeatAt: lastRepeat,
        acknowledged: acknowledged,
        mutedUntil: state.mutedUntil,
        lastChangeAt: lastChange,
      ),
      intents,
    );
  }

  /// Silences repeats for the current outage only. Recovery re-arms.
  AlertState acknowledge(AlertState state) => AlertState(
        status: state.status,
        consecutiveFailures: state.consecutiveFailures,
        consecutiveDegraded: state.consecutiveDegraded,
        lastDownAlertAt: state.lastDownAlertAt,
        lastRepeatAt: null,
        acknowledged: true,
        mutedUntil: state.mutedUntil,
        lastChangeAt: state.lastChangeAt,
      );

  /// Suppresses every alert until [until].
  AlertState mute(AlertState state, DateTime until) => AlertState(
        status: state.status,
        consecutiveFailures: state.consecutiveFailures,
        consecutiveDegraded: state.consecutiveDegraded,
        lastDownAlertAt: state.lastDownAlertAt,
        lastRepeatAt: state.lastRepeatAt,
        acknowledged: state.acknowledged,
        mutedUntil: until,
        lastChangeAt: state.lastChangeAt,
      );

  bool _cooldownElapsed(DateTime now, DateTime? last, Duration cooldown) =>
      last == null || now.difference(last) >= cooldown;

  bool _quietAllows(DateTime now, AlertPolicy policy, bool urgent) {
    final quiet = policy.quietHours;
    if (quiet == null) return true;
    if (!quiet.contains(now)) return true;
    return urgent && quiet.bypassForUrgent;
  }
}
