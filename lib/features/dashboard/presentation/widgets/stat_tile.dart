import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/status_pill.dart';

/// A single counter in the queue summary row.
class StatTile extends StatelessWidget {
  const StatTile({
    required this.label,
    required this.value,
    required this.tone,
    super.key,
    this.icon,
    this.onTap,
  });

  final String label;
  final int value;
  final StatusTone tone;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final color = switch (tone) {
      StatusTone.success => colors.success,
      StatusTone.warning => colors.warning,
      StatusTone.danger => colors.danger,
      StatusTone.info => colors.info,
      StatusTone.neutral => colors.neutral,
    };
    // A zero count is deliberately muted: on a healthy agent most of these are
    // zero, and colouring them all would make the row meaningless.
    final emphasised = value > 0;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppSpacing.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 14,
          ),
          decoration: BoxDecoration(
            color: emphasised
                ? color.withValues(alpha: 0.08)
                : colors.subtleBackground,
            borderRadius: BorderRadius.circular(AppSpacing.radius),
            border: Border.all(
              color: emphasised
                  ? color.withValues(alpha: 0.24)
                  : colors.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(
                      icon,
                      size: 14,
                      color: emphasised ? color : colors.neutral,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '$value',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: emphasised ? color : theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
