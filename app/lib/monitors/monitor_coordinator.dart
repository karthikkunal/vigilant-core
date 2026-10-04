import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../alerts/pager.dart';
import '../alerts/pager_style.dart';
import '../discovery/resolver_preference.dart';
import '../platform/android_power_status.dart';
import '../reminders/reminder_plan.dart';
import '../reminders/reminder_scheduler.dart';
import 'monitor_actions.dart';
import 'monitor_config.dart';
import 'monitor_repository.dart';
import 'monitor_runner.dart';
import 'monitor_service.dart';
import 'monitor_status.dart';
import 'monitor_transfer.dart';

/// The app-facing entry point for monitors: load, add, remove, enable, check
/// now, handle page actions, and keep expiry reminders in sync.
class MonitorCoordinator {
  MonitorCoordinator({
    Pager? pager,
    http.Client? client,
    MonitorStore? store,
    ServiceController? service,
    ReminderScheduler? reminders,
    PowerStatusController? powerStatus,
    ResolverStore? resolverStore,
  }) : _store = store ?? const PluginMonitorStore(),
       _service = service ?? const MonitorService(),
       _reminders = reminders ?? LocalReminderScheduler(),
       _powerStatus = powerStatus ?? const AndroidPowerStatus(),
       _resolverStore = resolverStore ?? const PluginResolverStore() {
    _pager =
        pager ??
        LocalPager(
          onAction: handleAction,
          onBackgroundAction: notificationActionBackground,
        );
    _runner = MonitorRunner(pager: _pager, client: client);
  }

  final MonitorStore _store;
  final ServiceController _service;
  final ReminderScheduler _reminders;
  final PowerStatusController _powerStatus;
  final ResolverStore _resolverStore;
  late final Pager _pager;
  late final MonitorRunner _runner;

  Pager get pager => _pager;

  /// The user's resolver choice, as a listenable so a screen already showing
  /// results rebuilds when it changes.
  final ValueNotifier<ResolverPreference> resolver =
      ValueNotifier<ResolverPreference>(const ResolverPreference.device());

  /// Reads the persisted preference into [resolver]. Safe to call more than
  /// once; a store failure leaves the device-resolver default in place.
  Future<void> loadResolver() async {
    try {
      resolver.value = await _resolverStore.load();
    } catch (_) {
      // Discovery must still work when the setting cannot be read.
    }
  }

