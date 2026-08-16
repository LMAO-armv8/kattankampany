import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The standard content container: a titled card with optional header actions.
class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.child,
    super.key,
    this.title,
    this.subtitle,
    this.actions,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.leading,
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final List<Widget>? actions;
  final EdgeInsets padding;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasHeader = title != null || actions != null;

    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (hasHeader) ...<Widget>[
              Row(
                children: <Widget>[
                  if (leading != null) ...<Widget>[
                    leading!,
                    const SizedBox(width: AppSpacing.sm),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (title != null)
                          Text(
                            title!,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (subtitle != null) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (actions != null)
                    Row(mainAxisSize: MainAxisSize.min, children: actions!),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// A label/value row used throughout Diagnostics and detail panels.
class DetailRow extends StatelessWidget {
  const DetailRow({
    required this.label,
    required this.value,
    super.key,
    this.valueWidget,
    this.labelWidth = 180,
    this.selectable = true,
  });

  final String label;
  final String value;
  final Widget? valueWidget;
  final double labelWidth;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: valueWidget ??
                (selectable
                    ? SelectableText(
                        value,
                        style: theme.textTheme.bodyMedium,
                      )
                    : Text(value, style: theme.textTheme.bodyMedium)),
          ),
        ],
      ),
    );
  }
}

/// Shown wherever a list can legitimately be empty.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    super.key,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 36, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: AppSpacing.md),
          Text(
            title,
            style: theme.textTheme.titleSmall,
            textAlign: TextAlign.center,
          ),
          if (message != null) ...<Widget>[
            const SizedBox(height: 6),
            SizedBox(
              width: 420,
              child: Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          if (action != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            action!,
          ],
        ],
      ),
    );
  }
}
