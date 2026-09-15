/// [ChatContext] and [ChatContextType], on their own for the reason given in
/// `ai_menu_item.dart`: they are pure data the page editor names, and their
/// home `chat_overlay.dart` pulls in the whole chat stack.
library;

/// Holds hidden context data that is attached to the next message sent.
///
/// The context block is never shown in the TextField. Instead, a small
/// [ChatContextChip] indicator is displayed above the input area. When the
/// user presses send, the visible text + context block are combined
/// automatically. After sending, this provider is reset to null.
class ChatContext {
  /// Short human-readable label shown in the context chip.
  /// e.g., "Alarm: Motor Overcurrent Protection" or "Asset: pump3.speed".
  final String label;

  /// The context type used for the chip icon (alarm, asset, page, etc.).
  final ChatContextType type;

  /// The full context block appended to the message on send.
  /// Contains the `[ALARM CONTEXT ...]` or `[ASSET CONTEXT ...]` block.
  final String contextBlock;

  const ChatContext({
    required this.label,
    required this.type,
    required this.contextBlock,
  });
}

/// Types of attached context, used to pick the right icon for the chip.
enum ChatContextType {
  alarm,
  asset,
  page,
  general,
}
