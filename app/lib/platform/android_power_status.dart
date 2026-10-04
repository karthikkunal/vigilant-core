import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform boundary for Android battery-optimization status and settings.
abstract class PowerStatusController {
  /// Whether the app is exempt from battery optimization.
  ///
  /// `null` means the platform does not expose this capability or the query
  /// could not be completed.
  Future<bool?> isBatteryOptimizationIgnored();

  /// Opens the Android battery-optimization settings screen.
  Future<bool> openBatteryOptimizationSettings();
}

class AndroidPowerStatus implements PowerStatusController {
  const AndroidPowerStatus();

  static const MethodChannel _channel = MethodChannel(
    'vigilant-core/android_power',
  );

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool?> isBatteryOptimizationIgnored() async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMethod<bool>('isBatteryOptimizationIgnored');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<bool> openBatteryOptimizationSettings() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'openBatteryOptimizationSettings',
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
