import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'system_dns_method_channel.dart';

/// The platform side of a resolver query.
///
/// Kept as raw DNS response bytes rather than decoded records so the wire
/// format is parsed once, in Dart, alongside the model it feeds.
abstract class SystemDnsPlatform extends PlatformInterface {
  SystemDnsPlatform() : super(token: _token);

  static final Object _token = Object();

  static SystemDnsPlatform _instance = MethodChannelSystemDns();

  static SystemDnsPlatform get instance => _instance;

  static set instance(SystemDnsPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Whether this platform can answer queries at all.
  Future<bool> isSupported() async => false;

  /// Returns the raw bytes of the DNS response for [name]/[typeCode].
  ///
  /// Throws [PlatformException] when the resolver itself fails. [timeout] bounds
  /// the lookup itself, rather than only the wait for the answer.
  Future<List<int>> queryRaw(
    String name,
    int typeCode, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    throw UnimplementedError('queryRaw() has not been implemented.');
  }
}
