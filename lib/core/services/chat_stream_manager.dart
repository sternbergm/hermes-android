// Background-safe chat streaming.
//
// The agent's reply is streamed over an SSE request that used to live *inside*
// the chat screen. That meant leaving the screen disposed the screen, which
// closed the HTTP client and cut the stream — the agent's answer was lost.
//
// [ChatStreamManager] is an app-lifetime singleton that owns the in-flight
// stream (and the underlying HTTP client) per session, independent of any
// widget. The chat screen becomes a thin view that *attaches* to the manager:
//   * navigating away no longer aborts the stream (the manager keeps running);
//   * coming back re-attaches and shows the live — or finished — reply;
//   * the agent itself runs server-side, so even if the OS kills the app the
//     turn keeps going on the server and is reconciled by re-fetching the
//     canonical transcript on return (see `ChatScreen`'s resume/poll logic).
// Imports widgets.dart (not foundation.dart) so both ChangeNotifier and Future
// resolve from a single Flutter import, keeping the file free of a redundant
// dart:async import.
import 'package:flutter/widgets.dart';

import 'connection_manager.dart';

/// Network abstraction the manager streams through. The real implementation
/// wraps [ApiClient] / [GatewayChatClient]; tests inject a fake so the
/// manager's logic can be exercised without a server.
abstract class ChatBackend {
  /// Stream an assistant reply. Resolves when the stream ends (after [onDone]
  /// or [onError] has fired). [onRunStarted] hands back the gateway run id, and
  /// [onApproval] fires when the agent pauses for a tool approval.
  Future<void> stream({
    required String message,
    required String sessionId,
    required List<Map<String, dynamic>> history,
    required void Function(String runId) onRunStarted,
    required void Function(String token) onToken,
    required ToolProgressCallback onToolProgress,
    required void Function(Map<String, dynamic> approval) onApproval,
    // Future-returning so the reconciliation in [onDone] is awaitable (the live
    // gateway client calls it fire-and-forget, which is fine; tests await it).
    required Future<void> Function() onDone,
    required void Function(String error) onError,
  });

  /// Fetch the canonical, server-side transcript for [sessionId].
  Future<List<Map<String, dynamic>>> getMessages(String sessionId);

  /// Answer a pending tool approval for [runId] (`once`/`session`/`always`/
  /// `deny`); the run then resumes server-side.
  Future<void> approve(String runId, String choice);

  /// Release the underlying HTTP client.
  void close();
}

/// Default [ChatBackend] backed by the live gateway. Each instance owns its own
/// [ApiClient] so a stream's lifetime is tied to the manager, not to a screen.
class RealChatBackend implements ChatBackend {
  RealChatBackend(SavedConnection connection)
    : _api = ApiClient(
        baseUrl: connection.baseUrl,
        apiKey: connection.apiKey,
      ) {
    _gateway = GatewayChatClient(_api);
  }

  final ApiClient _api;
  late final GatewayChatClient _gateway;

