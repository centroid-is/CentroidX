import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:mcp_dart/mcp_dart.dart';
import 'package:riverpod/riverpod.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart'
    show
        DriftDrawingIndex,
        DriftTechDocIndex,
        McpConfig,
        McpDatabase,
        kMcpTogglesEnvVar;

import 'package:tfc_dart/core/preferences.dart' show Preferences;

import 'database.dart' show databaseProvider;
import 'preferences.dart' show preferencesProvider;
import 'preferences_local_store.dart' show localStorePreferencesProvider;

import '../chat/tool_filter.dart';
import '../mcp/mcp_lifecycle_state.dart';
import '../chat/chat_overlay.dart';
import '../llm/claude_provider.dart';
import '../llm/conversation_models.dart';
import '../llm/gemini_provider.dart';
import '../llm/llm_models.dart';
import '../llm/llm_provider.dart';
import '../llm/openai_provider.dart';
import '../mcp/alarm_man_alarm_reader.dart';
import '../mcp/state_man_state_reader.dart';
import '../mcp/tool_schema_converter.dart';
import 'alarm.dart';
import 'llm.dart';
import 'mcp_bridge.dart';
import 'plc.dart' show plcCodeIndexProvider;
import 'proposal.dart' show describeProposalFeedback;
import 'proposal_state.dart';
import 'state_man.dart';

// describeProposalFeedback moved to proposal.dart when the proposal-feedback
// bus grew a second consumer for it. Re-exported so the many call sites that
// reach it through this library keep working.
export 'proposal.dart' show describeProposalFeedback;

/// Preference key for persisted chat history (legacy, migrated to conversations).
const kChatHistory = 'chat.history';

/// Preference key for the conversation list (JSON array of ConversationMeta).
const kConversationList = 'chat.conversations';

/// Preference key for the active conversation ID.
const kActiveConversation = 'chat.active_conversation';

/// Preference key prefix for per-conversation messages.
/// Full key: `chat.conversation.{id}`.
const kConversationPrefix = 'chat.conversation.';

/// Maximum number of messages to persist per conversation.
const kMaxHistoryMessages = 100;

/// Maximum number of conversations to keep. When exceeded, oldest is deleted.
const kMaxConversations = 20;

/// Chat processing status.
enum ChatStatus {
  idle,
  processing,
  error,
}

/// Progress tracking for a single tool invocation.
class ToolProgress {
  /// The tool name being executed.
  final String name;

  /// Human-readable status: 'Running...', 'Done', 'Error'.
  final String status;

  const ToolProgress({required this.name, required this.status});
}

/// Immutable state for the chat notifier.
class ChatState {
  /// All messages in the current conversation.
  final List<ChatMessage> messages;

  /// Current processing status.
  final ChatStatus status;

  /// Progress indicators for the current batch of tool calls.
  final List<ToolProgress> toolProgress;

  /// Error message if status is [ChatStatus.error].
  final String? error;

  /// The ID of the active conversation, or null if none loaded yet.
  final String? activeConversationId;

  /// All conversation metadata, ordered newest first.
  final List<ConversationMeta> conversations;

  const ChatState({
    this.messages = const [],
    this.status = ChatStatus.idle,
    this.toolProgress = const [],
    this.error,
    this.activeConversationId,
    this.conversations = const [],
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    ChatStatus? status,
    List<ToolProgress>? toolProgress,
    String? error,
    String? activeConversationId,
    List<ConversationMeta>? conversations,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      status: status ?? this.status,
      toolProgress: toolProgress ?? this.toolProgress,
      error: error,
      activeConversationId: activeConversationId ?? this.activeConversationId,
      conversations: conversations ?? this.conversations,
    );
  }
}

/// System prompt for the AI copilot.
const _systemPrompt =
    'You are an AI copilot for a SCADA HMI system. '
    'ALWAYS check local tools first before relying on general knowledge or '
    'web search. Use search_tech_docs to query locally uploaded manufacturer '
    'manuals, datasheets, and technical PDFs specific to this plant\'s '
    'equipment. Use search_plc_code and search_drawings for control logic and '
    'electrical diagrams. Tool priority: (1) local data via MCP tools, '
    '(2) general knowledge, (3) web search as a last resort. '
    'Always cite source data including document names and page numbers. '
    'When proposing changes, explain what will be modified. '
    'NEVER associate tech docs with assets unless an explicit link exists '
    '(e.g., a techDocId on the asset or a key mapping referencing a specific '
    'device). If a tool returns no results, say so — do not substitute with '
    'guesses or unrelated documents. NEVER fabricate diagnoses or assume '
    'relationships between components; only report what the data explicitly '
    'shows, and say "no data available" when it is missing.';

