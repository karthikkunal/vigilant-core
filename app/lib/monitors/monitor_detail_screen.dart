import 'dart:async';

import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/material.dart';

import '../ui/status_pill.dart';
import 'monitor_config.dart';
import 'monitor_coordinator.dart';
import 'monitor_status.dart';
import 'monitor_settings_screen.dart';
import 'monitor_form.dart';

/// A focused incident view for one monitor. It keeps routine controls close to
/// the status while leaving advanced policy in its own settings screen.
class MonitorDetailScreen extends StatefulWidget {
  const MonitorDetailScreen({
    super.key,
    required this.coordinator,
    required this.monitorId,
  });

  final MonitorCoordinator coordinator;
  final String monitorId;

  @override
  State<MonitorDetailScreen> createState() => _MonitorDetailScreenState();
}

class _MonitorDetailScreenState extends State<MonitorDetailScreen> {
  MonitorConfig? _monitor;
  AlertState _state = AlertState.initial;
  MonitorCheckRecord? _check;
  DateTime? _lastChecked;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() {});
      unawaited(_load());
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final repository = await widget.coordinator.load();
      final monitor = repository.byId(widget.monitorId);
      if (!mounted) return;
      if (monitor == null) {
        setState(() {
          _error = 'This monitor no longer exists.';
          _loading = false;
        });
        return;
      }
      setState(() {
        _monitor = monitor;
        _state = repository.stateFor(monitor.id);
        _check = repository.checkFor(monitor.id);
        _lastChecked = repository.lastChecked[monitor.id];
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = friendlyMonitorError(error);
          _loading = false;
        });
      }
    }
  }

  Future<void> _checkNow() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await widget.coordinator.checkNow(widget.monitorId);
      if (result != null) {
        final latency = result.verdict.latencyMs;
        _showMessage(
          result.verdict.reason ??
              'Check complete${latency == null ? '' : ' · ${latency}ms'}',
        );
      }
    } catch (error) {
      _showMessage('Check failed: ${friendlyMonitorError(error)}');
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _action(String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.coordinator.handleAction(action, widget.monitorId);
      _showMessage(
        action == 'ack' ? 'Alert acknowledged.' : 'Monitor muted for one hour.',
      );
    } catch (error) {
      _showMessage(
        'Could not update the monitor: ${friendlyMonitorError(error)}',
      );
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _openSettings() async {
    final monitor = _monitor;
    if (monitor == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MonitorSettingsScreen(
          coordinator: widget.coordinator,
          monitor: monitor,
        ),
      ),
    );
    await _load();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final monitor = _monitor;
    return Scaffold(
      appBar: AppBar(
        title: Text(monitor?.name ?? 'Monitor'),
        actions: [
          if (monitor != null)
            IconButton(
              tooltip: 'Monitor settings',
              onPressed: _busy ? null : _openSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _DetailError(message: _error!)
          : _buildBody(context, monitor!),
    );
  }

  Widget _buildBody(BuildContext context, MonitorConfig monitor) {
    final theme = Theme.of(context);
    final status = monitorStatusFor(
      monitor: monitor,
      state: _state,
      check: _check,
      lastChecked: _lastChecked,
      now: DateTime.now().toUtc(),
    );
    final tone = _toneFor(monitor, status);
    final needsIncidentAction =
        _state.status == HealthStatus.down ||
        (_state.status == HealthStatus.degraded && !_state.acknowledged);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Current status',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              monitor.name,
                              style: theme.textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              monitor.targetLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                      StatusPill(
                        tone: tone,
                        label:
                            tone == StatusTone.attention &&
                                status == MonitorStatus.healthy
                            ? 'Attention'
                            : status.label,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _headline(monitor, status),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _detail(monitor, status, _state, _check, _lastChecked),
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : _checkNow,
                        icon: _busy
                            ? const SizedBox(
                                width: 17,
                                height: 17,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded),
                        label: const Text('Check now'),
                      ),
                      if (needsIncidentAction && !_state.acknowledged)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _action('ack'),
                          icon: const Icon(Icons.done_all_rounded),
                          label: const Text('Acknowledge'),
                        ),
                      if (needsIncidentAction)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _action('mute'),
                          icon: const Icon(Icons.notifications_paused_outlined),
                          label: const Text('Mute 1h'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          _MetricsCard(
            monitor: monitor,
            status: status,
            check: _check,
            lastChecked: _lastChecked,
          ),
          const SizedBox(height: 14),
          _ExpiryCard(monitor: monitor),
          const SizedBox(height: 14),
          _PolicyCard(monitor: monitor, onEdit: _busy ? null : _openSettings),
          const SizedBox(height: 14),
          _ActivityCard(state: _state),
        ],
      ),
    );
  }

  static String _headline(MonitorConfig monitor, MonitorStatus status) {
    if (!monitor.enabled) return 'Monitoring is paused';
    if (status == MonitorStatus.healthy && _expiryWarning(monitor) != null) {
      return 'Expiry needs attention';
    }
    return switch (status) {
      MonitorStatus.healthy => 'Healthy and responding within budget',
      MonitorStatus.degraded => 'Responding slower than the latency budget',
      MonitorStatus.down => 'The last check failed',
      MonitorStatus.unknown => 'No current check result',
      MonitorStatus.stale => 'The last check is stale',
      MonitorStatus.paused => 'Monitoring is paused',
    };
  }

  static String _detail(
    MonitorConfig monitor,
    MonitorStatus status,
    AlertState state,
    MonitorCheckRecord? check,
    DateTime? lastChecked,
  ) {
    if (!monitor.enabled) {
      return 'Resume this monitor when you want checks to resume.';
    }
    if (status == MonitorStatus.stale) {
      final lastKnown = check == null
          ? 'No usable result was recorded.'
          : 'The last known result was ${_resultLabel(check.status).toLowerCase()}.';
      return '$lastKnown It is older than the ${monitor.cadence.inMinutes}-minute cadence plus scheduling grace. Run a check now.';
    }
    final checkedAt = check?.checkedAt ?? lastChecked;
    final expiryWarning = _expiryWarning(monitor);
    if (status == MonitorStatus.healthy && expiryWarning != null) {
      return '$expiryWarning. The service is currently responding normally.';
    }
    return switch (status) {
      MonitorStatus.healthy =>
        'The service is available. vigilant-core will keep checking ${monitor.cadence.inMinutes} minute(s).',
      MonitorStatus.degraded =>
        'The service responded, but slower than ${monitor.latencyBudget.inMilliseconds}ms.',
      MonitorStatus.down =>
        state.status == HealthStatus.down
            ? 'Check the service and its network path. You can acknowledge or mute the page while investigating.'
            : 'The last check failed. vigilant-core is waiting for the configured failure threshold before paging.',
      MonitorStatus.unknown =>
        checkedAt == null
            ? 'Run a check now to establish a baseline for this monitor.'
            : 'The last check did not produce a usable result. Run it again.',
      MonitorStatus.stale => 'The last check is too old to trust.',
      MonitorStatus.paused =>
        'Resume this monitor when you want checks to resume.',
    };
  }

  static StatusTone _toneFor(MonitorConfig monitor, MonitorStatus status) {
    if (!monitor.enabled) return StatusTone.paused;
    if (status == MonitorStatus.healthy && _expiryWarning(monitor) != null) {
      return StatusTone.attention;
    }
    return switch (status) {
      MonitorStatus.healthy => StatusTone.healthy,
      MonitorStatus.degraded => StatusTone.attention,
      MonitorStatus.down => StatusTone.critical,
      MonitorStatus.unknown => StatusTone.unknown,
      MonitorStatus.stale => StatusTone.stale,
      MonitorStatus.paused => StatusTone.paused,
    };
  }

  static String? _expiryWarning(MonitorConfig monitor) {
    final now = DateTime.now().toUtc();
    final certificateDays = monitor.certificateExpiry?.difference(now).inDays;
    if (certificateDays != null && certificateDays <= 14) {
      return 'TLS certificate ${_days(certificateDays)}';
    }
    final registrationDays = monitor.registrationExpiry?.difference(now).inDays;
    if (registrationDays != null && registrationDays <= 14) {
      return 'Registration ${_days(registrationDays)}';
    }
    return null;
  }
}

