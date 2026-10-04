import 'package:discovery_core/discovery_core.dart';
import 'package:test/test.dart';

void main() {
  const engine = AlertEngine();
  final t0 = DateTime(2026, 1, 1, 12, 0);

  AlertOutcome run(
    AlertState state,
    CheckVerdict verdict,
    AlertPolicy policy,
    DateTime now,
  ) =>
      engine.evaluate(
        state: state,
        verdict: verdict,
        policy: policy,
        now: now,
      );

  test('a blip below the threshold does not alert', () {
    const policy = AlertPolicy(failureThreshold: 3);

    var outcome = run(AlertState.initial, CheckVerdict.down(t0), policy, t0);
    expect(outcome.intents, isEmpty);
    expect(outcome.state.status, HealthStatus.unknown);

    outcome = run(
      outcome.state,
      CheckVerdict.down(t0.add(const Duration(minutes: 1))),
      policy,
      t0.add(const Duration(minutes: 1)),
    );
    expect(outcome.intents, isEmpty);

    outcome = run(
      outcome.state,
      CheckVerdict.down(t0.add(const Duration(minutes: 2))),
      policy,
      t0.add(const Duration(minutes: 2)),
    );
    expect(outcome.intents.map((i) => i.kind), [AlertKind.down]);
    expect(outcome.state.status, HealthStatus.down);
  });

  test('emits recovery when the target comes back', () {
    const policy = AlertPolicy();

    var outcome = run(AlertState.initial, CheckVerdict.down(t0), policy, t0);
    expect(outcome.intents.single.kind, AlertKind.down);

    outcome = run(
      outcome.state,
      CheckVerdict.up(t0.add(const Duration(minutes: 1))),
      policy,
      t0.add(const Duration(minutes: 1)),
    );
    expect(outcome.intents.single.kind, AlertKind.recovery);
    expect(outcome.state.status, HealthStatus.up);
  });

  test('cooldown suppresses a re-alert after a flap', () {
    const policy = AlertPolicy(cooldown: Duration(minutes: 10));

    var outcome = run(AlertState.initial, CheckVerdict.down(t0), policy, t0);
    expect(outcome.intents, hasLength(1));

    outcome = run(
      outcome.state,
      CheckVerdict.up(t0.add(const Duration(minutes: 1))),
      policy,
      t0.add(const Duration(minutes: 1)),
    );

    outcome = run(
      outcome.state,
      CheckVerdict.down(t0.add(const Duration(minutes: 2))),
      policy,
      t0.add(const Duration(minutes: 2)),
    );
    expect(
      outcome.intents.where((i) => i.kind == AlertKind.down),
      isEmpty,
    );
  });

  test('urgent repeats until acknowledged, then recovery re-arms', () {
    const policy = AlertPolicy(
      urgent: true,
      repeatInterval: Duration(minutes: 5),
    );

    var outcome = run(AlertState.initial, CheckVerdict.down(t0), policy, t0);
    expect(outcome.intents.single.kind, AlertKind.down);
    expect(outcome.intents.single.repeat, isFalse);

    outcome = run(
      outcome.state,
      CheckVerdict.down(t0.add(const Duration(minutes: 5))),
      policy,
      t0.add(const Duration(minutes: 5)),
    );
    expect(outcome.intents.single.repeat, isTrue);
    expect(outcome.intents.single.urgent, isTrue);

    final acked = engine.acknowledge(outcome.state);
    final quietTick = t0.add(const Duration(minutes: 20));
    final afterAck =
        run(acked, CheckVerdict.down(quietTick), policy, quietTick);
    expect(afterAck.intents, isEmpty);
    expect(afterAck.state.acknowledged, isTrue);

    final recovered = quietTick.add(const Duration(minutes: 1));
    final reArmed =
        run(afterAck.state, CheckVerdict.up(recovered), policy, recovered);
    expect(reArmed.state.acknowledged, isFalse);
  });

  test('quiet hours suppress non-urgent alerts, urgent bypasses', () {
    final midnight = DateTime(2026, 1, 1, 23, 0);

    final quiet = AlertPolicy(
      quietHours: QuietHours.fromClock(
        startHour: 22,
        startMinute: 0,
        endHour: 7,
        endMinute: 0,
      ),
    );
    var outcome =
        run(AlertState.initial, CheckVerdict.down(midnight), quiet, midnight);
    expect(outcome.intents, isEmpty);

    final quietUrgent = AlertPolicy(
      urgent: true,
      quietHours: QuietHours.fromClock(
        startHour: 22,
        startMinute: 0,
        endHour: 7,
        endMinute: 0,
        bypassForUrgent: true,
      ),
    );
    outcome = run(
        AlertState.initial, CheckVerdict.down(midnight), quietUrgent, midnight);
    expect(outcome.intents, hasLength(1));
  });

  test('mute suppresses alerts', () {
    const policy = AlertPolicy();
    final muted =
        engine.mute(AlertState.initial, t0.add(const Duration(hours: 1)));
    final outcome = run(muted, CheckVerdict.down(t0), policy, t0);
    expect(outcome.intents, isEmpty);
  });

  test('degraded runs on its own track with its own recovery', () {
    const policy = AlertPolicy();

    var outcome = run(AlertState.initial, CheckVerdict.up(t0), policy, t0);
    expect(outcome.intents, isEmpty);

    outcome = run(
      outcome.state,
      CheckVerdict.degraded(t0.add(const Duration(minutes: 1)),
          latencyMs: 4000),
      policy,
      t0.add(const Duration(minutes: 1)),
    );
    expect(outcome.intents.single.kind, AlertKind.degraded);

    outcome = run(
      outcome.state,
      CheckVerdict.up(t0.add(const Duration(minutes: 2))),
      policy,
      t0.add(const Duration(minutes: 2)),
    );
    expect(outcome.intents.single.kind, AlertKind.degradedRecovery);
  });

  test('quiet hours wrap across midnight', () {
    final quiet = QuietHours.fromClock(
      startHour: 22,
      startMinute: 0,
      endHour: 7,
      endMinute: 0,
    );
    expect(quiet.contains(DateTime(2026, 1, 1, 23, 30)), isTrue);
    expect(quiet.contains(DateTime(2026, 1, 1, 3, 0)), isTrue);
    expect(quiet.contains(DateTime(2026, 1, 1, 12, 0)), isFalse);
  });
}
