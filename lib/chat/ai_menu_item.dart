/// [AiMenuItem], on its own so a build without chat can still name it.
///
/// The page editor asks `buildEditorAssetMenuItems` for a list of these and
/// hands them to a menu wrapper. On a web build both of those are stubs — chat
/// is not compiled there — but the *type* still has to resolve, and its home,
/// `ai_context_action.dart`, reaches `providers/chat.dart` and through it
/// `mcp_dart`, which does not compile for the browser. A pure data class costs
/// nothing to keep, so it moves here and both arms of `editor_ai.dart` use the
/// same one rather than two declarations that can drift apart.
library;

import 'package:flutter/material.dart';

import 'chat_context_types.dart';

/// Describes a single item in an AI context menu.
///
/// When the user selects this item, the chat overlay opens with [prefillText]
/// pre-filled in the input field (or sent immediately if [sendImmediately] is
/// true).
///
/// When [contextBlock] is provided, the raw context data is hidden from the
/// user and stored in [chatContextProvider]. The user sees only [prefillText]
/// (a short, human-readable prompt) and a context indicator chip. The context
/// block is appended automatically when the message is sent.
class AiMenuItem {
  /// The label shown in the popup menu.
  final String label;

  /// The text to pre-fill (or send) in the chat input.
  ///
  /// When [contextBlock] is provided, this should be a short, user-friendly
  /// prompt (e.g., "Edit this alarm") rather than the full context dump.
  final String prefillText;

  /// The leading icon for the menu item. Defaults to [Icons.auto_awesome].
  final IconData icon;

  /// When true, the message is sent immediately instead of pre-filling the
  /// input for the user to review. Useful for diagnostic / "debug this asset"
  /// actions where the prompt is fully formed.
  final bool sendImmediately;

  /// Optional hidden context block appended to the message on send.
  ///
  /// Contains structured data like `[ALARM CONTEXT ...]` or
  /// `[ASSET CONTEXT ...]` that the LLM needs but the user should not see
  /// in the text field. Stored in [chatContextProvider] and shown as a
  /// small chip indicator.
  final String? contextBlock;

  /// Short label for the context chip (e.g., "Motor Overcurrent Protection").
  /// Required when [contextBlock] is provided.
  final String? contextLabel;

  /// The type of context, used for chip icon. Defaults to [ChatContextType.general].
  final ChatContextType contextType;

  const AiMenuItem({
    required this.label,
    required this.prefillText,
    this.icon = Icons.auto_awesome,
    this.sendImmediately = false,
    this.contextBlock,
    this.contextLabel,
    this.contextType = ChatContextType.general,
  });
}
