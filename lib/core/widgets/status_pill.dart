import 'package:flutter/material.dart';

import '../../features/agent/domain/agent.dart';
import '../../features/print_queue/domain/print_job.dart';
import '../../features/printers/domain/printer_status.dart';
import '../theme/app_theme.dart';

enum StatusTone { success, warning, danger, info, neutral }

/// A coloured status chip. One component for every status in the product, so
/// "green means the same thing everywhere" is enforced by construction rather
/// than by discipline.
class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.label,
    required this.tone,
    super.key,
    this.icon,
    this.compact = false,
    this.showDot = true,
  });

  final String label;
  final StatusTone tone;
  final IconData? icon;
  final bool compact;
  final bool showDot;

  factory StatusPill.connection(AgentConnectionState state, {Key? key}) =>
      StatusPill(
        key: key,
        label: state.label,
        tone: switch (state) {
          AgentConnectionState.connected => StatusTone.success,
          AgentConnectionState.connecting => StatusTone.info,
          AgentConnectionState.offline => StatusTone.warning,
          AgentConnectionState.paused => StatusTone.warning,
          AgentConnectionState.unauthorised => StatusTone.danger,
          AgentConnectionState.disconnected => StatusTone.neutral,
        },
      );

  factory StatusPill.printer(PrinterState state, {Key? key, bool compact = false}) =>
      StatusPill(
        key: key,
        label: state.label,
        compact: compact,
        tone: switch (state) {
          PrinterState.ready => StatusTone.success,
          PrinterState.busy => StatusTone.info,
          PrinterState.tonerLow => StatusTone.warning,
          PrinterState.paused => StatusTone.warning,
          PrinterState.unknown => StatusTone.neutral,
          PrinterState.offline ||
          PrinterState.outOfPaper ||
          PrinterState.paperJam ||
          PrinterState.doorOpen ||
          PrinterState.error =>
            StatusTone.danger,
        },
      );

  factory StatusPill.job(PrintJobStatus status, {Key? key, bool compact = true}) =>
      StatusPill(
        key: key,
        label: status.label,
        compact: compact,
        tone: switch (status) {
          PrintJobStatus.completed => StatusTone.success,
          PrintJobStatus.printing || PrintJobStatus.downloading => StatusTone.info,
          PrintJobStatus.queued || PrintJobStatus.claimed => StatusTone.neutral,
          PrintJobStatus.failed => StatusTone.danger,
          PrintJobStatus.interrupted => StatusTone.warning,
          PrintJobStatus.cancelled => StatusTone.neutral,
        },
      );

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final color = switch (tone) {
      StatusTone.success => colors.success,
      StatusTone.warning => colors.warning,
      StatusTone.danger => colors.danger,
      StatusTone.info => colors.info,
      StatusTone.neutral => colors.neutral,
    };

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: compact ? 12 : 14, color: color),
            const SizedBox(width: 6),
          ] else if (showDot) ...<Widget>[
            Container(
              width: compact ? 6 : 8,
              height: compact ? 6 : 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: compact ? 11 : 12.5,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}
