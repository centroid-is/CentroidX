// Chat availability is a **compile-time** question in this repository:
// `kChatEnabled` is `bool.fromEnvironment('CENTROIDX_CHAT', defaultValue: true)`
// and nothing else decides it — no access group, no ambient environment
// variable.
//
// Until phase 07 this file gated seven tests on an environment variable that CI
// never sets, so CI ran the four "chat is unavailable" tests and had **never
// once executed** the three that exercise the real flow. No test in this file
// may read process state for any reason.
//
// The only `skip:` left is `skip: kChatEnabled`, on the two tests that describe
// a build compiled with `--dart-define=CENTROIDX_CHAT=false`. Note the
// inversion: `skip:` takes *when to skip*, so "runs only when chat is compiled
// out" is written `skip: kChatEnabled`. Those two are dead weight in a normal
// CI run and load-bearing as a smoke test for the shipped, flag-off binary.
//
// `dart:io` survives only for `File` and `Directory` in the source assertions
// at the bottom of the file; nothing here touches the process environment.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/chat/ai_context_action.dart';
import 'package:tfc/chat/chat_overlay.dart';
import 'package:tfc/core/feature_flags.dart';
import 'package:tfc/llm/conversation_models.dart';
import 'package:tfc/llm/llm_models.dart';
import 'package:tfc/providers/chat.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/interface.dart';

// ─── Fakes ──────────────────────────────────────────────────────────────

class _FakeSecureStorage implements MySecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> write({required String key, required String value}) async {
    _store[key] = value;
  }

  @override
  Future<String?> read({required String key}) async => _store[key];

  @override
  Future<void> delete({required String key}) async {
    _store.remove(key);
  }
}

Preferences _createTestPreferences() {
  return Preferences(database: null, secureStorage: _FakeSecureStorage());
}

/// A mock ChatNotifier that tracks newConversation and sendMessage calls
/// without requiring a real LLM provider or MCP bridge.
class _TrackingChatNotifier extends ChatNotifier {
  int newConversationCalls = 0;
  final List<String> sentMessages = [];

  @override
  Future<void> newConversation() async {
    newConversationCalls++;
    // Simulate creating a new conversation by updating state
    final conv = ConversationMeta(
      id: ConversationMeta.generateId(),
      title: 'New conversation',
      createdAt: DateTime.now(),
    );
    state = state.copyWith(
      conversations: [conv, ...state.conversations],
      activeConversationId: conv.id,
      messages: const [],
      status: ChatStatus.idle,
      toolProgress: const [],
    );
  }

  @override
  Future<void> sendMessage(String text,
      {Set<String>? toolFilter, List<ChatAttachment>? attachments}) async {
    sentMessages.add(text);
    // Add message to state so we can verify it was added
    final messages = List<ChatMessage>.from(state.messages);
    messages.add(ChatMessage.user(text));
    state = state.copyWith(
      messages: List.unmodifiable(messages),
    );
  }
}

// ─── Test helpers ────────────────────────────────────────────────────────

