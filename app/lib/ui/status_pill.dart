import 'package:flutter/material.dart';

import '../theme/vigilant-core_theme.dart';

/// A state that can be communicated without depending on colour alone.
enum StatusTone { healthy, attention, critical, paused, unknown, stale }

extension StatusTonePresentation on StatusTone {
  String get label => switch (this) {
    StatusTone.healthy => 'Healthy',
    StatusTone.attention => 'Needs attention',
    StatusTone.critical => 'Critical',
    StatusTone.paused => 'Paused',
    StatusTone.unknown => 'Unknown',
    StatusTone.stale => 'Stale',
  };

  IconData get icon => switch (this) {
    StatusTone.healthy => Icons.check_circle_outline_rounded,
    StatusTone.attention => Icons.warning_amber_rounded,
    StatusTone.critical => Icons.error_outline_rounded,
    StatusTone.paused => Icons.pause_circle_outline_rounded,
    StatusTone.unknown => Icons.help_outline_rounded,
    StatusTone.stale => Icons.history_toggle_off_rounded,
  };

  Color color(BuildContext context) => switch (this) {
    StatusTone.healthy => vigilant-corePalette.healthy,
    StatusTone.attention => vigilant-corePalette.warning,
    StatusTone.critical => vigilant-corePalette.critical,
    StatusTone.paused => Theme.of(context).colorScheme.onSurfaceVariant,
    StatusTone.unknown => Theme.of(context).colorScheme.outline,
    StatusTone.stale => vigilant-corePalette.warning,
  };
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.tone,
    this.label,
    this.compact = false,
  });

  final StatusTone tone;
  final String? label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = tone.color(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 5 : 7,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(tone.icon, size: compact ? 14 : 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label ?? tone.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: color, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
