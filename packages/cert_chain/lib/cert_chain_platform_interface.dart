import 'package:discovery_core/discovery_core.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'cert_chain_method_channel.dart';

abstract class CertChainPlatform extends PlatformInterface {
  CertChainPlatform() : super(token: _token);

  static final Object _token = Object();

  static CertChainPlatform _instance = MethodChannelCertChain();

  static CertChainPlatform get instance => _instance;

  static set instance(CertChainPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<CertificateInfo> fetch(
    String host, {
    int port = 443,
    Duration timeout = const Duration(seconds: 15),
  }) {
    throw UnimplementedError('fetch() has not been implemented.');
  }
}
