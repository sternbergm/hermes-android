// Helpers for classifying and presenting agent tool-call / tool-result entries
// in the chat transcript.
//
// While a response streams, tool activity arrives as compact
// `hermes.tool.progress` events and is shown as small chips. The canonical
// transcript returned by `GET /api/sessions/{id}/messages`, however, stores each
// tool call/result as its own full message. Rendering those verbatim floods the
// chat with raw tool input/output, so they are detected here and collapsed into
// a chip instead.
import 'dart:convert';

/// Pure classification/formatting helpers for tool messages.
///
/// Kept free of Flutter imports so the logic can be unit-tested directly.
class ToolMessage {
  const ToolMessage._();

  /// Message roles that represent tool activity rather than conversational
  /// text. `tool_progress` is the app's own streaming chip; the rest cover the
  /// shapes a Hermes/OpenAI-style transcript may persist.
  static const roles = {
    'tool_progress',
    'tool',
    'tool_result',
    'tool_use',
    'tool_call',
    'tool_calls',
    'function',
    'function_call',
  };

  /// Whether [m] describes a tool call/result that should be collapsed.
  static bool isToolMessage(Map<String, dynamic> m) {
    final role = (m['role'] as String?)?.toLowerCase() ?? '';
    if (roles.contains(role)) return true;

    final toolCalls = m['tool_calls'];
    if (toolCalls is List && toolCalls.isNotEmpty) return true;

    final toolCallId = m['tool_call_id'] ?? m['toolCallId'];
    if (toolCallId != null && toolCallId.toString().isNotEmpty) return true;

    return false;
  }

  /// Human-friendly tool name for the chip label (falls back to `tool`).
  static String label(Map<String, dynamic> m) {
    for (final key in ['label', 'tool', 'tool_name', 'name']) {
      final v = m[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }

    final toolCalls = m['tool_calls'];
    if (toolCalls is List && toolCalls.isNotEmpty && toolCalls.first is Map) {
      final first = toolCalls.first as Map;
      final fn = first['function'];
      if (fn is Map && fn['name'] is String) return fn['name'] as String;
      final name = first['name'];
      if (name is String && name.isNotEmpty) return name;
    }

    return 'tool';
  }

  /// Emoji shown beside the label (falls back to a wrench).
  static String emoji(Map<String, dynamic> m) {
    final v = m['emoji'];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return '🔧';
  }

  /// Whether the tool has finished running. Persisted transcript entries carry
  /// no status and are treated as complete.
  static bool isDone(Map<String, dynamic> m) {
    final status = (m['status'] as String?)?.toLowerCase();
    if (status == null) return true;
    return status == 'completed' || status == 'finished' || status == 'done';
  }

  /// Status suffix for the chip, e.g. `— done` or `— running`.
  static String statusText(Map<String, dynamic> m) {
    if (isDone(m)) return 'done';
    return (m['status'] as String?) ?? 'running';
  }

  /// The full, expandable detail text for a tool message (inputs + output).
  static String detail(Map<String, dynamic> m) {
    final parts = <String>[];

    final input = m['input'] ?? m['arguments'] ?? m['args'] ?? m['parameters'];
    final inputText = _stringify(input).trim();
    if (inputText.isNotEmpty) parts.add('Input:\n$inputText');

    final contentText = _stringify(m['content']).trim();
    if (contentText.isNotEmpty) parts.add(contentText);

    final outputText = _stringify(m['output'] ?? m['result']).trim();
    if (outputText.isNotEmpty && outputText != contentText) {
      parts.add('Output:\n$outputText');
    }

    return parts.join('\n\n');
  }

  static String _stringify(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }
}
