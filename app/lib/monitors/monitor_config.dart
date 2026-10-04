import 'package:discovery_core/discovery_core.dart';

import '../alerts/pager_style.dart';

/// The transport-level operation used by a monitor.
enum MonitorType { http, tcp }

/// A watched target: what to check, how often, how to page, and when it expires.
class MonitorConfig {
  const MonitorConfig({
    required this.id,
    required this.name,
    required this.url,
    this.cadence = const Duration(minutes: 5),
    this.latencyBudget = const Duration(milliseconds: 2500),
    this.expectedStatus,
    this.policy = const AlertPolicy(),
    this.style = AlertStyle.normal,
    this.enabled = true,
    this.registrationExpiry,
    this.certificateExpiry,
    this.type = MonitorType.http,
    this.host,
    this.port,
    this.timeout = const Duration(seconds: 10),
    this.assertions = const [],
  });

  final String id;
  final String name;
  final String url;
  final Duration cadence;
  final Duration latencyBudget;
  final int? expectedStatus;
  final AlertPolicy policy;
  final AlertStyle style;
  final bool enabled;

  /// When the domain registration expires, if known.
  final DateTime? registrationExpiry;

  /// When the leaf certificate expires, if known.
  final DateTime? certificateExpiry;

  /// The check implementation used by this monitor.
  final MonitorType type;

  /// Hostname or IP for a TCP monitor. HTTP monitors derive this from [url].
  final String? host;

  /// TCP port. HTTP monitors derive this from [url].
  final int? port;

  /// Maximum time allowed for one transport operation.
  final Duration timeout;

  /// Literal body assertions applied to HTTP monitors.
  final List<ContentAssertion> assertions;

  bool get isTcp => type == MonitorType.tcp;

  String get targetHost {
    if (host != null && host!.isNotEmpty) return host!;
    return Uri.tryParse(url)?.host ?? '';
  }

  int? get targetPort {
    if (port != null) return port;
    final parsed = Uri.tryParse(url);
    return parsed != null && parsed.hasPort ? parsed.port : null;
  }

  String get targetLabel {
    if (!isTcp) return url;
    final port = targetPort;
    final displayHost = targetHost.contains(':') && !targetHost.startsWith('[')
        ? '[$targetHost]'
        : targetHost;
    return port == null ? '$displayHost:?' : '$displayHost:$port';
  }

  Uri get uri => Uri.parse(url);

  /// Builds a monitor from a bare domain — the app's primary input.
  factory MonitorConfig.forDomain(
    String domain, {
    AlertPolicy policy = const AlertPolicy(),
    AlertStyle style = AlertStyle.normal,
    Duration cadence = const Duration(minutes: 5),
    Duration timeout = const Duration(seconds: 10),
    int? expectedStatus,
    List<ContentAssertion> assertions = const [],
    DateTime? registrationExpiry,
    DateTime? certificateExpiry,
  }) {
    final input = DomainInput.tryParse(domain);
    final host = input?.host ?? domain.trim().toLowerCase();
    return MonitorConfig(
      id: host,
      name: input?.host ?? host,
      url: 'https://$host/',
      policy: policy,
      style: style,
      cadence: cadence,
      timeout: timeout,
      expectedStatus: expectedStatus,
      assertions: assertions,
      registrationExpiry: registrationExpiry,
      certificateExpiry: certificateExpiry,
    );
  }

  /// Builds an HTTP monitor for an explicit URL, preserving its path and query.
  factory MonitorConfig.forUrl(
    Uri url, {
    AlertPolicy policy = const AlertPolicy(),
    AlertStyle style = AlertStyle.normal,
    Duration cadence = const Duration(minutes: 5),
    Duration timeout = const Duration(seconds: 10),
    int? expectedStatus,
    List<ContentAssertion> assertions = const [],
  }) {
    if (!url.hasScheme || (url.scheme != 'http' && url.scheme != 'https')) {
      throw ArgumentError.value(url, 'url', 'HTTP or HTTPS URL required');
    }
    if (url.host.isEmpty) {
      throw ArgumentError.value(url, 'url', 'URL host cannot be empty');
    }
    return MonitorConfig(
      id: url.toString(),
      name: url.host,
      url: url.toString(),
      cadence: cadence,
      timeout: timeout,
      expectedStatus: expectedStatus,
      assertions: assertions,
      policy: policy,
      style: style,
    );
  }

