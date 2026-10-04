import 'dart:async';

import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/material.dart';

import '../theme/vigilant-core_theme.dart';
import '../ui/status_pill.dart';
import 'monitor_config.dart';
import 'monitor_coordinator.dart';
import 'monitor_detail_screen.dart';
import 'monitor_repository.dart';
import 'monitor_status.dart';
import 'monitor_form.dart';

/// The operational home: a calm summary first, then the monitors that need
/// attention and the rest of the fleet.
class MonitorsScreen extends StatefulWidget {
  const MonitorsScreen({
    super.key,
    required this.coordinator,
    this.onAddMonitor,
    this.onOpenSettings,
  });

  final MonitorCoordinator coordinator;

  /// Opens the single add-monitor form, which covers websites, URLs, body
  /// rules and TCP ports. It replaced three callbacks, one per kind.
  final VoidCallback? onAddMonitor;
  final VoidCallback? onOpenSettings;

  @override
  State<MonitorsScreen> createState() => _MonitorsScreenState();
}

enum _MonitorFilter { all, attention, paused }

extension on _MonitorFilter {
  String get label => switch (this) {
    _MonitorFilter.all => 'All',
    _MonitorFilter.attention => 'Needs attention',
    _MonitorFilter.paused => 'Paused',
  };
}

