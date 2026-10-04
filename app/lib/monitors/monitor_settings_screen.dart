import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/material.dart';

import '../alerts/pager_style.dart';
import 'monitor_config.dart';
import 'monitor_coordinator.dart';
import 'monitor_form.dart';

/// Edits a monitor using a clear starting point (preset) and progressive
/// disclosure for the controls that power users may need.
class MonitorSettingsScreen extends StatefulWidget {
  const MonitorSettingsScreen({
    super.key,
    required this.coordinator,
    required this.monitor,
  });

  final MonitorCoordinator coordinator;
  final MonitorConfig monitor;

  @override
  State<MonitorSettingsScreen> createState() => _MonitorSettingsScreenState();
}

enum _MonitorPreset { balanced, sensitive, availability, custom }

const _presetOptions = [
  _MonitorPreset.balanced,
  _MonitorPreset.sensitive,
  _MonitorPreset.availability,
];

extension on _MonitorPreset {
  String get label => switch (this) {
    _MonitorPreset.balanced => 'Balanced',
    _MonitorPreset.sensitive => 'Sensitive',
    _MonitorPreset.availability => 'Availability only',
    _MonitorPreset.custom => 'Custom',
  };

  String get description => switch (this) {
    _MonitorPreset.balanced => 'A practical default for most services. Alerts on failures and slow responses.',
    _MonitorPreset.sensitive =>
      'Checks more often and pages quickly when latency drifts or checks fail.',
    _MonitorPreset.availability =>
      'Fewer interruptions. Pages only after repeated hard failures.',
    _MonitorPreset.custom =>
      'Your own combination of cadence, thresholds, and alerts.',
  };

  IconData get icon => switch (this) {
    _MonitorPreset.balanced => Icons.tune_rounded,
    _MonitorPreset.sensitive => Icons.bolt_rounded,
    _MonitorPreset.availability => Icons.shield_outlined,
    _MonitorPreset.custom => Icons.edit_note_rounded,
  };
}

class _MonitorSettingsScreenState extends State<MonitorSettingsScreen> {
  static const List<int> _budgetMillis = [1000, 2500, 5000, 10000];
  static const List<int> _thresholds = [1, 2, 3, 5];
  static const List<int> _repeatMinutes = [1, 5, 15, 30];

  late final TextEditingController _nameController;
  late int _cadence;
  late int _budget;
  late int _threshold;
  late int _repeatMinutesValue;
  late bool _urgent;
  late bool _repeatWhileDown;
  late bool _notifyOnRecovery;
  late bool _notifyOnDegraded;
  late bool _quietEnabled;
  late int _quietStart;
  late int _quietEnd;
  late bool _quietBypass;
  late AlertSound _sound;
  late AlertVibration _vibration;
  late _MonitorPreset _preset;

