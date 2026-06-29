import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/chat_stream_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

/// The shape of [ChatBackend.stream]'s callback driving, so a test can script a
/// stream by invoking the callbacks directly. Positional params keep the test
/// closures terse (named params would be optional-with-null-default, which is
/// illegal for these non-nullable function types).
typedef StreamRunner =
    Future<void> Function(
      void Function(String token) onToken,
      ToolProgressCallback onToolProgress,
      Future<void> Function() onDone,
      void Function(String error) onError,
    );

/// A [ChatBackend] with no network: the test supplies the streaming script and
/// the canonical transcript returned by [getMessages].
class FakeChatBackend implements ChatBackend {
  FakeChatBackend({required this.runner, this.transcript = const []});

  final StreamRunner runner;
  List<Map<String, dynamic>> transcript;
  bool closed = false;
  int getMessagesCalls = 0;

  @override
  Future<void> stream({
    required String message,
    required String sessionId,
    required List<Map<String, dynamic>> history,
    required void Function(String token) onToken,
    required ToolProgressCallback onToolProgress,
    required Future<void> Function() onDone,
    required void Function(String error) onError,
  }) {
    return runner(onToken, onToolProgress, onDone, onError);
  }

  @override
  Future<List<Map<String, dynamic>>> getMessages(String sessionId) async {
    getMessagesCalls++;
    return transcript;
  }

  @override
  void close() => closed = true;
}

SavedConnection _conn() => SavedConnection(
  id: 'c1',
  label: 'test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  useHttps: false,
);