class _MonitorsScreenState extends State<MonitorsScreen>
    with WidgetsBindingObserver {
  MonitorRepository? _repository;
  String? _loadError;
  _MonitorFilter _filter = _MonitorFilter.all;
  final Set<String> _checking = {};
  bool _busy = false;
  bool? _canPage;
  bool? _hasDndAccess;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    unawaited(_loadPermissions());
    // Re-evaluate freshness while the dashboard remains open.
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() {});
      unawaited(_refresh());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Notification and Do Not Disturb access are granted outside the app, so
    // the banner must be re-derived when the user comes back rather than
    // showing a stale denial until the next cold start.
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadPermissions());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final repository = await widget.coordinator.load();
      if (mounted) {
        setState(() {
          _repository = repository;
          _loadError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _loadError = friendlyMonitorError(error));
    }
  }

  Future<void> _loadPermissions() async {
    try {
      final canPage = await widget.coordinator.pager.canPage();
      final hasDnd = await widget.coordinator.pager.hasDndAccess();
      if (mounted) {
        setState(() {
          _canPage = canPage;
          _hasDndAccess = hasDnd;
        });
      }
    } catch (_) {
      // Permission state is supplementary; never block the dashboard on it.
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _showMessage(
        'Could not complete that action: ${friendlyMonitorError(error)}',
      );
    }
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _checkNow(String id) async {
    if (_checking.contains(id)) return;
    setState(() => _checking.add(id));
    try {
      await widget.coordinator.checkNow(id);
    } catch (error) {
      _showMessage('Check failed: ${friendlyMonitorError(error)}');
    }
    await _refresh();
    if (mounted) setState(() => _checking.remove(id));
  }

  Future<void> _remove(MonitorConfig monitor) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop watching ${monitor.name}?'),
        content: const Text(
          'This removes the monitor, its alert history, and its expiry reminders.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep monitor'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(() => widget.coordinator.remove(monitor.id));
    }
  }

  Future<void> _open(MonitorConfig monitor) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MonitorDetailScreen(
          coordinator: widget.coordinator,
          monitorId: monitor.id,
        ),
      ),
    );
    await _refresh();
  }

  Future<void> _requestDndAccess() async {
    final granted = await widget.coordinator.pager.requestDndAccess();
    if (!mounted) return;
    setState(() => _hasDndAccess = granted);
    _showMessage(
      granted
          ? 'Critical pages can bypass Do Not Disturb.'
          : 'Do Not Disturb access was not granted.',
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final repository = _repository;
    final monitors = repository?.monitors ?? const <MonitorConfig>[];
    final now = DateTime.now().toUtc();
    final visible = _visibleMonitors(monitors, repository, now);

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _buildHeader(context, monitors, repository, now),
            ),
            if (_loadError != null && repository == null)
              SliverToBoxAdapter(child: _LoadError(message: _loadError!)),
            if (repository == null && _loadError == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (monitors.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyDashboard(onAddMonitor: widget.onAddMonitor),
              )
            else ...[
              if (_canPage == false ||
                  (_hasDndAccess == false &&
                      monitors.any(
                        (monitor) => monitor.enabled && monitor.policy.urgent,
                      )))
                SliverToBoxAdapter(
                  child: _PermissionBanner(
                    canPage: _canPage,
                    hasDndAccess: _hasDndAccess,
                    onOpenSettings: widget.onOpenSettings,
                    onRequestDndAccess: _requestDndAccess,
                  ),
                ),
              SliverToBoxAdapter(
                child: _buildFilterBar(context, monitors, now),
              ),
              if (visible.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: _NoFilterResults(),
                )
              else
                SliverList.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final monitor = visible[index];
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: _MonitorCard(
                        monitor: monitor,
                        state: repository!.stateFor(monitor.id),
                        check: repository.checkFor(monitor.id),
                        lastChecked: repository.lastChecked[monitor.id],
                        now: now,
                        checking: _checking.contains(monitor.id),
                        busy: _busy,
                        needsAttention: _needsAttention(
                          monitor,
                          repository,
                          now,
                        ),
                        onCheck: () => _checkNow(monitor.id),
                        onOpen: () => _open(monitor),
                        onAction: (action) => switch (action) {
                          _MonitorAction.check => _checkNow(monitor.id),
                          _MonitorAction.pause => _run(
                            () => widget.coordinator.setEnabled(
                              monitor.id,
                              false,
                            ),
                          ),
                          _MonitorAction.resume => _run(
                            () =>
                                widget.coordinator.setEnabled(monitor.id, true),
                          ),
                          _MonitorAction.remove => _remove(monitor),
                        },
                      ),
                    );
                  },
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: widget.onAddMonitor,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add monitor'),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    List<MonitorConfig> monitors,
    MonitorRepository? repository,
    DateTime now,
  ) {
    final theme = Theme.of(context);
    MonitorStatus statusFor(MonitorConfig monitor) => monitorStatusFor(
      monitor: monitor,
      state: repository?.stateFor(monitor.id) ?? AlertState.initial,
      check: repository?.checkFor(monitor.id),
      lastChecked: repository?.lastChecked[monitor.id],
      now: now,
    );
    final attention = monitors.where((monitor) {
      if (!monitor.enabled) return false;
      return statusFor(monitor).needsAttention ||
          _expiryWarning(monitor, now) != null;
    }).length;
    final unknown = monitors
        .where(
          (monitor) =>
              monitor.enabled && statusFor(monitor) == MonitorStatus.unknown,
        )
        .length;
    final paused = monitors.where((m) => !m.enabled).length;
    final enabled = monitors.where((m) => m.enabled).length;
    final tone = attention > 0
        ? StatusTone.attention
        : unknown > 0
        ? StatusTone.unknown
        : enabled == 0 && paused > 0
        ? StatusTone.paused
        : StatusTone.healthy;
    final headline = attention > 0
        ? attention == 1
              ? '1 needs attention'
              : '$attention need attention'
        : unknown > 0
        ? unknown == 1
              ? '1 waiting for its first check'
              : '$unknown waiting for first checks'
        : enabled == 0 && paused > 0
        ? 'All monitors are paused'
        : 'Everything looks good';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  Icons.sensors_rounded,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('vigilant-core', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 2),
                    Text(
                      'Local-first website & domain monitoring',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Settings',
                onPressed: widget.onOpenSettings,
                icon: const Icon(Icons.tune_rounded),
              ),
            ],
          ),
          const SizedBox(height: 22),
          // The empty state carries its own headline directly below, so the
          // header adds a status line only once there are monitors to describe.
          if (monitors.isNotEmpty) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Text(headline, style: theme.textTheme.titleLarge),
                ),
                StatusPill(tone: tone, compact: true),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (monitors.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _SummaryChip(
                  icon: Icons.visibility_outlined,
                  label: '$enabled active',
                ),
                if (paused > 0)
                  _SummaryChip(
                    icon: Icons.pause_circle_outline_rounded,
                    label: '$paused paused',
                  ),
                if (attention > 0)
                  _SummaryChip(
                    icon: Icons.warning_amber_rounded,
                    label: '$attention issue${attention == 1 ? '' : 's'}',
                    color: vigilant-corePalette.warning,
                  ),
              ],
            ),
          if (monitors.isNotEmpty) ...[
            const SizedBox(height: 14),
            _SweepLine(
              sweptAt: repository?.lastSweepAt,
              now: now,
              paused: repository?.monitoringPaused ?? false,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFilterBar(
    BuildContext context,
    List<MonitorConfig> monitors,
    DateTime now,
  ) {
    final counts = <_MonitorFilter, int>{
      for (final filter in _MonitorFilter.values)
        filter: filter == _MonitorFilter.all
            ? monitors.length
            : filter == _MonitorFilter.paused
            ? monitors.where((m) => !m.enabled).length
            : monitors
                  .where((m) => _needsAttention(m, _repository, now))
                  .length,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final filter in _MonitorFilter.values) ...[
              FilterChip(
                selected: _filter == filter,
                label: Text('${filter.label}  ${counts[filter]}'),
                onSelected: (_) => setState(() => _filter = filter),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }

  List<MonitorConfig> _visibleMonitors(
    List<MonitorConfig> monitors,
    MonitorRepository? repository,
    DateTime now,
  ) {
    final filtered = monitors.where((monitor) {
      return switch (_filter) {
        _MonitorFilter.all => true,
        _MonitorFilter.attention => _needsAttention(monitor, repository, now),
        _MonitorFilter.paused => !monitor.enabled,
      };
    }).toList();
    filtered.sort((a, b) {
      final aNeeds = _needsAttention(a, repository, now) ? 0 : 1;
      final bNeeds = _needsAttention(b, repository, now) ? 0 : 1;
      if (aNeeds != bNeeds) return aNeeds.compareTo(bNeeds);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return filtered;
  }

  bool _needsAttention(
    MonitorConfig monitor,
    MonitorRepository? repository,
    DateTime now,
  ) {
    if (!monitor.enabled) return false;
    final status = monitorStatusFor(
      monitor: monitor,
      state: repository?.stateFor(monitor.id) ?? AlertState.initial,
      check: repository?.checkFor(monitor.id),
      lastChecked: repository?.lastChecked[monitor.id],
      now: now,
    );
    if (status.needsAttention) return true;
    return _expiryWarning(monitor, now) != null;
  }

  String? _expiryWarning(MonitorConfig monitor, DateTime now) {
    final registrationDays = monitor.registrationExpiry?.difference(now).inDays;
    if (registrationDays != null && registrationDays <= 14) {
      return 'Registration ${_relativeDays(registrationDays)}';
    }
    final certificateDays = monitor.certificateExpiry?.difference(now).inDays;
    if (certificateDays != null && certificateDays <= 14) {
      return 'TLS certificate ${_relativeDays(certificateDays)}';
    }
    return null;
  }
}

class _MonitorCard extends StatelessWidget {
  const _MonitorCard({
    required this.monitor,
    required this.state,
    required this.check,
    required this.lastChecked,
    required this.now,
    required this.checking,
    required this.busy,
    required this.needsAttention,
    required this.onCheck,
    required this.onOpen,
    required this.onAction,
  });

  final MonitorConfig monitor;
  final AlertState state;
  final MonitorCheckRecord? check;
  final DateTime? lastChecked;
  final DateTime now;
  final bool checking;
  final bool busy;
  final bool needsAttention;
  final VoidCallback onCheck;
  final VoidCallback onOpen;
  final ValueChanged<_MonitorAction> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = monitorStatusFor(
      monitor: monitor,
      state: state,
      check: check,
      lastChecked: lastChecked,
      now: now,
    );
    final tone = _toneFor(monitor, status, needsAttention);
    final statusText = _statusText(
      monitor,
      status,
      state,
      check,
      lastChecked,
      needsAttention,
    );
    final expiry = _expiryText(monitor);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 15, 10, 15),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: tone.color(context).withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(tone.icon, color: tone.color(context), size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            monitor.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        StatusPill(
                          tone: tone,
                          label: _shortLabel(status, tone),
                          compact: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      statusText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: tone == StatusTone.critical
                            ? vigilant-corePalette.critical
                            : null,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _MetaChip(
                          icon: monitor.isTcp
                              ? Icons.lan_outlined
                              : Icons.language_rounded,
                          label: monitor.isTcp
                              ? 'TCP ${monitor.targetPort ?? '?'}'
                              : 'HTTP',
                        ),
                        _MetaChip(
                          icon: Icons.schedule_rounded,
                          label: _cadence(monitor),
                        ),
                        _MetaChip(
                          icon: Icons.speed_rounded,
                          label:
                              '${monitor.latencyBudget.inMilliseconds}ms budget',
                        ),
                        if (expiry != null)
                          _MetaChip(
                            icon: Icons.event_outlined,
                            label: expiry,
                            color: tone == StatusTone.attention
                                ? vigilant-corePalette.warning
                                : null,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 2),
              Column(
                children: [
                  IconButton(
                    tooltip: 'Check now',
                    onPressed: busy ? null : onCheck,
                    icon: checking
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bolt_rounded),
                  ),
                  PopupMenuButton<_MonitorAction>(
                    tooltip: 'More actions',
                    onSelected: onAction,
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: _MonitorAction.check,
                        child: const ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.refresh_rounded),
                          title: Text('Check now'),
                        ),
                      ),
                      PopupMenuItem(
                        value: monitor.enabled
                            ? _MonitorAction.pause
                            : _MonitorAction.resume,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            monitor.enabled
                                ? Icons.pause_circle_outline_rounded
                                : Icons.play_circle_outline_rounded,
                          ),
                          title: Text(
                            monitor.enabled
                                ? 'Pause monitor'
                                : 'Resume monitor',
                          ),
                        ),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: _MonitorAction.remove,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.delete_outline_rounded),
                          title: Text('Remove monitor'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static StatusTone _toneFor(
    MonitorConfig monitor,
    MonitorStatus status,
    bool needsAttention,
  ) {
    if (!monitor.enabled) return StatusTone.paused;
    if (status == MonitorStatus.stale) return StatusTone.stale;
    if (needsAttention && status == MonitorStatus.healthy) {
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

  static String _shortLabel(MonitorStatus status, StatusTone tone) {
    if (status == MonitorStatus.healthy && tone == StatusTone.attention) {
      return 'Attention';
    }
    return switch (status) {
      MonitorStatus.healthy => 'Healthy',
      MonitorStatus.degraded => 'Slow',
      MonitorStatus.down => 'Down',
      MonitorStatus.unknown => 'Unknown',
      MonitorStatus.stale => 'Stale',
      MonitorStatus.paused => 'Paused',
    };
  }

  static String _statusText(
    MonitorConfig monitor,
    MonitorStatus status,
    AlertState state,
    MonitorCheckRecord? check,
    DateTime? lastChecked,
    bool needsAttention,
  ) {
    if (!monitor.enabled) return 'Monitoring is paused';
    final checkedAt = check?.checkedAt ?? lastChecked;
    final checked = checkedAt == null
        ? 'not checked yet'
        : 'checked ${_ago(checkedAt)}';
    final provider = check?.provider ?? providerLabelFor(monitor);
    if (status == MonitorStatus.stale) {
      final lastKnown = check == null
          ? 'no last result'
          : 'last known ${check.status == HealthStatus.up
                ? 'healthy'
                : check.status == HealthStatus.down
                ? 'down'
                : 'not healthy'}';
      return 'Stale · $lastKnown · $provider · $checked';
    }
    if (status == MonitorStatus.unknown) {
      return 'Unknown · $provider · $checked';
    }
    if (needsAttention && status == MonitorStatus.healthy) {
      return 'Expiry needs attention · $provider · $checked';
    }
    final statusText = switch (status) {
      MonitorStatus.healthy => 'Healthy',
      MonitorStatus.degraded => 'Responding slowly',
      MonitorStatus.down => 'Down',
      MonitorStatus.unknown => 'Unknown',
      MonitorStatus.stale => 'Stale',
      MonitorStatus.paused => 'Paused',
    };
    final result = '$statusText · $provider · $checked';
    if (status == MonitorStatus.down && state.status != HealthStatus.down) {
      return '$result · awaiting confirmation';
    }
    if (state.acknowledged && status == MonitorStatus.down) {
      return '$result · acknowledged';
    }
    if (state.mutedUntil?.isAfter(DateTime.now().toUtc()) ?? false) {
      return '$result · muted';
    }
    return result;
  }

  static String? _expiryText(MonitorConfig monitor) {
    final expiry = [
      if (monitor.certificateExpiry != null)
        'TLS ${monitor.certificateExpiry!.toIso8601String().substring(0, 10)}',
      if (monitor.registrationExpiry != null)
        'Domain ${monitor.registrationExpiry!.toIso8601String().substring(0, 10)}',
    ];
    return expiry.isEmpty ? null : expiry.join(' · ');
  }

  static String _cadence(MonitorConfig monitor) {
    final minutes = monitor.cadence.inMinutes;
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    return '${hours}h${minutes % 60 == 0 ? '' : ' ${minutes % 60}m'}';
  }
}

enum _MonitorAction { check, pause, resume, remove }

/// Says when the background service last ran a check sweep.
///
/// Per-monitor freshness cannot answer this on its own. Every monitor looking
/// equally stale is what a dead scheduler and a fleet-wide outage both look
/// like, and "Everything looks good" is a claim the app should not be able to
/// make by accident. This line is the difference, and when the sweep is late it
/// names the reason instead of leaving the user to guess.
class _SweepLine extends StatelessWidget {
  const _SweepLine({
    required this.sweptAt,
    required this.now,
    required this.paused,
  });

  final DateTime? sweptAt;
  final DateTime now;

  /// Whether the user turned background monitoring off. When they have, a late
  /// sweep is the expected result of their own decision and must not be
  /// reported as the operating system failing to schedule work.
  final bool paused;

  /// The service repeats every 60s, so a sweep older than this means the
  /// scheduler stopped, not that the app was busy.
  static const _lateAfter = Duration(minutes: 5);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = sweptAt;

    final (IconData icon, String text, Color? color) = switch (at) {
      null => (
        Icons.schedule_rounded,
        'No background check has run on this device yet.',
        vigilant-corePalette.warning,
      ),
      _ when paused => (
        Icons.pause_circle_outline_rounded,
        'Background monitoring is off, so nothing is being checked. '
            'Turn it back on in Settings.',
        vigilant-corePalette.warning,
      ),
      _ when now.toUtc().difference(at) > _lateAfter => (
        Icons.pause_circle_outline_rounded,
        'Last background check ${_ago(at)} — Android is not scheduling it. '
            'Battery optimisation can stop this; see Settings.',
        vigilant-corePalette.warning,
      ),
      _ => (Icons.check_circle_outline_rounded, 'Checked ${_ago(at)}', null),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 14,
          color: color ?? theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color ?? theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: foreground, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: foreground),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: foreground),
        ),
      ],
    );
  }
}

