import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/feature_flags.dart';
import '../providers/chat.dart';
import 'chat_overlay.dart';
import 'ai_menu_item.dart';
export 'ai_menu_item.dart';


/// Reusable utility for the "open chat with AI" pattern.
///
/// Encapsulates the full flow: check availability, create a new conversation,
/// set prefill text (or send immediately), and open the chat overlay.
///
/// Usage:
/// ```dart
/// // Pre-fill chat input for user review:
/// AiContextAction.openChat(
///   ref: ref,
///   prefillText: 'Create an alarm that...',
/// );
///
/// // Send immediately (e.g. diagnostic prompt):
/// AiContextAction.openChatAndSend(
///   ref: ref,
///   message: 'Debug asset: pump3.speed ...',
/// );
///
/// // Show a context menu first:
/// AiContextAction.showMenuAndChat(
///   context: context,
///   ref: ref,
///   position: details.globalPosition,
///   menuItems: [
///     AiMenuItem(label: 'Create alarm with AI', prefillText: '...'),
///   ],
/// );
/// ```
class AiContextAction {
  AiContextAction._(); // Prevent instantiation

  /// Opens chat with AI, creating a new conversation and pre-filling the input.
  ///
  /// Returns false if MCP chat is not available (no-op). Returns true if the
  /// chat was opened.
  ///
  /// When [context] is provided, the context block is stored in
  /// [chatContextProvider] (hidden from the TextField) and shown as a small
  /// chip indicator. When the user sends the message, the context is
  /// appended automatically.
  ///
  /// Steps:
  /// 1. Check [kChatEnabled] -- return early if chat is compiled out
  /// 2. Create a NEW conversation via [ChatNotifier.newConversation]
  /// 3. Set [chatPrefillProvider] with the text
  /// 4. Optionally set [chatContextProvider] with hidden context
  /// 5. Open chat overlay via [chatVisibleProvider]
  static Future<bool> openChat({
    required WidgetRef ref,
    required String prefillText,
    ChatContext? context,
  }) async {
    if (!kChatEnabled) return false;

    // IMPORTANT: Set chatVisibleProvider FIRST so the lifecycle listener
    // connects the MCP bridge. Then yield a microtask so loadConversations()
    // can start, and only then create a new conversation. This matches the
    // ordering in openChatAndSend.
    ref.read(chatVisibleProvider.notifier).state = true;
    await Future<void>.delayed(Duration.zero);

    await ref.read(chatProvider.notifier).newConversation();
    ref.read(chatPrefillProvider.notifier).state = prefillText;
    if (context != null) {
      ref.read(chatContextProvider.notifier).state = context;
    }
    return true;
  }

  /// Opens chat with AI, creates a new conversation, and sends the message
  /// immediately (no prefill -- the prompt is sent directly).
  ///
  /// Returns false if MCP chat is not available.
  static Future<bool> openChatAndSend({
    required WidgetRef ref,
    required String message,
  }) async {
    if (!kChatEnabled) return false;

    // IMPORTANT: Set chatVisibleProvider FIRST so the lifecycle listener
    // runs loadConversations() and connects the MCP bridge. Then create
    // a new conversation AFTER, so it doesn't get overwritten by
    // loadConversations() loading stale state from preferences.
    // This ordering is critical after hot restarts where Riverpod state
    // is reset but preferences still hold old conversations.
    ref.read(chatVisibleProvider.notifier).state = true;

    // Give the lifecycle listener a microtask to start loadConversations().
    // We need conversations loaded before newConversation() so it can
    // properly save the current state and create a fresh one.
    await Future<void>.delayed(Duration.zero);

    final notifier = ref.read(chatProvider.notifier);
    await notifier.newConversation();
    // sendMessage is fire-and-forget: it captures state.messages (which is
    // now empty from newConversation) and adds the correct system prompt.
    notifier.sendMessage(message);
    return true;
  }

  /// Shows a context menu at [position] with the given [menuItems], then opens
  /// chat with the selected item's prefill text.
  ///
  /// Returns false if MCP chat is not available (menu is not shown at all).
  /// Returns true if a menu item was selected and chat was opened.
  /// Returns null if the menu was shown but dismissed without selection.
  static Future<bool?> showMenuAndChat({
    required BuildContext context,
    required WidgetRef ref,
    required Offset position,
    required List<AiMenuItem> menuItems,
  }) async {
    if (!kChatEnabled) return false;
    if (menuItems.isEmpty) return false;

    final result = await showMenu<int>(
      context: context,
      useRootNavigator: true,
      clipBehavior: Clip.antiAlias,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        for (var i = 0; i < menuItems.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: ListTile(
              leading: Icon(menuItems[i].icon),
              title: Text(menuItems[i].label),
              dense: true,
            ),
          ),
      ],
    );

    if (result == null) return null;

    return runMenuItem(ref: ref, item: menuItems[result]);
  }

  /// Opens chat for a single [item], as if it had been picked from the menu
  /// shown by [showMenuAndChat].
  ///
  /// Exposed so callers that build their own menu — the page editor mixes AI
  /// actions with plain editing actions in one popup — can dispatch an
  /// [AiMenuItem] without duplicating this logic.
  static Future<bool?> runMenuItem({
    required WidgetRef ref,
    required AiMenuItem item,
  }) async {
    if (item.sendImmediately) {
      return openChatAndSend(ref: ref, message: item.prefillText);
    } else {
      // Build ChatContext from the menu item if it has a context block
      ChatContext? chatContext;
      if (item.contextBlock != null) {
        chatContext = ChatContext(
          label: item.contextLabel ?? item.label,
          type: item.contextType,
          contextBlock: item.contextBlock!,
        );
      }
      return openChat(
        ref: ref,
        prefillText: item.prefillText,
        context: chatContext,
      );
    }
  }
}

/// Wraps a child widget with right-click AI context menu support.
///
/// Only shows the context menu when [kChatEnabled] is true.
/// When the user right-clicks, a popup menu with [menuItems] is shown.
/// Selecting an item opens the chat overlay with a new conversation.
///
/// Usage:
/// ```dart
/// AiContextMenuWrapper(
///   menuItems: [
///     AiMenuItem(label: 'Create alarm with AI', prefillText: '...'),
///   ],
///   child: IconButton(icon: Icon(Icons.add), onPressed: _create),
/// )
/// ```
class AiContextMenuWrapper extends ConsumerWidget {
  /// The child widget to wrap with right-click support.
  final Widget child;

  /// Menu items to show in the context menu.
  final List<AiMenuItem> menuItems;

  const AiContextMenuWrapper({
    super.key,
    required this.child,
    required this.menuItems,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kChatEnabled) return child;

    return GestureDetector(
      onSecondaryTapUp: (details) {
        AiContextAction.showMenuAndChat(
          context: context,
          ref: ref,
          position: details.globalPosition,
          menuItems: menuItems,
        );
      },
      child: child,
    );
  }
}