  /// Builds a TCP port monitor. The target is intentionally explicit: a port
  /// is required so a typo cannot turn into an accidental broad scan.
  factory MonitorConfig.forTcp(
    String host,
    int port, {
    AlertPolicy policy = const AlertPolicy(),
    AlertStyle style = AlertStyle.normal,
    Duration cadence = const Duration(minutes: 5),
    Duration timeout = const Duration(seconds: 10),
  }) {
    final normalizedHost = host.trim().toLowerCase();
    if (normalizedHost.isEmpty) {
      throw ArgumentError.value(host, 'host', 'TCP host cannot be empty');
    }
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'TCP port must be 1-65535');
    }

    final uri = Uri(scheme: 'tcp', host: normalizedHost, port: port);
    return MonitorConfig(
      id: uri.toString(),
      name: uri.toString(),
      url: uri.toString(),
      type: MonitorType.tcp,
      host: normalizedHost,
      port: port,
      cadence: cadence,
      timeout: timeout,
      policy: policy,
      style: style,
    );
  }

  MonitorConfig copyWith({
    String? name,
    Duration? cadence,
    Duration? latencyBudget,
    int? expectedStatus,
    AlertPolicy? policy,
    AlertStyle? style,
    bool? enabled,
    DateTime? registrationExpiry,
    DateTime? certificateExpiry,
    MonitorType? type,
    String? host,
    int? port,
    Duration? timeout,
    List<ContentAssertion>? assertions,
  }) => MonitorConfig(
    id: id,
    name: name ?? this.name,
    url: url,
    cadence: cadence ?? this.cadence,
    latencyBudget: latencyBudget ?? this.latencyBudget,
    expectedStatus: expectedStatus ?? this.expectedStatus,
    policy: policy ?? this.policy,
    style: style ?? this.style,
    enabled: enabled ?? this.enabled,
    registrationExpiry: registrationExpiry ?? this.registrationExpiry,
    certificateExpiry: certificateExpiry ?? this.certificateExpiry,
    type: type ?? this.type,
    host: host ?? this.host,
    port: port ?? this.port,
    timeout: timeout ?? this.timeout,
    assertions: assertions ?? this.assertions,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'cadenceMs': cadence.inMilliseconds,
    'latencyBudgetMs': latencyBudget.inMilliseconds,
    'expectedStatus': expectedStatus,
    'enabled': enabled,
    'registrationExpiry': registrationExpiry?.toIso8601String(),
    'certificateExpiry': certificateExpiry?.toIso8601String(),
    'type': type.name,
    'host': host,
    'port': port,
    'timeoutMs': timeout.inMilliseconds,
    'assertions': assertions.map((a) => a.toJson()).toList(),
    'style': {'sound': style.sound.name, 'vibration': style.vibration.name},
    'policy': policy.toJson(),
  };

  factory MonitorConfig.fromJson(Map<String, Object?> json) {
    final styleJson = (json['style'] as Map?)?.cast<String, Object?>();
    final typeName = json['type'] as String?;
    final type = MonitorType.values.firstWhere(
      (candidate) => candidate.name == typeName,
      orElse: () => MonitorType.http,
    );
    final parsedUrl = Uri.tryParse(json['url'] as String? ?? '');
    final host =
        json['host'] as String? ??
        (type == MonitorType.tcp ? parsedUrl?.host : null);
    final port =
        (json['port'] as num?)?.toInt() ??
        (type == MonitorType.tcp && parsedUrl != null && parsedUrl.hasPort
            ? parsedUrl.port
            : null);
    final assertions = (json['assertions'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => ContentAssertion.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
    return MonitorConfig(
      id: json['id']! as String,
      name: json['name']! as String,
      url: json['url']! as String,
      cadence: Duration(milliseconds: json['cadenceMs'] as int? ?? 300000),
      latencyBudget: Duration(
        milliseconds: json['latencyBudgetMs'] as int? ?? 2500,
      ),
      expectedStatus: json['expectedStatus'] as int?,
      enabled: json['enabled'] as bool? ?? true,
      registrationExpiry: _parseDate(json['registrationExpiry']),
      certificateExpiry: _parseDate(json['certificateExpiry']),
      type: type,
      host: host,
      port: port,
      timeout: Duration(milliseconds: json['timeoutMs'] as int? ?? 10000),
      assertions: assertions,
      style: AlertStyle(
        sound: AlertSound.values.byName(
          styleJson?['sound'] as String? ?? AlertSound.notification.name,
        ),
        vibration: AlertVibration.values.byName(
          styleJson?['vibration'] as String? ?? AlertVibration.short.name,
        ),
      ),
      policy: AlertPolicy.fromJson(
        (json['policy'] as Map?)?.cast<String, Object?>() ?? const {},
      ),
    );
  }
}

DateTime? _parseDate(Object? value) =>
    value == null ? null : DateTime.tryParse(value as String);
