import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, immutable, kIsWeb, defaultTargetPlatform;
import 'package:system_dns/system_dns.dart';

import 'resolver_preference.dart';

/// The resolver a preference actually resolves to on this platform.
///
/// A preference can ask for the device resolver on a platform that has none, so
/// the choice made and the client built are reported separately rather than
/// pretending the request was granted.
@immutable
class ResolverChoice {
  const ResolverChoice({
    required this.client,
    required this.label,
    required this.usesThirdParty,
  });

  final DnsClient client;

  /// Shown in settings so the user can see which resolver will answer.
  final String label;

  /// Whether queries reach a service outside the device. Surfaced in the scan
  /// report's provider status as well, so a scan never implies it stayed local
  /// when it did not.
  final bool usesThirdParty;
}

/// Resolves DNS using the device resolver where one exists, and a
/// DNS-over-HTTPS endpoint otherwise.
///
/// [platform] and [isWeb] are parameters so the selection logic is testable
/// without a device; production callers pass the real values.
ResolverChoice resolveDns(
  ResolverPreference preference, {
  TargetPlatform? platform,
  bool? isWeb,
}) {
  final target = platform ?? defaultTargetPlatform;
  final web = isWeb ?? kIsWeb;

  final custom = preference.endpoint;
  if (preference.mode == ResolverMode.custom && custom != null) {
    return ResolverChoice(
      client: DohClient(endpoint: custom),
      label: custom.host,
      usesThirdParty: true,
    );
  }

  // The browser has no socket to hand to a platform resolver, and the
  // `system_dns` plugin registers for Android only.
  final platformResolverAvailable = !web && target == TargetPlatform.android;
  if (preference.mode == ResolverMode.device && platformResolverAvailable) {
    return ResolverChoice(
      client: FallbackDnsClient(
        primary: SystemDnsClient(),
        fallback: DohClient(endpoint: ResolverPreference.fallbackEndpoint),
      ),
      label: 'Device resolver',
      usesThirdParty: false,
    );
  }

  return ResolverChoice(
    client: DohClient(endpoint: ResolverPreference.fallbackEndpoint),
    label: '${ResolverPreference.fallbackEndpoint.host} (fallback)',
    usesThirdParty: true,
  );
}

/// A device resolver that falls back to a public endpoint when the device
/// resolver fails.
///
/// The device resolver is the privacy-preserving default, and it is not
/// reliable everywhere: `android.net.DnsResolver` reads netd's resolver
/// configuration rather than the `getaddrinfo` path, so on an emulator it sees
/// SERVFAIL for names the platform itself resolves. Selecting it on platform
/// alone meant a scan on such a device silently lost its DNS and
/// email-authentication data, with no recovery.
///
/// The fallback is deliberately narrow:
///
/// - **Only for the device resolver.** A user who named a custom endpoint chose
///   that service; silently substituting a different one would override an
///   explicit privacy decision, so that path still surfaces its error.
/// - **Latched after the first failure.** A scan makes one bulk lookup plus
///   seven DMARC/DKIM lookups. Retrying the broken resolver seven more times
///   would add seven timeouts to no benefit, and would disclose the domain
///   repeatedly for the same result.
/// - **Disclosed where it happens.** [sourceLabel] names the service that
///   actually answered, so the scan's DNS provider status says a third party was
///   used rather than implying the domain stayed on the device.
class FallbackDnsClient implements DnsClient {
  FallbackDnsClient({required this.primary, required this.fallback})
    : timeout = fallback.timeout;

  /// The device resolver, tried first.
  final DnsClient primary;

  /// The public endpoint used once [primary] has failed.
  final DnsClient fallback;

  @override
  final Duration timeout;

  bool _primaryFailed = false;
  String? _primaryFailure;

  /// Whether this client has stopped trying the device resolver.
  bool get didFallBack => _primaryFailed;

  /// The error that ended the device resolver's attempt, for diagnostics.
  String? get primaryFailure => _primaryFailure;

  /// Only the types both resolvers can answer, so a fallback cannot be asked
  /// for something it does not model.
  @override
  Set<String> get supportedTypes =>
      primary.supportedTypes.intersection(fallback.supportedTypes);

  /// Names the resolver that answered, which is not always the one that was
  /// tried first. Read after the probes run, so it reflects what happened.
  @override
  String get sourceLabel => _primaryFailed
      ? '${fallback.sourceLabel} (device resolver unavailable)'
      : primary.sourceLabel;

  @override
  Future<List<DnsRecord>> query(String name, String type) async {
    if (!_primaryFailed) {
      try {
        return await primary.query(name, type);
      } on Object catch (error) {
        _primaryFailed = true;
        _primaryFailure = '$error';
      }
    }
    return fallback.query(name, type);
  }

  /// Routed the same way, and in one attempt rather than per type: the engine
  /// calls this once for the bulk lookup, then [query] for DMARC and the DKIM
  /// selectors.
  @override
  Future<DnsRecordSet> lookup(String name, List<String> types) async {
    if (!_primaryFailed) {
      try {
        return await primary.lookup(name, types);
      } on Object catch (error) {
        _primaryFailed = true;
        _primaryFailure = '$error';
      }
    }
    return fallback.lookup(name, types);
  }

  @override
  void close() {
    primary.close();
    fallback.close();
  }
}

/// Why the fallback was used, for display in settings.
String resolverFallbackReason(
  ResolverPreference preference, {
  TargetPlatform? platform,
  bool? isWeb,
}) {
  if (preference.mode == ResolverMode.custom) return '';
  final target = platform ?? defaultTargetPlatform;
  final web = isWeb ?? kIsWeb;
  if (web) {
    return 'A browser cannot reach the device resolver, so a DNS-over-HTTPS '
        'service is used instead.';
  }
  if (target != TargetPlatform.android) {
    return 'This platform has no public resolver API for arbitrary record '
        'types, so a DNS-over-HTTPS service is used instead.';
  }
  return '';
}
