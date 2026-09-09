import 'dart:io' as io;
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../llm/llm_models.dart';
import '../llm/llm_provider.dart';
import '../providers/chat.dart';
import '../providers/llm.dart';
import '../providers/navigator_key.dart';
import '../providers/preferences.dart';
import '../providers/preferences_local_store.dart';
import 'batch_proposal_summary.dart';
import 'chat_overlay.dart';
import 'chat_skill_chips.dart';
import 'message_bubble.dart';

/// The main chat widget with message list, input bar, and provider selector.
///
/// Displays conversation history, tool progress indicators, and a text input
/// with send button. Reads from [chatProvider] for state and dispatches
/// messages via [ChatNotifier.sendMessage].
class ChatWidget extends ConsumerStatefulWidget {
  const ChatWidget({super.key});

  @override
  ConsumerState<ChatWidget> createState() => _ChatWidgetState();
}

class _ChatWidgetState extends ConsumerState<ChatWidget> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();

  /// Guards the auto-hide of credentials so it only happens once per widget
  /// lifecycle. Without this, every rebuild where the API key is configured
  /// would re-hide credentials even after the user manually showed them.
  bool _hasAutoHiddenSettings = false;

  @override
  void initState() {
    super.initState();
    _inputFocusNode.onKeyEvent = _handleInputKeyEvent;

    // Auto-focus the text input when the chat overlay opens.
    // The overlay is mounted/unmounted with chatVisibleProvider, so initState
    // fires every time the user opens the chat (FAB tap, right-click action,
    // etc.).  A post-frame callback ensures the widget tree is fully built
    // before requesting focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _inputFocusNode.requestFocus();
      }
    });
  }

  /// Returns a [BuildContext] that is a descendant of the app [Navigator].
  ///
  /// The chat overlay lives inside `MaterialApp.builder`, above the
  /// Navigator in the widget tree.  Using [context] directly for
  /// `showDialog` or `ScaffoldMessenger.of` would fail with
  /// "Navigator operation requested with a context that does not
  /// include a Navigator".  This getter resolves the navigator key
  /// from the [BeamerDelegate] to obtain a valid context.
  BuildContext get _navigatorContext {
    final key = ref.read(navigatorKeyProvider);
    return key?.currentContext ?? context;
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Use select() to only rebuild when specific fields change, avoiding
    // full-tree rebuilds during tool progress updates in the LLM loop.
    final messages = ref.watch(chatProvider.select((s) => s.messages));
    final status = ref.watch(chatProvider.select((s) => s.status));
    final toolProgress = ref.watch(chatProvider.select((s) => s.toolProgress));
    final error = ref.watch(chatProvider.select((s) => s.error));
    final selectedProvider = ref.watch(selectedLlmProviderProvider);
    final showSettings = ref.watch(chatSettingsVisibleProvider);

    // Pick up pre-filled text from chatPrefillProvider (e.g. "Create alarm with AI")
    final prefill = ref.watch(chatPrefillProvider);
    if (prefill != null) {
      // Consume the prefill value immediately so it doesn't re-apply on rebuild
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _textController.text = prefill;
          // Move cursor to end of the pre-filled text
          _textController.selection = TextSelection.fromPosition(
            TextPosition(offset: _textController.text.length),
          );
          _inputFocusNode.requestFocus();
          ref.read(chatPrefillProvider.notifier).state = null;
        }
      });
    }

    // Auto-hide when API key is configured (first time only per widget lifecycle)
    if (!_hasAutoHiddenSettings) {
      final providerType = selectedProvider.valueOrNull;
      if (providerType != null) {
        final apiKeyAsync = ref.watch(llmApiKeyProvider(providerType));
        apiKeyAsync.whenData((key) {
          if (key != null && key.isNotEmpty) {
            _hasAutoHiddenSettings = true;
            // Schedule state update for after build
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && ref.read(chatSettingsVisibleProvider)) {
                ref.read(chatSettingsVisibleProvider.notifier).state = false;
              }
            });
          }
        });
      }
    }

    return Column(
      children: [
        // Provider selector bar (auto-hides when API key is configured)
        if (showSettings) _buildProviderSelector(context, selectedProvider),
        const Divider(height: 1),
        // Batch proposal summary (shows when 2+ proposals of the same type)
        const BatchProposalSummary(),
        // Message list -- always visible
        Expanded(child: _buildMessageList(context, messages)),
        // Tool progress indicators
        if (status == ChatStatus.processing && toolProgress.isNotEmpty)
          _buildToolProgress(context, toolProgress),
        // Error banner
        if (error != null) _buildErrorBanner(context, error),
        const Divider(height: 1),
        // Context chip (shown when a context block is attached)
        _buildContextChip(context),
        // Input bar
        _buildInputBar(context, status),
      ],
    );
  }

  Widget _buildProviderSelector(
      BuildContext context, AsyncValue<LlmProviderType?> selectedProvider) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey<String>('chat-config-section'),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(80),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withAlpha(60),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Row 1: LLM Provider dropdown -- full width
          DropdownButtonFormField<LlmProviderType>(
            key: const ValueKey<String>('chat-provider-dropdown'),
            value: selectedProvider.valueOrNull,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(),
              labelText: 'LLM Provider',
            ),
            items: LlmProviderType.values.map((type) {
              return DropdownMenuItem(
                value: type,
                child: Text(type.displayName,
                    style: const TextStyle(fontSize: 13)),
              );
            }).toList(),
            onChanged: (value) async {
              if (value == null) return;
              final prefs = await ref.read(localStorePreferencesProvider.future);
              await prefs.setString(kSelectedProvider, value.name);
              ref.invalidate(selectedLlmProviderProvider);
            },
          ),
          const SizedBox(height: 8),
          // Row 2: Credential status -- clear, tappable
          _buildCredentialStatus(context, selectedProvider),
        ],
      ),
    );
  }

  Widget _buildCredentialStatus(
      BuildContext context, AsyncValue<LlmProviderType?> selectedProvider) {
    final providerType = selectedProvider.valueOrNull;
    final theme = Theme.of(context);

    if (providerType == null) {
      return GestureDetector(
        key: const ValueKey<String>('chat-api-key-indicator'),
        child: Row(
          children: [
            Icon(Icons.vpn_key_off, size: 16, color: theme.colorScheme.outline),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Select a provider above',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.outline,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    final apiKey = ref.watch(llmApiKeyProvider(providerType));
    return apiKey.when(
      data: (key) {
        final hasKey = key != null && key.isNotEmpty;
        return InkWell(
          key: const ValueKey<String>('chat-api-key-indicator'),
          onTap: () => _showApiKeyDialog(providerType, key),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Row(
              children: [
                Icon(
                  hasKey ? Icons.check_circle : Icons.warning_amber_rounded,
                  size: 16,
                  color: hasKey ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hasKey ? 'API key configured' : 'API key required',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: hasKey ? Colors.green : Colors.orange,
                    ),
                  ),
                ),
                Icon(
                  Icons.edit,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            SizedBox(width: 8),
            Flexible(
              child: Text('Loading...', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
      error: (_, __) => GestureDetector(
        key: const ValueKey<String>('chat-api-key-indicator'),
        onTap: () => _showApiKeyDialog(providerType, null),
        child: const Row(
          children: [
            Icon(Icons.error_outline, size: 16, color: Colors.red),
            SizedBox(width: 8),
            Flexible(
              child: Text(
                'Error loading credentials',
                style: TextStyle(fontSize: 12, color: Colors.red),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showApiKeyDialog(
      LlmProviderType providerType, String? currentKey) async {
    // Capture context before any async gap to satisfy
    // use_build_context_synchronously.
    final navContext = _navigatorContext;

    final keyController = TextEditingController(
      text: currentKey != null && currentKey.isNotEmpty
          ? '\u2022' * 8 // masked dots
          : '',
    );

    // Load current base URL for this provider.
    // Await the future directly so we always get the persisted value even on
    // first open (before the FutureProvider has resolved its cached state).
    final currentBaseUrl =
        await ref.read(llmBaseUrlProvider(providerType).future);

    // Guard: widget or navigator may have been disposed while awaiting.
    if (!mounted || !navContext.mounted) return;

    final urlController = TextEditingController(text: currentBaseUrl ?? '');

    final supportsBaseUrl = providerType == LlmProviderType.claude ||
        providerType == LlmProviderType.openai;

    final defaultUrl = providerType == LlmProviderType.claude
        ? 'https://api.anthropic.com'
        : providerType == LlmProviderType.openai
            ? 'https://api.openai.com/v1'
            : '';

    showDialog(
      context: navContext,
      useRootNavigator: true,
      builder: (dialogContext) {
        return StandardDialogFrame(
          title: '${providerType.displayName} settings',
          icon: Icons.key,
          showClose: false,
          actions: [
            PaneAction(
              label: 'Cancel',
              buttonKey: const ValueKey<String>('chat-api-key-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            PaneAction.primary(
              label: 'Save',
              buttonKey: const ValueKey<String>('chat-api-key-save'),
              onPressed: () async {
                final prefs = await ref.read(localStorePreferencesProvider.future);

                final newKey = keyController.text.trim();
                if (newKey.isNotEmpty && !newKey.contains('\u2022')) {
                  final prefKey = switch (providerType) {
                    LlmProviderType.claude => kClaudeApiKey,
                    LlmProviderType.openai => kOpenAiApiKey,
                    LlmProviderType.gemini => kGeminiApiKey,
                  };
                  await prefs.setString(prefKey, newKey, secret: true);
                  ref.invalidate(llmApiKeyProvider(providerType));
                }

                // Save base URL if supported
                var sanitizedUrl = '';
                if (supportsBaseUrl) {
                  sanitizedUrl = urlController.text.trim();
                  // Strip common path suffixes that the SDK appends
                  // automatically, preventing doubled paths like
                  // http://host/v1/messages/v1/messages
                  for (final suffix in [
                    '/v1/messages',
                    '/v1/chat/completions',
                    '/v1',
                  ]) {
                    if (sanitizedUrl.endsWith(suffix)) {
                      sanitizedUrl = sanitizedUrl.substring(
                          0, sanitizedUrl.length - suffix.length);
                      break; // Stop after first match to avoid double-stripping
                    }
                  }
                  // Strip trailing slash
                  while (sanitizedUrl.endsWith('/')) {
                    sanitizedUrl =
                        sanitizedUrl.substring(0, sanitizedUrl.length - 1);
                  }
                  final urlPrefKey = providerType == LlmProviderType.claude
                      ? kClaudeBaseUrl
                      : kOpenAiBaseUrl;
                  if (sanitizedUrl.isEmpty) {
                    await prefs.remove(urlPrefKey);
                  } else {
                    await prefs.setString(urlPrefKey, sanitizedUrl);
                  }
                  ref.invalidate(llmBaseUrlProvider(providerType));
                }

                // Update the ChatNotifier's LLM provider
                final effectiveKey =
                    (newKey.isNotEmpty && !newKey.contains('\u2022'))
                        ? newKey
                        : currentKey;
                final effectiveUrl = supportsBaseUrl
                    ? (sanitizedUrl.isEmpty ? null : sanitizedUrl)
                    : null;
                final provider = createLlmProvider(providerType, effectiveKey,
                    baseUrl: effectiveUrl);
                if (provider != null) {
                  ref.read(chatProvider.notifier).setLlmProvider(provider);
                }

                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey<String>('chat-api-key-field'),
                controller: keyController,
                obscureText: true,
                decoration: InputDecoration(
                  hintText: 'Enter your ${providerType.displayName} API key',
                  labelText: 'API Key',
                  border: const OutlineInputBorder(),
                ),
                onTap: () {
                  // Clear masked placeholder on first tap
                  if (keyController.text.contains('\u2022')) {
                    keyController.clear();
                  }
                },
              ),
              if (supportsBaseUrl) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey<String>('chat-base-url-field'),
                  controller: urlController,
                  decoration: InputDecoration(
                    hintText: 'Default ($defaultUrl)',
                    labelText: 'Endpoint URL (optional)',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildMessageList(BuildContext context, List<ChatMessage> messages) {
    // Filter out system messages from display
    final displayMessages =
        messages.where((m) => m.role != ChatRole.system).toList();

    if (displayMessages.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                'Ask the AI copilot a question about your system',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              ChatSkillChips(
                onSkillTapped: (prompt) {
                  _textController.text = prompt;
                  _textController.selection = TextSelection.fromPosition(
                    TextPosition(offset: _textController.text.length),
                  );
                },
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: displayMessages.length,
      itemBuilder: (context, index) {
        return MessageBubble(message: displayMessages[index]);
      },
    );
  }

  Widget _buildToolProgress(
      BuildContext context, List<ToolProgress> toolProgressList) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: toolProgressList.map((tp) {
          final isRunning = tp.status == 'Running...';
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                if (isRunning)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (tp.status == 'Done')
                  const Icon(Icons.check_circle, size: 14, color: Colors.green)
                else
                  const Icon(Icons.error, size: 14, color: Colors.red),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${tp.name}: ${tp.status}',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildErrorBanner(BuildContext context, String errorText) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Row(
        children: [
          Icon(Icons.warning,
              size: 16, color: Theme.of(context).colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              errorText,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(BuildContext context, ChatStatus status) {
    final isProcessing = status == ChatStatus.processing;
    final pendingAttachments = ref.watch(pendingAttachmentsProvider);

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Attachment chips (shown when files are attached)
          if (pendingAttachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (var i = 0; i < pendingAttachments.length; i++)
                    Chip(
                      key: ValueKey<String>('chat-attachment-chip-$i'),
                      avatar: const Icon(Icons.picture_as_pdf, size: 16),
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(
                          pendingAttachments[i].filename,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      onDeleted: () {
                        final updated =
                            List<ChatAttachment>.from(pendingAttachments)
                              ..removeAt(i);
                        ref.read(pendingAttachmentsProvider.notifier).state =
                            updated;
                      },
                      deleteIcon: const Icon(Icons.close, size: 16),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
          // Input row: attach button + text field + send button
          Row(
            children: [
              IconButton(
                key: const ValueKey<String>('chat-attach-button'),
                icon: const Icon(Icons.attach_file),
                onPressed: isProcessing ? null : _pickAttachment,
                tooltip: 'Attach PDF',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                iconSize: 22,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: TextField(
                  key: const ValueKey<String>('chat-message-input'),
                  controller: _textController,
                  focusNode: _inputFocusNode,
                  readOnly: isProcessing,
                  decoration: const InputDecoration(
                    hintText: 'Ask about your system...',
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 6,
                  minLines: 1,
                  textInputAction: TextInputAction.newline,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: const ValueKey<String>('chat-send-button'),
                onPressed: isProcessing ? null : _sendMessage,
                icon: isProcessing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                tooltip: null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Opens a file picker for PDF files and adds the selected file to
  /// [pendingAttachmentsProvider].
  Future<void> _pickAttachment() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        allowMultiple: false,
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      Uint8List? bytes = file.bytes;

      // On desktop, bytes may be null even with withData: true.
      // Fall back to reading from the file path.
      if (bytes == null && file.path != null) {
        bytes = await io.File(file.path!).readAsBytes();
      }

      if (bytes == null || bytes.isEmpty) return;

      final attachment = ChatAttachment(
        bytes: bytes,
        filename: file.name,
        mimeType: 'application/pdf',
      );

      final current = ref.read(pendingAttachmentsProvider);
      ref.read(pendingAttachmentsProvider.notifier).state = [
        ...current,
        attachment,
      ];
    } catch (e) {
      io.stderr.writeln('ChatWidget._pickAttachment: $e');
    }
  }

  /// Builds a small context indicator chip when a context block is attached.
  ///
  /// Shows the context type icon, a short label, and an X button to clear.
  /// Hidden when no context is attached.
  Widget _buildContextChip(BuildContext context) {
    final chatContext = ref.watch(chatContextProvider);
    if (chatContext == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final icon = switch (chatContext.type) {
      ChatContextType.alarm => Icons.alarm,
      ChatContextType.asset => Icons.memory,
      ChatContextType.page => Icons.dashboard,
      ChatContextType.general => Icons.attach_file,
    };
    final typeLabel = switch (chatContext.type) {
      ChatContextType.alarm => 'Alarm',
      ChatContextType.asset => 'Asset',
      ChatContextType.page => 'Page',
      ChatContextType.general => 'Context',
    };

    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, top: 4),
      child: Row(
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon,
                      size: 14, color: theme.colorScheme.onSecondaryContainer),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      '$typeLabel: ${chatContext.label}',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () {
                      ref.read(chatContextProvider.notifier).state = null;
                    },
                    borderRadius: BorderRadius.circular(10),
                    child: Icon(Icons.close,
                        size: 14,
                        color: theme.colorScheme.onSecondaryContainer),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Handles keyboard events for the chat input field.
  ///
  /// - **Enter** (no Shift): sends the message.
  /// - **Shift+Enter**: inserts a newline at the cursor position.
  ///
  /// Only key-down events are intercepted; key-up and repeat events pass
  /// through so the platform text input continues to work normally.
  KeyEventResult _handleInputKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }

    final isShiftHeld = HardwareKeyboard.instance.isShiftPressed;

    if (isShiftHeld) {
      // Insert a newline at the current cursor position.
      final text = _textController.text;
      final selection = _textController.selection;
      final newText = text.replaceRange(
        selection.start,
        selection.end,
        '\n',
      );
      _textController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: selection.start + 1),
      );
      return KeyEventResult.handled;
    }

    // Plain Enter — send the message (unless currently processing).
    final status = ref.read(chatProvider.select((s) => s.status));
    if (status != ChatStatus.processing) {
      _sendMessage();
    }
    return KeyEventResult.handled;
  }

  void _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    // Check if an LLM provider is configured before sending
    final selectedType = ref.read(selectedLlmProviderProvider).valueOrNull;
    if (selectedType == null) {
      ScaffoldMessenger.of(_navigatorContext).showSnackBar(
        const SnackBar(
          content: Text('Please select an LLM provider first'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final apiKey = await ref.read(llmApiKeyProvider(selectedType).future);
    if (apiKey == null || apiKey.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(_navigatorContext).showSnackBar(
        SnackBar(
          content:
              Text('Please configure your ${selectedType.displayName} API key'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    _textController.clear();

    // Grab pending attachments before clearing
    final attachments = ref.read(pendingAttachmentsProvider);
    final hasAttachments = attachments.isNotEmpty;

    // Clear pending attachments immediately so the UI updates
    if (hasAttachments) {
      ref.read(pendingAttachmentsProvider.notifier).state = [];
    }

    // Combine visible text with hidden context block (if attached)
    final chatContext = ref.read(chatContextProvider);
    final messageToSend =
        chatContext != null ? '$text\n\n${chatContext.contextBlock}' : text;

    // Clear the context after sending
    if (chatContext != null) {
      ref.read(chatContextProvider.notifier).state = null;
    }

    // Send the combined message to the LLM, but the user only sees their text
    // in the message history (ChatNotifier handles message display).
    ref.read(chatProvider.notifier).sendMessage(
          messageToSend,
          attachments: hasAttachments ? attachments : null,
        );

    // Scroll to bottom after a frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }
}
