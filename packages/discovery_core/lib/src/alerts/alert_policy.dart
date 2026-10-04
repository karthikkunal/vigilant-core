/// A daily quiet window, expressed in minutes from midnight, that wraps across
/// midnight when [startMinutes] is greater than [endMinutes].
class QuietHours {
  const QuietHours({
    required this.startMinutes,
    required this.endMinutes,
    this.bypassForUrgent = false,
  });

  factory QuietHours.fromClock({
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
    bool bypassForUrgent = false,
  }) =>
      QuietHours(
        startMinutes: startHour * 60 + startMinute,
        endMinutes: endHour * 60 + endMinute,
        bypassForUrgent: bypassForUrgent,
      );

  final int startMinutes;
  final int endMinutes;

  /// Whether urgent pages ignore quiet hours. Off by default: quiet means quiet.
  final bool bypassForUrgent;

  /// Whether [local] (a local-time instant) falls inside the window.
  bool contains(DateTime local) {
    if (startMinutes == endMinutes) return false;
    final minute = local.hour * 60 + local.minute;
    if (startMinutes < endMinutes) {
      return minute >= startMinutes && minute < endMinutes;
    }
    // Wraps midnight, e.g. 22:00 -> 07:00.
    return minute >= startMinutes || minute < endMinutes;
  }

  Map<String, Object?> toJson() => {
        'startMinutes': startMinutes,
        'endMinutes': endMinutes,
        'bypassForUrgent': bypassForUrgent,
      };

  factory QuietHours.fromJson(Map<String, Object?> json) => QuietHours(
        startMinutes: json['startMinutes'] as int,
        endMinutes: json['endMinutes'] as int,
        bypassForUrgent: json['bypassForUrgent'] as bool? ?? false,
      );
}

/// How a monitor decides to alert. One policy can be shared or per-monitor.
class AlertPolicy {
  const AlertPolicy({
    this.failureThreshold = 1,
    this.cooldown = const Duration(minutes: 5),
    this.repeatWhileDown = false,
    this.repeatInterval = const Duration(minutes: 5),
    this.urgent = false,
    this.notifyOnRecovery = true,
    this.notifyOnDegraded = true,
    this.quietHours,
  });

  /// Consecutive failures required before declaring `down`. Suppresses blips.
  final int failureThreshold;

  /// Minimum gap between successive down alerts (flap protection).
  final Duration cooldown;

  /// Re-post the down alert while the target stays down.
  final bool repeatWhileDown;

  /// How often to repeat, and how often urgent pages re-fire.
  final Duration repeatInterval;

  /// Page like a pager: repeat until acknowledged, and ignore the cooldown.
  final bool urgent;

  final bool notifyOnRecovery;
  final bool notifyOnDegraded;
  final QuietHours? quietHours;

  Map<String, Object?> toJson() => {
        'failureThreshold': failureThreshold,
        'cooldownMs': cooldown.inMilliseconds,
        'repeatWhileDown': repeatWhileDown,
        'repeatIntervalMs': repeatInterval.inMilliseconds,
        'urgent': urgent,
        'notifyOnRecovery': notifyOnRecovery,
        'notifyOnDegraded': notifyOnDegraded,
        'quietHours': quietHours?.toJson(),
      };

  factory AlertPolicy.fromJson(Map<String, Object?> json) => AlertPolicy(
        failureThreshold: json['failureThreshold'] as int? ?? 1,
        cooldown: Duration(milliseconds: json['cooldownMs'] as int? ?? 300000),
        repeatWhileDown: json['repeatWhileDown'] as bool? ?? false,
        repeatInterval:
            Duration(milliseconds: json['repeatIntervalMs'] as int? ?? 300000),
        urgent: json['urgent'] as bool? ?? false,
        notifyOnRecovery: json['notifyOnRecovery'] as bool? ?? true,
        notifyOnDegraded: json['notifyOnDegraded'] as bool? ?? true,
        quietHours: json['quietHours'] == null
            ? null
            : QuietHours.fromJson(
                (json['quietHours']! as Map).cast<String, Object?>(),
              ),
      );
}
