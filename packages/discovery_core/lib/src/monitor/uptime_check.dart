import 'dart:async';

import 'package:http/http.dart' as http;

import '../alerts/health.dart';

/// Performs one HTTP uptime check and classifies the result.
///
/// A 2xx (or a pinned status) within the latency budget is [HealthStatus.up];
/// a successful but slow response is [HealthStatus.degraded] (its own alert
/// track); a wrong status or a transport error is [HealthStatus.down].
Future<CheckVerdict> checkUptime({
  required Uri url,
  required http.Client client,
  required DateTime now,
  Duration latencyBudget = const Duration(milliseconds: 2500),
  int? expectedStatus,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final stopwatch = Stopwatch()..start();
  try {
    final response = await client.get(url).timeout(timeout);
    stopwatch.stop();
    final latency = stopwatch.elapsedMilliseconds;

    final ok = expectedStatus != null
        ? response.statusCode == expectedStatus
        : response.statusCode >= 200 && response.statusCode < 300;

    if (!ok) {
      return CheckVerdict(
        status: HealthStatus.down,
        at: now,
        latencyMs: latency,
        reason: 'HTTP ${response.statusCode}',
      );
    }
    if (latency > latencyBudget.inMilliseconds) {
      return CheckVerdict(
        status: HealthStatus.degraded,
        at: now,
        latencyMs: latency,
        reason: 'Slow: ${latency}ms (budget ${latencyBudget.inMilliseconds}ms)',
      );
    }
    return CheckVerdict(
      status: HealthStatus.up,
      at: now,
      latencyMs: latency,
    );
  } catch (error) {
    stopwatch.stop();
    return CheckVerdict(
      status: HealthStatus.down,
      at: now,
      latencyMs: stopwatch.elapsedMilliseconds,
      reason: describeCheckError(error),
    );
  }
}

/// Turns a transport error into a short, human-readable reason.
String describeCheckError(Object error) {
  if (error is TimeoutException) return 'Timed out';
  final text = error.toString().replaceFirst(
        RegExp(
            r'^(SocketException|HandshakeException|ClientException|HttpException):\s*'),
        '',
      );
  return text.length > 140 ? '${text.substring(0, 140)}…' : text;
}