/// Flush pending microtasks/timers so streamed callbacks settle.
Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  const sessionId = 'mob-test-1';

  test('reply runs to completion even with no screen observing it', () async {
    final backend = FakeChatBackend(
      transcript: [
        {'role': 'user', 'content': 'hi'},
        {'role': 'assistant', 'content': 'Hello world'},
      ],
      runner: (onToken, onToolProgress, onDone, onError) async {
        onToken('Hel');
        onToken('lo');
        await onDone();
      },
    );
    final manager = ChatStreamManager(backendFactory: (_) => backend);

    // Capture the stream the way the screen would, but attach NO listener —
    // i.e. the user has left the chat. The work must still finish.
    final stream = manager.streamFor(sessionId);

    await manager.send(
      connection: _conn(),
      sessionId: sessionId,
      text: 'hi',
      history: const [],
    );

    expect(stream.streaming, isFalse);
    expect(stream.completedResponses, 1);
    // Reconciled to the authoritative server transcript on done.
    expect(stream.messages.last['content'], 'Hello world');
    expect(backend.getMessagesCalls, 1);
    expect(backend.closed, isTrue);
    // An unobserved, finished stream is reclaimed.
    expect(manager.isStreaming(sessionId), isFalse);
  });

  test('accumulates tokens and a tool-progress chip while streaming', () async {
    final gate = Completer<void>();
    final backend = FakeChatBackend(
      transcript: [
        {'role': 'user', 'content': 'go'},
        {'role': 'assistant', 'content': 'final answer'},
      ],
      runner: (onToken, onToolProgress, onDone, onError) async {
        onToken('Hel');
        onToken('lo');
        onToolProgress({
          'toolCallId': 'call_1',
          'tool': 'execute_code',
          'status': 'running',
        });
        await gate.future;
        await onDone();
      },
    );
    final manager = ChatStreamManager(backendFactory: (_) => backend);

    final stream = manager.streamFor(sessionId);
    stream.addListener(() {}); // an attached screen keeps it observed

    final pending = manager.send(
      connection: _conn(),
      sessionId: sessionId,
      text: 'go',
      history: const [],
    );
    await _tick();

    // Mid-stream: live token text plus the collapsed tool chip, before the
    // assistant bubble.
    expect(stream.streaming, isTrue);
    final assistant = stream.messages.lastWhere(
      (m) => m['role'] == 'assistant',
    );
    expect(assistant['content'], 'Hello');
    expect(
      stream.messages.any((m) => m['role'] == 'tool_progress'),
      isTrue,
    );

    gate.complete();
    await pending;

    // On done it reconciles to the server transcript and clears streaming.
    expect(stream.streaming, isFalse);
    expect(stream.completedResponses, 1);
    expect(stream.messages, [
      {'role': 'user', 'content': 'go'},
      {'role': 'assistant', 'content': 'final answer'},
    ]);
  });

  test('a second tool-progress event updates the same chip in place', () async {
    final gate = Completer<void>();
    final backend = FakeChatBackend(
      runner: (onToken, onToolProgress, onDone, onError) async {
        onToolProgress({
          'toolCallId': 'call_1',
          'tool': 'execute_code',
          'status': 'running',
        });
        onToolProgress({
          'toolCallId': 'call_1',
          'tool': 'execute_code',
          'status': 'completed',
        });
        await gate.future;
        await onDone();
      },
    );
    final manager = ChatStreamManager(backendFactory: (_) => backend);
    final stream = manager.streamFor(sessionId);
    stream.addListener(() {});

    final pending = manager.send(
      connection: _conn(),
      sessionId: sessionId,
      text: 'go',
      history: const [],
    );
    await _tick();

    final chips =
        stream.messages.where((m) => m['role'] == 'tool_progress').toList();
    expect(chips, hasLength(1));
    expect(chips.single['status'], 'completed');

    gate.complete();
    await pending;
  });

  test('an error rolls back the optimistic user/assistant placeholders',
      () async {
    final backend = FakeChatBackend(
      runner: (onToken, onToolProgress, onDone, onError) async {
        onError('network down');
      },
    );
    final manager = ChatStreamManager(backendFactory: (_) => backend);
    final stream = manager.streamFor(sessionId);
    stream.addListener(() {}); // observed, so it isn't reclaimed on error

    await manager.send(
      connection: _conn(),
      sessionId: sessionId,
      text: 'hi',
      history: const [],
    );

    expect(stream.streaming, isFalse);
    expect(stream.error, 'network down');
    // Nothing half-written left behind.
    expect(stream.messages, isEmpty);
    expect(stream.completedResponses, 0);
  });

  test('setMessages is ignored while a reply is streaming', () async {
    final gate = Completer<void>();
    final backend = FakeChatBackend(
      transcript: const [],
      runner: (onToken, onToolProgress, onDone, onError) async {
        onToken('partial');
        await gate.future;
        await onDone();
      },
    );
    final manager = ChatStreamManager(backendFactory: (_) => backend);
    final stream = manager.streamFor(sessionId);
    stream.addListener(() {});

    final pending = manager.send(
      connection: _conn(),
      sessionId: sessionId,
      text: 'go',
      history: const [],
    );
    await _tick();

    // A background refresh must not clobber the live stream.
    manager.setMessages(sessionId, [
      {'role': 'assistant', 'content': 'STALE'},
    ]);
    expect(
      stream.messages.any((m) => m['content'] == 'STALE'),
      isFalse,
    );
    expect(stream.messages.last['content'], 'partial');

    gate.complete();
    await pending;
  });

  test('isStreaming reflects the session lifecycle', () async {
    final gate = Completer<void>();
    final backend = FakeChatBackend(
      runner: (onToken, onToolProgress, onDone, onError) async {
        await gate.future;
        await onDone();
      },
    );
    final manager = ChatStreamManager(backendFactory: (_) => backend);
    manager.streamFor(sessionId).addListener(() {});

    expect(manager.isStreaming(sessionId), isFalse);
    final pending = manager.send(
      connection: _conn(),
      sessionId: sessionId,
      text: 'go',
      history: const [],
    );
    await _tick();
    expect(manager.isStreaming(sessionId), isTrue);

    gate.complete();
    await pending;
    expect(manager.isStreaming(sessionId), isFalse);
  });

  test('fetchMessages returns the transcript and closes its backend', () async {
    final backend = FakeChatBackend(
      transcript: [
        {'role': 'user', 'content': 'hi'},
      ],
      runner: (onToken, onToolProgress, onDone, onError) async {},
    );
    final manager = ChatStreamManager(backendFactory: (_) => backend);

    final messages = await manager.fetchMessages(_conn(), sessionId);

    expect(messages, [
      {'role': 'user', 'content': 'hi'},
    ]);
    expect(backend.closed, isTrue);
  });

  test('releaseIfIdle keeps a stream that a screen is still observing', () {
    final manager = ChatStreamManager(backendFactory: (_) => FakeChatBackend(
          runner: (onToken, onToolProgress, onDone, onError) async {},
        ));
    final stream = manager.streamFor(sessionId);
    stream.addListener(() {});

    manager.releaseIfIdle(sessionId);
    // Same instance is returned — it was not reclaimed.
    expect(identical(manager.streamFor(sessionId), stream), isTrue);
  });
}
