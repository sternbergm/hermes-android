// Chat screen with real-time streaming via REST API.
// Uses REST endpoints: POST /api/sessions/{id}/chat and
// GET /api/sessions/{id}/messages.
//
// The streaming itself lives in [ChatStreamManager], not in this widget, so the
// agent's reply keeps flowing when you leave the chat or background the app.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/chat_stream_manager.dart';
import '../services/connection_manager.dart';
import '../utils/responsive.dart';
import '../utils/tool_message.dart';
import '../widgets/tool_message_chip.dart';

class ChatScreen extends StatefulWidget {
  final SavedConnection connection;
  final Session session;

  const ChatScreen({
    required this.connection,
    required this.session,
    super.key,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  bool _loading = true;
  String? _error;

  // The session's streaming state lives in an app-lifetime manager, not in this
  // widget, so navigating away (or backgrounding the app) no longer cuts the
  // agent's reply. This screen is just a view that attaches to it.
  late final ChatStreamManager _manager;
  late final ActiveChatStream _stream;
  int _seenCompleted = 0;

  // Reconciliation for replies that finish while we're gone — including after
  // the OS kills the app and the turn keeps running server-side.
  Timer? _pollTimer;
  int _pollAttempts = 0;
  bool _pollingForReply = false;

  bool get _streaming => _stream.streaming;

  // Chat sending state
  final _textController = TextEditingController();

  // Voice input / spoken replies
  final SpeechToText _speechToText = SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();
  bool _speechAvailable = false;
  bool _listening = false;
  bool _voiceReplyEnabled = true;
  bool _awaitingVoiceReply = false;
  String? _voiceStatus;

  // Verbose mode
  bool _verboseMode = false;

  // Scroll management
  final _scrollController = ScrollController();
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _manager = ChatStreamManager.instance;
    _stream = _manager.streamFor(widget.session.id);
    _seenCompleted = _stream.completedResponses;
    _stream.addListener(_onStreamChanged);
    WidgetsBinding.instance.addObserver(this);
    _loadVerboseMode();
    _initVoice();
    _scrollController.addListener(_onScroll);

    if (_stream.streaming) {
      // Re-attaching to a reply that's still streaming in the background — show
      // the live state, don't refetch over it.
      _loading = false;
      _scrollToBottomDeferred();
    } else {
      // Show any cached transcript instantly, then reconcile with the server.
      _fetchMessages(showSpinner: _stream.messages.isEmpty);
    }
  }

  /// Rebuild as the manager pushes tokens, tool-progress chips, completion, and
  /// errors for this session.
  void _onStreamChanged() {
    if (!mounted) return;
    setState(() {});

    // Follow the tail while tokens stream in, unless the user scrolled up.
    if (_stream.streaming && !_showScrollToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToBottom();
      });
    }

    // A reply just finished (in the foreground, or while we were away).
    if (_stream.completedResponses != _seenCompleted) {
      _seenCompleted = _stream.completedResponses;
      _onResponseCompleted();
    }

    // Surface a streaming failure once, then consume it.
    final err = _stream.error;
    if (err != null) {
      _stream.error = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Send failed: $err'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  void _onResponseCompleted() {
    _scrollToBottomDeferred();
    if (_awaitingVoiceReply) {
      _awaitingVoiceReply = false;
      final assistant = _stream.messages.reversed.firstWhere(
        (m) => m['role'] == 'assistant',
        orElse: () => const <String, dynamic>{},
      );
      final assistantText = assistant['content']?.toString();
      if (assistantText != null) {
        _speakAssistantText(assistantText);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_stream.streaming) {
      // Back in the foreground: pick up a reply that may have completed (or is
      // still finishing server-side) while we were backgrounded or killed.
      _fetchMessages(showSpinner: false);
    }
  }

  Future<void> _loadVerboseMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _verboseMode = prefs.getBool('verbose_mode') ?? false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _speechToText.cancel();
    _flutterTts.stop();
    // Deliberately do NOT abort the stream — it keeps running in the manager so
    // the agent's reply survives leaving the chat. Just stop observing it and
    // let the manager reclaim it if it's finished and unobserved.
    _stream.removeListener(_onStreamChanged);
    _manager.releaseIfIdle(widget.session.id);
    _textController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initVoice() async {
    try {
      await _flutterTts.setLanguage('en-AU');
      await _flutterTts.setSpeechRate(0.48);
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);

      final available = await _speechToText.initialize(
        onStatus: _handleSpeechStatus,
        onError: _handleSpeechError,
      );
      if (!mounted) return;
      setState(() {
        _speechAvailable = available;
        _voiceStatus = available ? null : 'Speech recognition is unavailable';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _speechAvailable = false;
        _voiceStatus = 'Voice setup failed: $e';
      });
    }
  }

