import 'health.dart';

/// Why an alert is being raised.
enum AlertKind { down, recovery, degraded, degradedRecovery }

/// A request to notify. The platform layer turns this into a notification; the
/// engine never touches the OS.
class AlertIntent {
  const AlertIntent({
    required this.kind,
    required this.at,
    this.urgent = false,
    this.repeat = false,
    this.reason,
  });

  final AlertKind kind;
  final DateTime at;

  /// Should be delivered even through Do Not Disturb (if permitted).
  final bool urgent;

  /// True for a re-post of an ongoing down alert, false for the first one.
  final bool repeat;

  final String? reason;

  @override
  String toString() =>
      'AlertIntent(${kind.name}${repeat ? ', repeat' : ''}${urgent ? ', urgent' : ''})';
}

/// Everything the engine remembers about one monitor between checks.
class AlertState {
  const AlertState({
    this.status = HealthStatus.unknown,
    this.consecutiveFailures = 0,
    this.consecutiveDegraded = 0,
    this.lastDownAlertAt,
    this.lastRepeatAt,
    this.acknowledged = false,
    this.mutedUntil,
    this.lastChangeAt,
  });

  final HealthStatus status;
  final int consecutiveFailures;
  final int consecutiveDegraded;
  final DateTime? lastDownAlertAt;
  final DateTime? lastRepeatAt;

  /// The current outage has been acknowledged; repeats stop until recovery.
  final bool acknowledged;

  final DateTime? mutedUntil;
  final DateTime? lastChangeAt;

  static const AlertState initial = AlertState();

  bool isMutedAt(DateTime now) =>
      mutedUntil != null && now.isBefore(mutedUntil!);

  AlertState copyWith({
    HealthStatus? status,
    int? consecutiveFailures,
    int? consecutiveDegraded,
    DateTime? lastDownAlertAt,
    DateTime? lastRepeatAt,
    bool? acknowledged,
    DateTime? mutedUntil,
    DateTime? lastChangeAt,
  }) =>
      AlertState(
        status: status ?? this.status,
        consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
        consecutiveDegraded: consecutiveDegraded ?? this.consecutiveDegraded,
        lastDownAlertAt: lastDownAlertAt ?? this.lastDownAlertAt,
        lastRepeatAt: lastRepeatAt ?? this.lastRepeatAt,
        acknowledged: acknowledged ?? this.acknowledged,
        mutedUntil: mutedUntil ?? this.mutedUntil,
        lastChangeAt: lastChangeAt ?? this.lastChangeAt,
      );

  Map<String, Object?> toJson() => {
        'status': status.name,
        'consecutiveFailures': consecutiveFailures,
        'consecutiveDegraded': consecutiveDegraded,
        'lastDownAlertAt': lastDownAlertAt?.toIso8601String(),
        'lastRepeatAt': lastRepeatAt?.toIso8601String(),
        'acknowledged': acknowledged,
        'mutedUntil': mutedUntil?.toIso8601String(),
        'lastChangeAt': lastChangeAt?.toIso8601String(),
      };

  factory AlertState.fromJson(Map<String, Object?> json) => AlertState(
        status: HealthStatus.values.byName(
          json['status'] as String? ?? HealthStatus.unknown.name,
        ),
        consecutiveFailures: json['consecutiveFailures'] as int? ?? 0,
        consecutiveDegraded: json['consecutiveDegraded'] as int? ?? 0,
        lastDownAlertAt: _parseDate(json['lastDownAlertAt']),
        lastRepeatAt: _parseDate(json['lastRepeatAt']),
        acknowledged: json['acknowledged'] as bool? ?? false,
        mutedUntil: _parseDate(json['mutedUntil']),
        lastChangeAt: _parseDate(json['lastChangeAt']),
      );
}

DateTime? _parseDate(Object? value) =>
    value == null ? null : DateTime.tryParse(value as String);

/// The new state plus any alerts to deliver.
class AlertOutcome {
  const AlertOutcome(this.state, this.intents);

  final AlertState state;
  final List<AlertIntent> intents;

  bool get hasAlerts => intents.isNotEmpty;
}