class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner({
    required this.canPage,
    required this.hasDndAccess,
    required this.onOpenSettings,
    required this.onRequestDndAccess,
  });

  final bool? canPage;
  final bool? hasDndAccess;
  final VoidCallback? onOpenSettings;
  final VoidCallback onRequestDndAccess;

  @override
  Widget build(BuildContext context) {
    final notificationsBlocked = canPage == false;
    final dndBlocked = canPage != false && hasDndAccess == false;
    if (!notificationsBlocked && !dndBlocked) return const SizedBox.shrink();

    final color = notificationsBlocked
        ? vigilant-corePalette.critical
        : vigilant-corePalette.warning;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Card(
        color: color.withValues(alpha: 0.10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              Icon(Icons.notifications_off_outlined, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notificationsBlocked
                          ? 'Notifications are turned off'
                          : 'Critical pages may be silenced',
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(color: color),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      notificationsBlocked
                          ? 'Allow notifications so vigilant-core can tell you about incidents.'
                          : 'Allow Do Not Disturb access if urgent pages should wake the device.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: notificationsBlocked
                    ? onOpenSettings
                    : onRequestDndAccess,
                child: Text(notificationsBlocked ? 'Settings' : 'Allow'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyDashboard extends StatelessWidget {
  const _EmptyDashboard({required this.onAddMonitor});

  final VoidCallback? onAddMonitor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      // Anchored near the top: the header sits directly above, so centring in
      // the remaining viewport strands the call to action behind a large void.
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 12, 28, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.sensors_rounded,
                size: 34,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text('Watch what matters', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Scan a website or domain you own or rely on, then keep an eye on it from this device.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onAddMonitor != null) ...[
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: onAddMonitor,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add monitor'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NoFilterResults extends StatelessWidget {
  const _NoFilterResults();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.filter_alt_off_outlined,
              size: 36,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            const Text('No monitors match this filter.'),
          ],
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _ago(DateTime at) {
  final delta = DateTime.now().toUtc().difference(at);
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inHours < 1) return '${delta.inMinutes}m ago';
  if (delta.inDays < 1) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}

String _relativeDays(int days) => days < 0
    ? '${days.abs()}d overdue'
    : days == 0
    ? 'expires today'
    : 'expires in ${days}d';