  void _handleSpeechStatus(String status) {
    if (!mounted) return;
    final listening = status == 'listening';
    setState(() {
      _listening = listening;
      if (!listening && status == 'done') {
        _voiceStatus = null;
      }
    });
  }

  void _handleSpeechError(SpeechRecognitionError error) {
    if (!mounted) return;
    setState(() {
      _listening = false;
      _voiceStatus = error.errorMsg;
    });
  }

  Future<void> _toggleVoiceInput() async {
    if (_streaming || _loading) return;
    if (_listening) {
      await _speechToText.stop();
      if (!mounted) return;
      setState(() => _listening = false);
      return;
    }

    if (!_speechAvailable) {
      await _initVoice();
      if (!_speechAvailable) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _voiceStatus ?? 'Speech recognition is unavailable',
              ),
            ),
          );
        }
        return;
      }
    }

    await _flutterTts.stop();
    if (!mounted) return;
    setState(() => _voiceStatus = 'Listening…');
    await _speechToText.listen(
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      ),
      onResult: _handleSpeechResult,
    );
  }

  void _handleSpeechResult(SpeechRecognitionResult result) {
    final recognised = result.recognizedWords.trim();
    if (recognised.isEmpty || !mounted) return;
    setState(() {
      _textController.text = recognised;
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
    });
    if (result.finalResult) {
      _sendMessage(speakResponse: true);
    }
  }

  Future<void> _speakAssistantText(String text) async {
    final spokenText = text.trim();
    if (spokenText.isEmpty || !_voiceReplyEnabled) return;
    await _flutterTts.stop();
    await _flutterTts.speak(spokenText);
  }

  void _onScroll() {
    final atBottom =
        _scrollController.hasClients &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200;
    if (atBottom != !_showScrollToBottom && _streaming) {
      setState(() => _showScrollToBottom = !atBottom);
    }
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final target = _scrollController.position.maxScrollExtent;
    if (animate) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  /// Jump to the bottom after the list has had a chance to lay out.
  ///
  /// A single post-frame jump can undershoot because list items (and their
  /// final heights) are built lazily, so `maxScrollExtent` may still be growing
  /// on the first frame. Jumping again on the following frame settles us at the
  /// true bottom — this is what keeps the chat pinned to the latest message when
  /// entering a conversation or finishing a response.
  void _scrollToBottomDeferred({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToBottom(animate: animate);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollToBottom(animate: false);
      });
    });
  }

  Future<void> _fetchMessages({bool showSpinner = true}) async {
    // Never clobber a live stream with a slower REST refresh.
    if (_stream.streaming) {
      if (_loading) setState(() => _loading = false);
      return;
    }
    setState(() {
      if (showSpinner) _loading = true;
      _error = null;
    });

    try {
      final messages = await _manager.fetchMessages(
        widget.connection,
        widget.session.id,
      );
      if (!mounted || _stream.streaming) return;
      _manager.setMessages(widget.session.id, messages);
      setState(() => _loading = false);
      // Start pinned to the bottom (newest message), like a regular chat app.
      _scrollToBottomDeferred();
      // If the last turn is still awaiting the agent's reply (e.g. the app was
      // killed mid-stream and the turn is finishing server-side), keep polling
      // until it lands.
      _maybePollForPendingReply();
    } catch (e) {
      if (!mounted) return;
      final errStr = e.toString();
      if (errStr.contains('404') || errStr.contains('not found')) {
        _manager.setMessages(widget.session.id, []);
        setState(() => _loading = false);
        return;
      }
      setState(() {
        _error = errStr;
        _loading = false;
      });
    }
  }

  /// Whether the transcript ends on a user turn with no assistant reply yet —
  /// the signal that the agent is (or was) still composing a response.
  bool _awaitingAgentReply(List<Map<String, dynamic>> messages) {
    if (messages.isEmpty) return false;
    final role = (messages.last['role'] as String?) ?? '';
    return role == 'user';
  }

  /// Poll the transcript for a reply that's completing server-side (the
  /// app-was-killed case). Bounded so it can't run forever if no reply comes.
  void _maybePollForPendingReply() {
    _pollTimer?.cancel();
    _pollAttempts = 0;
    if (_stream.streaming || !_awaitingAgentReply(_stream.messages)) {
      if (_pollingForReply) setState(() => _pollingForReply = false);
      return;
    }
    setState(() => _pollingForReply = true);
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!mounted || _stream.streaming) {
        timer.cancel();
        if (mounted && _pollingForReply) {
          setState(() => _pollingForReply = false);
        }
        return;
      }
      if (++_pollAttempts > 20) {
        timer.cancel();
        setState(() => _pollingForReply = false);
        return;
      }
      try {
        final messages = await _manager.fetchMessages(
          widget.connection,
          widget.session.id,
        );
        if (!mounted || _stream.streaming) {
          timer.cancel();
          return;
        }
        _manager.setMessages(widget.session.id, messages);
        if (!_awaitingAgentReply(messages)) {
          timer.cancel();
          setState(() => _pollingForReply = false);
          _scrollToBottomDeferred();
        }
      } catch (_) {
        // Transient failure — keep polling until the attempt cap.
      }
    });
  }

  /// Send a message. The streaming itself runs in [ChatStreamManager] so it
  /// keeps going even if this screen is disposed; [_onStreamChanged] drives the
  /// UI from there.
  Future<void> _sendMessage({bool speakResponse = false}) async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    if (_streaming) return;

    _textController.text = '';
    _awaitingVoiceReply = speakResponse && _voiceReplyEnabled;
    _pollTimer?.cancel();

    // Build conversation history from the current transcript, before the
    // manager appends the optimistic user/assistant placeholders.
    final history = <Map<String, dynamic>>[];
    for (var i = _stream.messages.length - 1; i >= 0; i--) {
      final m = _stream.messages[i];
      history.add({'role': m['role'] ?? 'user', 'content': m['content'] ?? ''});
    }

    setState(() {
      _showScrollToBottom = false;
      _pollingForReply = false;
    });

    // Fire-and-forget: the manager owns the stream's lifetime.
    unawaited(
      _manager.send(
        connection: widget.connection,
        sessionId: widget.session.id,
        text: text,
        history: history,
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToBottom();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_streaming || _pollingForReply)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  // While streaming we're live; while polling the reply is
                  // still finishing server-side (e.g. after an app restart).
                  Text(
                    _streaming ? 'Responding…' : 'Catching up…',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _fetchMessages,
              tooltip: 'Refresh',
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: Responsive.isTablet(context) ? 800 : double.infinity,
          ),
          child: Column(
            children: [
              Expanded(child: _buildBody()),
              _buildInputBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(blurRadius: 4, color: Colors.black.withValues(alpha: 0.1)),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                decoration: InputDecoration(
                  hintText: 'Type a message…',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  isDense: true,
                ),
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.send,
                enabled: !_loading && !_streaming,
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              icon: Icon(_listening ? Icons.mic_off : Icons.mic),
              color: _listening ? Theme.of(context).colorScheme.error : null,
              onPressed: (!_loading && !_streaming)
                  ? _toggleVoiceInput
                  : null,
              tooltip: _listening ? 'Stop listening' : 'Speak to Hermes',
            ),
            IconButton(
              icon: Icon(
                _voiceReplyEnabled ? Icons.volume_up : Icons.volume_off,
              ),
              onPressed: () {
                setState(() => _voiceReplyEnabled = !_voiceReplyEnabled);
                if (!_voiceReplyEnabled) {
                  _flutterTts.stop();
                }
              },
              tooltip: _voiceReplyEnabled
                  ? 'Spoken replies on'
                  : 'Spoken replies off',
            ),
            const SizedBox(width: 4),
            CircleAvatar(
              child: _streaming
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      icon: const Icon(Icons.send, size: 20),
                      onPressed: _sendMessage,
                      tooltip: 'Send',
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text(
                'Failed to load messages',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _fetchMessages,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final messages = _stream.messages;
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 4),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index];
        final role = (msg['role'] as String?) ?? 'assistant';

        // Tool calls / results stay collapsed as a compact chip so a finished
        // response doesn't explode into the full tool output. Tapping a chip
        // expands its details on demand.
        if (ToolMessage.isToolMessage(msg)) {
          return ToolMessageChip(
            key: ValueKey(_toolMessageKey(msg, index)),
            message: msg,
            verbose: _verboseMode,
          );
        }

        final content = (msg['content'] as String?) ?? '';
        final isUser = role == 'user';

        return _MessageBubble(
          content: content,
          isUser: isUser,
          verbose: _verboseMode,
          metadata: msg,
        );
      },
    );
  }
}

