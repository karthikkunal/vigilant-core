import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cert_chain_platform_interface.dart';
import 'src/certificate_parser.dart';

/// The method-channel implementation of [CertChainPlatform].
class MethodChannelCertChain extends CertChainPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('cert_chain');

  @override
  Future<CertificateInfo> fetch(
    String host, {
    int port = 443,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final payload = await methodChannel.invokeMethod<Map<Object?, Object?>>(
      'fetch',
      {'host': host, 'port': port, 'timeoutMs': timeout.inMilliseconds},
    );
    if (payload == null) {
      throw const CertificateParseException('The platform returned no data.');
    }
    return certificateInfoFromPlatformMap(payload);
  }
}
