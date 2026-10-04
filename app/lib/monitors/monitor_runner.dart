import 'package:discovery_core/discovery_core.dart';
import 'package:http/http.dart' as http;

import '../alerts/pager.dart';
import 'monitor_config.dart';

/// The outcome of one monitor run.
class MonitorRunResult {
  const MonitorRunResult({
    required this.state,
    required this.verdict,
    required this.intents,
  });

  final AlertState state;
  final CheckVerdict verdict;
  final List<AlertIntent> intents;

  bool get alerted => intents.isNotEmpty;
}

/// Runs one check for a monitor: probe → decide → deliver, and returns the new
/// state for the caller to persist.
///
/// All the intelligence is in the pure [AlertEngine]; this class only wires it
/// to a probe and a [Pager].
class MonitorRunner {
  MonitorRunner({required this.pager, http.Client? client})
    : _client = client ?? http.Client();

  final Pager pager;
  final http.Client _client;

  static const AlertEngine _engine = AlertEngine();

  Future<MonitorRunResult> run(
    MonitorConfig monitor,
    AlertState state, {
    DateTime? now,
  }) async {
    final at = (now ?? DateTime.now()).toUtc();

    final verdict = await _checkMonitor(monitor, at);

    final outcome = _engine.evaluate(
      state: state,
      verdict: verdict,
      policy: monitor.policy,
      now: at,
    );

    for (final intent in outcome.intents) {
      await pager.deliver(
        intent,
        monitorId: monitor.id,
        monitorName: monitor.name,
        style: monitor.style,
      );
    }

    return MonitorRunResult(
      state: outcome.state,
      verdict: verdict,
      intents: outcome.intents,
    );
  }

  Future<CheckVerdict> _checkMonitor(MonitorConfig monitor, DateTime at) async {
    if (monitor.isTcp) {
      final port = monitor.targetPort;
      if (monitor.targetHost.isEmpty || port == null) {
        return CheckVerdict.down(at, reason: 'TCP target is incomplete');
      }
      return checkTcp(
        host: monitor.targetHost,
        port: port,
        now: at,
        timeout: monitor.timeout,
        latencyBudget: monitor.latencyBudget,
      );
    }

    if (monitor.assertions.isNotEmpty) {
      return checkHttpAssertions(
        url: monitor.uri,
        client: _client,
        now: at,
        assertions: monitor.assertions,
        timeout: monitor.timeout,
        latencyBudget: monitor.latencyBudget,
        expectedStatus: monitor.expectedStatus,
      );
    }

    return checkUptime(
      url: monitor.uri,
      client: _client,
      now: at,
      timeout: monitor.timeout,
      latencyBudget: monitor.latencyBudget,
      expectedStatus: monitor.expectedStatus,
    );
  }

  /// Acknowledges the current outage: stops repeats and clears the page.
  AlertState acknowledge(MonitorConfig monitor, AlertState state) {
    pager.clear(monitor.id);
    return _engine.acknowledge(state);
  }

  /// Silences a monitor until [until].
  AlertState mute(AlertState state, DateTime until) =>
      _engine.mute(state, until);

  void close() => _client.close();
}
