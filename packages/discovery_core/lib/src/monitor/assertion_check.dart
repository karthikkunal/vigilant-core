import 'dart:async';

import 'package:http/http.dart' as http;

import '../alerts/health.dart';
import 'uptime_check.dart';

/// The literal body checks supported by the first assertion-based monitor.
enum ContentAssertionOperator { contains, notContains }

/// One user-configured body assertion.
///
/// Assertions are deliberately literal rather than executable expressions: a
/// monitor must not run arbitrary code or persist a response body just to
/// decide whether a service is healthy.
class ContentAssertion {
  const ContentAssertion({
    required this.value,
    this.operator = ContentAssertionOperator.contains,
    this.caseSensitive = false,
  });

  final String value;
  final ContentAssertionOperator operator;
  final bool caseSensitive;

  bool get isValid => value.trim().isNotEmpty;

  bool matches(String body) {
    final haystack = caseSensitive ? body : body.toLowerCase();
    final needle = caseSensitive ? value : value.toLowerCase();
    return switch (operator) {
      ContentAssertionOperator.contains => haystack.contains(needle),
      ContentAssertionOperator.notContains => !haystack.contains(needle),
    };
  }

  Map<String, Object?> toJson() => {
        'value': value,
        'operator': operator.name,
        'caseSensitive': caseSensitive,
      };

  factory ContentAssertion.fromJson(Map<String, Object?> json) {
    final operatorName = json['operator'] as String?;
    final operator = ContentAssertionOperator.values.firstWhere(
      (candidate) => candidate.name == operatorName,
      orElse: () => ContentAssertionOperator.contains,
    );
    return ContentAssertion(
      value: json['value'] as String? ?? '',
      operator: operator,
      caseSensitive: json['caseSensitive'] as bool? ?? false,
    );
  }

  @override
  String toString() {
    final label = operator == ContentAssertionOperator.contains
        ? 'contains'
        : 'does not contain';
    final safeValue = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    final display =
        safeValue.length <= 80 ? safeValue : '${safeValue.substring(0, 77)}…';
    return '$label "$display"';
  }
}

/// Performs one HTTP check and evaluates literal body assertions.
///
/// HTTP status and latency retain the same semantics as [checkUptime]. An
/// assertion failure is a failed check, while a successful slow response is
/// degraded.
Future<CheckVerdict> checkHttpAssertions({
  required Uri url,
  required http.Client client,
  required DateTime now,
  required List<ContentAssertion> assertions,
  Duration timeout = const Duration(seconds: 10),
  Duration latencyBudget = const Duration(milliseconds: 2500),
  int? expectedStatus,
}) async {
  if (assertions.isEmpty) {
    return CheckVerdict.down(now, reason: 'No content assertions configured');
  }
  if (assertions.any((assertion) => !assertion.isValid)) {
    return CheckVerdict.down(now, reason: 'Content assertion cannot be empty');
  }

  final stopwatch = Stopwatch()..start();
  try {
    final response = await client.get(url).timeout(timeout);
    stopwatch.stop();
    final latency = stopwatch.elapsedMilliseconds;

    final statusOk = expectedStatus != null
        ? response.statusCode == expectedStatus
        : response.statusCode >= 200 && response.statusCode < 300;
    if (!statusOk) {
      return CheckVerdict.down(
        now,
        latencyMs: latency,
        reason: 'HTTP ${response.statusCode}',
      );
    }

    final failures = assertions
        .where((assertion) => !assertion.matches(response.body))
        .map((assertion) => assertion.toString())
        .toList(growable: false);
    if (failures.isNotEmpty) {
      return CheckVerdict.down(
        now,
        latencyMs: latency,
        reason: 'Assertion failed: ${failures.join('; ')}',
      );
    }

    if (latency > latencyBudget.inMilliseconds) {
      return CheckVerdict.degraded(
        now,
        latencyMs: latency,
        reason: 'Slow: ${latency}ms (budget ${latencyBudget.inMilliseconds}ms)',
      );
    }
    return CheckVerdict.up(now, latencyMs: latency);
  } catch (error) {
    stopwatch.stop();
    return CheckVerdict.down(
      now,
      latencyMs: stopwatch.elapsedMilliseconds,
      reason: describeCheckError(error),
    );
  }
}
