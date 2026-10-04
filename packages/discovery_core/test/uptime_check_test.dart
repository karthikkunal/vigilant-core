import 'dart:async';

import 'package:discovery_core/discovery_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 1, 1);
  final url = Uri.parse('https://example.com/');

  test('2xx within budget is up', () async {
    final client = MockClient((_) async => http.Response('ok', 200));
    final verdict = await checkUptime(url: url, client: client, now: now);
    expect(verdict.status, HealthStatus.up);
    expect(verdict.latencyMs, isNotNull);
    expect(verdict.reason, isNull);
  });

  test('non-2xx is down, naming the status', () async {
    final client = MockClient((_) async => http.Response('boom', 500));
    final verdict = await checkUptime(url: url, client: client, now: now);
    expect(verdict.status, HealthStatus.down);
    expect(verdict.reason, contains('500'));
  });

  test('slower than the budget is degraded, not down', () async {
    final client = MockClient((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      return http.Response('ok', 200);
    });
    final verdict = await checkUptime(
      url: url,
      client: client,
      now: now,
      latencyBudget: const Duration(milliseconds: 5),
    );
    expect(verdict.status, HealthStatus.degraded);
    expect(verdict.reason, contains('Slow'));
  });

  test('an expected status can be pinned', () async {
    final client = MockClient((_) async => http.Response('ok', 204));
    final pinned = await checkUptime(
      url: url,
      client: client,
      now: now,
      expectedStatus: 204,
    );
    expect(pinned.status, HealthStatus.up);

    final mismatched = await checkUptime(
      url: url,
      client: client,
      now: now,
      expectedStatus: 200,
    );
    expect(mismatched.status, HealthStatus.down);
  });

  test('a transport error is down with a readable reason', () async {
    final client = MockClient(
      (_) async => throw http.ClientException('connection refused'),
    );
    final verdict = await checkUptime(url: url, client: client, now: now);
    expect(verdict.status, HealthStatus.down);
    expect(verdict.reason, contains('connection refused'));
  });

  test('a timeout is down and says so', () async {
    final client = MockClient((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return http.Response('late', 200);
    });
    final verdict = await checkUptime(
      url: url,
      client: client,
      now: now,
      timeout: const Duration(milliseconds: 5),
    );
    expect(verdict.status, HealthStatus.down);
    expect(verdict.reason, 'Timed out');
  });
}