class _MetricsCard extends StatelessWidget {
  const _MetricsCard({
    required this.monitor,
    required this.status,
    required this.check,
    required this.lastChecked,
  });

  final MonitorConfig monitor;
  final MonitorStatus status;
  final MonitorCheckRecord? check;
  final DateTime? lastChecked;

  @override
  Widget build(BuildContext context) {
    final checkedAt = check?.checkedAt ?? lastChecked;
    return _DetailSection(
      title: 'Check profile',
      icon: Icons.speed_rounded,
      child: Column(
        children: [
          _MetricRow(
            icon: monitor.isTcp ? Icons.lan_outlined : Icons.language_rounded,
            label: 'Check type',
            value: monitor.isTcp ? 'TCP port' : 'HTTP endpoint',
          ),
          _MetricRow(
            icon: Icons.schedule_rounded,
            label: 'Cadence',
            value: _cadence(monitor.cadence),
          ),
          _MetricRow(
            icon: Icons.timer_outlined,
            label: 'Latency budget',
            value: '${monitor.latencyBudget.inMilliseconds}ms',
          ),
          _MetricRow(
            icon: Icons.timer_off_outlined,
            label: 'Timeout',
            value: '${monitor.timeout.inSeconds}s',
          ),
          _MetricRow(
            icon: Icons.schedule_outlined,
            label: 'Last check',
            value: checkedAt == null
                ? 'Never'
                : '${_formatDateTime(checkedAt)} · ${_ago(checkedAt)}',
          ),
          _MetricRow(
            icon: check == null
                ? Icons.help_outline_rounded
                : Icons.check_circle_outline_rounded,
            label: 'Last check result',
            value: check == null ? 'Unknown' : _resultLabel(check!.status),
          ),
          _MetricRow(
            icon: Icons.hub_outlined,
            label: 'Check source',
            value: check?.provider ?? providerLabelFor(monitor),
          ),
          _MetricRow(
            icon: Icons.cloud_outlined,
            label: 'Check source status',
            value: status == MonitorStatus.stale
                ? 'Stale'
                : check == null
                ? 'Unknown'
                : _resultLabel(check!.status),
          ),
          _MetricRow(
            icon: Icons.notifications_active_outlined,
            label: 'On degraded',
            value: monitor.policy.notifyOnDegraded ? 'Notify' : 'Stay quiet',
          ),
        ],
      ),
    );
  }

