import 'package:discovery_core/discovery_core.dart';
import 'package:flutter/material.dart';

import 'monitor_coordinator.dart';
import 'monitor_form.dart';
import 'monitor_target.dart';

/// Creates any kind of monitor from one form.
///
/// This replaces three separate screens. What a monitor checks is decided by
/// [resolveMonitorTarget] from the target line and the presence of body rules,
/// so the form has one field where the old three had a host field, a port field
/// and a URL field between them. The decision is shown back to the user as it is
/// typed, because a monitor quietly checking the wrong thing is the one failure
/// mode worth spending a control on.
class AddMonitorScreen extends StatefulWidget {
  const AddMonitorScreen({super.key, required this.coordinator});

  final MonitorCoordinator coordinator;

  @override
  State<AddMonitorScreen> createState() => _AddMonitorScreenState();
}

class _AddMonitorScreenState extends State<AddMonitorScreen> {
  final TextEditingController _target = TextEditingController();
  final TextEditingController _status = TextEditingController();
  final List<_RuleDraft> _rules = [_RuleDraft()];

  MonitorTargetChoice _choice = MonitorTargetChoice.auto;
  int _cadence = kDefaultCadenceMinutes;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _target.addListener(_onTargetChanged);
  }

  @override
  void dispose() {
    _target.removeListener(_onTargetChanged);
    _target.dispose();
    _status.dispose();
    for (final rule in _rules) {
      rule.dispose();
    }
    super.dispose();
  }

  void _onTargetChanged() {
    if (mounted) setState(() {});
  }

  /// The rules the user has actually filled in. Empty rows are ignored rather
  /// than rejected, so an untouched "add rule" row is not an error.
  List<ContentAssertion> get _activeRules => [
    for (final rule in _rules)
      if (rule.valueController.text.trim().isNotEmpty)
        ContentAssertion(
          value: rule.valueController.text.trim(),
          operator: rule.operator,
          caseSensitive: rule.caseSensitive,
        ),
  ];

  TargetResolution get _resolution => resolveMonitorTarget(
    _target.text,
    choice: _choice,
    assertionCount: _activeRules.length,
  );

  void _addRule() => setState(() => _rules.add(_RuleDraft()));

  void _removeRule(int index) {
    if (_rules.length == 1) return;
    setState(() => _rules.removeAt(index).dispose());
  }

  Future<void> _save() async {
    if (_saving) return;

    final resolution = _resolution;
    if (!resolution.isResolved) {
      setState(() => _error = resolution.error);
      return;
    }
    final target = resolution.target!;

    final expectedStatus = _intOrNull(_status.text);
    if (_status.text.trim().isNotEmpty &&
        (expectedStatus == null ||
            expectedStatus < 100 ||
            expectedStatus > 599)) {
      setState(() => _error = 'Expected status must be between 100 and 599.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final cadence = Duration(minutes: _cadence);
    try {
      if (target.isTcp) {
        await widget.coordinator.addTcp(
          target.host,
          target.port!,
          cadence: cadence,
        );
      } else if (target.isPlainWebsite && _activeRules.isEmpty) {
        // Routed through the domain path so a plain website added here and the
        // same domain added from a scan share one id, and one monitor, instead
        // of two.
        await widget.coordinator.addDomain(target.host, cadence: cadence);
      } else {
        await widget.coordinator.addHttp(
          target.uri,
          assertions: _activeRules,
          expectedStatus: expectedStatus,
          cadence: cadence,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _error = friendlyMonitorError(error));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static int? _intOrNull(String raw) {
    final value = raw.trim();
    return value.isEmpty ? null : int.tryParse(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolution = _resolution;
    final target = resolution.target;
    final showWebFields = target?.isTcp != true;

    return Scaffold(
      appBar: AppBar(title: const Text('Add monitor')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'Watch a website, a URL, or a single TCP port.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 6),
          Text(
            'Enter what to watch. vigilant-core works out the kind of check from '
            'it, and shows you what it decided.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 22),
          TextField(
            controller: _target,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: const InputDecoration(
              labelText: 'Domain, URL, or host:port',
              hintText: 'example.com',
              prefixIcon: Icon(Icons.link_rounded),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<MonitorTargetChoice>(
            initialValue: _choice,
            decoration: const InputDecoration(
              labelText: 'Check',
              prefixIcon: Icon(Icons.rule_rounded),
            ),
            items: const [
              DropdownMenuItem(
                value: MonitorTargetChoice.auto,
                child: Text('Work it out'),
              ),
              DropdownMenuItem(
                value: MonitorTargetChoice.website,
                child: Text('Website or URL'),
              ),
              DropdownMenuItem(
                value: MonitorTargetChoice.tcp,
                child: Text('TCP port'),
              ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _choice = value);
            },
          ),
          // The inference is shown, not hidden. One line, and it updates as you
          // type, so a wrong guess is visible before saving rather than after.
          if (target != null) ...[
            const SizedBox(height: 12),
            _ResolutionBanner(target: target),
          ],
          if (showWebFields) ...[
            const SizedBox(height: 20),
            TextField(
              controller: _status,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Expected HTTP status (optional)',
                hintText: 'Any 2xx',
                prefixIcon: Icon(Icons.check_circle_outline_rounded),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text('Body rules', style: theme.textTheme.titleMedium),
                ),
                TextButton.icon(
                  onPressed: _saving ? null : _addRule,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add rule'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Optional. A rule that is present makes this a body check: the '
              'response must satisfy every rule as well as return the expected '
              'status.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (var index = 0; index < _rules.length; index++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _RuleEditor(
                  key: ValueKey(_rules[index]),
                  draft: _rules[index],
                  canRemove: _rules.length > 1,
                  onRemove: () => _removeRule(index),
                ),
              ),
          ],
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            initialValue: _cadence,
            decoration: const InputDecoration(
              labelText: 'Check every',
              prefixIcon: Icon(Icons.schedule_rounded),
            ),
            items: [
              for (final minutes in kCadenceMinutes)
                DropdownMenuItem(
                  value: minutes,
                  child: Text(cadenceLabel(minutes)),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _cadence = value);
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded),
            label: Text(
              _saving
                  ? 'Starting…'
                  : target == null
                  ? 'Start monitor'
                  : 'Start ${_buttonLabel(target)}',
            ),
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.privacy_tip_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'No account or vigilant-core server is involved. The selected '
                      'target receives the check from this device; background '
                      'execution depends on the operating system.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _buttonLabel(ResolvedMonitorTarget target) =>
      switch (target.kind) {
        ResolvedMonitorKind.tcp => 'TCP monitor',
        ResolvedMonitorKind.assertion => 'body check',
        ResolvedMonitorKind.uptime => 'website monitor',
      };
}

class _ResolutionBanner extends StatelessWidget {
  const _ResolutionBanner({required this.target});

  final ResolvedMonitorTarget target;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            target.isTcp ? Icons.lan_outlined : Icons.public_rounded,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(target.summary, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _RuleDraft {
  _RuleDraft()
    : valueController = TextEditingController(),
      operator = ContentAssertionOperator.contains,
      caseSensitive = false;

  final TextEditingController valueController;
  ContentAssertionOperator operator;
  bool caseSensitive;

  void dispose() => valueController.dispose();
}

class _RuleEditor extends StatelessWidget {
  const _RuleEditor({
    super.key,
    required this.draft,
    required this.canRemove,
    required this.onRemove,
  });

  final _RuleDraft draft;
  final bool canRemove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<ContentAssertionOperator>(
                    initialValue: draft.operator,
                    decoration: const InputDecoration(labelText: 'Rule'),
                    items: const [
                      DropdownMenuItem(
                        value: ContentAssertionOperator.contains,
                        child: Text('Must contain'),
                      ),
                      DropdownMenuItem(
                        value: ContentAssertionOperator.notContains,
                        child: Text('Must not contain'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        draft.operator = value;
                      }
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Remove rule',
                  onPressed: canRemove ? onRemove : null,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: draft.valueController,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Text',
                hintText: 'Service healthy',
                prefixIcon: Icon(Icons.text_fields_rounded),
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Case-sensitive'),
              subtitle: const Text('Match capitalization exactly.'),
              value: draft.caseSensitive,
              onChanged: (value) => draft.caseSensitive = value,
            ),
          ],
        ),
      ),
    );
  }
}
