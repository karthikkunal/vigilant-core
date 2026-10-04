import 'package:discovery_core/discovery_core.dart';

import 'cert_chain_platform_interface.dart';

export 'cert_chain_method_channel.dart' show MethodChannelCertChain;
export 'cert_chain_platform_interface.dart' show CertChainPlatform;
export 'src/certificate_parser.dart'
    show CertificateParseException, certificateInfoFromPlatformMap;

/// Captures the TLS certificate chain a server actually presents.
///
/// The high-level HTTP stack cannot see the chain, which is why this lives in a
/// native plugin. Native returns raw DER plus a trust verdict; parsing happens
/// once in Dart so no X.509 code is duplicated per platform.
class CertChain {
  const CertChain._();

  static Future<CertificateInfo> fetch(
    String host, {
    int port = 443,
    Duration timeout = const Duration(seconds: 15),
  }) => CertChainPlatform.instance.fetch(host, port: port, timeout: timeout);
}
