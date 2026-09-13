/// The Session card on the access admin page: a read-out, not a knob.
///
/// It used to edit a device-local `access.inactivity_timeout_minutes` and
/// carry a switch that stopped every session on the panel from expiring. The
/// timeout is per account now — set on the users list, beside the account it
/// governs — so what is left here is the sentence that says where it went, and
/// the panel-account read-out that was always the other half of this card.
///
/// The tests for the timeout itself moved with it:
/// `test/pages/access_users_section_test.dart` covers the dialog and the
/// write, and `test/providers/access_session_test.dart` covers what a session
/// does with the value.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/access_session_section.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc_access/tfc_access.dart';

import '../helpers/page_editor_harness.dart' show FakeEditorPreferences;

/// A store whose string reads never answer — the panel account is the only
/// string this card asks for.
class _PendingStringPreferences extends FakeEditorPreferences {
  @override
  Future<String?> getString(String key) => Completer<String?>().future;
}

/// A session controller that answers a release with [result] and counts the
/// calls. Overriding [build] keeps the database, the audit sink and the timer
/// out of a card test.
class _ReleasingSession extends AccessSessionController {
  _ReleasingSession({required this.result});

  final bool result;
  int releaseCalls = 0;

  @override
  Future<AccessSession> build() async =>
      AccessSession.anonymous(const {AccessGroup.operate});

  @override
  Future<bool> releasePanelAccount() async {
    releaseCalls++;
    return result;
  }
}

({Widget app, FakeEditorPreferences prefs}) _shell({String? panelAccount}) {
  final prefs = FakeEditorPreferences();
  if (panelAccount != null) {
    prefs.setString(kAccessPanelAccountPrefKey, panelAccount);
  }
  final app = ProviderScope(
    overrides: [
      localPreferencesProvider.overrideWithValue(prefs),
    ],
    child: const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: AccessSessionSection())),
    ),
  );
  return (app: app, prefs: prefs);
}

void main() {
  testWidgets('says where the timeout is set and what it defaults to',
      (tester) async {
    // The card is what an administrator who remembers the field will look at
    // first, so it has to answer "where did it go?" rather than simply not
    // mention it.
    final shell = _shell();
    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();

    expect(find.byKey(kAccessSessionSectionKey), findsOneWidget);
    expect(find.text(kAccessSessionExplainer), findsOneWidget);
    expect(kAccessSessionExplainer,
        contains('${kDefaultInactivityTimeout.inMinutes} minutes'));
  });

  testWidgets('offers no timeout control of its own', (tester) async {
    // The station-wide knob is gone, not hidden. A field here would be a
    // second answer to a question the users list now owns, and the switch it
    // sat beside made every human session on the panel immortal.
    final shell = _shell();
    await tester.pumpWidget(shell.app);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.byType(Switch), findsNothing);
  });

  group('the panel account read-out', () {
    testWidgets('names the account a committed panel returns to',
        (tester) async {
      final shell = _shell(panelAccount: 'freezer');
      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessSessionPanelAccountKey), findsOneWidget);
      expect(find.text(kAccessSessionPanelCommittedNote('freezer')),
          findsOneWidget,
          reason: 'support asking what this panel comes back as had nowhere '
              'to look — the commitment is device-local and is not the '
              'signed-in identity');
    });

    testWidgets('says so plainly when the panel is committed to nobody',
        (tester) async {
      final shell = _shell();
      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      expect(find.text(kAccessSessionPanelUncommittedNote), findsOneWidget,
          reason: 'a blank where the account would be reads as "not loaded '
              'yet", not as "there is none"');
    });

    testWidgets('an empty stored value is no commitment, not an account '
        'named ""', (tester) async {
      final shell = _shell(panelAccount: '');
      await tester.pumpWidget(shell.app);
      await tester.pumpAndSettle();

      expect(find.text(kAccessSessionPanelUncommittedNote), findsOneWidget,
          reason: 'the same rule the resume applies to a half-written '
              'preference file — one function, so the card and the resume '
              'cannot disagree about it');
    });

    group('Release panel', () {
      Widget releaseShell(_ReleasingSession session) {
        final prefs = FakeEditorPreferences()
          ..setString(kAccessPanelAccountPrefKey, 'panel_a');
        return ProviderScope(
          overrides: [
            localPreferencesProvider.overrideWithValue(prefs),
            accessSessionProvider.overrideWith(() => session),
          ],
          child: const MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(child: AccessSessionSection())),
          ),
        );
      }

      testWidgets('is offered on a committed panel', (tester) async {
        final shell = _shell(panelAccount: 'panel_a');
        await tester.pumpWidget(shell.app);
        await tester.pumpAndSettle();

        expect(find.byKey(kAccessSessionReleasePanelKey), findsOneWidget);
      });

      testWidgets('is not offered when there is nothing to release',
          (tester) async {
        final shell = _shell();
        await tester.pumpWidget(shell.app);
        await tester.pumpAndSettle();

        expect(find.byKey(kAccessSessionReleasePanelKey), findsNothing);
      });

      testWidgets('confirming releases once', (tester) async {
        final session = _ReleasingSession(result: true);
        await tester.pumpWidget(releaseShell(session));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(kAccessSessionReleasePanelKey));
        await tester.pumpAndSettle();
        expect(find.text(kAccessSessionReleaseTitle('panel_a')), findsOneWidget);

        // `.last`: the card's own button carries the same words, and the
        // dialog's confirm is painted above it.
        await tester.tap(find.text(kAccessSessionReleasePanelLabel).last);
        await tester.pumpAndSettle();

        expect(session.releaseCalls, 1);
        expect(find.byKey(kAccessSessionReleaseFailedKey), findsNothing);
      });

      testWidgets('cancelling releases nothing', (tester) async {
        final session = _ReleasingSession(result: true);
        await tester.pumpWidget(releaseShell(session));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(kAccessSessionReleasePanelKey));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(session.releaseCalls, 0);
      });

      testWidgets('a refused release says so', (tester) async {
        final session = _ReleasingSession(result: false);
        await tester.pumpWidget(releaseShell(session));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(kAccessSessionReleasePanelKey));
        await tester.pumpAndSettle();
        // `.last`: the card's own button carries the same words, and the
        // dialog's confirm is painted above it.
        await tester.tap(find.text(kAccessSessionReleasePanelLabel).last);
        await tester.pumpAndSettle();

        expect(find.byKey(kAccessSessionReleaseFailedKey), findsOneWidget);
      });
    });

    testWidgets('claims nothing before the store has answered', (tester) async {
      final prefs = _PendingStringPreferences();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          localPreferencesProvider.overrideWithValue(prefs),
        ],
        child: const MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(child: AccessSessionSection())),
        ),
      ));
      await tester.pump();

      expect(find.byKey(kAccessSessionPanelAccountKey), findsNothing,
          reason: 'the two sentences are opposites, so showing either before '
              'the store has answered is a claim, and a card that briefly '
              'calls a committed panel uncommitted is worse than one that '
              'says nothing');
    });
  });
}