  /// Persists [preference] and notifies listeners. Returns false when the write
  /// failed, so settings can tell the user the choice did not stick.
  Future<bool> setResolver(ResolverPreference preference) async {
    try {
      await _resolverStore.save(preference);
      resolver.value = preference;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool?> isBatteryOptimizationIgnored() =>
      _powerStatus.isBatteryOptimizationIgnored();

  Future<bool> openBatteryOptimizationSettings() =>
      _powerStatus.openBatteryOptimizationSettings();

  Future<MonitorRepository> load() => _store.load();

  /// A shareable list of the targets being watched, one per line.
  ///
  /// Only the target travels. Cadence, thresholds, quiet hours, alert style and
  /// learned expiry dates stay on this device: they are local settings, and a
  /// backup that carried them would tie a shareable list to how this app stores
  /// monitors.
  Future<String> exportMonitors() async {
    final repository = await _store.load();
    return MonitorTargetList(
      repository.monitors.map(targetLineFor).toList(growable: false),
    ).encode();
  }

  /// What applying [source] would change, without changing anything.
  Future<ImportPreview> previewImport(String source) async {
    final document = MonitorTargetList.read(source);
    final repository = await _store.load();
    return buildImportPreview(
      document: document,
      existing: repository.monitors,
    );
  }

  /// Adds the targets in [source] that are not already on this device.
  ///
  /// Each line becomes a new monitor on this app's defaults. Monitors already
  /// here are left exactly as they are, so re-importing a list that overlaps
  /// cannot disturb settings the user has since tuned.
  Future<ImportPreview> importMonitors(String source) async {
    final document = MonitorTargetList.read(source);
    final repository = await _store.load();
    final preview = buildImportPreview(
      document: document,
      existing: repository.monitors,
    );
    if (preview.additions.isEmpty) return preview;

    for (final monitor in preview.additions) {
      repository.upsert(monitor);
    }
    await _commit(repository);
    return preview;
  }

  Future<void> addDomain(
    String domain, {
    AlertPolicy policy = const AlertPolicy(),
    AlertStyle style = AlertStyle.normal,
    Duration cadence = const Duration(minutes: 5),
    DateTime? registrationExpiry,
    DateTime? certificateExpiry,
  }) async {
    final repository = await _store.load();
    repository.upsert(
      MonitorConfig.forDomain(
        domain,
        policy: policy,
        style: style,
        cadence: cadence,
        registrationExpiry: registrationExpiry,
        certificateExpiry: certificateExpiry,
      ),
    );
    await _commit(repository);
  }

  /// Creates an HTTP monitor for [url], with optional body [assertions].
  ///
  /// With no assertions this is a plain uptime check; with assertions it is the
  /// assertion monitor. The add-monitor screen relies on that: what a monitor
  /// checks is a property of what was typed, not a separate creation path.
  Future<void> addHttp(
    Uri url, {
    List<ContentAssertion> assertions = const [],
    AlertPolicy policy = const AlertPolicy(),
    AlertStyle style = AlertStyle.normal,
    Duration cadence = const Duration(minutes: 5),
    Duration timeout = const Duration(seconds: 10),
    int? expectedStatus,
  }) async {
    if (assertions.any((assertion) => !assertion.isValid)) {
      throw ArgumentError.value(
        assertions,
        'assertions',
        'Content assertions must not be empty',
      );
    }
    final repository = await _store.load();
    repository.upsert(
      MonitorConfig.forUrl(
        url,
        policy: policy,
        style: style,
        cadence: cadence,
        timeout: timeout,
        expectedStatus: expectedStatus,
        assertions: assertions,
      ),
    );
    await _commit(repository);
  }

  Future<void> addHttpAssertions(
    Uri url, {
    required List<ContentAssertion> assertions,
    AlertPolicy policy = const AlertPolicy(),
    AlertStyle style = AlertStyle.normal,
    Duration cadence = const Duration(minutes: 5),
    Duration timeout = const Duration(seconds: 10),
    int? expectedStatus,
  }) async {
    if (assertions.isEmpty) {
      throw ArgumentError.value(
        assertions,
        'assertions',
        'At least one non-empty content assertion is required',
      );
    }
    await addHttp(
      url,
      assertions: assertions,
      policy: policy,
      style: style,
      cadence: cadence,
      timeout: timeout,
      expectedStatus: expectedStatus,
    );
  }

  Future<void> addTcp(
    String host,
    int port, {
    AlertPolicy policy = const AlertPolicy(),
    AlertStyle style = AlertStyle.normal,
    Duration cadence = const Duration(minutes: 5),
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final repository = await _store.load();
    repository.upsert(
      MonitorConfig.forTcp(
        host,
        port,
        policy: policy,
        style: style,
        cadence: cadence,
        timeout: timeout,
      ),
    );
    await _commit(repository);
  }

  /// Persists a new or changed monitor and brings the rest of the app back in
  /// line with it. Shared by every add path so none of them can forget a step:
  /// the service is started last because the notification channels it pages on
  /// have to exist first.
  Future<void> _commit(MonitorRepository repository) async {
    await _store.save(repository);
    await _rescheduleReminders(repository);
    // Provision channels and request notification permission from the UI
    // isolate before the service isolate starts delivering pages.
    await _pager.initialize();
    // A user who turned background monitoring off asked for no checks to run
    // while the app is closed, so adding a monitor must not quietly undo that.
    // Channels are still provisioned, so a later start — or a foreground check —
    // can deliver immediately.
    if (repository.monitoringPaused) return;
    await _service.start();
  }

  Future<void> remove(String id) async {
    final repository = await _store.load();
    repository.remove(id);
    await _store.save(repository);
    await _pager.clear(id);
    await _rescheduleReminders(repository);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final repository = await _store.load();
    final monitor = repository.byId(id);
    if (monitor == null) return;
    repository.upsert(monitor.copyWith(enabled: enabled));
    await _store.save(repository);
  }

  /// Persists an edited monitor (cadence, policy, style, name).
  Future<void> updateMonitor(MonitorConfig monitor) async {
    final repository = await _store.load();
    repository.upsert(monitor);
    await _store.save(repository);
  }

  Future<MonitorRunResult?> checkNow(String id) async {
    final repository = await _store.load();
    final monitor = repository.byId(id);
    if (monitor == null) return null;

    final result = await _runner.run(monitor, repository.stateFor(id));
    repository.setState(id, result.state);
    repository.recordCheck(
      id,
      result.verdict,
      provider: providerLabelFor(monitor),
    );
    await _store.save(repository);
    return result;
  }

  /// Handles a tapped page action. Safe in either isolate.
  Future<void> handleAction(String actionId, String? monitorId) async {
    if (monitorId == null || monitorId.isEmpty) return;

    final repository = await _store.load();
    final monitor = repository.byId(monitorId);
    if (monitor == null) return;

    final state = repository.stateFor(monitorId);
    final now = DateTime.now().toUtc();

    if (actionId == 'ack') {
      repository.setState(monitorId, _runner.acknowledge(monitor, state));
    } else if (actionId == 'mute') {
      repository.setState(
        monitorId,
        _runner.mute(state, now.add(const Duration(hours: 1))),
      );
      await _pager.clear(monitorId);
    } else if (actionId == 'recheck') {
      final result = await _runner.run(monitor, state, now: now);
      repository.setState(monitorId, result.state);
      repository.recordCheck(
        monitorId,
        result.verdict,
        provider: providerLabelFor(monitor),
      );
    } else {
      return;
    }

    await _store.save(repository);
  }

  /// Recomputes and reschedules every expiry reminder. Call on startup and after
  /// any change that affects expiry dates.
  Future<void> refreshReminders() async {
    final repository = await _store.load();
    await _rescheduleReminders(repository);
  }

  Future<void> _rescheduleReminders(MonitorRepository repository) =>
      _reminders.replaceAll(planRemindersForRepository(repository));

  /// Whether the user has turned background monitoring off, as a listenable so a
  /// screen already showing scheduler state rebuilds when it changes.
  final ValueNotifier<bool> monitoringPaused = ValueNotifier(false);

  /// Brings the running service in line with the stored pause preference.
  ///
  /// Call once on startup. A service that restarts on boot comes back without
  /// asking, so this is where a pause is re-applied — and where a service that
  /// died while unpaused is brought back, which is what the user expects after
  /// force-stopping the app or an OS update.
  ///
  /// A service that will not answer is left alone rather than reported as
  /// stopped: the stored preference is the user's intent, not a claim about
  /// what the OS is currently doing.
  Future<void> syncMonitoringPreference() async {
    final repository = await _store.load();
    final paused = repository.monitoringPaused;
    monitoringPaused.value = paused;
    try {
      if (paused) {
        await _service.stop();
      } else if (repository.enabledMonitors.isNotEmpty) {
        await _service.start();
      }
    } on Object {
      // The platform refused. The stored preference still stands, and the sweep
      // line reports what actually ran.
    }
  }

  /// Turns background monitoring on or off.
  ///
  /// The service call happens first and the preference is written only if it
  /// succeeded, so [MonitorRepository.monitoringPaused] never says "stopped" for
  /// a service that is still running. Returns whether the switch moved; a false
  /// result means the platform refused and nothing was changed.
  Future<bool> setMonitoringPaused(bool paused) async {
    final repository = await _store.load();
    try {
      if (paused) {
        await _service.stop();
      } else {
        // Channels must exist before the service isolate can deliver a page.
        await _pager.initialize();
        await _service.start();
      }
    } on Object {
      return false;
    }
    repository.monitoringPaused = paused;
    await _store.save(repository);
    monitoringPaused.value = paused;
    return true;
  }
}