/// System prompt for debug-asset mode when all context is pre-computed.
///
/// The user message already contains all the data (asset config, live values,
/// PLC call graph, alarms, drawings, tech docs). The LLM should prefer the
/// pre-computed context but may call `get_plc_code_block` if it needs full
/// source for a specific block.
const _debugAssetCompleteSystemPrompt =
    'You are an AI copilot for a SCADA HMI system. '
    'The user is asking you to diagnose an asset. ALL relevant data has been '
    'pre-computed and included in the user\'s message: asset configuration, '
    'live tag values, PLC call graph, alarm definitions, electrical drawings, '
    'and technical documentation. '
    'The call graph below shows the key relationships. Use the pre-computed '
    'context first. Only call get_plc_code_block if you need full source code '
    'for a specific block. DO NOT call other tools — all the information you '
    'need is already provided. '
    'Analyze the provided data and give a clear, focused diagnostic summary. '
    'Be specific: reference actual values, PLC variable names, alarm states, '
    'and drawing references from the provided context. '
    'NEVER fabricate diagnoses or assume relationships between components; '
    'only report what the data explicitly shows, and say "no data available" '
    'when it is missing.';

/// System prompt for debug-asset mode when some context is pre-computed
/// but additional data still needs to be gathered via tools.
const _debugAssetPartialSystemPrompt =
    'You are an AI copilot for a SCADA HMI system. '
    'The user is asking you to diagnose an asset. Some data has been '
    'pre-computed and is included in the user\'s message (marked with '
    '[ALREADY FETCHED] tags). DO NOT re-fetch any data that is already provided. '
    'The call graph below shows the key relationships. Use the pre-computed '
    'context first. Only call get_plc_code_block if you need full source code '
    'for a specific block. '
    'Only call other tools for the specific items listed in the "You still need '
    'to gather" section of the user\'s message — nothing else. '
    'After gathering the missing data, provide a clear diagnostic summary. '
    'Be specific: reference actual values, PLC variable names, alarm states, '
    'and drawing references. '
    'NEVER fabricate diagnoses or assume relationships between components; '
    'only report what the data explicitly shows.';

/// Checks whether a debug-asset message has all context pre-computed.
///
/// Returns true when the message contains the `[IMPORTANT INSTRUCTION]`
/// marker that [buildDebugAssetMessageWithTechDoc] emits only when every
/// context section (live values, PLC, alarms, drawings, tech docs) was
/// successfully pre-fetched. The LLM still has access to `get_plc_code_block`
/// but should use pre-computed context first.
bool _isDebugContextComplete(String message) {
  return message.contains('[IMPORTANT INSTRUCTION]') &&
      message.contains('ALL diagnostic context');
}

/// Manages chat message history and orchestrates the tool call loop
/// between LLM providers and the MCP bridge.
///
/// Supports multiple conversations with persistence. Each conversation
/// stores its messages under `chat.conversation.{id}` and the conversation
/// list is stored under `chat.conversations`.
///
/// The core interaction loop:
/// 1. User sends message
/// 2. LLM is called with message history + available MCP tools
/// 3. If LLM returns tool_use, each tool is executed via McpBridge
/// 4. Tool results are added to history and LLM is called again
/// 5. Loop terminates when LLM returns text-only response
class ChatNotifier extends Notifier<ChatState> {
  LlmProvider? _llmProvider;

  @override
  ChatState build() {
    return const ChatState();
  }

  /// Sets the LLM provider to use for completions.
  ///
  /// Called when the user selects a provider or on initialization.
  void setLlmProvider(LlmProvider provider) {
    _llmProvider = provider;
  }

  /// Whether the notifier is currently processing a request.
  bool get isProcessing => state.status == ChatStatus.processing;

  // ─── Conversation management ───────────────────────────────────────

