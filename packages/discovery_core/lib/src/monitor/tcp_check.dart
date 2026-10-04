import 'dart:async';
import 'dart:io';

import '../alerts/health.dart';
import 'uptime_check.dart';

/// Performs one TCP connection check and classifies the result.
///
/// A successful connection within [latencyBudget] is [HealthStatus.up]. A
/// connection that succeeds outside the budget is [HealthStatus.degraded], and
/// connection failures are [HealthStatus.down].
///
/// This uses Dart's standard `dart:io` socket implementation, so the check
/// runs from the caller and does not require a vigilant-core monitoring backend.
Future<CheckVerdict> checkTcp({
  required String host,
  required int port,
  required DateTime now,
  Duration timeout = const Duration(seconds: 10),
  Duration latencyBudget = const Duration(milliseconds: 2500),
}) async {
  final target = host.trim();
  if (target.isEmpty) {
    return CheckVerdict.down(now, reason: 'TCP target host is empty');
  }
  if (port < 1 || port > 65535) {
    return CheckVerdict.down(now, reason: 'Invalid TCP port: $port');
  }

  final stopwatch = Stopwatch()..start();
  Socket? socket;
  try {
    socket = await Socket.connect(target, port, timeout: timeout);
    stopwatch.stop();
    final latency = stopwatch.elapsedMilliseconds;
    if (latency > latencyBudget.inMilliseconds) {
      return CheckVerdict.degraded(
        now,
        latencyMs: latency,
        reason:
            'Slow TCP connect: ${latency}ms (budget ${latencyBudget.inMilliseconds}ms)',
      );
    }
    return CheckVerdict.up(now, latencyMs: latency);
  } catch (error) {
    stopwatch.stop();
    return CheckVerdict.down(
      now,
      latencyMs: stopwatch.elapsedMilliseconds,
      reason: 'TCP $target:$port: ${describeCheckError(error)}',
    );
  } finally {
    socket?.destroy();
  }
}