  @override
  Future<void> stream({
    required String message,
    required String sessionId,
    required List<Map<String, dynamic>> history,
    required void Function(String runId) onRunStarted,
    required void Function(String token) onToken,
    required ToolProgressCallback onToolProgress,
    required void Function(Map<String, dynamic> approval) onApproval,
    required Future<void> Function() onDone,
    required void Function(String error) onError,
  }) {
    return _gateway.streamRun(
      message: message,
      sessionId: sessionId,
      history: history,
      onRunStarted: onRunStarted,
      onToken: onToken,
      onToolProgress: onToolProgress,
      onApproval: onApproval,
      onDone: onDone,
      onError: onError,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getMessages(String sessionId) =>
      _api.getMessages(sessionId);

  @override
  Future<void> approve(String runId, String choice) =>
      _gateway.respondToApproval(runId: runId, choice: choice);

  @override
  void close() => _api.close();
}

/// One conversation's live state, owned by [ChatStreamManager] and outliving
/// the chat screen. A [ChangeNotifier] so the screen can rebuild as tokens and
/// tool-progress chips arrive.
class ActiveChatStream extends ChangeNotifier {
  ActiveChatStream(this.sessionId);

  final String sessionId;

  /// The working transcript: the cached canonical messages plus, while a reply
  /// is streaming, the optimistic user message and the growing assistant
  /// placeholder.
  List<Map<String, dynamic>> messages = [];

  /// True while a reply is actively streaming for this session.
  bool streaming = false;

  /// The last streaming error, surfaced to the screen as a snackbar.
  String? error;

  /// The active gateway run id for this turn (needed to answer an approval).
  String? runId;

  /// A pending tool-approval request (the gateway's `approval.request` event:
  /// `{command, description, choices, ...}`), or null. While set, the agent is
  /// paused waiting for the user's choice. Survives leaving the chat, like the
  /// stream itself.
  Map<String, dynamic>? pendingApproval;

  /// Bumped each time a streamed reply finishes. Lets a (re-)attached screen
  /// distinguish "a response just completed" (scroll to bottom, speak it) from
  /// ordinary token updates.
  int completedResponses = 0;

  /// Whether a view (the chat screen) is currently observing this stream.
  /// Exposes the protected [ChangeNotifier.hasListeners] for the manager's
  /// idle-cleanup check.
  bool get hasObservers => hasListeners;

  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// App-lifetime owner of every session's [ActiveChatStream]. Use
/// [ChatStreamManager.instance] in the app; construct directly in tests.
class ChatStreamManager {
  ChatStreamManager({ChatBackend Function(SavedConnection)? backendFactory})
    : backendFactory = backendFactory ?? ((c) => RealChatBackend(c));

  /// The shared instance used by the running app.
  static final ChatStreamManager instance = ChatStreamManager();

  /// Builds the backend for a stream. Overridable for tests.
  final ChatBackend Function(SavedConnection) backendFactory;

  final Map<String, ActiveChatStream> _streams = {};

  /// The in-flight backend per session, kept so [approve] can reach the same
  /// connection that started the run.
  final Map<String, ChatBackend> _activeBackends = {};

  /// The stream state for [sessionId], creating an empty one on first use.
  ActiveChatStream streamFor(String sessionId) =>
      _streams.putIfAbsent(sessionId, () => ActiveChatStream(sessionId));

  bool isStreaming(String sessionId) =>
      _streams[sessionId]?.streaming ?? false;

  /// Replace a session's cached transcript (initial load / manual refresh).
  /// Ignored while streaming so a background refresh can't clobber live tokens.
  void setMessages(String sessionId, List<Map<String, dynamic>> messages) {
    final s = streamFor(sessionId);
    if (s.streaming) return;
    s.messages = messages;
    s._notify();
  }

  /// Fetch the canonical transcript without mutating any cached state. The
  /// caller decides what to do with the result (e.g. [setMessages]).
  Future<List<Map<String, dynamic>>> fetchMessages(
    SavedConnection connection,
    String sessionId,
  ) async {
    final backend = backendFactory(connection);
    try {
      return await backend.getMessages(sessionId);
    } finally {
      backend.close();
    }
  }

  /// Start streaming a reply for [sessionId]. Returns immediately useful state
  /// via the session's [ActiveChatStream]; the returned future completes when
  /// the stream ends, but callers (the screen) deliberately do **not** await it
  /// so the work continues after the screen is gone.
  Future<void> send({
    required SavedConnection connection,
    required String sessionId,
    required String text,
    required List<Map<String, dynamic>> history,
  }) async {
    final s = streamFor(sessionId);
    if (s.streaming) return;

    s.error = null;
    s.streaming = true;
    s.runId = null;
    s.pendingApproval = null;
    // Optimistically show the user's message and an empty assistant bubble to
    // stream into.
    s.messages = [
      ...s.messages,
      {'role': 'user', 'content': text},
      {'role': 'assistant', 'content': ''},
    ];
    s._notify();

    final backend = backendFactory(connection);
    _activeBackends[sessionId] = backend;

    await backend.stream(
      message: text,
      sessionId: sessionId,
      history: history,
      onRunStarted: (runId) => s.runId = runId,
      onApproval: (approval) {
        s.pendingApproval = approval;
        s._notify();
      },
      onToken: (token) {
        if (s.messages.isNotEmpty && s.messages.last['role'] == 'assistant') {
          s.messages.last['content'] =
              (s.messages.last['content'] as String) + token;
          s._notify();
        }
      },
      onToolProgress: (progress) => _upsertToolProgress(s, progress),
      onDone: () async {
        // Reconcile against the authoritative server-side transcript.
        try {
          s.messages = await backend.getMessages(sessionId);
        } catch (_) {
          // Keep the optimistic/streamed messages if the refresh fails.
        }
        s.streaming = false;
        s.completedResponses++;
        s.runId = null;
        s.pendingApproval = null;
        s._notify();
        _activeBackends.remove(sessionId);
        backend.close();
        // If no screen is watching (finished in the background), reclaim it.
        releaseIfIdle(sessionId);
      },
      onError: (err) {
        // Roll back the optimistic placeholders so a failed send leaves no
        // half-written turn behind.
        if (s.messages.isNotEmpty &&
            s.messages.last['role'] == 'assistant' &&
            (s.messages.last['content'] as String).isEmpty) {
          s.messages.removeLast();
        }
        if (s.messages.isNotEmpty &&
            s.messages.last['role'] == 'user' &&
            s.messages.last['content'] == text) {
          s.messages.removeLast();
        }
        s.streaming = false;
        s.error = err;
        s.runId = null;
        s.pendingApproval = null;
        s._notify();
        _activeBackends.remove(sessionId);
        backend.close();
        releaseIfIdle(sessionId);
      },
    );
  }

  /// Answer the pending tool approval for [sessionId]. [choice] is one of
  /// `once`, `session`, `always`, `deny`. Clears the prompt immediately; the
  /// run resumes server-side and tokens keep streaming into the same session.
  Future<void> approve(String sessionId, String choice) async {
    final s = _streams[sessionId];
    final backend = _activeBackends[sessionId];
    final runId = s?.runId;
    if (s == null || backend == null || runId == null) return;
    // Optimistically clear the prompt so the UI returns to the streaming view.
    s.pendingApproval = null;
    s._notify();
    try {
      await backend.approve(runId, choice);
    } catch (e) {
      s.error = 'Approval failed: $e';
      s._notify();
    }
  }

  /// Drop a session's state if it is idle (not streaming) and unobserved, so
  /// finished conversations don't accumulate in memory. Active streams are
  /// always kept so they keep running and can be re-attached on return.
  void releaseIfIdle(String sessionId) {
    final s = _streams[sessionId];
    if (s == null) return;
    if (s.streaming || s.hasObservers) return;
    _streams.remove(sessionId);
    s.dispose();
  }

  /// Mirror of the chat screen's old `_upsertToolProgress`: insert or update the
  /// compact tool-progress chip just before the streaming assistant bubble.
  void _upsertToolProgress(ActiveChatStream s, Map<String, dynamic> progress) {
    final toolCallId =
        progress['toolCallId']?.toString() ??
        progress['tool_call_id']?.toString() ??
        progress['id']?.toString() ??
        '';
    final tool = progress['tool']?.toString() ?? 'tool';
    final status = progress['status']?.toString() ?? 'running';
    final emoji = progress['emoji']?.toString() ?? '🔧';
    final label = progress['label']?.toString();
    final display = label == null || label.isEmpty ? tool : label;
    final done = status == 'completed' || status == 'finished';
    final content = done
        ? '$emoji $display — done'
        : '$emoji $display — $status';

    final idx = toolCallId.isEmpty
        ? -1
        : s.messages.indexWhere(
            (m) =>
                m['role'] == 'tool_progress' && m['toolCallId'] == toolCallId,
          );
    final payload = {
      'role': 'tool_progress',
      'content': content,
      'toolCallId': toolCallId,
      'status': status,
      'tool': tool,
    };
    if (idx >= 0) {
      s.messages[idx] = payload;
    } else {
      final insertAt =
          s.messages.isNotEmpty && s.messages.last['role'] == 'assistant'
          ? s.messages.length - 1
          : s.messages.length;
      s.messages.insert(insertAt, payload);
    }
    s._notify();
  }
}
