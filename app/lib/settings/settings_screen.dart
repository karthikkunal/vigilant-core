import 'dart:async';

import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../alerts/pager_style.dart';
import '../discovery/dns_resolver.dart';
import '../discovery/resolver_preference.dart';
import '../monitors/list_clipboard.dart';
import '../monitors/monitor_config.dart';
import '../monitors/monitor_coordinator.dart';
import '../monitors/monitor_transfer.dart';
import '../theme/vigilant-core_theme.dart';
import '../ui/status_pill.dart';
import '../monitors/monitor_form.dart';

/// Secondary navigation for privacy, permissions, and safe developer tools.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.coordinator,
    this.clipboard = const SystemListClipboard(),
  });

  final MonitorCoordinator coordinator;

  /// Where the site list is written to and read from.
  final ListClipboard clipboard;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool? _canPage;
  bool? _hasDndAccess;
  bool? _batteryOptimizationIgnored;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAccess();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadAccess();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadAccess() async {
    try {
      final canPage = await widget.coordinator.pager.canPage();
      final hasDnd = await widget.coordinator.pager.hasDndAccess();
      final batteryOptimizationIgnored = await widget.coordinator
          .isBatteryOptimizationIgnored();
      if (mounted) {
        setState(() {
          _canPage = canPage;
          _hasDndAccess = hasDnd;
          _batteryOptimizationIgnored = batteryOptimizationIgnored;
        });
      }
    } catch (_) {
      // Settings should remain usable when a platform capability is absent.
    }
  }

  Future<void> _enableNotifications() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.coordinator.pager.initialize();
      final enabled = await widget.coordinator.pager.canPage();
      if (!mounted) return;
      setState(() => _canPage = enabled);
      _showMessage(
        enabled
            ? 'Notifications are ready.'
            : 'Notifications are still disabled in system settings.',
      );
    } catch (error) {
      _showMessage(
        'Could not update notification access: ${friendlyMonitorError(error)}',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enableDndAccess() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final granted = await widget.coordinator.pager.requestDndAccess();
      if (!mounted) return;
      setState(() => _hasDndAccess = granted);
      _showMessage(
        granted
            ? 'Critical pages can bypass Do Not Disturb.'
            : 'Do Not Disturb access was not granted.',
      );
    } catch (error) {
      _showMessage(
        'Could not open Do Not Disturb settings: ${friendlyMonitorError(error)}',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openBatterySettings() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final opened = await widget.coordinator.openBatteryOptimizationSettings();
      if (!opened) {
        _showMessage('Android battery settings could not be opened.');
      }
    } catch (error) {
      _showMessage(
        'Could not open Android battery settings: ${friendlyMonitorError(error)}',
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _loadAccess();
      }
    }
  }

  Future<void> _sendTestPage() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final name = 'test.example.com';
      await widget.coordinator.pager.deliver(
        AlertIntent(
          kind: AlertKind.down,
          at: DateTime.now(),
          urgent: true,
          reason: 'Simulated check failure',
        ),
        monitorId: name,
        monitorName: name,
        style: AlertStyle.urgent,
      );
      _showMessage('Test page sent.');
    } catch (error) {
      _showMessage('Could not send test page: ${friendlyMonitorError(error)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 18),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(
                      Icons.tune_rounded,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Settings', style: theme.textTheme.headlineSmall),
                        const SizedBox(height: 2),
                        Text(
                          'Control how vigilant-core behaves',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: _PrivacyCard(),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: _ResolverCard(coordinator: widget.coordinator),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: _AccessCard(
                canPage: _canPage,
                hasDndAccess: _hasDndAccess,
                canPageInBackground:
                    widget.coordinator.pager.canPageInBackground,
                busy: _busy,
                onEnableNotifications: _enableNotifications,
                onEnableDnd: _enableDndAccess,
              ),
            ),
          ),
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: _BackgroundMonitoringCard(
                  coordinator: widget.coordinator,
                  busy: _busy,
                  onChanged: () => setState(() {}),
                ),
              ),
            ),
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: _BatteryGuidanceCard(
                  optimizationIgnored: _batteryOptimizationIgnored,
                  busy: _busy,
                  onOpenSettings: _openBatterySettings,
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: _TransferCard(
                coordinator: widget.coordinator,
                busy: _busy,
                onChanged: () => setState(() {}),
                clipboard: widget.clipboard,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: _TestPageCard(busy: _busy, onSendTest: _sendTestPage),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: _AboutCard(),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

class _PrivacyCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: vigilant-corePalette.healthy.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(
                Icons.shield_outlined,
                color: vigilant-corePalette.healthy,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Transparent by design',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'vigilant-core has no account or backend and does not store your '
                    'monitor data on a server. Checks originate on this device. '
                    'Scans contact the selected site and public discovery services; '
                    'monitors contact the site or service you selected.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  const StatusPill(
                    tone: StatusTone.healthy,
                    label: 'Local-first monitoring',
                    compact: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResolverCard extends StatefulWidget {
  const _ResolverCard({required this.coordinator});

  final MonitorCoordinator coordinator;

  @override
  State<_ResolverCard> createState() => _ResolverCardState();
}

class _ResolverCardState extends State<_ResolverCard> {
  late ResolverPreference _preference;
  late final TextEditingController _endpointController;
  String? _error;

  /// True while a custom endpoint is being edited but not yet accepted.
  ///
  /// The endpoint field used to render only when [ResolverPreference.mode] was
  /// already [ResolverMode.custom], which made the option unreachable: choosing
  /// it called [_applyCustom], that validated an empty controller, it bailed,
  /// the mode never changed, and the field never appeared. The only way in was
  /// to already have a saved endpoint. Track the intent separately from the
  /// saved preference so selecting the option reveals the field, and let the
  /// error ride on that field instead of replacing it.
  bool _editingCustom = false;

  @override
  void initState() {
    super.initState();
    _preference = widget.coordinator.resolver.value;
    _endpointController = TextEditingController(
      text: _preference.endpoint?.toString() ?? '',
    );
    widget.coordinator.resolver.addListener(_onCoordinatorChanged);
    unawaited(widget.coordinator.loadResolver());
  }

  @override
  void didUpdateWidget(covariant _ResolverCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coordinator != widget.coordinator) {
      oldWidget.coordinator.resolver.removeListener(_onCoordinatorChanged);
      widget.coordinator.resolver.addListener(_onCoordinatorChanged);
    }
  }

  @override
  void dispose() {
    widget.coordinator.resolver.removeListener(_onCoordinatorChanged);
    _endpointController.dispose();
    super.dispose();
  }

  void _onCoordinatorChanged() {
    if (!mounted) return;
    setState(() => _preference = widget.coordinator.resolver.value);
  }

  Future<void> _apply(ResolverPreference preference) async {
    final saved = await widget.coordinator.setResolver(preference);
    if (!mounted) return;
    final message = saved
        ? null
        : 'The resolver choice could not be saved on this device.';
    setState(() {
      _preference = widget.coordinator.resolver.value;
      _error = message;
    });
    if (message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _applyCustom() async {
    final raw = _endpointController.text.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        !uri.hasAuthority) {
      setState(() => _error = 'Enter a full https:// URL for the resolver.');
      return;
    }
    setState(() {
      _error = null;
      // Accepted: the saved preference is now the source of truth, so drop the
      // transient editing state and let the field render off the mode.
      _editingCustom = false;
    });
    await _apply(ResolverPreference.custom(uri));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final choice = resolveDns(_preference);
    final fallback = resolverFallbackReason(_preference);
    // What selecting the device option would actually do on this platform. The
    // claim has to follow the resolver, not a fixed string: where no platform
    // resolver exists the choice silently becomes a third-party lookup.
    final deviceChoice = resolveDns(const ResolverPreference.device());
    final deviceStaysLocal = !deviceChoice.usesThirdParty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: vigilant-corePalette.healthy.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    Icons.dns_outlined,
                    color: vigilant-corePalette.healthy,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('DNS resolver', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 5),
                      Text(
                        'The device resolver keeps the domains you scan on this '
                        'device. A DNS-over-HTTPS service is a third party and '
                        'sees every name you look up. If the device resolver '
                        'cannot answer, a scan falls back to a public service '
                        'and names it in the report rather than losing the '
                        'results.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            StatusPill(
              tone: choice.usesThirdParty
                  ? StatusTone.attention
                  : StatusTone.healthy,
              label: choice.usesThirdParty
                  ? 'Third-party resolver: ${choice.label}'
                  : 'Device resolver',
              compact: true,
            ),
            if (fallback.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(fallback, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 6),
            RadioListTile<ResolverMode>(
              value: ResolverMode.device,
              // ignore: deprecated_member_use
              groupValue: _preference.mode,
              // ignore: deprecated_member_use
              onChanged: (mode) {
                if (mode != null) {
                  setState(() => _editingCustom = false);
                  unawaited(_apply(const ResolverPreference.device()));
                }
              },
              title: const Text('Device resolver'),
              // The privacy benefit is worth stating when it is true. When the
              // fallback note above already explains that this platform cannot
              // honour the choice, a second explanation here is just an echo.
              //
              // "No third party is contacted" would no longer be true as an
              // unconditional claim: the device resolver is tried first and a
              // scan falls back to a public service if it cannot answer. That
              // fallback is disclosed in the scan report, so the promise here is
              // about what is tried first, not about a guarantee.
              subtitle: deviceStaysLocal
                  ? const Text(
                      'Recommended. Lookups go to the device resolver first, '
                      'and the report names any service used instead.',
                    )
                  : fallback.isEmpty
                  ? const Text('Not available on this platform.')
                  : null,
              contentPadding: EdgeInsets.zero,
            ),
            RadioListTile<ResolverMode>(
              value: ResolverMode.custom,
              // ignore: deprecated_member_use
              groupValue: _preference.mode,
              // ignore: deprecated_member_use
              onChanged: (mode) {
                // Reveal the endpoint field rather than trying to validate a
                // controller the reader has not been able to see yet.
                if (mode != null) setState(() => _editingCustom = true);
              },
              title: const Text('Custom DNS-over-HTTPS'),
              subtitle: const Text('Point vigilant-core at your own resolver.'),
              contentPadding: EdgeInsets.zero,
            ),
            if (_editingCustom || _preference.mode == ResolverMode.custom) ...[
              const SizedBox(height: 4),
              TextField(
                controller: _endpointController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Resolver endpoint',
                  hintText: 'https://dns.example.com/dns-query',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.check_rounded),
                    tooltip: 'Use this resolver',
                    onPressed: () => unawaited(_applyCustom()),
                  ),
                ),
                onSubmitted: (_) => unawaited(_applyCustom()),
              ),
            ] else if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AccessCard extends StatelessWidget {
  const _AccessCard({
    required this.canPage,
    required this.hasDndAccess,
    required this.canPageInBackground,
    required this.busy,
    required this.onEnableNotifications,
    required this.onEnableDnd,
  });

  final bool? canPage;
  final bool? hasDndAccess;

  /// False on platforms with no foreground monitoring, where a "Ready" state
  /// would promise incident pages that cannot be delivered.
  final bool canPageInBackground;

  final bool busy;
  final VoidCallback onEnableNotifications;
  final VoidCallback onEnableDnd;

  @override
  Widget build(BuildContext context) {
    final notificationsReady = canPageInBackground && canPage == true;
    final dndReady = hasDndAccess == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 17, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'System access',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 5),
            Text(
              canPageInBackground
                  ? 'Permissions are requested only when you need the related alert behavior.'
                  : 'Incident pages need the Android foreground service. '
                        'This platform still runs scheduled expiry reminders and '
                        'on-demand checks.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _AccessRow(
              icon: Icons.notifications_outlined,
              title: 'Notifications',
              detail: !canPageInBackground
                  ? 'No background monitoring on this platform'
                  : notificationsReady
                  ? 'Ready to deliver incident pages'
                  : 'Required for outage and recovery alerts',
              ready: notificationsReady,
              applicable: canPageInBackground,
              actionLabel: 'Enable',
              onAction: onEnableNotifications,
              busy: busy,
            ),
            if (canPageInBackground) ...[
              const Divider(height: 1),
              _AccessRow(
                icon: Icons.do_not_disturb_on_outlined,
                title: 'Critical pages',
                detail: dndReady
                    ? 'Can bypass Do Not Disturb when urgent'
                    : 'Optional: allow urgent pages to wake the device',
                ready: dndReady,
                actionLabel: 'Allow',
                onAction: onEnableDnd,
                busy: busy,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AccessRow extends StatelessWidget {
  const _AccessRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.ready,
    required this.actionLabel,
    required this.onAction,
    required this.busy,
    this.applicable = true,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool ready;
  final String actionLabel;
  final VoidCallback onAction;
  final bool busy;

  /// When false the row reports that the capability is missing here, and offers
  /// no action, because there is no system setting that would enable it.
  final bool applicable;

  @override
  Widget build(BuildContext context) {
    final color = ready
        ? vigilant-corePalette.healthy
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 3),
                Text(detail, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (!applicable)
            const StatusPill(
              tone: StatusTone.unknown,
              label: 'Not available',
              compact: true,
            )
          else if (ready)
            const StatusPill(
              tone: StatusTone.healthy,
              label: 'Ready',
              compact: true,
            )
          else
            TextButton(
              onPressed: busy ? null : onAction,
              child: Text(actionLabel),
            ),
        ],
      ),
    );
  }
}

/// The master switch for background monitoring.
///
/// Disabling a monitor stops that one being checked, but the foreground service
/// and its persistent notification are separate and outlive it. This is the only
/// control that stops the service, which is why it lives here rather than on a
/// per-monitor card.
///
/// Shown only on Android, because the service only exists there. On other
/// platforms there is nothing to stop: checks run when the app is open, and
/// expiry reminders are scheduled locally.
class _BackgroundMonitoringCard extends StatelessWidget {
  const _BackgroundMonitoringCard({
    required this.coordinator,
    required this.busy,
    required this.onChanged,
  });

  final MonitorCoordinator coordinator;
  final bool busy;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: coordinator.monitoringPaused,
      builder: (context, paused, _) {
        final theme = Theme.of(context);
        final tone = paused ? StatusTone.attention : StatusTone.healthy;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.play_circle_outline, color: tone.color(context)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Background monitoring',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: StatusPill(
                    tone: tone,
                    label: paused ? 'Off' : 'On',
                    compact: true,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  paused
                      ? 'The background service is stopped, so nothing is '
                            'checked while the app is closed and no pages can '
                            'arrive. Your monitors are kept, and "Check now" '
                            'still works. It stays off until you turn it back on.'
                      : 'The background service checks your monitors on their '
                            'own cadence and pages you when a check fails.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () async {
                          await coordinator.setMonitoringPaused(!paused);
                          onChanged();
                        },
                  icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                  label: Text(
                    paused ? 'Turn monitoring back on' : 'Turn monitoring off',
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BatteryGuidanceCard extends StatelessWidget {
  const _BatteryGuidanceCard({
    required this.optimizationIgnored,
    required this.busy,
    required this.onOpenSettings,
  });

  final bool? optimizationIgnored;
  final bool busy;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isExempt = optimizationIgnored == true;
    final isKnown = optimizationIgnored != null;
    final tone = isExempt
        ? StatusTone.healthy
        : optimizationIgnored == false
        ? StatusTone.attention
        : StatusTone.unknown;
    final detail = isExempt
        ? 'Battery optimization is not restricting vigilant-core. Android can still defer work under Doze or OEM power rules.'
        : optimizationIgnored == false
        ? 'Android may delay or skip checks while vigilant-core is optimized. Exempt the app for more reliable background monitoring.'
        : 'vigilant-core could not determine the Android battery-optimization setting. Check it manually if pages are delayed.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.battery_saver_outlined, color: tone.color(context)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Android background reliability',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: StatusPill(
                tone: tone,
                label: isKnown
                    ? (isExempt ? 'Exempt' : 'Restricted')
                    : 'Check settings',
                compact: true,
              ),
            ),
            const SizedBox(height: 10),
            Text(detail, style: theme.textTheme.bodySmall),
            if (optimizationIgnored != true) ...[
              const SizedBox(height: 10),
              Text(
                'Settings → Apps → vigilant-core → Battery → Unrestricted',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: busy ? null : onOpenSettings,
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Review battery settings'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Moves the monitor list between devices as a text document.
///
/// Both directions go through the clipboard rather than a file picker, so the
/// feature works identically on every platform the app targets and adds no
/// dependency that would change the build or the F-Droid recipe.
class _TransferCard extends StatefulWidget {
  const _TransferCard({
    required this.coordinator,
    required this.busy,
    required this.onChanged,
    this.clipboard = const SystemListClipboard(),
  });

  final MonitorCoordinator coordinator;
  final bool busy;
  final VoidCallback onChanged;

  /// Injectable so the flow can be tested without a platform channel.
  final ListClipboard clipboard;

  @override
  State<_TransferCard> createState() => _TransferCardState();
}

class _TransferCardState extends State<_TransferCard> {
  bool _working = false;

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _export() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final document = await widget.coordinator.exportMonitors();
      // Counted here rather than by reading the document back, so an empty list
      // says so rather than reporting that there is nothing to import.
      final lines = document
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList(growable: false);
      if (lines.isEmpty) {
        _message('There are no sites to copy yet.');
        return;
      }
      await widget.clipboard.write(document);
      _message('Copied ${_count(lines.length, 'site')} to the clipboard.');
    } catch (error) {
      _message('Could not copy the list: ${friendlyMonitorError(error)}');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _import() async {
    if (_working) return;

    // Read the clipboard first: on a browser build this can be refused, and
    // asking for permission before the user has chosen to import is noise.
    String payload;
    try {
      payload = await widget.clipboard.read() ?? '';
    } catch (_) {
      _message('This device would not let vigilant-core read the clipboard.');
      return;
    }

    ImportPreview preview;
    try {
      preview = await widget.coordinator.previewImport(payload);
    } on MonitorTransferException catch (error) {
      _message(error.message);
      return;
    } catch (error) {
      _message('Could not read the backup: ${friendlyMonitorError(error)}');
      return;
    }

    if (!mounted) return;
    if (preview.additions.isEmpty) {
      _message(
        preview.unreadable > 0
            ? 'Nothing to add. ${_count(preview.unreadable, 'line')} could not be read.'
            : 'Every site in that list is already on this device.',
      );
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _ImportPreviewDialog(preview: preview),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _working = true);
    try {
      final result = await widget.coordinator.importMonitors(payload);
      widget.onChanged();
      _message(
        [
          'Added ${_count(result.additions.length, 'site')}.',
          if (result.alreadyPresent > 0)
            '${_count(result.alreadyPresent, 'site')} already here.',
          if (result.unreadable > 0)
            '${_count(result.unreadable, 'line')} skipped.',
        ].join(' '),
      );
    } on MonitorTransferException catch (error) {
      _message(error.message);
    } catch (error) {
      _message('Could not import: ${friendlyMonitorError(error)}');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  static String _count(int value, String singular, [String? plural]) =>
      '$value ${value == 1 ? singular : (plural ?? '${singular}s')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.format_list_bulleted_rounded,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Site list', style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              'Copy the sites you watch as a plain list, or paste one in to add '
              'them. Only the addresses travel — your settings stay on this '
              'device.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _working ? null : _import,
                    icon: _working
                        ? const SizedBox(
                            width: 17,
                            height: 17,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.content_paste_go_outlined),
                    label: const Text('Import list'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _working ? null : _export,
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('Copy list'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows what an import would add, so a mistaken paste is caught before it
/// changes the list.
class _ImportPreviewDialog extends StatelessWidget {
  const _ImportPreviewDialog({required this.preview});

  final ImportPreview preview;

  /// Beyond this the names stop being a useful list and become a wall of text.
  static const int _maxNames = 12;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final additions = preview.additions;
    final shown = additions.take(_maxNames).toList();

    return AlertDialog(
      title: Text(
        'Add ${_TransferCardState._count(additions.length, 'site')}?',
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              preview.alreadyPresent > 0
                  ? '${_TransferCardState._count(preview.alreadyPresent, 'site')} '
                        '${preview.alreadyPresent == 1 ? 'is' : 'are'} already on '
                        'this device and will be left alone.'
                  : 'None of these are on this device yet.',
              style: theme.textTheme.bodyMedium,
            ),
            if (preview.unreadable > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${_TransferCardState._count(preview.unreadable, 'line')} could '
                'not be read and will be skipped.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 14),
            for (final monitor in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _iconFor(monitor),
                      size: 17,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        targetLineFor(monitor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            if (additions.length > shown.length)
              Text(
                'and ${additions.length - shown.length} more',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Add ${additions.length}'),
        ),
      ],
    );
  }

  static IconData _iconFor(MonitorConfig monitor) =>
      monitor.isTcp ? Icons.lan_outlined : Icons.language_rounded;
}

class _TestPageCard extends StatelessWidget {
  const _TestPageCard({required this.busy, required this.onSendTest});

  final bool busy;
  final VoidCallback onSendTest;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.science_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Developer tools',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              'Test the real delivery path on this device: sound, vibration, and notification actions.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: busy ? null : onSendTest,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Send test page'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('About vigilant-core', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Local-first monitoring for websites and domains you own or rely on. Reminders and checks are scheduled on your device; scans contact the selected site and public discovery services, while monitors contact the selected target.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            const _AboutRow(
              icon: Icons.schedule_outlined,
              title: 'Expiry reminders',
              detail: 'Scheduled locally from the last discovery result',
            ),
            const _AboutRow(
              icon: Icons.wifi_tethering_rounded,
              title: 'Availability checks',
              detail: 'Android can keep checking in the background',
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '$title · $detail',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
