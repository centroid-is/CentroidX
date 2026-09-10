import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../llm/conversation_models.dart';
import '../llm/llm_models.dart';
import '../providers/chat.dart';
import '../widgets/resizable_overlay_frame.dart';
import 'chat_widget.dart';
import 'chat_context_types.dart';
export 'chat_context_types.dart';

/// Provider controlling chat overlay visibility.
final chatVisibleProvider = StateProvider<bool>((ref) => false);

/// Provider controlling whether the settings/provider config section is visible.
final chatSettingsVisibleProvider = StateProvider<bool>((ref) => true);

/// Provider for pre-filling the chat message input field.
///
/// When set to a non-null value, the [ChatWidget] picks up the text,
/// populates its [TextEditingController], and resets this provider to null.
/// The user can then review/edit the text before sending.
final chatPrefillProvider = StateProvider<String?>((ref) => null);



/// Provider for the hidden context block attached to the next chat message.
///
/// Set by [AiContextAction.openChat] when an AI action includes a context
/// block. Cleared after the message is sent or when the user dismisses the
/// context chip.
final chatContextProvider = StateProvider<ChatContext?>((ref) => null);

/// Provider holding pending file attachments for the next chat message.
///
/// Managed by the chat input bar: populated when the user picks a PDF via the
/// attach button, cleared after the message is sent. Exposed as a provider
/// (rather than local widget state) so that widget tests can inject
/// attachments without needing to mock the native file picker.
final pendingAttachmentsProvider =
    StateProvider<List<ChatAttachment>>((ref) => []);

/// A floating, draggable, resizable chat overlay window.
///
/// Positioned above the main HMI content (not inside BaseScaffold).
/// Contains the [ChatWidget] with drag and resize functionality.
class ChatOverlay extends ConsumerStatefulWidget {
  const ChatOverlay({super.key});

  @override
  ConsumerState<ChatOverlay> createState() => ChatOverlayState();
}

/// Visible for testing to allow access to position/size.
class ChatOverlayState extends ConsumerState<ChatOverlay> {
  /// Current position of the overlay (top-left corner).
  Offset position = const Offset(-1, -1); // sentinel for uninitialized
  bool _initialized = false;

  /// Current size of the overlay.
  /// Initialized to zero; set to a window-relative size on first build.
  Size size = Size.zero;

  /// Minimum allowed size.
  static const Size minSize = Size(300, 400);

  /// Cached screen size from the latest build, used by gesture handlers.
  Size _screenSize = Size.zero;

  /// Cached content widget — rebuilt only when content dependencies change
  /// (provider state), NOT on position/size changes during drag/resize.
  Widget? _cachedContent;

  /// Clamps [position] so the overlay stays fully within the screen.
  void _clampPosition() {
    final maxX = (_screenSize.width - size.width).clamp(0.0, double.infinity);
    final maxY = (_screenSize.height - size.height).clamp(0.0, double.infinity);
    position = Offset(
      position.dx.clamp(0.0, maxX),
      position.dy.clamp(0.0, maxY),
    );
  }

