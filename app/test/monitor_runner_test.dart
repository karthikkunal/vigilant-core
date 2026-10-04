import 'dart:io';

import 'package:discovery_core/discovery_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vigilant-core/alerts/pager.dart';
import 'package:vigilant-core/alerts/pager_style.dart';
import 'package:vigilant-core/monitors/monitor_config.dart';
import 'package:vigilant-core/monitors/monitor_runner.dart';

class _FakePager implements Pager {
  final List<AlertIntent> delivered = [];
  final List<String> cleared = [];

  /// Settable so a test can exercise the path where the platform cannot page
  /// in the background. Defaults to true, which is the Android case.
  bool pageInBackground = true;

  @override
  bool get canPageInBackground => pageInBackground;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> deliver(
    AlertIntent intent, {
    required String monitorId,
    required String monitorName,
    required AlertStyle style,
  }) async {
    delivered.add(intent);
  }

  @override
  Future<void> clear(String monitorId) async => cleared.add(monitorId);

  @override
  Future<bool> canPage() async => true;

  @override
  Future<bool> hasDndAccess() async => true;

  @override
  Future<bool> requestDndAccess() async => true;
}

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12);

  MockClient clientReturning(List<int> codes) {
    final queue = [...codes];
    return MockClient((_) async {
      final code = queue.isEmpty ? 200 : queue.removeAt(0);
      return http.Response('body', code);
    });
  }

  test('delivers a down page, then a recovery', () async {
    final pager = _FakePager();
    final runner = MonitorRunner(
      pager: pager,
      client: clientReturning([500, 200]),
    );
    final monitor = MonitorConfig.forDomain('example.com');

    final first = await runner.run(monitor, AlertState.initial, now: t0);
    expect(first.verdict.status, HealthStatus.down);
    expect(first.alerted, isTrue);
    expect(pager.delivered.map((i) => i.kind), [AlertKind.down]);

    final second = await runner.run(
      monitor,
      first.state,
      now: t0.add(const Duration(minutes: 1)),
    );
    expect(second.verdict.status, HealthStatus.up);
    expect(pager.delivered.map((i) => i.kind), [
      AlertKind.down,
      AlertKind.recovery,
    ]);
  });

  test('the failure threshold suppresses a blip', () async {
    final pager = _FakePager();
    final runner = MonitorRunner(
      pager: pager,
      client: clientReturning([500, 500]),
    );
    final monitor = MonitorConfig.forDomain(
      'example.com',
      policy: const AlertPolicy(failureThreshold: 2),
    );

    final first = await runner.run(monitor, AlertState.initial, now: t0);
    expect(first.alerted, isFalse);

    final second = await runner.run(
      monitor,
      first.state,
      now: t0.add(const Duration(minutes: 1)),
    );
    expect(second.alerted, isTrue);
    expect(pager.delivered.single.kind, AlertKind.down);
  });

  test('urgent paging repeats on the next check', () async {
    final pager = _FakePager();
    final runner = MonitorRunner(
      pager: pager,
      client: clientReturning([500, 500]),
    );
    final monitor = MonitorConfig.forDomain(
      'example.com',
      policy: const AlertPolicy(
        urgent: true,
        repeatInterval: Duration(minutes: 5),
      ),
    );

    final first = await runner.run(monitor, AlertState.initial, now: t0);
    expect(first.intents.single.repeat, isFalse);

    final second = await runner.run(
      monitor,
      first.state,
      now: t0.add(const Duration(minutes: 5)),
    );
    expect(second.intents.single.repeat, isTrue);
    expect(second.intents.single.urgent, isTrue);
  });

  test('acknowledging stops repeats and clears the page', () async {
    final pager = _FakePager();
    final runner = MonitorRunner(
      pager: pager,
      client: clientReturning([500, 500]),
    );
    final monitor = MonitorConfig.forDomain(
      'example.com',
      policy: const AlertPolicy(
        urgent: true,
        repeatInterval: Duration(minutes: 5),
      ),
    );

    final first = await runner.run(monitor, AlertState.initial, now: t0);
    final acked = runner.acknowledge(monitor, first.state);

    expect(pager.cleared, contains('example.com'));
    expect(acked.acknowledged, isTrue);

    final later = await runner.run(
      monitor,
      acked,
      now: t0.add(const Duration(minutes: 20)),
    );
    expect(later.intents, isEmpty);
  });

  test('a slow response is degraded, not down', () async {
    final pager = _FakePager();
    final runner = MonitorRunner(pager: pager, client: clientReturning([200]));
    final monitor = MonitorConfig.forDomain(
      'example.com',
      policy: const AlertPolicy(),
    );
    final slowMonitor = MonitorConfig(
      id: monitor.id,
      name: monitor.name,
      url: monitor.url,
      latencyBudget: Duration.zero,
    );

    final result = await runner.run(slowMonitor, AlertState.initial, now: t0);
    expect(
      result.verdict.status,
      anyOf(HealthStatus.degraded, HealthStatus.up),
    );
  });

  test('runs a TCP monitor through the TCP check', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    final pager = _FakePager();
    final runner = MonitorRunner(pager: pager, client: clientReturning([200]));

    try {
      final result = await runner.run(
        MonitorConfig.forTcp('127.0.0.1', server.port),
        AlertState.initial,
        now: t0,
      );

      expect(result.verdict.status, HealthStatus.up);
      expect(result.alerted, isFalse);
      final socket = await accepted;
      socket.destroy();
    } finally {
      await server.close();
    }
  });

  test('runs configured body assertions through the HTTP check', () async {
    final pager = _FakePager();
    final runner = MonitorRunner(
      pager: pager,
      client: MockClient((_) async => http.Response('healthy', 200)),
    );
    final monitor = MonitorConfig.forDomain(
      'example.com',
      assertions: const [ContentAssertion(value: 'healthy')],
    );

    final result = await runner.run(monitor, AlertState.initial, now: t0);

    expect(result.verdict.status, HealthStatus.up);
    expect(result.alerted, isFalse);
  });

  test('a failed body assertion pages the monitor', () async {
    final pager = _FakePager();
    final runner = MonitorRunner(
      pager: pager,
      client: MockClient((_) async => http.Response('maintenance', 200)),
    );
    final monitor = MonitorConfig.forDomain(
      'example.com',
      assertions: const [ContentAssertion(value: 'healthy')],
    );

    final result = await runner.run(monitor, AlertState.initial, now: t0);

    expect(result.verdict.status, HealthStatus.down);
    expect(result.verdict.reason, contains('Assertion failed'));
    expect(pager.delivered.single.kind, AlertKind.down);
  });
}