/// A stable-ish key so a collapsed tool chip keeps its expand/collapse state
/// across rebuilds where possible. Falls back to the list index.
String _toolMessageKey(Map<String, dynamic> m, int index) {
  final id = m['tool_call_id'] ?? m['toolCallId'] ?? m['id'];
  if (id != null && id.toString().isNotEmpty) return 'tool-$id';
  return 'tool-$index-${ToolMessage.label(m)}';
}

class _MessageBubble extends StatelessWidget {
  final String content;
  final bool isUser;
  final bool verbose;
  final Map<String, dynamic> metadata;

  const _MessageBubble({
    required this.content,
    required this.isUser,
    this.verbose = false,
    this.metadata = const {},
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Bubble colors
    final userBubbleColor = const Color(0xFFD4AF37);
    final assistantBubbleColor = isDark
        ? const Color(0xFF2A2A2A)
        : const Color(0xFFEAEAEA);
    final assistantTextColor = isDark ? Colors.white : Colors.black87;

    // Collect extra metadata for verbose mode
    final List<String> metaLines = [];
    if (verbose) {
      final role = (metadata['role'] as String?) ?? 'unknown';
      metaLines.add('role: $role');
      // Show any extra fields that aren't role/content
      for (final entry in metadata.entries) {
        if (entry.key == 'role' || entry.key == 'content') continue;
        final value = entry.value?.toString() ?? 'null';
        if (value.length > 80) {
          metaLines.add('${entry.key}: ${value.substring(0, 80)}…');
        } else {
          metaLines.add('${entry.key}: $value');
        }
      }
    }

    final bubble = Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width - 80,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isUser ? userBubbleColor : assistantBubbleColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Verbose metadata header
          if (metaLines.isNotEmpty) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: (isUser ? Colors.white : Colors.black).withValues(
                  alpha: 0.1,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: metaLines
                    .map(
                      (line) => Text(
                        line,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: isUser
                              ? Colors.white.withValues(alpha: 0.8)
                              : (isDark ? Colors.grey[400] : Colors.grey[600]),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
          // Message content
          MarkdownBody(
            data: content,
            styleSheet: MarkdownStyleSheet(
              p: (isUser
                  ? theme.textTheme.bodyMedium?.copyWith(color: Colors.white)
                  : theme.textTheme.bodyMedium?.copyWith(
                      color: assistantTextColor,
                    )),
              code: TextStyle(
                backgroundColor: (isUser ? Colors.white : Colors.black)
                    .withValues(alpha: 0.12),
                fontFamily: 'monospace',
                color: isUser ? Colors.white : null,
              ),
              a: TextStyle(
                color: isUser ? Colors.white70 : theme.colorScheme.primary,
              ),
              h1: isUser
                  ? theme.textTheme.headlineSmall?.copyWith(color: Colors.white)
                  : theme.textTheme.headlineSmall,
              h2: isUser
                  ? theme.textTheme.titleLarge?.copyWith(color: Colors.white)
                  : theme.textTheme.titleLarge,
              h3: isUser
                  ? theme.textTheme.titleMedium?.copyWith(color: Colors.white)
                  : theme.textTheme.titleMedium,
              blockquote: TextStyle(
                color: isUser ? Colors.white60 : Colors.grey,
                fontStyle: FontStyle.italic,
              ),
              blockquoteDecoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: isUser ? Colors.white38 : theme.colorScheme.primary,
                    width: 3,
                  ),
                ),
              ),
              em: isUser
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: Colors.white,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
              strong: isUser
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
            ),
          ),
        ],
      ),
    );

    return Row(
      mainAxisAlignment: isUser
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [bubble],
    );
  }
}
