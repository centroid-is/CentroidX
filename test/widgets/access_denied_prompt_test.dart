/// The denial prompt: what an operator sees when a write is refused.
///
/// Two halves, matching the two tasks of plan 03-07.
///
///  * The widget itself — that it costs nothing while idle, that a denial
///    produces a lock rather than an error, that one action produces one
///    prompt, and that signing in from it does not repeat the refused write.
///  * The mount in `BaseScaffold`, and the honest count of the write call
///    sites that still let `AccessDenied` past them. The count is derived from
///    the tree here rather than asserted from a comment, so it cannot quietly
///    grow and Phase 4 has a countdown to zero.
library;

import 'dart:async';
import 'dart:io';

import 'package:beamer/beamer.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/button.dart';
import 'package:tfc/page_creator/assets/number.dart';
import 'package:tfc/page_creator/assets/section_button.dart';
import 'package:tfc/page_creator/assets/start_stop_button.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/access_denied_prompt.dart';
import 'package:tfc/widgets/access_sign_in_dialog.dart';
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart' show closeSidePane;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/preferences.dart' show InMemoryPreferences;
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

import '../helpers/path_separators.dart';
import '../helpers/test_helpers.dart';
import 'package:tfc_dart/core/state_man.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// The refusal every test drives, unless it needs a second, different one.
const AccessDenied _denial =
    AccessDenied('ST101.CN01.p_cmd_JogFwd', AccessGroup.force);

/// A second refusal, from a different item and a different group, so a test
/// that asserts the prompt names *this* one cannot pass on the other's copy.
const AccessDenied _otherDenial =
    AccessDenied('ST201.MX02.p_par_Recipe', AccessGroup.setpoints);

/// Counts the taps on the sign-in affordance without standing up a dialog
/// route — the `AccessStatusAction` / `AccessLockedBody` idiom.
class _CountingOpener {
  int calls = 0;

  Future<void> call(BuildContext context, WidgetRef ref) async {
    calls++;
  }
}

/// A session that answers one fixed value. `accessSessionProvider` is
/// overridden in every host below, always: an unoverridden one runs the real
/// controller chain and a frame captured before it settles is `AsyncLoading`,
/// in which `AccessStatusAction` renders nothing at all.
class _FixedSession extends AccessSessionController {
  _FixedSession(this._session);

  final AccessSession _session;

  @override
  Future<AccessSession> build() async => _session;

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.ok;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

/// A repository that answers nothing. Nothing in this file asks it anything;
/// it exists so `accessRepositoryProvider` never reaches `databaseProvider`
/// and the station keychain.
class _StubRepository extends Fake implements AccessRepository {}

AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

/// Overrides every host in this file shares.
List<Override> _accessOverrides({AccessSession? session}) => [
      accessSessionProvider
          .overrideWith(() => _FixedSession(session ?? _anonymous())),
      accessRepositoryProvider.overrideWith((ref) async => _StubRepository()),
      // 17-12: `auditSinkProvider` now consults the transport row
      // (`gatewayConfigProvider` → `localPreferencesProvider`) before it
      // decides which sink to hand back, so the deny-row path these tests
      // exercise would otherwise reach an unmocked SharedPreferences. An
      // in-memory device-local store reads as direct mode.
      localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
    ];

/// What plan 04-10's converted call sites decide from: one key bound to a
/// one-rule template, and somewhere for the refusal's audit row to go.
///
/// The rule is on [kWholeKeyMember] by default, because most of the converted
/// sites these drive — `number.dart`, `start_stop_button.dart`, `button.dart`
/// — write scalar keys and name no member. Pass [member] for the ones that do
/// name one: `section_button.dart` sets a single `p_cmd_*` bit on a struct.
List<Override> _tagOverrides({
  required String key,
  required AccessGroup group,
  String? member,
}) {
  final resolver = TagBindingResolver()
    ..setSnapshot(
      keyToTemplate: {key: 'test-template'},
      templates: {
        'test-template': AccessTemplate(
          name: 'test-template',
          rules: {member ?? kWholeKeyMember: group},
        ),
      },
    );
  return [
    tagBindingResolverProvider.overrideWith((ref) => resolver),
    // The loader is what `tagAccessProvider` watches. It must answer without a
    // database; the snapshot is already in the resolver.
    accessTemplatesProvider.overrideWith((ref) async => const <AccessTemplate>[]),
    auditSinkProvider.overrideWith((ref) async => const NullAuditSink()),
    stationNameProvider.overrideWithValue('test-station'),
  ];
}

/// The prompt under a bare `MaterialApp`, with the denial stream driven by the
/// test and the sign-in opener injected.
Widget _promptHost({
  required Stream<AccessDenied> denials,
  required AccessSignInOpener openSignIn,
  Widget? child,
}) {
  return ProviderScope(
    overrides: [
      ..._accessOverrides(),
      accessDenialsProvider.overrideWithValue(denials),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            AccessDeniedPrompt(openSignIn: openSignIn, child: child),
          ],
        ),
      ),
    ),
  );
}

