import 'dart:typed_data';

import 'package:discovery_core/discovery_core.dart';

/// What sound a channel uses. Custom raw resources are deliberately not used
/// yet, so non-silent channels use the system default.
enum AlertSound { none, notification, alarm }

/// The vibration waveform a channel uses.
enum AlertVibration { none, short, long, escalating }

/// The behavioural bucket a channel is built for.
enum AlertSeverity { critical, warning, info }

/// How a monitor's alerts should sound and feel.
class AlertStyle {
  const AlertStyle({
    this.sound = AlertSound.notification,
    this.vibration = AlertVibration.short,
  });

  final AlertSound sound;
  final AlertVibration vibration;

  static const AlertStyle urgent = AlertStyle(
    sound: AlertSound.alarm,
    vibration: AlertVibration.escalating,
  );
  static const AlertStyle normal = AlertStyle(
    sound: AlertSound.notification,
    vibration: AlertVibration.short,
  );
  static const AlertStyle silent = AlertStyle(
    sound: AlertSound.none,
    vibration: AlertVibration.none,
  );

  /// The styles provisioned up front. Android freezes sound and vibration onto a
  /// channel at creation, so every combination that might be needed must exist.
  static const List<AlertStyle> all = [urgent, normal, silent];
}

/// Maps an alert to the severity bucket it should be delivered at.
AlertSeverity severityFor(AlertIntent intent) => switch (intent.kind) {
  AlertKind.down =>
    intent.urgent ? AlertSeverity.critical : AlertSeverity.warning,
  AlertKind.recovery => AlertSeverity.info,
  AlertKind.degraded => AlertSeverity.warning,
  AlertKind.degradedRecovery => AlertSeverity.info,
};

/// A single Android notification channel.
class ChannelSpec {
  const ChannelSpec({
    required this.id,
    required this.name,
    required this.severity,
    required this.style,
  });

  final String id;
  final String name;
  final AlertSeverity severity;
  final AlertStyle style;

  bool get playSound => style.sound != AlertSound.none;
  bool get enableVibration => style.vibration != AlertVibration.none;

  /// Name of the bundled raw sound for alarm channels, or null for the system
  /// default. The resource lives at `android/app/src/main/res/raw/alarm.wav`.
  String? get soundResource => style.sound == AlertSound.alarm ? 'alarm' : null;

  /// Critical channels ask to bypass Do Not Disturb (needs policy access).
  bool get bypassDnd => severity == AlertSeverity.critical;

  /// Channel group, so the paging channels sit together in system settings.
  String get groupId => 'vigilant-core_pages';

  /// Vibration waveform, or null when the channel does not vibrate.
  Int64List? get vibrationPattern => switch (style.vibration) {
    AlertVibration.none => null,
    AlertVibration.short => Int64List.fromList([0, 300]),
    AlertVibration.long => Int64List.fromList([0, 800]),
    AlertVibration.escalating => Int64List.fromList([
      0,
      400,
      200,
      400,
      200,
      900,
    ]),
  };

  @override
  String toString() => id;
}

/// Builds the channel for a severity and style. One channel per combination.
ChannelSpec channelSpecFor(AlertSeverity severity, AlertStyle style) {
  final id = 'wt_${severity.name}_${style.sound.name}_${style.vibration.name}';
  return ChannelSpec(
    id: id,
    name: 'vigilant-core ${severity.name} · ${style.sound.name}',
    severity: severity,
    style: style,
  );
}

/// Every channel that must exist before paging can work.
List<ChannelSpec> defaultChannelSpecs() => [
  for (final severity in AlertSeverity.values)
    for (final style in AlertStyle.all) channelSpecFor(severity, style),
];

/// A stable notification id for a monitor, so repeats update one notification.
int notificationIdFor(String monitorId) => monitorId.hashCode & 0x7fffffff;