  static String _cadence(Duration duration) {
    final minutes = duration.inMinutes;
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    return '${hours}h${minutes % 60 == 0 ? '' : ' ${minutes % 60}m'}';
  }
}

class _ExpiryCard extends StatelessWidget {
  const _ExpiryCard({required this.monitor});

  final MonitorConfig monitor;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    final certificateExpiry = monitor.certificateExpiry;
    final registrationExpiry = monitor.registrationExpiry;
    final certificateDays = certificateExpiry?.difference(now).inDays;
    final registrationDays = registrationExpiry?.difference(now).inDays;
    return _DetailSection(
      title: 'Expiry watch',
      icon: Icons.event_available_outlined,
      child: Column(
        children: [
          _MetricRow(
            icon: Icons.lock_outline_rounded,
            label: 'TLS certificate',
            value: certificateExpiry == null
                ? 'Not known yet'
                : '${_date(certificateExpiry)} · ${_days(certificateDays!)}',
          ),
          _MetricRow(
            icon: Icons.badge_outlined,
            label: 'Registration',
            value: registrationExpiry == null
                ? 'Not known yet'
                : '${_date(registrationExpiry)} · ${_days(registrationDays!)}',
          ),
          const SizedBox(height: 4),
          Text(
            'Expiry reminders are scheduled locally and do not require a server.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _PolicyCard extends StatelessWidget {
  const _PolicyCard({required this.monitor, required this.onEdit});

  final MonitorConfig monitor;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final policy = monitor.policy;
    return _DetailSection(
      title: 'Alert policy',
      icon: Icons.tune_rounded,
      trailing: TextButton.icon(
        onPressed: onEdit,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Edit'),
      ),
      child: Column(
        children: [
          _MetricRow(
            icon: Icons.filter_alt_outlined,
            label: 'Failures before down',
            value: '${policy.failureThreshold}',
          ),
          _MetricRow(
            icon: Icons.repeat_rounded,
            label: 'Repeat while down',
            value: policy.repeatWhileDown
                ? 'Every ${policy.repeatInterval.inMinutes} min'
                : 'Off',
          ),
          _MetricRow(
            icon: policy.urgent
                ? Icons.priority_high_rounded
                : Icons.notifications_none_rounded,
            label: 'Urgency',
            value: policy.urgent
                ? 'Critical / repeats until acknowledged'
                : 'Standard notification',
          ),
          if (policy.quietHours != null)
            _MetricRow(
              icon: Icons.bedtime_outlined,
              label: 'Quiet hours',
              value:
                  '${_formatMinutes(policy.quietHours!.startMinutes)}–${_formatMinutes(policy.quietHours!.endMinutes)}',
            ),
        ],
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.state});

  final AlertState state;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      _MetricRow(
        icon: Icons.change_history_rounded,
        label: 'Last state change',
        value: state.lastChangeAt == null
            ? 'No change recorded'
            : _ago(state.lastChangeAt!),
      ),
      _MetricRow(
        icon: Icons.check_circle_outline_rounded,
        label: 'Current outage',
        value: state.acknowledged ? 'Acknowledged' : 'Not acknowledged',
      ),
      if (state.mutedUntil != null)
        _MetricRow(
          icon: Icons.notifications_paused_outlined,
          label: 'Muted until',
          value: _formatDateTime(state.mutedUntil!),
        ),
    ];
    return _DetailSection(
      title: 'Recent activity',
      icon: Icons.history_rounded,
      child: Column(children: rows),
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 128,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _DetailError extends StatelessWidget {
  const _DetailError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.link_off_rounded,
              size: 38,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('Go back'),
            ),
          ],
        ),
      ),
    );
  }
}

String _resultLabel(HealthStatus status) => switch (status) {
  HealthStatus.up => 'Healthy',
  HealthStatus.degraded => 'Responding slowly',
  HealthStatus.down => 'Down',
  HealthStatus.unknown => 'Unknown',
};

String _date(DateTime value) => value.toIso8601String().substring(0, 10);

String _days(int days) => days < 0
    ? '${days.abs()}d overdue'
    : days == 0
    ? 'today'
    : '${days}d left';

String _formatMinutes(int minutes) {
  final hour = (minutes ~/ 60).toString().padLeft(2, '0');
  final minute = (minutes % 60).toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${_date(local)} $hour:$minute';
}

String _ago(DateTime at) {
  final delta = DateTime.now().toUtc().difference(at);
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inHours < 1) return '${delta.inMinutes}m ago';
  if (delta.inDays < 1) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}