  @override
  Widget build(BuildContext context) {
    _screenSize = MediaQuery.sizeOf(context);

    // On first build compute size as 30% width × 60% height of the window,
    // clamped to minSize, then position bottom-right with an 80px margin.
    if (!_initialized) {
      final w = (_screenSize.width * 0.30).clamp(minSize.width, double.infinity);
      final h = (_screenSize.height * 0.60).clamp(minSize.height, double.infinity);
      size = Size(w, h);
      position = Offset(
        _screenSize.width - size.width - 80,
        _screenSize.height - size.height - 80,
      );
      _initialized = true;
    }

    // On every build, clamp size so it never exceeds the current window
    // (e.g. after the user resizes the macOS window smaller).
    // Size only shrinks here — it does not grow back automatically.
    const margin = 16.0;
    final maxW = (_screenSize.width - margin).clamp(minSize.width, double.infinity);
    final maxH = (_screenSize.height - margin).clamp(minSize.height, double.infinity);
    final clampedW = size.width.clamp(minSize.width, maxW);
    final clampedH = size.height.clamp(minSize.height, maxH);

    // Early-out: skip state mutation if clamped values match current.
    if (clampedW != size.width || clampedH != size.height) {
      size = Size(clampedW, clampedH);
    }
    // Clamp position so the overlay stays fully on-screen after size change.
    _clampPosition();

    // Cache the content widget so it is reused across position/size-only
    // rebuilds (drag/resize). Flutter's element tree will diff and skip
    // rebuilding the heavy subtree because the widget identity is the same.
    _cachedContent ??= _ChatOverlayContent(key: const ValueKey('chat-content'));

    return Positioned(
      left: position.dx,
      top: position.dy,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: ResizableOverlayFrame(
          position: position,
          size: size,
          minSize: minSize,
          screenSize: _screenSize,
          onResize: (newPosition, newSize) {
            setState(() {
              position = newPosition;
              size = newSize;
            });
          },
          child: RepaintBoundary(
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: Theme.of(context).colorScheme.surface,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                // Navigator wraps the ENTIRE overlay content (title bar +
                // ChatWidget) so that every widget — including
                // PopupMenuButton in the title bar — has a
                // Navigator/Overlay ancestor.  The overlay sits inside
                // MaterialApp.builder, which is *above* the app Navigator.
                child: _cachedContent!,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Called by [_ChatOverlayContent] when the title bar is dragged.
  void handleDrag(Offset delta) {
    setState(() {
      position += delta;
      _clampPosition();
    });
  }

}

/// The heavy content subtree of the chat overlay (Navigator + title bar +
/// ChatWidget). Extracted as a separate [ConsumerWidget] so that
/// position/size-only changes in [ChatOverlayState] (drag, resize, window
/// resize clamping) do NOT rebuild this subtree. Because the widget instance
/// is cached in [ChatOverlayState._cachedContent] with a stable key,
/// Flutter's element tree reuses it across those rebuilds.
///
/// Provider-driven rebuilds (conversation list changes, etc.) still work
/// normally because [ref.watch] triggers rebuilds independently of the parent.
class _ChatOverlayContent extends ConsumerWidget {
  const _ChatOverlayContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HeroControllerScope.none(
      child: Navigator(
        onGenerateRoute: (_) => PageRouteBuilder<void>(
          pageBuilder: (navContext, __, ___) => Column(
            children: [
              _ChatTitleBar(key: const ValueKey('chat-title-bar')),
              const Expanded(child: ChatWidget()),
            ],
          ),
        ),
      ),
    );
  }
}

/// The draggable title bar for [ChatOverlay], extracted so it can independently
/// rebuild when provider state changes without coupling to position/size state.
class _ChatTitleBar extends ConsumerWidget {
  const _ChatTitleBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations =
        ref.watch(chatProvider.select((s) => s.conversations));
    final activeId =
        ref.watch(chatProvider.select((s) => s.activeConversationId));
    final activeConv = conversations.where((c) => c.id == activeId).firstOrNull;
    final title = activeConv?.title ?? 'New conversation';

    return GestureDetector(
      onPanUpdate: (details) {
        context.findAncestorStateOfType<ChatOverlayState>()
            ?.handleDrag(details.delta);
      },
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            Icon(
              Icons.drag_indicator,
              size: 20,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _TitleBarConversationPicker(
                title: title,
                conversations: conversations,
                activeId: activeId,
                onSelect: (id) {
                  ref.read(chatProvider.notifier).switchConversation(id);
                },
                onNew: () {
                  ref.read(chatProvider.notifier).newConversation();
                },
                onDelete: (id) {
                  ref.read(chatProvider.notifier).deleteConversation(id);
                },
              ),
            ),
            PopupMenuButton<String>(
              key: const ValueKey<String>('chat-overflow-menu'),
              clipBehavior: Clip.antiAlias,
              icon: Icon(Icons.more_vert,
                  size: 18,
                  color: Theme.of(context).colorScheme.onPrimaryContainer),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: null,
              onSelected: (value) {
                switch (value) {
                  case 'credentials':
                    ref.read(chatSettingsVisibleProvider.notifier).state =
                        !ref.read(chatSettingsVisibleProvider);
                  case 'clear_all':
                    ref.read(chatProvider.notifier).clearAllConversations();
                }
              },
              itemBuilder: (context) {
                final showingCredentials =
                    ref.read(chatSettingsVisibleProvider);
                return [
                  PopupMenuItem(
                    value: 'credentials',
                    child: Row(
                      children: [
                        Icon(
                          showingCredentials ? Icons.visibility_off : Icons.key,
                          size: 18,
                        ),
                        const SizedBox(width: 12),
                        Text(showingCredentials
                            ? 'Hide Credentials'
                            : 'Show Credentials'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'clear_all',
                    child: Row(
                      children: [
                        Icon(Icons.delete_sweep, size: 18),
                        SizedBox(width: 12),
                        Text('Clear All'),
                      ],
                    ),
                  ),
                ];
              },
            ),
            IconButton(
              key: const ValueKey<String>('chat-close-button'),
              icon: const Icon(Icons.close, size: 18),
              onPressed: () {
                ref.read(chatVisibleProvider.notifier).state = false;
              },
              tooltip: null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// A tappable title-bar element that shows the active conversation title
/// with a dropdown arrow. Tapping opens a popup menu listing all
/// conversations (each with an inline delete button) and a
/// "New Conversation" option at the bottom.
class _TitleBarConversationPicker extends StatelessWidget {
  final String title;
  final List<ConversationMeta> conversations;
  final String? activeId;
  final ValueChanged<String> onSelect;
  final VoidCallback onNew;
  final ValueChanged<String> onDelete;

  const _TitleBarConversationPicker({
    required this.title,
    required this.conversations,
    required this.activeId,
    required this.onSelect,
    required this.onNew,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onPrimaryContainer;

    return PopupMenuButton<String>(
      key: const ValueKey<String>('chat-title-picker'),
      clipBehavior: Clip.antiAlias,
      onSelected: (value) {
        if (value == '__new__') {
          onNew();
        } else {
          onSelect(value);
        }
      },
      offset: const Offset(0, 40),
      constraints: const BoxConstraints(
        minWidth: 200,
        maxWidth: 340,
      ),
      tooltip: null,
      itemBuilder: (context) => [
        ...conversations.map((c) {
          final isActive = c.id == activeId;
          return PopupMenuItem<String>(
            key: ValueKey<String>('chat-conv-item-${c.id}'),
            value: c.id,
            height: 36,
            child: Row(
              children: [
                if (isActive)
                  Icon(Icons.check, size: 14, color: theme.colorScheme.primary)
                else
                  const SizedBox(width: 14),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          isActive ? FontWeight.w600 : FontWeight.normal,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                _InlineDeleteButton(
                  key: ValueKey<String>('chat-delete-conv-${c.id}'),
                  onPressed: () {
                    // Close the popup first, then delete
                    Navigator.of(context).pop();
                    onDelete(c.id);
                  },
                ),
              ],
            ),
          );
        }),
        const PopupMenuDivider(height: 8),
        const PopupMenuItem<String>(
          value: '__new__',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.add, size: 14),
              SizedBox(width: 8),
              Text(
                'New Conversation',
                style: TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: color,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.expand_more, size: 18, color: color),
          ],
        ),
      ),
    );
  }
}

/// A small inline delete (X) button used inside popup menu items.
///
/// Uses an [InkWell] with a [GestureDetector] stop-propagation trick so
/// tapping the X triggers the delete callback without also triggering the
/// parent [PopupMenuItem]'s onTap/value selection.
class _InlineDeleteButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _InlineDeleteButton({
    super.key,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 24,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Icon(
          Icons.close,
          size: 14,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
