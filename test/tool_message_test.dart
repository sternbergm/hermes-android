import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/tool_message.dart';

void main() {
  group('ToolMessage.isToolMessage', () {
    test('detects the app\'s own streaming progress chips', () {
      expect(
        ToolMessage.isToolMessage({
          'role': 'tool_progress',
          'tool': 'execute_code',
          'status': 'running',
        }),
        isTrue,
      );
    });

    test('detects persisted transcript tool roles', () {
      for (final role in ['tool', 'tool_result', 'tool_use', 'function']) {
        expect(
          ToolMessage.isToolMessage({'role': role, 'content': 'output'}),
          isTrue,
          reason: 'role "$role" should be treated as a tool message',
        );
      }
    });

    test('detects assistant messages carrying tool_calls', () {
      expect(
        ToolMessage.isToolMessage({
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'function': {'name': 'read_file'},
            },
          ],
        }),
        isTrue,
      );
    });

    test('detects messages carrying a tool_call_id', () {
      expect(
        ToolMessage.isToolMessage({
          'role': 'assistant',
          'tool_call_id': 'call_42',
        }),
        isTrue,
      );
      expect(
        ToolMessage.isToolMessage({'role': 'assistant', 'toolCallId': 'call_7'}),
        isTrue,
      );
    });

    test('leaves normal user and assistant text alone', () {
      expect(
        ToolMessage.isToolMessage({'role': 'user', 'content': 'hi'}),
        isFalse,
      );
      expect(
        ToolMessage.isToolMessage({
          'role': 'assistant',
          'content': 'Here is your answer.',
        }),
        isFalse,
      );
    });

    test('ignores empty tool_calls lists', () {
      expect(
        ToolMessage.isToolMessage({'role': 'assistant', 'tool_calls': []}),
        isFalse,
      );
    });
  });

  group('ToolMessage.label', () {
    test('prefers an explicit label, then tool name', () {
      expect(ToolMessage.label({'label': 'Reading file', 'tool': 'read_file'}),
          'Reading file');
      expect(ToolMessage.label({'tool': 'execute_code'}), 'execute_code');
    });

    test('reads the function name from an OpenAI-style tool_calls entry', () {
      expect(
        ToolMessage.label({
          'role': 'assistant',
          'tool_calls': [
            {
              'function': {'name': 'browser_navigate'},
            },
          ],
        }),
        'browser_navigate',
      );
    });

    test('falls back to a generic label', () {
      expect(ToolMessage.label({'role': 'tool', 'content': 'x'}), 'tool');
    });
  });

  group('ToolMessage.isDone / statusText', () {
    test('running progress chips are not done', () {
      final m = {'role': 'tool_progress', 'status': 'running'};
      expect(ToolMessage.isDone(m), isFalse);
      expect(ToolMessage.statusText(m), 'running');
    });

    test('completed / finished / done count as done', () {
      for (final status in ['completed', 'finished', 'done']) {
        expect(ToolMessage.isDone({'status': status}), isTrue);
      }
    });

    test('persisted entries without a status are treated as complete', () {
      final m = {'role': 'tool', 'content': 'output'};
      expect(ToolMessage.isDone(m), isTrue);
      expect(ToolMessage.statusText(m), 'done');
    });
  });

  group('ToolMessage.detail', () {
    test('returns the content string for a simple tool result', () {
      expect(
        ToolMessage.detail({'role': 'tool', 'content': 'file contents here'}),
        'file contents here',
      );
    });

    test('pretty-prints structured input and labels it', () {
      final detail = ToolMessage.detail({
        'role': 'tool',
        'input': {'path': '/etc/hosts'},
        'content': 'ok',
      });
      expect(detail, contains('Input:'));
      expect(detail, contains('"path": "/etc/hosts"'));
      expect(detail, contains('ok'));
    });

    test('does not duplicate identical content and output', () {
      final detail = ToolMessage.detail({
        'role': 'tool',
        'content': 'same',
        'output': 'same',
      });
      expect('same'.allMatches(detail).length, 1);
    });

    test('is empty when there is nothing to show', () {
      expect(ToolMessage.detail({'role': 'tool_progress', 'status': 'done'}),
          isEmpty);
    });
  });
}
