import 'package:discovery_core/discovery_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 1, 1);
  final url = Uri.parse('https://example.com/');

  test('passes when all body assertions match', () async {
    final client =
        MockClient((_) async => http.Response('Service healthy', 200));
    final verdict = await checkHttpAssertions(
      url: url,
      client: client,
      now: now,
      assertions: const [
        ContentAssertion(value: 'service healthy'),
        ContentAssertion(
          value: 'maintenance',
          operator: ContentAssertionOperator.notContains,
        ),
      ],
    );

    expect(verdict.status, HealthStatus.up);
    expect(verdict.reason, isNull);
  });

  test('a failed body assertion is down and identifies the rule', () async {
    final client =
        MockClient((_) async => http.Response('maintenance mode', 200));
    final verdict = await checkHttpAssertions(
      url: url,
      client: client,
      now: now,
      assertions: const [ContentAssertion(value: 'healthy')],
    );

    expect(verdict.status, HealthStatus.down);
    expect(verdict.reason, contains('contains "healthy"'));
  });

  test('case sensitivity is configurable', () async {
    final client = MockClient((_) async => http.Response('Healthy', 200));
    final verdict = await checkHttpAssertions(
      url: url,
      client: client,
      now: now,
      assertions: const [ContentAssertion(value: 'healthy')],
    );

    expect(verdict.status, HealthStatus.up);
  });

  test('expected status and assertions are both enforced', () async {
    final client = MockClient((_) async => http.Response('healthy', 503));
    final verdict = await checkHttpAssertions(
      url: url,
      client: client,
      now: now,
      expectedStatus: 200,
      assertions: const [ContentAssertion(value: 'healthy')],
    );

    expect(verdict.status, HealthStatus.down);
    expect(verdict.reason, 'HTTP 503');
  });

  test('empty assertion text is rejected', () async {
    final client = MockClient((_) async => http.Response('healthy', 200));
    final verdict = await checkHttpAssertions(
      url: url,
      client: client,
      now: now,
      assertions: const [ContentAssertion(value: '  ')],
    );

    expect(verdict.status, HealthStatus.down);
    expect(verdict.reason, 'Content assertion cannot be empty');
  });
}