/// The Phase 1 lesson, copied deliberately: `find.text` passes on a string the
/// painter has clipped to "…will not repeat th…", which is how an ellipsised
/// honesty line shipped past a green assertion. Pin the properties that decide
/// legibility, then check the paragraph really is taller than one line at the
/// width the prompt renders it at.
void _expectWrapsLegibly(WidgetTester tester, Key key, String expected) {
  final text = tester.widget<Text>(find.byKey(key));
  expect(text.data, expected);
  expect(text.maxLines, isNull);
  expect(text.overflow, isNot(TextOverflow.ellipsis));

  final rendered = tester.renderObject<RenderParagraph>(
    find.descendant(of: find.byKey(key), matching: find.byType(RichText)),
  );
  expect(
    rendered.size.height,
    greaterThan(rendered.preferredLineHeight),
    reason: 'the line must wrap onto more than one line at the real width',
  );
}

// ---------------------------------------------------------------------------
// Task 1 — the widget
// ---------------------------------------------------------------------------

void main() {
  group('idle cost', () {
    testWidgets('renders nothing at all before any write is refused',
        (tester) async {
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: _CountingOpener().call,
      ));
      await tester.pumpAndSettle();

      // Not merely "no text found": the render object occupies no pixels, so
      // the four Phase 2 goldens containing a BaseScaffold cannot move.
      expect(tester.getSize(find.byType(AccessDeniedPrompt)), Size.zero);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing);

      // And nothing that paints, pads or elevates sits inside it either.
      expect(
        find.descendant(
          of: find.byType(AccessDeniedPrompt),
          matching: find.byWidgetPredicate((w) => w is! SizedBox),
        ),
        findsNothing,
      );
    });

    testWidgets('wrapping a page adds no render object of its own',
        (tester) async {
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: _CountingOpener().call,
        child: const SizedBox(key: Key('page'), width: 111, height: 47),
      ));
      await tester.pumpAndSettle();

      // The mount form used by BaseScaffold contributes NO render object,
      // which is a stronger statement than Size.zero: there is nothing in the
      // layout for a golden to shift against.
      expect(
        tester.renderObject(find.byType(AccessDeniedPrompt)),
        same(tester.renderObject(find.byKey(const Key('page')))),
      );
      expect(
          tester.getSize(find.byType(AccessDeniedPrompt)), const Size(111, 47));
    });
  });

  group('the prompt a refused write produces', () {
    testWidgets('names the item that was refused and the permission needed',
        (tester) async {
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: _CountingOpener().call,
      ));
      await tester.pumpAndSettle();

      denials.add(_denial);
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.text(kAccessDeniedHeadline), findsOneWidget);
      expect(
          find.text(kAccessDeniedGroupNote(_denial.required)), findsOneWidget);
      expect(find.text(kAccessDeniedItemNote(_denial.itemKey)), findsOneWidget);

      // The copy is about *this* refusal, not a generic one: the other
      // fixture's group and item must not appear.
      expect(find.text(kAccessDeniedGroupNote(_otherDenial.required)),
          findsNothing);
      expect(
          find.text(kAccessDeniedItemNote(_otherDenial.itemKey)), findsNothing);
    });

    testWidgets('reads as a lock, not as an error', (tester) async {
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: _CountingOpener().call,
      ));
      await tester.pumpAndSettle();

      denials.add(_denial);
      await tester.pumpAndSettle();

      final scheme = Theme.of(tester.element(find.byKey(kAccessDeniedBodyKey)))
          .colorScheme;

      // A lock glyph, in onSurfaceVariant. NOT HmiStateColors.orange, which
      // means forced/override and — since plan 01-08 — an elevated session; a
      // lock is neither. And never the error colour.
      final lock = tester.widget<Icon>(find.byKey(kAccessDeniedLockKey));
      expect(lock.icon, Icons.lock_outline);
      expect(lock.color, scheme.onSurfaceVariant);

      expect(find.byIcon(Icons.error), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(find.byIcon(Icons.warning_amber), findsNothing);

      // Nothing on the prompt is painted in the error colour.
      final texts = tester.widgetList<Text>(find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Text),
      ));
      for (final text in texts) {
        expect(text.style?.color, isNot(scheme.error));
      }
    });

    testWidgets('never renders the developer exception string', (tester) async {
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: _CountingOpener().call,
      ));
      await tester.pumpAndSettle();

      denials.add(_denial);
      await tester.pumpAndSettle();

      // `AccessDenied.toString()` is a developer string; the prompt's copy is
      // the operator's.
      expect(find.text(_denial.toString()), findsNothing);
      final texts = tester.widgetList<Text>(find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Text),
      ));
      for (final text in texts) {
        expect(text.data ?? '', isNot(contains('AccessDenied')));
        expect(text.data ?? '', isNot(contains('Exception')));
      }
    });

    testWidgets('offers exactly a sign-in and a dismissal — no retry',
        (tester) async {
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: _CountingOpener().call,
      ));
      await tester.pumpAndSettle();

      denials.add(_denial);
      await tester.pumpAndSettle();

      final bar = tester.widget<PaneActionBar>(find.byType(PaneActionBar));
      expect(bar.actions, hasLength(2),
          reason: 'a sign-in and a dismissal, and nothing else');
      expect(
        bar.actions.map((a) => a.buttonKey).toSet(),
        {kAccessDeniedDismissKey, kAccessDeniedSignInKey},
      );

      // There is nobody in this build to request access from, and a retry
      // affordance would re-issue a write the operator did not ask for twice.
      for (final label in const ['Retry', 'Try again', 'Request access']) {
        expect(find.text(label), findsNothing);
      }
      // The header's close button is off, so dismissal has exactly one home.
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byTooltip('Close'),
        ),
        findsNothing,
      );
    });

    testWidgets('says plainly that the change did not happen', (tester) async {
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: _CountingOpener().call,
      ));
      await tester.pumpAndSettle();

      denials.add(_denial);
      await tester.pumpAndSettle();

      expect(find.text(kAccessDeniedNoReplayNote), findsOneWidget);
      // An operator who signs in and walks away believing the jog happened is
      // the failure this sentence prevents, so it has to say both halves.
      expect(kAccessDeniedNoReplayNote, contains('Nothing was changed'));
    });

    testWidgets('the no-replay line wraps rather than ellipsising',
        (tester) async {
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: _CountingOpener().call,
      ));
      await tester.pumpAndSettle();

      denials.add(_denial);
      await tester.pumpAndSettle();

      _expectWrapsLegibly(
          tester, kAccessDeniedNoReplayKey, kAccessDeniedNoReplayNote);
    });

    testWidgets('dismissing returns to the page with nothing changed',
        (tester) async {
      final opener = _CountingOpener();
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: opener.call,
        child: const Text('page-body'),
      ));
      await tester.pumpAndSettle();

      denials.add(_denial);
      await tester.pumpAndSettle();
      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);

      await tester.tap(find.byKey(kAccessDeniedDismissKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsNothing);
      expect(find.text('page-body'), findsOneWidget);
      expect(opener.calls, 0);
    });

    testWidgets('the sign-in action opens the sign-in prompt and dismisses',
        (tester) async {
      final opener = _CountingOpener();
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: opener.call,
      ));
      await tester.pumpAndSettle();

      denials.add(_denial);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kAccessDeniedSignInKey));
      await tester.pumpAndSettle();

      expect(opener.calls, 1);
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing);
    });
  });

  group('one action, one prompt', () {
    testWidgets('four denials from one struct write show exactly one prompt',
        (tester) async {
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: _CountingOpener().call,
      ));
      await tester.pumpAndSettle();

      // One tap on a struct write: the guard produces one denial per member
      // that moved. The operator pressed one button and must see one prompt.
      denials
        ..add(_denial)
        ..add(_denial)
        ..add(_denial)
        ..add(_denial);
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget);
    });

    testWidgets('a later refusal shows a prompt again once the first is gone',
        (tester) async {
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: _CountingOpener().call,
      ));
      await tester.pumpAndSettle();

      denials.add(_denial);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kAccessDeniedDismissKey));
      await tester.pumpAndSettle();

      // Dropping while showing must not latch: the next refusal is a new
      // action and gets its own prompt, naming its own item.
      denials.add(_otherDenial);
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.text(kAccessDeniedItemNote(_otherDenial.itemKey)),
          findsOneWidget);
    });

    testWidgets('a nested prompt does not produce a second prompt',
        (tester) async {
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: _CountingOpener().call,
        child: AccessDeniedPrompt(
          openSignIn: _CountingOpener().call,
          child: const Text('inner-page'),
        ),
      ));
      await tester.pumpAndSettle();

      denials.add(_denial);
      await tester.pumpAndSettle();

      expect(find.byType(AccessDeniedPrompt), findsNWidgets(2));
      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget);
    });
  });

  group('the never-replay rule', () {
    testWidgets(
        'the guarded interface is called exactly once across denial, sign-in '
        'and dismiss', (tester) async {
      // A real GuardedStateMan over a recording inner, with a binding that
      // refuses the key. Nothing holds the attempted write, so the only way
      // this count can reach two is if something re-issued it.
      final inner = _RecordingStateMan();
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);
      final guard = _CountingStateMan(GuardedStateMan(
        inner: inner,
        policy: AccessPolicy(tagBindings: (key, member) => AccessGroup.force),
        session: _anonymous,
        audit: const NullAuditSink(),
        station: 'test-station',
        onDenied: denials.add,
      ));

      final opener = _CountingOpener();
      await tester.pumpWidget(_promptHost(
        denials: denials.stream,
        openSignIn: opener.call,
      ));
      await tester.pumpAndSettle();

      // The refused write, exactly as an asset issues it.
      await expectLater(
        guard.write('ST101.CN01.p_cmd_JogFwd',
            DynamicValue(value: true, typeId: NodeId.boolean)),
        throwsA(isA<AccessDenied>()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);

      await tester.tap(find.byKey(kAccessDeniedSignInKey));
      await tester.pumpAndSettle();
      expect(opener.calls, 1);

      expect(guard.writes, 1,
          reason: 'signing in must not repeat the refused write');
      expect(inner.writes, isEmpty,
          reason: 'the refused write reached nothing');
    });
  });

  group('the source', () {
    test('names no raw Material colour constant', () {
      final source =
          File('lib/widgets/access_denied_prompt.dart').readAsStringSync();
      // Deliberately not a bare `Colors\.` — that also matches
      // `HmiStateColors.`, and a grep that cannot fail is not a gate.
      final raw = RegExp(r'(^|[^A-Za-z])Colors\.', multiLine: true);
      expect(raw.allMatches(source).map((m) => m.group(0)).toList(), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Task 2 — the mount, and the residual
  // -------------------------------------------------------------------------

  group('mounted in the shell', () {
    setUp(_registerAppMenu);
    tearDown(() => RouteRegistry().menuItems.clear());

    testWidgets('BaseScaffold mounts the prompt exactly once', (tester) async {
      await tester.pumpWidget(_shell(
        body: const Text('home-body'),
        overrides: const [],
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AccessDeniedPrompt), findsOneWidget);
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing);
    });

    testWidgets('the mount adds no render object to the page', (tester) async {
      await tester.pumpWidget(_shell(
        body: const SizedBox.expand(child: Text('home-body')),
        overrides: const [],
      ));
      await tester.pumpAndSettle();

      // The zero-pixel budget, mechanically: the prompt's nearest render
      // object IS the body's, so there is nothing in the layout for any
      // Phase 1 or Phase 2 golden to shift against.
      expect(
        tester.renderObject(find.byType(AccessDeniedPrompt)),
        same(tester.renderObject(find.byType(SizedBox).first)),
      );
    });

    testWidgets('a nested BaseScaffold shows one prompt for one denial',
        (tester) async {
      final denials = StreamController<AccessDenied>.broadcast();
      addTearDown(denials.close);

      await tester.pumpWidget(_shell(
        body: const BaseScaffold(title: 'Inner', body: Text('inner-body')),
        overrides: [accessDenialsProvider.overrideWithValue(denials.stream)],
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AccessDeniedPrompt), findsNWidgets(2));

      denials.add(_denial);
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget);
    });
  });

  group('end to end, through a real asset', () {
    setUp(() {
      _registerAppMenu();
      // These cases build a real asset, so a provider reaches DatabaseConfig
      // and asks for secure storage. `SecureStorage.getInstance` falls back to
      // `AwsSecureStorage` on Linux and macOS but throws on Windows, so
      // without this the group passed on two platforms and died on the third
      // for a reason that had nothing to do with access control.
      SecureStorage.setInstance(FakeSecureStorage());
    });
    tearDown(() => RouteRegistry().menuItems.clear());

    testWidgets(
        'a refused start/stop press shows the prompt even though the call '
        'site swallows the exception', (tester) async {
      final inner = _RecordingStateMan()..push('fb/running', false);
      await tester.pumpWidget(_shell(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 80,
            child: StartStopPillButton(StartStopPillButtonConfig(
              runKey: 'cmd/run',
              stopKey: 'cmd/stop',
              runningKey: 'fb/running',
              stoppedKey: 'fb/stopped',
            )),
          ),
        ),
        overrides: [_guardedStateMan(inner)],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(StartStopPillButton).first);
      await tester.pumpAndSettle();

      // The prompt is on screen and the write reached nothing.
      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(
          find.text(kAccessDeniedGroupNote(AccessGroup.force)), findsOneWidget);
      expect(inner.writes, isEmpty);

      // And this is the ordering guarantee, stated as an assertion rather than
      // a comment: `start_stop_button.dart:184` catches every exception and
      // logs it, so nothing here caught `AccessDenied` on the prompt's behalf.
      // The prompt appeared because the guard published to
      // `accessDenialsProvider` BEFORE it threw.
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a refused number write shows the prompt and the exception still '
        'escapes the call site uncaught', (tester) async {
      final inner = _RecordingStateMan()..push('ST101.CN01.p_par_Speed', 12.0);
      final config =
          NumberConfig(key: 'ST101.CN01.p_par_Speed', writable: true);

      await tester.pumpWidget(_shell(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 80,
            child: NumberWidget(config: config),
          ),
        ),
        overrides: [_guardedStateMan(inner)],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(NumberWidget));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '42');
      await tester.pumpAndSettle();

      // `number.dart:473` awaits the write with no `try` anywhere above it, so
      // the refusal leaves the call site as an unhandled **asynchronous**
      // error. `tester.takeException()` cannot see that: it returns errors the
      // Flutter framework reported (build, layout, paint), whereas a zone
      // error from an `onPressed` future fails the test the instant it
      // arrives. Catching it in a guarded zone is what makes the escape an
      // assertion instead of a red test.
      Object? escaped;
      await runZonedGuarded(() async {
        await tester.tap(find.text('Write'));
        await tester.pumpAndSettle();
      }, (error, stack) => escaped = error);

      expect(escaped, isA<AccessDenied>(),
          reason: 'the residual kUncaughtAccessDeniedWriteSites counts');
      expect(tester.takeException(), isNull,
          reason: 'nothing reported it to the framework either');
      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(inner.writes, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Plan 04-10 — the same two assets, refused at the tap instead
  // -------------------------------------------------------------------------
  //
  // The two tests above are 03-07's: they drive the **guard**, which is still
  // underneath and still throws. These two drive the tap-time gate in front of
  // it, with an ordinary unguarded `StateMan` behind — so a write reaching
  // `inner.writes` here means the gate let it through, not that the guard
  // failed to catch it.
  group('refused at the tap, through a real asset', () {
    setUp(_registerAppMenu);
    tearDown(() => RouteRegistry().menuItems.clear());

    testWidgets(
        'a refused number write keeps the typed value and leaves the dialog '
        'open', (tester) async {
      const key = 'ST101.CN01.p_par_Speed';
      final inner = _RecordingStateMan()..push(key, 12.0);

      await tester.pumpWidget(_shell(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 80,
            child: NumberWidget(config: NumberConfig(key: key, writable: true)),
          ),
        ),
        overrides: [
          stateManProvider.overrideWith((ref) async => inner),
          ..._tagOverrides(key: key, group: AccessGroup.setpoints),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(NumberWidget));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '42');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(inner.writes, isEmpty);
      // Nothing was thrown at all — this is the half 03-07's version of this
      // test asserts the opposite of, and the difference is the whole plan.
      expect(tester.takeException(), isNull);

      // The dialog is still up with the operator's number still in it. After
      // signing in they press Enter; they do not type 42 again, and nothing
      // was sent on their behalf while they were away.
      expect(find.byType(TextField), findsWidgets);
      expect(find.text('42'), findsOneWidget);
    });

    testWidgets('a refused start/stop press produces no pulse and prompts',
        (tester) async {
      final inner = _RecordingStateMan()..push('fb/running', false);

      await tester.pumpWidget(_shell(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 80,
            child: StartStopPillButton(StartStopPillButtonConfig(
              runKey: 'cmd/run',
              stopKey: 'cmd/stop',
              runningKey: 'fb/running',
              stoppedKey: 'fb/stopped',
            )),
          ),
        ),
        overrides: [
          stateManProvider.overrideWith((ref) async => inner),
          ..._tagOverrides(key: 'cmd/run', group: AccessGroup.force),
        ],
      ));
      await tester.pumpAndSettle();

      // The run segment by its own icon, not the pill's centre: the centre of
      // a two-segment pill is the boundary between run and stop, and only
      // `cmd/run` is bound here.
      await tester.tap(find.byIcon(FontAwesomeIcons.play.data));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.text(kAccessDeniedGroupNote(AccessGroup.force)),
          findsOneWidget);
      // Both halves of the pulse: neither the press's `true` nor the
      // release's `false` may reach the PLC.
      expect(inner.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });

    // -----------------------------------------------------------------
    // Plan 04-11 — the last two assets, and the ones whose bare `catch (e)`
    // used to swallow the refusal into a log line
    // -----------------------------------------------------------------

    testWidgets('a refused button press writes neither the press nor the '
        'release', (tester) async {
      const key = 'cmd/pulse';
      final inner = _RecordingStateMan();

      await tester.pumpWidget(_shell(
        body: Center(
          child: SizedBox(
            width: 120,
            height: 120,
            child: Button(
                ButtonConfig(key: key, buttonType: ButtonType.circle)),
          ),
        ),
        overrides: [
          stateManProvider.overrideWith((ref) async => inner),
          ..._tagOverrides(key: key, group: AccessGroup.force),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Button));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.text(kAccessDeniedGroupNote(AccessGroup.force)),
          findsOneWidget);
      // Both halves. `onTapUp` writes `false` unconditionally today, so a
      // refused press that only suppressed the rise would still send a lone
      // falling edge to a PLC that never saw it go high.
      expect(inner.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a refused section command names the member it would have set',
        (tester) async {
      const key = 'sec/a';
      final inner = _RecordingStateMan();
      final struct = DynamicValue();
      struct[kSectionStatEnabled] = false;
      struct[kSectionStatCleanEnabled] = false;
      struct[kSectionStatPermissive] = true;
      inner.pushStruct(key, struct);

      // The pane is a full-height strip; on the default surface Run scrolls
      // out from under the pinned action bar.
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => closeSidePane(immediate: true));

      await tester.pumpWidget(_shell(
        body: Center(
          child: SizedBox(
            width: 80,
            height: 80,
            child: SectionButton(
              config: SectionButtonConfig(
                label: 'Before freezers',
                sections: [SectionRef(key: key)],
              ),
            ),
          ),
        ),
        overrides: [
          stateManProvider.overrideWith((ref) async => inner),
          // The member, not the whole key: a section struct carries status
          // bits an operator must keep reading while the command that sets
          // one bit of it is locked.
          ..._tagOverrides(
              key: key, group: AccessGroup.device, member: kSectionCmdStart),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SectionButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('section-run')));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.text(kAccessDeniedGroupNote(AccessGroup.device)),
          findsOneWidget);
      expect(inner.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('the residual, counted', () {
    test('_kHandledWriteSites is non-empty and every path exists', () {
      // An exclusion set that has quietly emptied — a file renamed, a helper
      // moved — would widen the count back out without anything failing. So
      // the set is asserted to have members and the members are asserted to
      // exist, which makes a rename loud.
      expect(_kHandledWriteSites, isNotEmpty);
      for (final path in _kHandledWriteSites) {
        expect(File(path).existsSync(), isTrue,
            reason: '$path is excluded from the count but is not on disk');
      }
    });

    test('kUncaughtAccessDeniedWriteSites matches the tree', () {
      final sites = _stateManWriteSites();

      // The scan and the count are two numbers, and this is where they part.
      // The scan still walks the whole tree, so `isNotEmpty` still has
      // something to find; the count is the **residual** after the handled
      // sites come off. One number cannot be both zero (04-11's target) and
      // non-empty (this guard), which is why the split exists at all.
      expect(sites, isNotEmpty,
          reason: 'a walk that finds nothing would pass vacuously');
      expect(sites.map((s) => s.file), contains('lib/widgets/tag_access_guard.dart'),
          reason: 'the walk must still see the handled helper; an exclusion '
              'that works by the walk missing the file proves nothing');

      expect(
        _unhandledWriteSites().length,
        kUncaughtAccessDeniedWriteSites,
        reason: 'the doc comment beside the constant carries the command that '
            'produced it; re-run it and update both together',
      );
    });

    test('not one of those call sites handles AccessDenied', () {
      // The constant claims these sites do not handle the refusal. That claim
      // is checked, not assumed: no file holding one of them mentions
      // `AccessDenied` at all, so no `on AccessDenied` clause and no
      // `catchError` that inspects the type can be hiding in any of them.
      //
      // Over the **unhandled** set, because `tag_access_guard.dart` mentioning
      // `AccessDenied` is exactly what its handling consists of.
      //
      // **Vacuous since plan 04-11, and left in place on purpose.** The
      // unhandled set is empty, so this iterates nothing and asserts nothing;
      // it re-arms the moment a site comes back. A green run here is not
      // evidence about anything today — the reason string below says so, so
      // that nobody reads the tick as a check that was made.
      final files = _unhandledWriteSites().map((s) => s.file).toSet();
      final handling = <String>[
        for (final file in files)
          if (File(file).readAsStringSync().contains('AccessDenied')) file,
      ];
      expect(handling, isEmpty,
          reason: 'VACUOUS AT ZERO: there are no unhandled sites left, so '
              'this test currently asserts nothing. It re-arms when one '
              'returns, and then means: a site that handles AccessDenied '
              'must come off the count — lower '
              'kUncaughtAccessDeniedWriteSites and say so');
    });

    test('every .write( receiver in lib/ is classified', () {
      // Both directions, the 03-06 idiom. A renamed receiver would otherwise
      // shrink the count silently, and a new non-StateMan `.write(` would
      // inflate it.
      final unclassified = <String>[];
      for (final file in _libDartFiles()) {
        final source = _stripComments(File(file).readAsStringSync());
        for (final match in _writeCall.allMatches(source)) {
          final receiver = match.group(1)!;
          if (_kStateManWriteReceivers.contains(receiver)) continue;
          if (_kOtherWriteReceivers.contains(receiver)) continue;
          unclassified.add('$file: $receiver.write(');
        }
      }
      expect(unclassified, isEmpty,
          reason: 'add the receiver to _kStateManWriteReceivers or to '
              '_kOtherWriteReceivers, and re-derive the count');
    });
  });
}

// ---------------------------------------------------------------------------
// The count's derivation
// ---------------------------------------------------------------------------

/// The receivers that mean a `StateMan`. Every one of them is a variable
/// holding the value of `ref.read(stateManProvider.future)` or the
/// `stateMan` a pane builder hands down.
///
/// `_remote` is the odd one out and belongs here rather than in
/// [_kOtherWriteReceivers]: it is a `StateManApi`, so it is a real plant
/// write, but it is issued from *inside* an implementation rather than by a
/// caller holding a guarded object. See `lib/core/gateway_state_man.dart`'s
/// row in [_kHandledWriteSites] for why that means the refusal is already
/// settled by the time it runs.
const Set<String> _kStateManWriteReceivers = {
  'client',
  'stateMan',
  'sm',
  'widget.stateMan',
  '_remote',
};

/// Every other `.write(` receiver in `lib/`: string buffers, the secure
/// store, and the page editor's in-memory property bindings. Listed rather
/// than filtered by a pattern so a new one fails the classification test
/// instead of quietly joining either side.
///
/// `b` is a `StringBuffer` in `newAssetId()`. `binding` and `slot` are
/// upstream #459's bulk property editor: both write
/// onto an asset's **config object in memory**, which the editor then saves
/// through `PageManager` — a `configure`-classified preference behind a
/// `configure`-gated route. Neither is a plant write and neither reaches a
/// `StateMan`; the check that keeps this honest is that the census reads the
/// receiver name from the source rather than trusting this comment.
const Set<String> _kOtherWriteReceivers = {
  'b',
  // quick/20260908-unify-config-ui: `GatewayConfigSource.write` forwarding
  // onto `BackendConfigApi.write` — the backend's config document over the
  // relay, the same non-plant write as `backendConfig` below. The
  // `administer` check and the audit row live server-side (17-09/17-10).
  '_api',
  // 17-13: `BackendConfigApi.write` on the Server Config page — the backend's
  // config document over the relay, not a plant tag. The `administer` check
  // and the audit row live server-side (17-09/17-10), and the page surfaces
  // the refusal itself; there is no StateMan in this call.
  'backendConfig',
  'binding',
  'buffer',
  'builder',
  'contentBuffer',
  'request',
  'secureStorage',
  'slot',
  '_storage',
  '_legacy',
  // quick/20260908-unify-config-ui: `ConfigSource.write` in the unified
  // editor — the ONE config document, written to this station's preferences
  // (direct) or the backend's file over the relay (gateway). Not a plant
  // tag; the editor surfaces the refusal in its own snackbar.
  'widget.source',
};

/// The files whose `StateMan` `.write(` is **already** resolved and shown.
///
/// **This is not "files we have decided not to count".** It is "files where
/// the refusal is settled before the write is issued and put in front of the
/// operator". A file joins this set by containing that mechanism, never by
/// being inconvenient. Adding an entry without the mechanism is how
/// [kUncaughtAccessDeniedWriteSites] silently stops meaning anything — the
/// same failure the `isNotEmpty` guard one level up exists to prevent.
///
/// Why the split exists at all: plan 04-11 took the unhandled count to
/// **zero**, and a single number that must be both zero and non-empty is a
/// contradiction. So the scan proves the walk still works and the count is the
/// residual. At zero the scan is the half that still means something — it is
/// what would catch a derivation that had quietly stopped finding anything.
///
/// | File | Why its `.write(` is handled |
/// |---|---|
/// | `lib/widgets/tag_access_guard.dart` | `writeTag`'s own call, reached only after `guardTagWrite` has resolved the permission; a refusal there is prompted and recorded rather than thrown, so there is nothing at this site for a caller to let past |
/// | `lib/core/gateway_state_man.dart` | `GatewayStateMan.write`'s call onto the relay client. It sits **below** `GuardedStateMan`, which is what `stateManProvider` returns in gateway mode exactly as it does in direct mode, so the permission is resolved and the audit row written before this line runs. There is no caller here to let a refusal past: the refusal never reaches this frame |
const Set<String> _kHandledWriteSites = {
  'lib/widgets/tag_access_guard.dart',
  'lib/core/gateway_state_man.dart',
};

final RegExp _writeCall = RegExp(r'([A-Za-z_][A-Za-z0-9_.]*)\.write\(');

/// One `StateMan` write call site: the file it is in and the receiver.
class _WriteSite {
  const _WriteSite(this.file, this.receiver);

  final String file;
  final String receiver;
}

/// Separators normalised to `/`. Every path this census compares against —
/// `_kHandledWriteSites`, the reason strings, the doc comment beside the
/// constant — is written with forward slashes, and `listSync` hands back
/// backslashes on Windows. Without this the walk finds the files, matches
/// none of them, and the count silently disagrees with the tree on one
/// platform only.
List<String> _libDartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .map((f) => withForwardSlashes(f.path))
    .where((p) => p.endsWith('.dart'))
    .toList()
  ..sort();

/// Drops comment lines, so a `stateMan.write(...)` quoted inside a doc comment
/// is not counted as a call site. `advantys_stb.dart` has exactly one.
String _stripComments(String source) {
  final withoutBlocks =
      source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutBlocks
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
}

/// The residual: every `StateMan` write site whose refusal is still
/// unresolved. This is what [kUncaughtAccessDeniedWriteSites] counts.
List<_WriteSite> _unhandledWriteSites() => _stateManWriteSites()
    .where((s) => !_kHandledWriteSites.contains(s.file))
    .toList();

List<_WriteSite> _stateManWriteSites() {
  final sites = <_WriteSite>[];
  for (final file in _libDartFiles()) {
    final source = _stripComments(File(file).readAsStringSync());
    for (final match in _writeCall.allMatches(source)) {
      final receiver = match.group(1)!;
      if (!_kStateManWriteReceivers.contains(receiver)) continue;
      sites.add(_WriteSite(file, receiver));
    }
  }
  return sites;
}

// ---------------------------------------------------------------------------
// Harnesses
// ---------------------------------------------------------------------------

/// A `StateMan` that answers subscriptions from a map and records writes.
class _RecordingStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};
  final List<String> writes = [];

  void push(String key, Object value) {
    _streams
        .putIfAbsent(key, () => BehaviorSubject<DynamicValue>())
        .add(DynamicValue(
          value: value,
          typeId: value is bool ? NodeId.boolean : NodeId.double,
        ));
  }

  /// A struct, for the assets whose key is one.
  void pushStruct(String key, DynamicValue value) {
    _streams
        .putIfAbsent(key, () => BehaviorSubject<DynamicValue>())
        .add(value);
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      _streams.putIfAbsent(key, () => BehaviorSubject<DynamicValue>()).stream;

  @override
  Future<DynamicValue> read(String key) async =>
      _streams[key]?.valueOrNull ??
      DynamicValue(value: 0.0, typeId: NodeId.double);

  /// The guard resolves before it checks, and hands the call straight on when
  /// this throws — so a fake that left it to `noSuchMethod` would silently
  /// turn every denial in this file into a permitted write.
  @override
  String resolveKey(String key) => key;

  @override
  Future<void> write(String key, DynamicValue value) async => writes.add(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_RecordingStateMan: ${invocation.memberName} not in test scope',
      );
}

/// Counts calls to the guarded interface, so the never-replay rule is an
/// assertion about what was invoked rather than about what was written.
class _CountingStateMan implements StateMan {
  _CountingStateMan(this._guard);

  final StateMan _guard;
  int writes = 0;

  @override
  Future<void> write(String key, DynamicValue value) {
    writes++;
    return _guard.write(key, value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_CountingStateMan: not in test scope');
}

/// `stateManProvider` answering a real `GuardedStateMan` that refuses every
/// tag and publishes each refusal the way `lib/providers/state_man.dart` does.
Override _guardedStateMan(_RecordingStateMan inner) =>
    stateManProvider.overrideWith((ref) async => GuardedStateMan(
          inner: inner,
          policy: AccessPolicy(tagBindings: (key, member) => AccessGroup.force),
          session: () => _anonymous(),
          audit: const NullAuditSink(),
          station: 'test-station',
          onDenied: (denial) => reportAccessDenial(ref, denial),
        ));

/// The top-level menu `BaseScaffold` renders its navigation bar from.
void _registerAppMenu() {
  final registry = RouteRegistry();
  registry.menuItems.clear();
  registry
      .addMenuItem(const MenuItem(label: 'Home', path: '/', icon: Icons.home));
  // Two, not one: `NavigationBar` asserts `destinations.length >= 2`.
  registry.addMenuItem(const MenuItem(
      label: 'Alarm View', path: '/alarm-view', icon: Icons.alarm));
}

/// A one-route Beamer shell around a real `BaseScaffold`.
///
/// The Beamer wrapper is not optional: `BaseScaffold` calls
/// `context.currentBeamLocation`, so it cannot be pumped without a router
/// above it.
Widget _shell({required Widget body, required List<Override> overrides}) {
  final delegate = BeamerDelegate(
    locationBuilder: RoutesLocationBuilder(routes: {
      '/': (context, state, data) => BeamPage(
            key: const ValueKey('/'),
            title: 'Home',
            child: BaseScaffold(title: 'Home', body: body),
          ),
    }).call,
  );

  return ProviderScope(
    overrides: [..._accessOverrides(), ...overrides],
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}
