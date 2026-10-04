import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vigilant-core/alerts/pager.dart';
import 'package:vigilant-core/discovery/resolver_preference.dart';
import 'package:vigilant-core/monitors/monitor_coordinator.dart';
import 'package:vigilant-core/monitors/monitor_service.dart';

/// Device-level verification for the background service, the notification
/// channels, and the persistence boundary.
///
/// A widget test can only assert what a fake service was told. The rows in the
/// manual test plan that describe stopping monitoring say outright that unit
/// tests cannot show a service actually stops, so that claim is checked here
/// against the real controller on a real device.
///
/// These talk to platform channels, so they are meaningless off-device.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late MonitorCoordinator coordinator;

  /// A platform call that never returns should fail the test quickly rather than
  /// stall the whole run; the foreground-task plugin does not always settle.
  const platformTimeout = Duration(seconds: 20);

  setUp(() {
    // `main()` initialises the task before anything can start it, and the
    // foreground-task plugin refuses to start without that, so the same call is
    // made here.
    const MonitorService().init();

    // The real coordinator: real plugin store, real service, real pager. Only
    // the notification plumbing is left to the platform as it is in production.
    //
    // `requestPermissions: false` suppresses the POST_NOTIFICATIONS dialog and
    // nothing else. Nothing on an unattended emulator can dismiss that dialog,
    // so leaving it on meant `initialize()` never returned and every test that
    // adds a monitor hung until the run timed out. Channel provisioning still
    // happens either way, so the plugin is exercised for real.
    //
    // What this suite therefore still cannot show is a page actually being
    // displayed. That needs the permission granted and a human to allow it, so
    // it stays manual-plan rows 1 and 2.
    coordinator = MonitorCoordinator(
      pager: LocalPager(requestPermissions: false),
      resolverStore: InMemoryResolverStore(),
    );
  });

  group('the foreground monitoring service', () {
    // Row 39/40: the switch exists, reports state, and stopping it works.
    testWidgets('starts, reports running, and stops', (tester) async {
      const service = MonitorService();

      expect(await service.isRunning(), isFalse);

      await service.start().timeout(platformTimeout);
      expect(
        await service.isRunning().timeout(platformTimeout),
        isTrue,
        reason: 'start() reported success but the service is not running',
      );

      await service.stop().timeout(platformTimeout);
      expect(
        await service.isRunning().timeout(platformTimeout),
        isFalse,
        reason: 'stop() reported success but the service is still running',
      );
    });

    // Row 43: adding a monitor must not be the thing that starts the service.
    // The switch has to be authoritative, or "off" is only advisory.
    //
    // This goes through `setMonitoringPaused` rather than stopping the service
    // directly: the app records the user's decision, and calling `stop()`
    // behind its back leaves it believing monitoring is on, which is a
    // different scenario from the one the row describes.
    testWidgets('adding a monitor does not start a service switched off', (
      tester,
    ) async {
      const service = MonitorService();

      // Each test establishes its own precondition. Stopping a task that is
      // already stopped does not reliably return, so the service is started
      // first and then switched off through the app's own path.
      await service.start().timeout(platformTimeout);

      await coordinator.setMonitoringPaused(true).timeout(platformTimeout);
      expect(
        await service.isRunning().timeout(platformTimeout),
        isFalse,
        reason: 'switching monitoring off did not stop the service',
      );

      await coordinator.addDomain('example.com').timeout(platformTimeout);

      expect(
        await service.isRunning().timeout(platformTimeout),
        isFalse,
        reason: 'adding a monitor restarted a service that was switched off',
      );

      await coordinator.setMonitoringPaused(false).timeout(platformTimeout);
    });

    // Row 44: the switch is about the background, not about checking.
    testWidgets('a check still runs while background monitoring is off', (
      tester,
    ) async {
      // Left paused by the previous test, so the service is started first:
      // stopping an already-stopped task does not reliably return.
      await const MonitorService().start().timeout(platformTimeout);
      await coordinator.setMonitoringPaused(true).timeout(platformTimeout);
      await coordinator.addDomain('example.com').timeout(platformTimeout);

      final result = await coordinator
          .checkNow('example.com')
          .timeout(platformTimeout);

      expect(result, isNotNull, reason: 'checkNow returned nothing');
      expect(
        result!.verdict.reason ?? result.verdict.status.name,
        isNotEmpty,
        reason: 'the check produced no verdict to show',
      );

      await coordinator.setMonitoringPaused(false).timeout(platformTimeout);
    });
  });

  group('persistence across a real store', () {
    // The widget tests inject an in-memory store. This proves the actual plugin
    // store round-trips, which is the boundary a corrupted preference or a
    // failed write would show up at.
    testWidgets('a monitor survives a write and read', (tester) async {
      final id = 'integration-${DateTime.now().microsecondsSinceEpoch}.example';

      await coordinator
          .addDomain(id, registrationExpiry: DateTime.utc(2030, 1, 1))
          .timeout(platformTimeout);

      final repository = await coordinator.load().timeout(platformTimeout);
      final stored = repository.byId(id);

      expect(
        stored,
        isNotNull,
        reason: 'the monitor did not come back from the real store',
      );
      expect(stored!.url, contains(id));
      expect(
        stored.registrationExpiry,
        DateTime.utc(2030, 1, 1),
        reason: 'expiry did not survive the round trip',
      );

      // And the list the user would copy matches what is stored.
      final copied = await coordinator.exportMonitors().timeout(
        platformTimeout,
      );
      expect(
        copied,
        contains(id),
        reason: 'the copied site list is missing a stored monitor',
      );

      await coordinator.remove(id).timeout(platformTimeout);
      expect(
        (await coordinator.load().timeout(platformTimeout)).byId(id),
        isNull,
      );
    });
  });

  group('the resolver preference', () {
    // The default must be the device resolver, or a scan discloses the domain
    // to a third party without the user ever being asked.
    testWidgets('defaults to the device resolver', (tester) async {
      await coordinator.loadResolver().timeout(platformTimeout);

      expect(
        coordinator.resolver.value.mode,
        ResolverMode.device,
        reason: 'first run did not default to the device resolver',
      );
      expect(
        coordinator.pager.canPageInBackground,
        isTrue,
        reason: 'Android should be able to page in the background',
      );
    });
  });
}