  @override
  void initState() {
    super.initState();
    final monitor = widget.monitor;
    final policy = monitor.policy;
    _nameController = TextEditingController(text: monitor.name);
    _cadence = _nearest(kCadenceMinutes, monitor.cadence.inMinutes);
    _budget = _nearest(_budgetMillis, monitor.latencyBudget.inMilliseconds);
    _threshold = _nearest(_thresholds, policy.failureThreshold);
    _repeatMinutesValue = _nearest(
      _repeatMinutes,
      policy.repeatInterval.inMinutes,
    );
    _urgent = policy.urgent;
    _repeatWhileDown = policy.repeatWhileDown;
    _notifyOnRecovery = policy.notifyOnRecovery;
    _notifyOnDegraded = policy.notifyOnDegraded;
    _quietEnabled = policy.quietHours != null;
    _quietStart = policy.quietHours?.startMinutes ?? 22 * 60;
    _quietEnd = policy.quietHours?.endMinutes ?? 7 * 60;
    _quietBypass = policy.quietHours?.bypassForUrgent ?? false;
    _sound = monitor.style.sound;
    _vibration = monitor.style.vibration;
    _preset = _inferPreset();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  MonitorConfig _build() => widget.monitor.copyWith(
    name: _nameController.text.trim().isEmpty
        ? widget.monitor.name
        : _nameController.text.trim(),
    cadence: Duration(minutes: _cadence),
    latencyBudget: Duration(milliseconds: _budget),
    policy: AlertPolicy(
      failureThreshold: _threshold,
      cooldown: widget.monitor.policy.cooldown,
      repeatWhileDown: _repeatWhileDown,
      repeatInterval: Duration(minutes: _repeatMinutesValue),
      urgent: _urgent,
      notifyOnRecovery: _notifyOnRecovery,
      notifyOnDegraded: _notifyOnDegraded,
      quietHours: _quietEnabled
          ? QuietHours(
              startMinutes: _quietStart,
              endMinutes: _quietEnd,
              bypassForUrgent: _quietBypass,
            )
          : null,
    ),
    style: AlertStyle(sound: _sound, vibration: _vibration),
  );

  Future<void> _save() async {
    try {
      await widget.coordinator.updateMonitor(_build());
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not save settings: ${friendlyMonitorError(error)}',
            ),
          ),
        );
      }
    }
  }

  Future<void> _pickTime(bool start) async {
    final current = _tod(start ? _quietStart : _quietEnd);
    final picked = await showTimePicker(context: context, initialTime: current);
    if (picked == null) return;
    setState(() {
      if (start) {
        _quietStart = _minutes(picked);
      } else {
        _quietEnd = _minutes(picked);
      }
    });
  }

  void _applyPreset(_MonitorPreset preset) {
    setState(() {
      _preset = preset;
      switch (preset) {
        case _MonitorPreset.balanced:
          _cadence = 5;
          _budget = 2500;
          _threshold = 1;
          _repeatWhileDown = false;
          _repeatMinutesValue = 5;
          _urgent = false;
          _notifyOnRecovery = true;
          _notifyOnDegraded = true;
        case _MonitorPreset.sensitive:
          _cadence = 1;
          _budget = 1000;
          _threshold = 1;
          _repeatWhileDown = true;
          _repeatMinutesValue = 1;
          _urgent = false;
          _notifyOnRecovery = true;
          _notifyOnDegraded = true;
        case _MonitorPreset.availability:
          _cadence = 10;
          _budget = 5000;
          _threshold = 2;
          _repeatWhileDown = false;
          _repeatMinutesValue = 5;
          _urgent = false;
          _notifyOnRecovery = true;
          _notifyOnDegraded = false;
        case _MonitorPreset.custom:
          break;
      }
    });
  }

  _MonitorPreset _inferPreset() {
    if (_cadence == 1 &&
        _budget == 1000 &&
        _repeatWhileDown &&
        _notifyOnDegraded) {
      return _MonitorPreset.sensitive;
    }
    if (_cadence == 10 &&
        _budget == 5000 &&
        _threshold == 2 &&
        !_notifyOnDegraded) {
      return _MonitorPreset.availability;
    }
    return _MonitorPreset.balanced;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monitor settings'),
        actions: [
          IconButton(
            tooltip: 'Save settings',
            onPressed: _save,
            icon: const Icon(Icons.check_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'Make this monitor fit your service.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _nameController,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Monitor name',
              prefixIcon: Icon(Icons.label_outline_rounded),
            ),
          ),
          const SizedBox(height: 26),
          Text('Alert profile', style: theme.textTheme.titleMedium),
          const SizedBox(height: 5),
          Text(
            'Start with a profile, then fine-tune the advanced controls below.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final preset in _presetOptions)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _PresetCard(
                preset: preset,
                selected: _preset == preset,
                onTap: () => _applyPreset(preset),
              ),
            ),
          if (_preset == _MonitorPreset.custom)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Icon(
                    Icons.edit_note_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text('Custom settings', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          _SettingsGroup(
            title: 'Checking',
            icon: Icons.radar_rounded,
            initiallyExpanded: true,
            children: [
              _dropdown<int>(
                label: 'Check every',
                value: _cadence,
                items: kCadenceMinutes,
                labelOf: cadenceLabel,
                onChanged: (value) => setState(() {
                  _cadence = value;
                  _preset = _MonitorPreset.custom;
                }),
              ),
              _dropdown<int>(
                label: 'Latency budget',
                value: _budget,
                items: _budgetMillis,
                labelOf: (value) => '$value ms',
                onChanged: (value) => setState(() {
                  _budget = value;
                  _preset = _MonitorPreset.custom;
                }),
              ),
            ],
          ),
          _SettingsGroup(
            title: 'Paging and recovery',
            icon: Icons.notifications_active_outlined,
            initiallyExpanded: true,
            children: [
              _dropdown<int>(
                label: 'Failures before down',
                value: _threshold,
                items: _thresholds,
                labelOf: (value) => '$value failure${value == 1 ? '' : 's'}',
                onChanged: (value) => setState(() {
                  _threshold = value;
                  _preset = _MonitorPreset.custom;
                }),
              ),
              _switchTile(
                title: 'Notify when degraded',
                subtitle: 'Alert when a successful response is slower than the budget.',
                value: _notifyOnDegraded,
                onChanged: (value) => setState(() {
                  _notifyOnDegraded = value;
                  _preset = _MonitorPreset.custom;
                }),
              ),
              _switchTile(
                title: 'Repeat while down',
                subtitle: 'Keep reminding you until the service recovers or you acknowledge it.',
                value: _repeatWhileDown,
                onChanged: (value) => setState(() {
                  _repeatWhileDown = value;
                  _preset = _MonitorPreset.custom;
                }),
              ),
              if (_repeatWhileDown)
                _dropdown<int>(
                  label: 'Repeat interval',
                  value: _repeatMinutesValue,
                  items: _repeatMinutes,
                  labelOf: (value) => '$value min',
                  onChanged: (value) => setState(() {
                    _repeatMinutesValue = value;
                    _preset = _MonitorPreset.custom;
                  }),
                ),
              _switchTile(
                title: 'Notify on recovery',
                subtitle: 'Send a confirmation when the service comes back.',
                value: _notifyOnRecovery,
                onChanged: (value) => setState(() {
                  _notifyOnRecovery = value;
                  _preset = _MonitorPreset.custom;
                }),
              ),
              _switchTile(
                title: 'Critical / urgent page',
                subtitle: 'Repeat until acknowledged and bypass Do Not Disturb when allowed.',
                value: _urgent,
                onChanged: (value) => setState(() {
                  _urgent = value;
                  _preset = _MonitorPreset.custom;
                }),
              ),
            ],
          ),
          _SettingsGroup(
            title: 'Sound and vibration',
            icon: Icons.graphic_eq_rounded,
            children: [
              _dropdown<AlertSound>(
                label: 'Sound',
                value: _sound,
                items: AlertSound.values,
                labelOf: _soundLabel,
                onChanged: (value) => setState(() => _sound = value),
              ),
              _dropdown<AlertVibration>(
                label: 'Vibration',
                value: _vibration,
                items: AlertVibration.values,
                labelOf: _vibrationLabel,
                onChanged: (value) => setState(() => _vibration = value),
              ),
            ],
          ),
          _SettingsGroup(
            title: 'Quiet hours',
            icon: Icons.bedtime_outlined,
            children: [
              _switchTile(
                title: 'Enable quiet hours',
                subtitle: 'Pause non-urgent pages during a daily window.',
                value: _quietEnabled,
                onChanged: (value) => setState(() => _quietEnabled = value),
              ),
              if (_quietEnabled) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Start'),
                  trailing: Text(_formatMinutes(_quietStart)),
                  onTap: () => _pickTime(true),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('End'),
                  trailing: Text(_formatMinutes(_quietEnd)),
                  onTap: () => _pickTime(false),
                ),
                _switchTile(
                  title: 'Urgent bypasses quiet hours',
                  subtitle: 'Only applies when system permission is available.',
                  value: _quietBypass,
                  onChanged: (value) => setState(() => _quietBypass = value),
                ),
              ],
            ],
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.check_rounded),
          label: const Text('Save monitor settings'),
        ),
      ),
    );
  }

  Widget _switchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) labelOf,
    required ValueChanged<T> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final item in items)
            DropdownMenuItem(value: item, child: Text(labelOf(item))),
        ],
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final _MonitorPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.outline;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color, width: selected ? 1.5 : 1),
      ),
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.08)
          : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  preset.icon,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(preset.label, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 3),
                    Text(preset.description, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: color,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({
    required this.title,
    required this.icon,
    required this.children,
    this.initiallyExpanded = false,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(title),
        children: children,
      ),
    );
  }
}

String _soundLabel(AlertSound value) => switch (value) {
  AlertSound.none => 'Silent',
  AlertSound.notification => 'Notification',
  AlertSound.alarm => 'Alarm',
};

String _vibrationLabel(AlertVibration value) => switch (value) {
  AlertVibration.none => 'None',
  AlertVibration.short => 'Short',
  AlertVibration.long => 'Long',
  AlertVibration.escalating => 'Escalating',
};

int _nearest(List<int> options, int value) {
  var best = options.first;
  for (final option in options) {
    if ((option - value).abs() < (best - value).abs()) best = option;
  }
  return best;
}

TimeOfDay _tod(int minutes) =>
    TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);

int _minutes(TimeOfDay time) => time.hour * 60 + time.minute;

String _formatMinutes(int minutes) {
  final time = _tod(minutes);
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}