/// Wraps a child in a ProviderScope with tracking notifier and preferences.
Widget _wrapWithTracking({
  required _TrackingChatNotifier notifier,
  required Widget child,
}) {
  return ProviderScope(
    overrides: [
      preferencesProvider.overrideWith((_) async => _createTestPreferences()),
      chatProvider.overrideWith(() => notifier),
    ],
    child: MaterialApp(
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  setUp(Preferences.clearSecretCache);
  // Resolve the project root directory.
  final cwd = Directory.current.path;
  final projectRoot =
      cwd.endsWith('centroid-hmi') ? Directory.current.parent.path : cwd;

  String projectFile(String relativePath) => '$projectRoot/$relativePath';

  group('AiMenuItem', () {
    test('has correct default values', () {
      const item = AiMenuItem(
        label: 'Test',
        prefillText: 'Hello',
      );
      expect(item.label, 'Test');
      expect(item.prefillText, 'Hello');
      expect(item.icon, Icons.auto_awesome);
      expect(item.sendImmediately, false);
    });

    test('sendImmediately can be set to true', () {
      const item = AiMenuItem(
        label: 'Debug',
        prefillText: 'Debug this',
        sendImmediately: true,
        icon: Icons.bug_report,
      );
      expect(item.sendImmediately, true);
      expect(item.icon, Icons.bug_report);
    });
  });

  group('AiContextAction.openChat', () {
    testWidgets(
      'creates new conversation and sets prefill text',
      (tester) async {
        final notifier = _TrackingChatNotifier();
        bool chatOpened = false;
        String? prefillText;

        await tester.pumpWidget(
          _wrapWithTracking(
            notifier: notifier,
            child: Consumer(
              builder: (context, ref, _) {
                chatOpened = ref.watch(chatVisibleProvider);
                prefillText = ref.watch(chatPrefillProvider);
                return ElevatedButton(
                  onPressed: () {
                    AiContextAction.openChat(
                      ref: ref,
                      prefillText:
                          'Create an alarm that monitors pump pressure',
                    );
                  },
                  child: const Text('Open Chat'),
                );
              },
            ),
          ),
        );

        // Initially chat is not visible
        expect(chatOpened, false);
        expect(prefillText, null);

        // Tap the button
        await tester.tap(find.text('Open Chat'));
        await tester.pumpAndSettle();

        // Verify new conversation was created
        expect(notifier.newConversationCalls, 1);

        // Verify prefill text was set
        expect(prefillText, 'Create an alarm that monitors pump pressure');

        // Verify chat was opened
        expect(chatOpened, true);

        // Verify NO message was sent (prefill only)
        expect(notifier.sentMessages, isEmpty);
      },
    );

    // Kept, and it only runs in a flag-off build. `openChat` is the one of the
    // four entry points whose return value a caller actually branches on —
    // `debugAsset` in `lib/chat/asset_context_menu.dart` does `if (!opened)
    // return;` before it spends anything gathering context. That contract is
    // worth a test even though every UI path into it is separately guarded by
    // `kChatEnabled`.
    testWidgets(
      'returns false, and creates nothing, in a chat-flag-off build',
      skip: kChatEnabled,
      (tester) async {
        final notifier = _TrackingChatNotifier();
        bool? result;

        await tester.pumpWidget(
          _wrapWithTracking(
            notifier: notifier,
            child: Consumer(
              builder: (context, ref, _) {
                return ElevatedButton(
                  onPressed: () async {
                    result = await AiContextAction.openChat(
                      ref: ref,
                      prefillText: 'test',
                    );
                  },
                  child: const Text('Try Open'),
                );
              },
            ),
          ),
        );

        await tester.tap(find.text('Try Open'));
        await tester.pumpAndSettle();

        expect(result, false);
        expect(notifier.newConversationCalls, 0);
      },
    );
  });

  group('AiContextAction.openChatAndSend', () {
    testWidgets(
      'creates new conversation and sends message immediately',
      (tester) async {
        final notifier = _TrackingChatNotifier();

        await tester.pumpWidget(
          _wrapWithTracking(
            notifier: notifier,
            child: Consumer(
              builder: (context, ref, _) {
                return ElevatedButton(
                  onPressed: () {
                    AiContextAction.openChatAndSend(
                      ref: ref,
                      message: 'Debug asset: pump3.speed',
                    );
                  },
                  child: const Text('Send'),
                );
              },
            ),
          ),
        );

        await tester.tap(find.text('Send'));
        await tester.pumpAndSettle();

        // Verify new conversation was created BEFORE sending
        expect(notifier.newConversationCalls, 1);

        // Verify message was sent (not just prefilled)
        expect(notifier.sentMessages, ['Debug asset: pump3.speed']);
      },
    );

    // A companion "returns false when MCP is not available" test was deleted
    // here. It asserted the return value of `openChatAndSend`, and every one of
    // its five call sites — `plc_detail_panel.dart:541` and `:768`,
    // `tech_doc_library_section.dart:527` and `:1087`, `page_editor.dart:3566` —
    // discards that value without even awaiting it. All it proved was that the
    // ambient gate closed, and that gate no longer exists.
  });

  group('AiContextAction.showMenuAndChat', () {
    // A "returns false when MCP is not available" test was deleted here. Its
    // whole content — `showMenuAndChat` takes an early `return false` and shows
    // no menu — is already asserted, on a condition that still exists, by the
    // empty-menuItems test below. What it added over that one was the ambient
    // gate, and nothing else.
    testWidgets('returns false when menuItems is empty', (tester) async {
      final notifier = _TrackingChatNotifier();
      bool? result;

      await tester.pumpWidget(
        _wrapWithTracking(
          notifier: notifier,
          child: Consumer(
            builder: (context, ref, _) {
              return ElevatedButton(
                onPressed: () async {
                  result = await AiContextAction.showMenuAndChat(
                    context: context,
                    ref: ref,
                    position: const Offset(100, 100),
                    menuItems: const [],
                  );
                },
                child: const Text('Menu'),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();

      expect(result, false);
    });
  });

  group('AiContextMenuWrapper', () {
    // Kept, and it only runs in a flag-off build. Unlike the three action
    // helpers, this asserts a property of the **widget tree**: the wrapper is
    // transparent rather than merely inert. The child is still rendered and no
    // GestureDetector is interposed, so the child's own gestures still reach
    // it. A flag-off build that swallowed taps would be a broken panel, not a
    // panel without chat.
    testWidgets(
      'renders the child transparently in a chat-flag-off build',
      skip: kChatEnabled,
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                body: const AiContextMenuWrapper(
                  menuItems: [
                    AiMenuItem(label: 'Test', prefillText: 'test'),
                  ],
                  child: Text('Hello'),
                ),
              ),
            ),
          ),
        );

        expect(find.text('Hello'), findsOneWidget);
        // Should NOT have a GestureDetector wrapping the child: the wrapper
        // returns the child directly when chat is compiled out.
        expect(find.byType(GestureDetector), findsNothing);
      },
    );

    testWidgets(
      'wraps child in GestureDetector when chat is compiled in',
      (tester) async {
        final notifier = _TrackingChatNotifier();

        await tester.pumpWidget(
          _wrapWithTracking(
            notifier: notifier,
            child: const AiContextMenuWrapper(
              menuItems: [
                AiMenuItem(label: 'Create alarm', prefillText: 'Create...'),
              ],
              child: Text('Add Button'),
            ),
          ),
        );

        expect(find.text('Add Button'), findsOneWidget);
        expect(find.byType(GestureDetector), findsOneWidget);
      },
    );
  });

  group('Source assertions', () {
    test('ai_context_action.dart uses useRootNavigator: true in showMenu', () {
      final source = File(projectFile('lib/chat/ai_context_action.dart'))
          .readAsStringSync();
      expect(source, contains('useRootNavigator: true'));
    });

    test('ai_context_action.dart uses clipBehavior: Clip.antiAlias', () {
      final source = File(projectFile('lib/chat/ai_context_action.dart'))
          .readAsStringSync();
      expect(source, contains('clipBehavior: Clip.antiAlias'));
    });

    test('openChat awaits newConversation before setting prefill', () {
      // Verify the source code awaits newConversation() before setting prefill
      final source = File(projectFile('lib/chat/ai_context_action.dart'))
          .readAsStringSync();
      final awaitIdx = source
          .indexOf('await ref.read(chatProvider.notifier).newConversation()');
      final prefillIdx = source.indexOf(
          'ref.read(chatPrefillProvider.notifier).state = prefillText');
      expect(awaitIdx, isNot(-1),
          reason: 'openChat must await newConversation()');
      expect(prefillIdx, isNot(-1),
          reason: 'openChat must set chatPrefillProvider');
      expect(awaitIdx, lessThan(prefillIdx),
          reason: 'newConversation() must be awaited before setting prefill');
    });

    test('openChatAndSend awaits newConversation before sending', () {
      final source = File(projectFile('lib/chat/ai_context_action.dart'))
          .readAsStringSync();
      final awaitIdx = source.indexOf('await notifier.newConversation()');
      final sendIdx = source.indexOf('notifier.sendMessage(message)');
      expect(awaitIdx, isNot(-1),
          reason: 'openChatAndSend must await newConversation()');
      expect(sendIdx, isNot(-1),
          reason: 'openChatAndSend must call sendMessage');
      expect(awaitIdx, lessThan(sendIdx),
          reason: 'newConversation() must be awaited before sendMessage');
    });
  });

  group('Bug fix: callers no longer use clear() for new conversations', () {
    test('tech_doc_library_section does not call notifier.clear() for chat',
        () {
      final source =
          File(projectFile('lib/tech_docs/tech_doc_library_section.dart'))
              .readAsStringSync();
      // Should use AiContextAction, not direct notifier.clear()
      expect(source, contains('AiContextAction.openChatAndSend'));
      expect(source.contains('notifier.clear()'), false,
          reason:
              '_chatAboutDocument must not use clear() -- it must create a new conversation');
    });

    test('plc_detail_panel uses AiContextAction instead of direct calls', () {
      final source =
          File(projectFile('lib/plc/plc_detail_panel.dart')).readAsStringSync();
      expect(source, contains('AiContextAction.openChatAndSend'));
      // Should not contain the old pattern of un-awaited newConversation()
      expect(source.contains('notifier.newConversation()'), false,
          reason:
              'Should use AiContextAction which properly awaits newConversation');
    });

    test(
        'asset_context_menu uses AiContextAction.openChat for debugAsset (prefill, not send)',
        () {
      final source = File(projectFile('lib/chat/asset_context_menu.dart'))
          .readAsStringSync();
      expect(source, contains('AiContextAction.openChat'));
      // debugAsset should NOT send immediately — it should prefill and let the
      // user review/edit before sending.
      expect(source.contains('sendDebugAssetMessage'), false,
          reason:
              'Should use AiContextAction, not the removed sendDebugAssetMessage');
    });

    test('alarm.dart uses AiContextMenuWrapper for all AI actions', () {
      final source =
          File(projectFile('lib/widgets/alarm.dart')).readAsStringSync();
      // Should use AiContextMenuWrapper for all three AI actions
      // (create, edit, duplicate)
      expect('AiContextMenuWrapper'.allMatches(source).length,
          greaterThanOrEqualTo(3),
          reason: 'All three alarm AI actions should use AiContextMenuWrapper');
      // Should NOT reference any undefined _show*WithAiMenu methods
      expect(source.contains('_showEditAlarmWithAiMenu'), false);
      expect(source.contains('_showDuplicateAlarmWithAiMenu'), false);
      expect(source.contains('_showCreateAlarmWithAiMenu'), false);
    });

    test('ChatNotifier no longer has sendDebugAssetMessage', () {
      final source =
          File(projectFile('lib/providers/chat.dart')).readAsStringSync();
      expect(source.contains('sendDebugAssetMessage'), false,
          reason: 'sendDebugAssetMessage was moved to AiContextAction');
    });
  });

  group('Refactoring: all callers use centralized utility', () {
    test('all callers reach ai_context_action.dart, directly or by the seam',
        () {
      final files = [
        'lib/widgets/alarm.dart',
        'lib/plc/plc_detail_panel.dart',
        'lib/tech_docs/tech_doc_library_section.dart',
        'lib/chat/asset_context_menu.dart',
      ];
      for (final path in files) {
        final source = File(projectFile(path)).readAsStringSync();
        // Two spellings, one invariant. `editor_ai.dart` is the io/web seam
        // the browser build needs — `providers/chat.dart` reaches `mcp_dart`,
        // which has no web implementation, so the choice has to be made at
        // import time rather than by `kChatEnabled` at runtime — and its io
        // arm re-exports `AiContextAction` and friends from
        // `ai_context_action.dart` unchanged. A caller that goes through it is
        // still using the centralised utility, which is what this group is
        // about; naming only the direct import would make the arm fail on the
        // web seam while the thing it guards is perfectly intact.
        //
        // What is still refused is the old way round, and the arm below is
        // where that lives: reaching `chat_overlay.dart` and
        // `providers/chat.dart` to assemble an AI action by hand.
        expect(
            source.contains('ai_context_action') ||
                source.contains('editor_ai.dart'),
            true,
            reason: '$path must reach ai_context_action.dart, either '
                'directly or through the editor_ai.dart seam');
      }
    });

    test(
        'no caller directly imports both chat_overlay.dart and providers/chat.dart for AI actions',
        () {
      // plc_detail_panel.dart should not need chat_overlay.dart or
      // providers/chat.dart since it delegates everything to AiContextAction
      final plcSource =
          File(projectFile('lib/plc/plc_detail_panel.dart')).readAsStringSync();
      expect(plcSource.contains("import '../chat/chat_overlay.dart'"), false,
          reason:
              'plc_detail_panel should not import chat_overlay directly -- AiContextAction handles it');
      expect(plcSource.contains("import '../providers/chat.dart'"), false,
          reason:
              'plc_detail_panel should not import providers/chat directly -- AiContextAction handles it');
    });
  });
}
