import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'pager_style.dart';

/// Called when the user taps an action on a page.
typedef PagerActionHandler = void Function(String actionId, String? payload);

/// Delivers alerts as notifications. Abstract so delivery can be faked in tests
/// while the decision logic stays in `discovery_core`.
abstract class Pager {
  Future<void> initialize();

  Future<void> deliver(
    AlertIntent intent, {
    required String monitorId,
    required String monitorName,
    required AlertStyle style,
  });

  /// Removes the notification for a monitor (e.g. on recovery or acknowledge).
  Future<void> clear(String monitorId);

  /// Whether this platform can check monitors in the background and page on the
  /// result. Only the Android foreground service does this; other platforms get
  /// scheduled expiry reminders and on-open discovery instead, so reporting
  /// readiness there would promise pages that never arrive.
  bool get canPageInBackground;

  /// True when the user can be paged (Android 13+ notification permission).
  Future<bool> canPage();

  /// Whether the app may bypass Do Not Disturb. Always true off Android.
  Future<bool> hasDndAccess();

  /// Opens the system screen to grant Do Not Disturb access.
  Future<bool> requestDndAccess();
}

/// The real pager, backed by `flutter_local_notifications`.
class LocalPager implements Pager {
  LocalPager({
    FlutterLocalNotificationsPlugin? plugin,
    this.onAction,
    this.onBackgroundAction,
    this.requestPermissions = true,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// Permission prompts require an attached Activity and must stay in the UI
  /// isolate. The foreground-service isolate sets this to false.
  final bool requestPermissions;

  /// Called when the user taps a page action (Ack / Mute / Re-check).
  final PagerActionHandler? onAction;

  /// Called for a page action while the app is not running. Must be a
  /// top-level function so the background isolate can reach it.
  final void Function(NotificationResponse response)? onBackgroundAction;

  bool _ready = false;
  Future<void>? _initializing;

  static const _pagesGroup = AndroidNotificationChannelGroup(
    'vigilant-core_pages',
    'vigilant-core pages',
    description: 'Paging and alert channels for vigilant-core monitors.',
  );

  @override
  Future<void> initialize() {
    if (_ready) return Future<void>.value();
    final initializing = _initializing;
    if (initializing != null) return initializing;

    final future = _initialize().whenComplete(() => _initializing = null);
    _initializing = future;
    return future;
  }

  Future<void> _initialize() async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) {
        onAction?.call(response.actionId ?? '', response.payload);
      },
      onDidReceiveBackgroundNotificationResponse: onBackgroundAction,
    );

    await _provisionChannels();
    if (requestPermissions) await _requestPermissions();

