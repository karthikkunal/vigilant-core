import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Which resolver answers DNS questions during a scan.
enum ResolverMode {
  /// The device's own resolver. On Android this is `android.net.DnsResolver`,
  /// so no third party sees the queried name. Platforms without a public API
  /// for arbitrary record types fall back to [ResolverMode.custom]'s machinery
  /// using [fallbackEndpoint].
  device,

  /// A DNS-over-HTTPS endpoint the user names.
  custom,
}

/// How vigilant-core resolves DNS, as the user configured it.
///
/// Defaults to [ResolverMode.device]: the resolver that needs no third party is
/// the safe default, and a DoH endpoint is something a user opts into
/// deliberately rather than inherits.
@immutable
class ResolverPreference {
  const ResolverPreference._(this.mode, this.endpoint);

  /// Resolve through the platform resolver, falling back to
  /// [fallbackEndpoint] where the platform has none.
  const ResolverPreference.device()
    : mode = ResolverMode.device,
      endpoint = null;

  /// Resolve through [endpoint], which must be an https URL.
  const ResolverPreference.custom(this.endpoint) : mode = ResolverMode.custom;

  /// The endpoint used when the user asked for the device resolver but the
  /// platform cannot answer, or when a custom endpoint is not usable.
  static final Uri fallbackEndpoint = Uri.parse(
    'https://cloudflare-dns.com/dns-query',
  );

  final ResolverMode mode;
  final Uri? endpoint;

  /// Whether this preference names an endpoint the app can actually use.
  bool get isUsable => switch (mode) {
    ResolverMode.device => true,
    ResolverMode.custom => endpoint != null,
  };

  ResolverPreference copyWith({ResolverMode? mode, Uri? endpoint}) =>
      ResolverPreference._(mode ?? this.mode, endpoint ?? this.endpoint);

  /// Serialises for [ResolverStore]. A null or blank payload decodes to the
  /// device-resolver default, so a first run and a cleared setting behave the
  /// same way.
  String encode() => jsonEncode({
    'mode': mode.name,
    if (endpoint != null) 'endpoint': endpoint.toString(),
  });

  /// Parses [raw], falling back to the device resolver when it is absent,
  /// unparseable, or names a non-https endpoint.
  ///
  /// Falling back rather than throwing keeps a corrupted or hand-edited
  /// setting from bricking discovery; the alternative DoH contact is recorded
  /// in the scan's provider status either way.
  factory ResolverPreference.decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const ResolverPreference.device();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const ResolverPreference.device();
      }
      final mode = switch (decoded['mode']) {
        'custom' => ResolverMode.custom,
        _ => ResolverMode.device,
      };
      final endpoint = switch (mode) {
        ResolverMode.device => null,
        ResolverMode.custom => Uri.tryParse('${decoded['endpoint'] ?? ''}'),
      };
      // Only https endpoints are accepted: a plaintext DoH URL would leak the
      // query over the network in the clear.
      if (mode == ResolverMode.custom &&
          (endpoint == null || endpoint.scheme != 'https')) {
        return const ResolverPreference.device();
      }
      return ResolverPreference._(mode, endpoint);
    } on FormatException {
      return const ResolverPreference.device();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ResolverPreference &&
      other.mode == mode &&
      other.endpoint == endpoint;

  @override
  int get hashCode => Object.hash(mode, endpoint);

  @override
  String toString() =>
      'ResolverPreference(${mode.name}'
      '${endpoint == null ? '' : ', $endpoint'})';
}

/// The persistence boundary for [ResolverPreference], so tests can supply an
/// in-memory implementation instead of the platform store.
abstract class ResolverStore {
  Future<ResolverPreference> load();
  Future<void> save(ResolverPreference preference);
}

/// Backed by the same `flutter_foreground_task` key/value store the monitors
/// use, under a separate versioned key.
class PluginResolverStore implements ResolverStore {
  const PluginResolverStore();

  static const String _key = 'vigilant-core.resolver.v1';

  @override
  Future<ResolverPreference> load() async {
    final raw = await FlutterForegroundTask.getData<String>(key: _key);
    return ResolverPreference.decode(raw);
  }

  @override
  Future<void> save(ResolverPreference preference) =>
      FlutterForegroundTask.saveData(key: _key, value: preference.encode());
}

/// Test store: keeps the preference in memory.
class InMemoryResolverStore implements ResolverStore {
  InMemoryResolverStore([this._preference = const ResolverPreference.device()]);

  ResolverPreference _preference;

  @override
  Future<ResolverPreference> load() async => _preference;

  @override
  Future<void> save(ResolverPreference preference) async =>
      _preference = preference;
}
