import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/services.dart';

import '../system_dns_platform_interface.dart';

/// A [DnsClient] backed by the device's own resolver.
///
/// Android exposes `android.net.DnsResolver`, which answers over whichever
/// network the system is already using. That removes the public DoH resolver
/// from the request path on Android, so a scan no longer discloses the domain
/// to a third party for DNS.
///
/// Record types come back as raw DNS wire bytes and are decoded by
/// [parseDnsResponse] in `discovery_core`, so this platform holds no parsing
/// logic of its own.
///
/// Everywhere else this client reports [isSupported] as false; the app is
/// expected to substitute a DoH client rather than report a false negative as
/// "no such record".
class SystemDnsClient extends DnsClient {
  SystemDnsClient({
    SystemDnsPlatform? platform,
    super.timeout = const Duration(seconds: 10),
  }) : _platform = platform ?? SystemDnsPlatform.instance;

  final SystemDnsPlatform _platform;
  bool? _supported;

  /// Whether the underlying platform can answer queries.
  Future<bool> isSupported() async =>
      _supported ??= await _platform.isSupported();

  @override
  Set<String> get supportedTypes => DnsClient.typeCodes.keys.toSet();

  @override
  String get sourceLabel => 'Device resolver';

  @override
  Future<List<DnsRecord>> query(String name, String type) async {
    final code = DnsClient.typeCodes[type];
    if (code == null) {
      throw DiscoveryException('Unsupported DNS type: $type');
    }
    if (!await isSupported()) {
      throw const DiscoveryException(
        'The platform resolver is unavailable on this device.',
      );
    }

    final List<int> bytes;
    try {
      bytes = await _platform
          .queryRaw(name, code, timeout: timeout)
          .timeout(timeout);
    } on PlatformException catch (error) {
      throw DiscoveryException(
        'System resolver $type $name: ${error.message ?? error.code}',
      );
    } on MissingPluginException {
      throw const DiscoveryException(
        'The platform resolver is not registered on this platform.',
      );
    }

    // The channel hands back a plain List<int>; the parser reads a Uint8List.
    final response = tryParseDnsResponse(Uint8List.fromList(bytes));
    if (response == null) {
      throw DiscoveryException(
        'System resolver $type $name: the response could not be decoded.',
      );
    }
    if (!response.isAuthoritative) {
      // A non-authoritative code such as SERVFAIL or REFUSED means the lookup
      // did not happen. Reporting it as "no records" would present a resolver
      // fault as an absent record.
      throw DiscoveryException(
        'System resolver $type $name: '
        'the responder returned rcode ${response.responseCode}.',
      );
    }
    // NXDOMAIN is a real answer meaning the name does not exist, so it
    // legitimately yields no records.
    return response.answers
        .where((record) => record.type == type)
        .toList(growable: false);
  }
}