    _ready = true;
  }

  Future<void> _requestPermissions() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  Future<void> _provisionChannels() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return;

    await android.createNotificationChannelGroup(_pagesGroup);

    for (final spec in defaultChannelSpecs()) {
      await _createChannel(
        android,
        AndroidNotificationChannel(
          spec.id,
          spec.name,
          description: 'vigilant-core ${spec.severity.name} pages',
          groupId: spec.groupId,
          importance: _importanceFor(spec.severity),
          playSound: spec.playSound,
          enableVibration: spec.enableVibration,
          vibrationPattern: spec.vibrationPattern,
          sound: _rawSound(spec.soundResource),
          bypassDnd: spec.bypassDnd,
        ),
      );
    }
  }

  Future<void> _createChannel(
    AndroidFlutterLocalNotificationsPlugin android,
    AndroidNotificationChannel channel,
  ) async {
    try {
      await android.createNotificationChannel(channel);
    } catch (error) {
      // Android can briefly report a missing group when the UI and service
      // isolates provision channels at the same time. Re-create the idempotent
      // group and retry once instead of losing alert delivery.
      if (!error.toString().contains('NotificationChannelGroup')) rethrow;
      await android.createNotificationChannelGroup(_pagesGroup);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await android.createNotificationChannel(channel);
    }
  }

  AndroidNotificationSound? _rawSound(String? resource) =>
      resource == null ? null : RawResourceAndroidNotificationSound(resource);

  /// The Android implementation, or null on any other platform.
  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Whether background incident paging exists here at all.
  ///
  /// Answered from the platform rather than the plugin, because the UI reads it
  /// during build and the plugin's platform state is not initialised until
  /// [initialize] has run.
  @override
  bool get canPageInBackground =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> canPage() async {
    final android = _android;
    // Off Android this reports the notification permission rather than whether
    // paging is possible at all; [canPageInBackground] answers that separately.
    if (android == null) return true;
    return await android.areNotificationsEnabled() ?? false;
  }

  @override
  Future<bool> hasDndAccess() async {
    final android = _android;
    if (android == null) return true;
    return await android.hasNotificationPolicyAccess() ?? false;
  }

  @override
  Future<bool> requestDndAccess() async {
    final android = _android;
    if (android == null) return true;
    return await android.requestNotificationPolicyAccess() ?? false;
  }

  @override
  Future<void> deliver(
    AlertIntent intent, {
    required String monitorId,
    required String monitorName,
    required AlertStyle style,
  }) async {
    await initialize();

    final severity = severityFor(intent);
    final spec = channelSpecFor(severity, style);
    final isDown = intent.kind == AlertKind.down;
    final isPage = severity == AlertSeverity.critical;

    await _plugin.show(
      id: notificationIdFor(monitorId),
      title: _title(intent, monitorName),
      body: intent.reason ?? _body(intent.kind),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          spec.id,
          spec.name,
          importance: _importanceFor(severity),
          priority: isPage ? Priority.max : Priority.high,
          category: isDown
              ? AndroidNotificationCategory.alarm
              : AndroidNotificationCategory.status,
          // Group a monitor's pages together so they do not stack.
          groupKey: 'wt_monitor_$monitorId',
          groupAlertBehavior: GroupAlertBehavior.children,
          fullScreenIntent: isPage && isDown,
          ongoing: intent.urgent && isDown,
          autoCancel: !(intent.urgent && isDown),
          playSound: spec.playSound,
          enableVibration: spec.enableVibration,
          vibrationPattern: spec.vibrationPattern,
          sound: _rawSound(spec.soundResource),
          audioAttributesUsage: isPage
              ? AudioAttributesUsage.alarm
              : AudioAttributesUsage.notification,
          actions: isDown
              ? const [
                  AndroidNotificationAction(
                    'ack',
                    'Acknowledge',
                    showsUserInterface: false,
                  ),
                  AndroidNotificationAction(
                    'mute',
                    'Mute 1h',
                    showsUserInterface: false,
                  ),
                  AndroidNotificationAction(
                    'recheck',
                    'Re-check',
                    showsUserInterface: false,
                  ),
                ]
              : null,
        ),
        iOS: DarwinNotificationDetails(
          interruptionLevel: isPage
              ? InterruptionLevel.critical
              : InterruptionLevel.timeSensitive,
          presentSound: spec.playSound,
        ),
      ),
      payload: monitorId,
    );
  }

  @override
  Future<void> clear(String monitorId) =>
      _plugin.cancel(id: notificationIdFor(monitorId));

  Importance _importanceFor(AlertSeverity severity) => switch (severity) {
    AlertSeverity.critical => Importance.max,
    AlertSeverity.warning => Importance.high,
    AlertSeverity.info => Importance.defaultImportance,
  };

  String _title(AlertIntent intent, String monitorName) =>
      switch (intent.kind) {
        AlertKind.down =>
          intent.repeat ? '$monitorName still down' : '$monitorName is down',
        AlertKind.recovery => '$monitorName recovered',
        AlertKind.degraded => '$monitorName is slow',
        AlertKind.degradedRecovery => '$monitorName is back to normal',
      };

  String _body(AlertKind kind) => switch (kind) {
    AlertKind.down => 'The check failed.',
    AlertKind.recovery => 'The check is passing again.',
    AlertKind.degraded => 'Responding slower than its budget.',
    AlertKind.degradedRecovery => 'Response time is back within budget.',
  };
}
