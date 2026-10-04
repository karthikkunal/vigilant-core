import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'system_dns_platform_interface.dart';

/// The method-channel implementation of [SystemDnsPlatform].
class MethodChannelSystemDns extends SystemDnsPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('system_dns');

  @override
  Future<bool> isSupported() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    if (await methodChannel.invokeMethod<bool>('isSupported') != true) {
      return false;
    }
    // A plugin registered for Android still reports a missing implementation
    // when the host has no matching native code, so confirm the channel works
    // rather than trusting registration alone.
    try {
      await methodChannel.invokeMethod<void>('ping');
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<List<int>> queryRaw(
    String name,
    int typeCode, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final payload = await methodChannel.invokeMethod<List<Object?>>('query', {
      'name': name,
      'type': typeCode,
      'timeoutMs': timeout.inMilliseconds,
    });
    if (payload == null) {
      throw PlatformException(
        code: 'empty_response',
        message: 'The platform resolver returned no response.',
      );
    }
    return payload.whereType<int>().toList(growable: false);
  }
}
