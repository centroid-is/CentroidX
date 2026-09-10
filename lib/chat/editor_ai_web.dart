import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:tfc_dart/core/alarm.dart' show AlarmConfig;

import '../page_creator/assets/common.dart' show Asset;
import 'ai_menu_item.dart';
import 'chat_context_types.dart';

export 'ai_menu_item.dart' show AiMenuItem;

/// The chat entry points, inert.
///
/// Every method answers the same way the real one does when the user dismisses
/// the menu without choosing anything, so the editor's call sites need no
/// `if (kIsWeb)` around them.
class AiContextAction {
  AiContextAction._();

  static Future<bool> openChat({
    required WidgetRef ref,
    required String prefillText,
    ChatContext? context,
  }) async =>
      false;

  static Future<bool> openChatAndSend({
    required WidgetRef ref,
    required String message,
  }) async =>
      false;

  static Future<bool?> showMenuAndChat({
    required BuildContext context,
    required WidgetRef ref,
    required Offset position,
    required List<AiMenuItem> menuItems,
  }) async =>
      null;

  static Future<bool?> runMenuItem({
    required WidgetRef ref,
    required AiMenuItem item,
  }) async =>
      null;
}

/// Passes its child straight through: with no chat there is no menu to open on
/// a right-click, and the real wrapper does exactly this when `kChatEnabled`
/// is false.
class AiContextMenuWrapper extends ConsumerWidget {
  const AiContextMenuWrapper({
    super.key,
    required this.child,
    required this.menuItems,
  });

  final Widget child;
  final List<AiMenuItem> menuItems;

  @override
  Widget build(BuildContext context, WidgetRef ref) => child;
}

/// No AI actions to offer for an asset.
///
/// The editor builds its context menu from this list and its own entries, so
/// an empty list removes the AI section and leaves the rest intact.
List<AiMenuItem> buildEditorAssetMenuItems(Asset asset) => const [];

/// The runtime asset menu, with its one entry — "Debug with AI" — gone.
///
/// The real menu has nothing else in it, so rather than pop an empty sheet
/// this does nothing at all. [onDebug] is accepted and never called.
Future<void> showAssetContextMenu(
  BuildContext context,
  Offset globalPosition,
  VoidCallback onDebug,
) async {}

/// The editor's right-click asset menu, likewise absent.
Future<void> showEditorAssetContextMenu(
  BuildContext context,
  WidgetRef ref,
  Offset globalPosition,
  Asset asset,
) async {}

/// Diagnosing an asset means opening chat with its context attached, and there
/// is no chat here.
Future<void> debugAsset(WidgetRef ref, Asset asset) async {}

/// The alarm's context block, which exists only to be pasted into a chat
/// message. With no chat there is no reader, and an empty block is what the
/// real one produces for an alarm with nothing worth attaching.
String buildAlarmContextBlock(AlarmConfig alarm) => '';

/// The asset's identifier as the context menus label it.
///
/// Kept real rather than stubbed: it is pure string work over the asset's own
/// fields, the menus use it for their titles, and a blank title would be a
/// visible regression rather than an absent feature.
String extractAssetIdentifier(Asset asset) {
  final json = asset.toJson();
  final key = json['key'] as String?;
  if (key != null && key.isNotEmpty) return key;
  final text = asset.text;
  if (text != null && text.isNotEmpty) return text;
  return asset.displayName;
}
