import 'package:discovery_core/discovery_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vigilant-core/alerts/pager_style.dart';

void main() {
  final at = DateTime(2026, 1, 1);

  test('severity follows the alert kind and urgency', () {
    expect(
      severityFor(AlertIntent(kind: AlertKind.down, at: at, urgent: true)),
      AlertSeverity.critical,
    );
    expect(
      severityFor(AlertIntent(kind: AlertKind.down, at: at)),
      AlertSeverity.warning,
    );
    expect(
      severityFor(AlertIntent(kind: AlertKind.recovery, at: at)),
      AlertSeverity.info,
    );
    expect(
      severityFor(AlertIntent(kind: AlertKind.degraded, at: at)),
      AlertSeverity.warning,
    );
  });

  test('channel id encodes severity, sound and vibration', () {
    final spec = channelSpecFor(AlertSeverity.critical, AlertStyle.urgent);
    expect(spec.id, 'wt_critical_alarm_escalating');
    expect(spec.playSound, isTrue);
    expect(spec.enableVibration, isTrue);
    expect(spec.vibrationPattern, isNotNull);
    expect(spec.vibrationPattern!.length, greaterThan(2));
  });

  test('silent channels neither sound nor vibrate', () {
    final spec = channelSpecFor(AlertSeverity.info, AlertStyle.silent);
    expect(spec.playSound, isFalse);
    expect(spec.enableVibration, isFalse);
    expect(spec.vibrationPattern, isNull);
  });

  test('alarm channels carry the bundled sound; critical bypasses DND', () {
    final critical = channelSpecFor(AlertSeverity.critical, AlertStyle.urgent);
    expect(critical.soundResource, 'alarm');
    expect(critical.bypassDnd, isTrue);
    expect(critical.groupId, 'vigilant-core_pages');

    final info = channelSpecFor(AlertSeverity.info, AlertStyle.normal);
    expect(info.soundResource, isNull);
    expect(info.bypassDnd, isFalse);
  });

  test('every severity has a unique channel per style', () {
    final specs = defaultChannelSpecs();
    expect(
      specs,
      hasLength(AlertSeverity.values.length * AlertStyle.all.length),
    );
    final ids = specs.map((s) => s.id).toSet();
    expect(ids, hasLength(specs.length));
  });

  test('notification id is stable per monitor', () {
    expect(notificationIdFor('example.com'), notificationIdFor('example.com'));
    expect(
      notificationIdFor('example.com'),
      isNot(notificationIdFor('other.com')),
    );
    expect(notificationIdFor('example.com'), isNonNegative);
  });
}