  /// Loads the conversation list from preferences.
  ///
  /// Called when chat becomes visible. If a legacy `chat.history` key
  /// exists, migrates it into a single conversation first.
  Future<void> loadConversations() async {
    final prefs = await ref.read(localStorePreferencesProvider.future);

    // Migrate legacy history if present
    await _migrateLegacyHistory(prefs);

    // Load conversation list
    final listJson = await prefs.getString(kConversationList);
    var conversations = <ConversationMeta>[];
    if (listJson != null && listJson.isNotEmpty) {
      try {
        final list = jsonDecode(listJson) as List<dynamic>;
        conversations = list
            .map((e) => ConversationMeta.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        // Corrupted list -- start fresh
      }
    }

    // Load active conversation ID
    final activeId = await prefs.getString(kActiveConversation);

    if (conversations.isEmpty) {
      // Create a fresh conversation if none exist
      final conv = ConversationMeta(
        id: ConversationMeta.generateId(),
        title: 'New conversation',
        createdAt: DateTime.now(),
      );
      conversations = [conv];
      state = state.copyWith(
        conversations: List.unmodifiable(conversations),
        activeConversationId: conv.id,
        messages: const [],
      );
      await _saveConversationList();
      await _saveActiveConversationId();
      return;
    }

    // Determine active conversation
    final effectiveId =
        (activeId != null && conversations.any((c) => c.id == activeId))
            ? activeId
            : conversations.first.id;

    state = state.copyWith(
      conversations: List.unmodifiable(conversations),
      activeConversationId: effectiveId,
    );

    // Load messages for the active conversation
    await loadConversation(effectiveId);
  }

  /// Loads messages for a specific conversation from preferences.
  Future<void> loadConversation(String id) async {
    final prefs = await ref.read(localStorePreferencesProvider.future);
    final json = await prefs.getString('$kConversationPrefix$id');

    var messages = <ChatMessage>[];
    if (json != null && json.isNotEmpty) {
      try {
        final list = jsonDecode(json) as List<dynamic>;
        messages = list
            .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        // Corrupted messages -- start fresh for this conversation
      }
    }

    state = state.copyWith(
      messages: List.unmodifiable(messages),
      activeConversationId: id,
      status: ChatStatus.idle,
      toolProgress: const [],
    );
    await _saveActiveConversationId();
  }

  /// Saves the current messages under the active conversation ID.
  Future<void> saveConversation() async {
    final id = state.activeConversationId;
    if (id == null) return;

    var messages = state.messages.toList();
    if (messages.length > kMaxHistoryMessages) {
      final system = messages.where((m) => m.role == ChatRole.system).toList();
      final nonSystem =
          messages.where((m) => m.role != ChatRole.system).toList();
      final keep = nonSystem.length > kMaxHistoryMessages - system.length
          ? nonSystem
              .sublist(nonSystem.length - (kMaxHistoryMessages - system.length))
          : nonSystem;
      messages = [...system, ...keep];
    }

    final json = jsonEncode(messages.map((m) => m.toJson()).toList());
    final prefs = await ref.read(localStorePreferencesProvider.future);
    await prefs.setString('$kConversationPrefix$id', json);
  }

  /// Creates a new conversation, saves the current one, and switches to it.
  Future<void> newConversation() async {
    // If the active conversation has no messages at all, reuse it
    // instead of creating a duplicate empty conversation. This prevents
    // the "two New conversation" entries after Clear All + tapping +.
    if (state.messages.isEmpty && state.activeConversationId != null) {
      return;
    }

    // Save current conversation before switching
    await saveConversation();

    final conv = ConversationMeta(
      id: ConversationMeta.generateId(),
      title: 'New conversation',
      createdAt: DateTime.now(),
    );

    var conversations = [conv, ...state.conversations];

    // Enforce max conversations limit
    if (conversations.length > kMaxConversations) {
      final removed = conversations.sublist(kMaxConversations);
      conversations = conversations.sublist(0, kMaxConversations);
      // Clean up messages for removed conversations
      final prefs = await ref.read(localStorePreferencesProvider.future);
      for (final old in removed) {
        await prefs.remove('$kConversationPrefix${old.id}');
      }
    }

    state = state.copyWith(
      conversations: List.unmodifiable(conversations),
      activeConversationId: conv.id,
      messages: const [],
      status: ChatStatus.idle,
      toolProgress: const [],
    );

    await _saveConversationList();
    await _saveActiveConversationId();
  }

  /// Saves the current conversation, then loads the target conversation.
  Future<void> switchConversation(String id) async {
    if (id == state.activeConversationId) return;

    // Save current conversation before switching
    await saveConversation();

    // Load target
    await loadConversation(id);
  }

  /// Deletes a conversation and its messages from preferences.
  ///
  /// If the deleted conversation is active, switches to another.
  /// If no conversations remain, creates a new one.
  Future<void> deleteConversation(String id) async {
    final prefs = await ref.read(localStorePreferencesProvider.future);

    // Remove messages
    await prefs.remove('$kConversationPrefix$id');

    // Remove from list
    var conversations = state.conversations.where((c) => c.id != id).toList();

    if (conversations.isEmpty) {
      // Create a new conversation to replace the deleted one
      final conv = ConversationMeta(
        id: ConversationMeta.generateId(),
        title: 'New conversation',
        createdAt: DateTime.now(),
      );
      conversations = [conv];
      state = state.copyWith(
        conversations: List.unmodifiable(conversations),
        activeConversationId: conv.id,
        messages: const [],
        status: ChatStatus.idle,
        toolProgress: const [],
      );
    } else if (state.activeConversationId == id) {
      // Switch to the first remaining conversation
      state = state.copyWith(
        conversations: List.unmodifiable(conversations),
      );
      await loadConversation(conversations.first.id);
    } else {
      state = state.copyWith(
        conversations: List.unmodifiable(conversations),
      );
    }

    await _saveConversationList();
    await _saveActiveConversationId();
  }

  /// Deletes all conversations and their messages from preferences.
  ///
  /// Creates a fresh empty conversation afterwards.
  Future<void> clearAllConversations() async {
    final prefs = await ref.read(localStorePreferencesProvider.future);

    // Remove all conversation messages
    for (final conv in state.conversations) {
      await prefs.remove('$kConversationPrefix${conv.id}');
    }

    // Also remove legacy key if it still exists
    await prefs.remove(kChatHistory);

    // Create a fresh conversation
    final conv = ConversationMeta(
      id: ConversationMeta.generateId(),
      title: 'New conversation',
      createdAt: DateTime.now(),
    );

    state = ChatState(
      activeConversationId: conv.id,
      conversations: [conv],
    );

    await _saveConversationList();
    await _saveActiveConversationId();
  }

  // ─── Legacy compatibility ──────────────────────────────────────────

  /// Loads persisted chat history from preferences (legacy single-conversation).
  ///
  /// Kept for backward compatibility. New code should use [loadConversations].
  Future<void> loadHistory() async {
    await loadConversations();
  }

  /// Persists current messages to preferences (delegates to [saveConversation]).
  Future<void> saveHistory() async {
    await saveConversation();
  }

  /// Migrates legacy `chat.history` into a single conversation.
  Future<void> _migrateLegacyHistory(Preferences prefs) async {
    final legacyJson = await prefs.getString(kChatHistory);
    if (legacyJson == null || legacyJson.isEmpty) return;

    // Check if conversations already exist (already migrated)
    final existingList = await prefs.getString(kConversationList);
    if (existingList != null && existingList.isNotEmpty) {
      // Already migrated, just clean up legacy key
      await prefs.remove(kChatHistory);
      return;
    }

    try {
      final list = jsonDecode(legacyJson) as List<dynamic>;
      final messages = list
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();

      if (messages.isEmpty) {
        await prefs.remove(kChatHistory);
        return;
      }

      // Create a conversation from the legacy history
      final id = ConversationMeta.generateId();
      final firstUserMsg =
          messages.where((m) => m.role == ChatRole.user).firstOrNull;
      final title = firstUserMsg != null
          ? ConversationMeta.titleFromMessage(firstUserMsg.content)
          : 'Migrated conversation';

      final conv = ConversationMeta(
        id: id,
        title: title,
        createdAt: DateTime.now(),
      );

      // Save conversation messages
      final messagesJson = jsonEncode(messages.map((m) => m.toJson()).toList());
      await prefs.setString('$kConversationPrefix$id', messagesJson);

      // Save conversation list
      final convListJson = jsonEncode([conv.toJson()]);
      await prefs.setString(kConversationList, convListJson);

      // Set active
      await prefs.setString(kActiveConversation, id);

      // Remove legacy key
      await prefs.remove(kChatHistory);
    } catch (_) {
      // Corrupted legacy data -- just remove it
      await prefs.remove(kChatHistory);
    }
  }

  // ─── Internal helpers ──────────────────────────────────────────────

  Future<void> _saveConversationList() async {
    final prefs = await ref.read(localStorePreferencesProvider.future);
    final json =
        jsonEncode(state.conversations.map((c) => c.toJson()).toList());
    await prefs.setString(kConversationList, json);
  }

  String? _lastSavedActiveId;

  Future<void> _saveActiveConversationId() async {
    final id = state.activeConversationId;
    if (id == null || id == _lastSavedActiveId) return;
    _lastSavedActiveId = id;
    final prefs = await ref.read(localStorePreferencesProvider.future);
    await prefs.setString(kActiveConversation, id);
  }

  /// Updates the title of the active conversation in the list.
  void _updateActiveConversationTitle(String title) {
    final id = state.activeConversationId;
    if (id == null) return;

    final conversations = state.conversations.map((c) {
      if (c.id == id) return c.copyWith(title: title);
      return c;
    }).toList();

    state = state.copyWith(
      conversations: List.unmodifiable(conversations),
    );

    // Fire and forget save
    _saveConversationList();
  }

  // ─── Message sending ──────────────────────────────────────────────

  /// Sends a user message and runs the LLM tool call loop.
  ///
  /// Adds the user message to history, calls the LLM with available MCP tools,
  /// and iterates through tool calls until the LLM returns a text-only response.
  /// Auto-saves after each exchange and updates the conversation title on the
  /// first user message.
  ///
  /// When [toolFilter] is provided, only tools whose names are in the set
  /// are sent to the LLM. When null, the action is auto-detected from the
  /// message content via [detectActionFromMessage]. For freeform messages
  /// (no detected action), all tools are sent.
  Future<void> sendMessage(String text,
      {Set<String>? toolFilter, List<ChatAttachment>? attachments}) async {
    if (_llmProvider == null) {
      state = state.copyWith(
        status: ChatStatus.error,
        error: 'No LLM provider configured',
      );
      return;
    }

    final messages = List<ChatMessage>.from(state.messages);

    // Detect action to select the appropriate system prompt.
    final detectedAction = detectActionFromMessage(text);
    final isDebugAssetComplete = detectedAction == AiAction.debugAsset &&
        _isDebugContextComplete(text);
    final isDebugAssetPartial = detectedAction == AiAction.debugAsset &&
        !isDebugAssetComplete;

    // Select the appropriate system prompt for this action.
    final systemPrompt = isDebugAssetComplete
        ? _debugAssetCompleteSystemPrompt
        : isDebugAssetPartial
            ? _debugAssetPartialSystemPrompt
            : _systemPrompt;

    // Add system prompt if this is the first message.
    // Debug-asset mode gets a specialized system prompt that prevents
    // unnecessary tool calls when context is pre-computed.
    if (messages.isEmpty) {
      messages.add(ChatMessage.system(systemPrompt));
    } else if (detectedAction == AiAction.debugAsset) {
      // SAFETY NET: After a hot restart, loadConversations() (triggered by
      // the chatLifecycle listener) may reload stale messages from a
      // previous conversation before sendMessage runs. In that case
      // messages is NOT empty, so the debug system prompt would be skipped
      // and the LLM would use the old generic prompt — causing it to
      // respond as a generic assistant instead of diagnosing the asset.
      //
      // Fix: for debug-asset actions, always replace the existing system
      // prompt (or prepend one) so the LLM gets the correct instructions.
      final hasSystem = messages.isNotEmpty && messages.first.role == ChatRole.system;
      if (hasSystem) {
        messages[0] = ChatMessage.system(systemPrompt);
      } else {
        messages.insert(0, ChatMessage.system(systemPrompt));
      }
    }

    // Check if this is the first user message (for title update)
    final isFirstUserMessage = !messages.any((m) => m.role == ChatRole.user);

    // Add user message (with optional PDF attachments)
    messages.add(ChatMessage.user(text, attachments: attachments));

    state = state.copyWith(
      messages: List.unmodifiable(messages),
      status: ChatStatus.processing,
      toolProgress: [],
      error: null,
    );

    // Update conversation title on first user message
    if (isFirstUserMessage) {
      _updateActiveConversationTitle(ConversationMeta.titleFromMessage(text));
    }

    try {
      final bridge = ref.read(mcpBridgeProvider);

      // Wait for bridge if it's still connecting (race with chatLifecycleProvider)
      if (bridge.currentState.connectionState ==
          McpConnectionState.connecting) {
        try {
          await bridge.waitForReady();
        } on StateError catch (e) {
          io.stderr.writeln('ChatNotifier: bridge failed to connect: $e');
          // Continue without tools -- LLM will respond text-only
        } on TimeoutException catch (_) {
          io.stderr
              .writeln('ChatNotifier: timed out waiting for bridge connection');
          // Continue without tools -- LLM will respond text-only
        }
      }

      // Determine effective tool filter: explicit > auto-detected > all.
      // When debug-asset context is fully pre-computed, restrict tools to
      // ONLY get_plc_code_block so the LLM cannot call diagnose_asset,
      // get_tag_value, etc. and redo work that is already in the prompt.
      // This is the key mechanism that prevents 30+ redundant tool calls.
      final Set<String>? effectiveFilter;
      if (toolFilter != null) {
        effectiveFilter = toolFilter;
      } else if (isDebugAssetComplete) {
        // All context pre-computed: only allow fetching full PLC source
        effectiveFilter = const {'get_plc_code_block'};
      } else {
        effectiveFilter = toolsFor(detectedAction);
      }

      final mcpTools = filterTools<Tool>(
        bridge.tools,
        effectiveFilter,
        (t) => t.name,
      );
      final convertedTools = mcpTools.isNotEmpty
          ? ToolSchemaConverter.convertAll(mcpTools, _llmProvider!.providerType)
          : <Map<String, dynamic>>[];

      // Call LLM
      var response = await _llmProvider!.complete(
        messages,
        tools: convertedTools,
      );

      // Tool call loop
      while (response.hasToolCalls) {
        // Add assistant message with tool calls to history
        messages.add(ChatMessage.assistant(
          response.content,
          toolCalls: response.toolCalls,
        ));

        // Show all tools as running
        final progress = response.toolCalls
            .map((tc) => ToolProgress(name: tc.name, status: 'Running...'))
            .toList();
        state = state.copyWith(
          messages: List.unmodifiable(messages),
          toolProgress: List.unmodifiable(progress),
        );

        // Execute all tool calls in parallel. The MCP server has its own
        // concurrency limiter (max 3) so we don't throttle here. Each
        // call is wrapped in try/catch so one failure doesn't block others.
        final toolCalls = response.toolCalls;
        final results = await Future.wait(
          toolCalls.asMap().entries.map((entry) async {
            final idx = entry.key;
            final toolCall = entry.value;
            try {
              final result =
                  await bridge.callTool(toolCall.name, toolCall.arguments);
              final resultText = result.content
                  .whereType<TextContent>()
                  .map((c) => c.text)
                  .join('\n');

              progress[idx] =
                  ToolProgress(name: toolCall.name, status: 'Done');
              state = state.copyWith(
                toolProgress: List.unmodifiable(progress),
              );

              // Surface proposals immediately into ProposalStateNotifier
              // so the UI shows them without waiting for the DB poll cycle.
              _surfaceProposalFromToolResult(resultText);

              return ChatMessage.toolResult(toolCall.id, resultText);
            } catch (e) {
              progress[idx] =
                  ToolProgress(name: toolCall.name, status: 'Error');
              state = state.copyWith(
                toolProgress: List.unmodifiable(progress),
              );

              return ChatMessage.toolResult(toolCall.id, 'Error: $e');
            }
          }),
        );

        // Add all tool results to history in the same order as the calls
        messages.addAll(results);
        state = state.copyWith(
          messages: List.unmodifiable(messages),
          toolProgress: List.unmodifiable(progress),
        );

        // Call LLM again with tool results
        response = await _llmProvider!.complete(
          messages,
          tools: convertedTools,
        );
      }

      // Final text-only response
      messages.add(ChatMessage.assistant(response.content));

      state = state.copyWith(
        messages: List.unmodifiable(messages),
        status: ChatStatus.idle,
        toolProgress: [],
      );

      // Fire-and-forget: persist in background so the UI doesn't block on
      // the PostgreSQL write. State is already up-to-date in memory.
      unawaited(saveConversation());
    } catch (e) {
      state = state.copyWith(
        messages: List.unmodifiable(messages),
        status: ChatStatus.error,
        toolProgress: [],
        error: e.toString(),
      );

      // Fire-and-forget: persist the user message without blocking the UI.
      unawaited(saveConversation());
    }
  }

  /// Extracts proposal JSON from a tool result and adds it to the
  /// [ProposalStateNotifier].
  ///
  /// A proposal is a JSON object containing `_proposal_type`. The parsing
  /// lives on [PendingProposal] because `proposalIngestProvider` stages the
  /// very same proposals when the chat is compiled out, and two copies of
  /// this that drifted apart would show the operator two different titles
  /// for one change.
  void _surfaceProposalFromToolResult(String resultText) {
    final proposal = PendingProposal.tryParse(resultText);
    if (proposal == null) return;
    ref.read(proposalStateProvider.notifier).addProposal(proposal);
  }

  /// Injects a proposal into the chat as an assistant message.
  ///
  /// Called when the MCP server (running either in-process or via SSE)
  /// creates a proposal. This ensures the proposal is visible in the
  /// chat UI even when tool execution happens outside Flutter's tool
  /// loop (e.g., via an external Agent SDK proxy calling the SSE server).
  ///
  /// The proposal JSON contains `_proposal_type`, which causes
  /// [MessageBubble] to render a [ProposalAction] button.
  ///
  /// Deduplicates: if a tool result message already contains this exact
  /// proposal JSON, skip injection (it is already visible).
  void injectProposal(String proposalJson) {
    // Check if this proposal is already in any message's content.
    final isDuplicate = state.messages.any(
      (m) => m.content == proposalJson,
    );
    if (isDuplicate) {
      io.stderr.writeln(
          'ChatNotifier.injectProposal: skipping duplicate proposal');
      return;
    }

    io.stderr.writeln(
        'ChatNotifier.injectProposal: adding proposal as assistant message '
        '(${state.messages.length} existing messages)');
    final messages = List<ChatMessage>.from(state.messages);
    messages.add(ChatMessage.assistant(proposalJson));
    state = state.copyWith(messages: List.unmodifiable(messages));

    // Also surface to ProposalStateNotifier for status tracking.
    _surfaceProposalFromToolResult(proposalJson);

    // Fire-and-forget save.
    unawaited(saveConversation());
  }

  /// Injects an operator decision on proposals into the conversation.
  ///
  /// The note carries the user role prefixed with [kOperatorDecisionPrefix],
  /// so the AI reads it as coming from the operator on its next turn while
  /// [MessageBubble] renders nothing for it -- the operator already saw the
  /// button they clicked. Deliberately does NOT trigger a completion: a
  /// decision is context for the next exchange, not a question that warrants
  /// spending a turn on "great, glad you accepted".
  void injectProposalFeedback(String text) {
    final messages = List<ChatMessage>.from(state.messages);
    messages.add(ChatMessage.user('$kOperatorDecisionPrefix $text'));
    state = state.copyWith(messages: List.unmodifiable(messages));

    // Fire-and-forget save.
    unawaited(saveConversation());
  }

  /// Clears all messages in the current conversation and resets to idle state.
  ///
  /// Also removes persisted messages for the active conversation.
  void clear() {
    final activeId = state.activeConversationId;
    final conversations = state.conversations;
    state = ChatState(
      activeConversationId: activeId,
      conversations: conversations,
    );
    // Clear persisted messages for active conversation
    if (activeId != null) {
      ref.read(localStorePreferencesProvider.future).then((prefs) {
        prefs.remove('$kConversationPrefix$activeId');
      });
    }
  }
}

/// Provider for the [ChatNotifier].
final chatProvider = NotifierProvider<ChatNotifier, ChatState>(
  () => ChatNotifier(),
);

/// Creates an [LlmProvider] instance for the given type and API key.
///
/// Returns null if the API key is null or empty.
/// Optional [baseUrl] overrides the default API endpoint (Claude/OpenAI only).
LlmProvider? createLlmProvider(LlmProviderType type, String? apiKey,
    {String? baseUrl}) {
  if (apiKey == null || apiKey.isEmpty) return null;
  switch (type) {
    case LlmProviderType.claude:
      return ClaudeProvider(apiKey: apiKey, baseUrl: baseUrl);
    case LlmProviderType.openai:
      return OpenAiProvider(apiKey: apiKey, baseUrl: baseUrl);
    case LlmProviderType.gemini:
      return GeminiProvider(apiKey: apiKey);
  }
}

/// Mutable state for the chat lifecycle provider.
final _chatLifecycle = McpLifecycleState();

/// Manages the MCP bridge lifecycle based on chat visibility.
///
/// When [chatVisibleProvider] goes true, connects the MCP bridge using
/// in-process mode with real StateMan/AlarmMan readers when available,
/// falling back to subprocess mode otherwise.
///
/// When it goes false, disconnects and disposes reader subscriptions.
///
/// Also watches the selected LLM provider and API key to create/update
/// the [LlmProvider] on the [ChatNotifier].
final chatLifecycleProvider = Provider<void>((ref) {
  // Watch visibility changes.
  //
  // The callback is async and contains many awaits (loadConversations,
  // provider reads, connectInProcess). To guard against race conditions
  // where chatVisibleProvider changes again before the callback completes,
  // we re-check the current visibility after every await boundary.
  ref.listen<bool>(chatVisibleProvider, (prev, next) async {
    final bridge = ref.read(mcpBridgeProvider);
    if (next) {
      // Chat opened: load conversations before connecting
      await ref.read(chatProvider.notifier).loadConversations();

      // Re-check: if the user closed chat while we were loading, abort.
      if (!ref.read(chatVisibleProvider)) return;

      // Attempt in-process connection with live data readers

      // Get current LLM provider for sampling support
      final selectedType = await ref.read(selectedLlmProviderProvider.future);
      LlmProvider? llmProvider;
      if (selectedType != null) {
        final apiKey = await ref.read(llmApiKeyProvider(selectedType).future);
        final baseUrl = await ref.read(llmBaseUrlProvider(selectedType).future);
        llmProvider = createLlmProvider(selectedType, apiKey, baseUrl: baseUrl);
      }

      // Re-check: if the user closed chat while we were reading providers, abort.
      if (!ref.read(chatVisibleProvider)) return;

      try {
        // Try to get live StateMan and AlarmMan
        final stateMan = await ref.read(stateManProvider.future);
        // Awaited only to surface an AlarmMan that cannot be built; the
        // reader below resolves the provider on every read instead of
        // holding this instance, which an accepted alarm edit replaces.
        await ref.read(alarmManProvider.future);

        // Create live data readers
        final stateReader = StateManStateReader(stateMan);
        _chatLifecycle.activeStateReader = stateReader;
        // Subscribe in the background -- see _startServer in
        // providers/mcp_bridge.dart: init() can block indefinitely on an
        // unreachable node, and the bridge must connect regardless.
        unawaited(stateReader.init().catchError((Object e) {
          io.stderr.writeln('chatLifecycleProvider: state reader init failed: $e');
        }));

        final alarmReader =
            AlarmManAlarmReader.live(() => currentAlarmConfigs(ref));

        // Get AppDatabase as McpDatabase (single pool, no new connections)
        final dbWrapper = await ref.read(databaseProvider.future);
        if (dbWrapper == null) {
          throw StateError('Database not connected');
        }
        final McpDatabase database = dbWrapper.db;

        // Read toggle state from consolidated config
        final config = await ref.read(mcpConfigProvider.future);

        // Final re-check before connecting
        if (!ref.read(chatVisibleProvider)) {
          _chatLifecycle.disposeReader();
          return;
        }

        // Connect in-process with real readers.
        // Use the shared plcCodeIndexProvider so the MCP server sees the
        // same isEmpty cache that upload updates.
        await bridge.connectInProcess(
          database: database,
          stateReader: stateReader,
          alarmReader: alarmReader,
          llmProvider: llmProvider,
          drawingIndex: DriftDrawingIndex(database),
          plcCodeIndex: ref.read(plcCodeIndexProvider),
          techDocIndex: DriftTechDocIndex(database),
          toggles: config.toggles,
        );
      } catch (e) {
        // StateMan/AlarmMan not available: fall back to subprocess mode
        io.stderr.writeln(
            'chatLifecycleProvider: In-process connection failed ($e), '
            'falling back to subprocess mode');
        _chatLifecycle.disposeReader();

        // Don't fall back if chat was closed during the attempt
        if (!ref.read(chatVisibleProvider)) return;

        // The MCP config is device-local, so the subprocess cannot read
        // the tool toggles from the shared database — pass them along.
        final fallbackConfig = await ref.read(mcpConfigProvider.future);
        final dbEnv = {
          ...getMcpServerEnv(),
          kMcpTogglesEnvVar: jsonEncode(fallbackConfig.toggles.toJson()),
        };
        await bridge.connect(
          dbEnv: dbEnv,
          llmProvider: llmProvider,
        );
      }
    } else {
      // Chat closed: cancel any pending toggle reconnect, then disconnect.
      _chatLifecycle.cancelTimer();
      _chatLifecycle.disposeReader();
      await bridge.disconnect();
    }
  });

  // Watch LLM provider/key changes to update ChatNotifier
  ref.listen<AsyncValue<LlmProviderType?>>(selectedLlmProviderProvider,
      (prev, next) async {
    final type = next.valueOrNull;
    if (type == null) return;
    final apiKey = await ref.read(llmApiKeyProvider(type).future);
    final baseUrl = await ref.read(llmBaseUrlProvider(type).future);
    final provider = createLlmProvider(type, apiKey, baseUrl: baseUrl);
    if (provider != null) {
      ref.read(chatProvider.notifier).setLlmProvider(provider);
    }
  });

  // Listen for proposals emitted by the MCP server's write tools. This is
  // the whole delivery path -- a proposal is never stored anywhere, so if it
  // does not arrive here it does not arrive at all. It covers both cases:
  //   (a) In-process: tool executed by ChatNotifier's tool loop — the tool
  //       result message already contains the proposal JSON, but this
  //       stream fires too (harmless: injectProposal deduplicates).
  //   (b) SSE: tool executed by an external client (e.g., Agent SDK proxy)
  //       — the tool result never enters ChatNotifier, so this stream
  //       is the only way the proposal reaches the chat UI.
  {
    final bridge = ref.read(mcpBridgeProvider);
    final proposalSub = bridge.proposalStream.listen(
      (proposalJson) {
        try {
          ref.read(chatProvider.notifier).injectProposal(proposalJson);
        } catch (e) {
          io.stderr.writeln(
              'chatLifecycleProvider: failed to inject proposal: $e');
        }
      },
      onError: (Object e) {
        io.stderr.writeln(
            'chatLifecycleProvider: proposalStream error: $e');
      },
    );
    ref.onDispose(() => proposalSub.cancel());
  }

  // Relay operator decisions on proposals back into the conversation, so the
  // AI learns whether its proposals were accepted, viewed, or rejected.
  // Events are buffered briefly and merged into one note per action: the
  // editor commit path accepts a batch one proposal at a time, and twenty
  // "[Operator decision] Accepted …" lines is noise where one line will do.
  {
    final feedbackController = ref.read(proposalFeedbackProvider);
    final buffered = <ProposalFeedback>[];
    Timer? flushTimer;

    void flush() {
      final byAction = <String, List<PendingProposal>>{};
      for (final event in buffered) {
        final list = byAction.putIfAbsent(event.action, () => []);
        for (final p in event.proposals) {
          if (!list.any((existing) => existing.id == p.id)) list.add(p);
        }
      }
      buffered.clear();
      for (final entry in byAction.entries) {
        try {
          ref.read(chatProvider.notifier).injectProposalFeedback(
              describeProposalFeedback(entry.key, entry.value));
        } catch (e) {
          io.stderr.writeln(
              'chatLifecycleProvider: failed to inject proposal feedback: $e');
        }
      }
    }

    final feedbackSub = feedbackController.stream.listen((event) {
      buffered.add(event);
      flushTimer?.cancel();
      flushTimer = Timer(const Duration(milliseconds: 300), flush);
    });
    ref.onDispose(() {
      flushTimer?.cancel();
      feedbackSub.cancel();
    });
  }

  // Watch config changes (toggles) for debounced reconnect. The config
  // lives in device-local preferences, so changes arrive through
  // mcpConfigProvider (invalidated on every save), not through the
  // database-backed preferences change stream.
  ref.listen<AsyncValue<McpConfig>>(mcpConfigProvider, (prev, next) {
    if (next is AsyncLoading) return;
    final config = next.valueOrNull;
    if (config == null) return;
    if (prev?.valueOrNull == config) return;
    if (!ref.read(chatVisibleProvider)) return;

    final bridge = ref.read(mcpBridgeProvider);
    if (bridge.currentState.connectionState != McpConnectionState.connected) {
      return;
    }

    // Debounce: cancel previous timer, set new one
    _chatLifecycle.cancelTimer();
    _chatLifecycle.reconnectTimer =
        Timer(const Duration(milliseconds: 800), () async {
      try {
        // Abort if chat was closed while the timer was pending.
        if (!ref.read(chatVisibleProvider)) return;

        await bridge.disconnect();

        // Re-check after async gap.
        if (!ref.read(chatVisibleProvider)) return;

        final freshConfig = await ref.read(mcpConfigProvider.future);

          final stateMan = await ref.read(stateManProvider.future);
          // See above: resolved live, not captured -- an accepted alarm
          // edit invalidates alarmManProvider and replaces this instance.
          await ref.read(alarmManProvider.future);
          final stateReader = StateManStateReader(stateMan);
          _chatLifecycle.activeStateReader = stateReader;
          unawaited(stateReader.init().catchError((Object e) {
            io.stderr
                .writeln('chatLifecycleProvider: state reader init failed: $e');
          }));
          final alarmReader =
              AlarmManAlarmReader.live(() => currentAlarmConfigs(ref));
          final dbWrapper = await ref.read(databaseProvider.future);
          if (dbWrapper == null) return;
          final McpDatabase database = dbWrapper.db;

          final selectedType =
              await ref.read(selectedLlmProviderProvider.future);
          LlmProvider? llmProvider;
          if (selectedType != null) {
            final apiKey =
                await ref.read(llmApiKeyProvider(selectedType).future);
            final baseUrl =
                await ref.read(llmBaseUrlProvider(selectedType).future);
            llmProvider =
                createLlmProvider(selectedType, apiKey, baseUrl: baseUrl);
          }

          // Final re-check before reconnecting.
          if (!ref.read(chatVisibleProvider)) return;

          await bridge.connectInProcess(
            database: database,
            stateReader: stateReader,
            alarmReader: alarmReader,
            llmProvider: llmProvider,
            drawingIndex: DriftDrawingIndex(database),
            plcCodeIndex: ref.read(plcCodeIndexProvider),
            techDocIndex: DriftTechDocIndex(database),
            toggles: freshConfig.toggles,
          );
        } catch (e) {
          io.stderr.writeln('Toggle reconnect failed: $e');
        }
      });
  });

  ref.onDispose(() {
    _chatLifecycle.dispose();
  });
});
