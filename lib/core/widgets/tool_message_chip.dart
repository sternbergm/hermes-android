// Collapsed, tappable representation of a tool call/result in the chat.
//
// Matches the compact progress chips shown while the agent is responding, so a
// finished response keeps its clean look instead of flooding the chat with raw
// tool output. The full tool detail is hidden by default and revealed on tap.
import 'package:flutter/material.dart';

import '../utils/tool_message.dart';

class ToolMessageChip extends StatefulWidget {
  final Map<String, dynamic> message;
  final bool verbose;

  const ToolMessageChip({
    required this.message,
    this.verbose = false,
    super.key,
  });

  @override
  State<ToolMessageChip> createState() => _ToolMessageChipState();
}

class _ToolMessageChipState extends State<ToolMessageChip> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final chipColor = isDark
        ? const Color(0xFF2A2A2A)
        : const Color(0xFFEAEAEA);
    final textColor = isDark ? Colors.grey[300] : Colors.grey[800];

    final label = ToolMessage.label(widget.message);
    final emoji = ToolMessage.emoji(widget.message);
    final headline = '$label — ${ToolMessage.statusText(widget.message)}';

    final detail = ToolMessage.detail(widget.message);
    final hasDetail = detail.isNotEmpty || widget.verbose;

    final chip = Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: chipColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: hasDetail
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(emoji, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    headline,
                    style: TextStyle(fontSize: 13, color: textColor),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hasDetail) ...[
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: textColor,
                  ),
                ],
              ],
            ),
          ),
          if (_expanded && hasDetail) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 280),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: (isDark ? Colors.black : Colors.white).withValues(
                  alpha: 0.3,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  detail.isEmpty ? '(no details)' : detail,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: textColor,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Flexible(child: chip)],
    );
  }
}
