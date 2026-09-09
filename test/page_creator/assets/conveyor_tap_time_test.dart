/// The phase's acceptance sentence, driven through the real conveyor pane.
///
/// > *A conveyor key locks `p_cfg_ManualFreq` while leaving `p_cmd_JogFwd`
/// > usable by an anonymous session.*
///
/// One key, one template, one pane. The template is spec §7b's `conveyor`
/// example verbatim, the session is anonymous with `operate`, and every
/// assertion is on the fake `StateMan`'s `writes` list — because the claim is
/// about what the PLC hears, not about what a mock was asked.
///
/// Three things have to be true at once and each is asserted separately:
///
///  * the jog reaches `StateMan.write`,
///  * the manual frequency does not, and prompts instead,
///  * `tester.takeException()` is null throughout — nothing is thrown
///    anywhere on the operator's path, which is what separates tap-time
///    elevation from 03-07's safety net.
///
/// The unbound case is asserted too. A conveyor on a station with no
/// templates must behave exactly as it did before this plan: every control
/// writes, nothing renders a lock, and nothing prompts.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/access_denied_prompt.dart';
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/state_man.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// The key the whole phase is argued around: one struct carrying a jog
/// command an operator may issue and a drive frequency they may not set.
const String _key = 'ST101.CN01';

const String _templateName = 'conveyor';

/// Three numbers, all different, so a finder for one setpoint's value can
/// never accidentally match another's.
const double _manualFreq = 37.5;
const double _autoFreq = 45.0;
const double _cleaningFreq = 12.0;

/// Spec §7b's worked example, verbatim: jogging and the fault reset are
/// `operate`, the two frequencies are `setpoints`.
///
/// A resolver already carrying the snapshot, so no test here depends on the
/// loader, the store, or a database.
TagBindingResolver _boundResolver() => TagBindingResolver()
  ..setSnapshot(
    keyToTemplate: const {_key: _templateName},
    templates: {
      _templateName: AccessTemplate(
        name: _templateName,
        rules: const {
          'p_cmd_JogFwd': AccessGroup.operate,
          'p_cmd_JogBwd': AccessGroup.operate,
          'p_cmd_FaultReset': AccessGroup.operate,
          'p_cfg_ManualFreq': AccessGroup.setpoints,
          'p_cfg_AutoFreq': AccessGroup.setpoints,
        },
      ),
    },
  );

/// A station where nobody has bound anything — the shape every conveyor on
/// every panel has today, and which this plan must not change.
TagBindingResolver _unboundResolver() => TagBindingResolver()
  ..setSnapshot(keyToTemplate: const {}, templates: const {});

AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

/// A session that answers one fixed value without standing up the real
/// controller chain (database, preferences, audit sink, inactivity monitor).
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

/// A repository that answers nothing, so `accessRepositoryProvider` never
/// reaches `databaseProvider` and the station keychain.
class _StubRepository extends Fake implements AccessRepository {}

/// Swallows the rows a refusal writes. What they contain is
/// `tag_access_guard_test.dart`'s subject; this file is about the write that
/// did not happen.
class _NullSink implements AuditSink {
  @override
  Future<void> record(AuditRecord entry) async {}
}

/// One write, as the PLC would have received it.
typedef _Write = ({String key, DynamicValue value});

/// Serves one drive struct and records every write.
class _FakeStateMan implements StateMan {
  _FakeStateMan(this.driveKey);

  final String driveKey;
  final List<_Write> writes = [];

  DynamicValue get _struct {
    final dv = DynamicValue();
    dv['p_stat_State'] = 2; // hmis_e.rdy
    dv['p_stat_LastFault'] = 0;
    dv['p_stat_Frequency'] = 0.0;
    dv['p_stat_Current'] = 0.0;
    dv['p_stat_RunMinutes'] = 0;
    dv['p_stat_JogFwd'] = false;
    dv['p_stat_JogBwd'] = false;
    // False, so a jog button latches on one tap rather than writing on press
    // and again on release: the assertion is about how many writes one
    // deliberate command produces.
    dv['p_stat_ManualStopOnRelease'] = false;
    dv['p_cfg_ManualFreq'] = _manualFreq;
    dv['p_cfg_AutoFreq'] = _autoFreq;
    dv['p_cfg_CleaningFreq'] = _cleaningFreq;
    return dv;
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async => key == driveKey
      ? Stream<DynamicValue>.value(_struct)
      : const Stream<DynamicValue>.empty();

  /// The guard resolves before it decides and hands the call straight on when
  /// this throws — a fake that left it to `noSuchMethod` would silently turn
  /// every refusal in this file into a permitted write.
  @override
  String resolveKey(String key) => key;

  @override
  Future<void> write(String key, DynamicValue value) async =>
      writes.add((key: key, value: value));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_FakeStateMan: ${invocation.memberName} not in test scope',
      );
}

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

/// A one-route Beamer shell around a real `BaseScaffold`, which is where
/// `AccessDeniedPrompt` is mounted (`base_scaffold.dart`). The side pane opens
/// into this tree's overlay, so the prompt and the pane are on screen together
/// exactly as they are on a panel.
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
    overrides: overrides,
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

/// Opens the conveyor's pane over [resolver]'s snapshot and returns the fake
/// the pane writes through.
Future<_FakeStateMan> _openPane(
  WidgetTester tester, {
  required TagBindingResolver resolver,
}) async {
  final fake = _FakeStateMan(_key);
  final config = ConveyorConfig(key: _key)
    ..size = const RelativeSize(width: 1.0, height: 1.0);

  await tester.pumpWidget(_shell(
    body: Center(
      child: SizedBox(width: 400, height: 80, child: Conveyor(config)),
    ),
    overrides: [
      // The pane's trend tile resolves the collector, which builds a real
      // Database with periodic timers that outlive the test.
      collectorProvider.overrideWith((ref) async => null),
      stateManProvider.overrideWith((ref) async => fake),
      tagBindingResolverProvider.overrideWith((ref) => resolver),
      // The loader is what `tagAccessProvider` watches. It must answer without
      // a database; the snapshot is already in the resolver.
      accessTemplatesProvider
          .overrideWith((ref) async => const <AccessTemplate>[]),
      accessSessionProvider.overrideWith(() => _FixedSession(_anonymous())),
      accessRepositoryProvider.overrideWith((ref) async => _StubRepository()),
      auditSinkProvider.overrideWith((ref) async => _NullSink()),
      stationNameProvider.overrideWithValue('test-station'),
    ],
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(Conveyor));
  await _settlePane(tester);
  return fake;
}

/// Advances past the pane's slide-in without waiting for the trend spinner,
/// which never settles under a fake `StateMan`.
Future<void> _settlePane(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// The locked frequency field's value, as rendered by `SetpointField`.
final Finder _lockedManualFreq =
    find.byKey(const Key('manual_freq_field_locked_value'));

/// The editable frequency field.
final Finder _editableManualFreq = find.byKey(const Key('manual_freq_field'));

void main() {
  // A real station is a 1080p panel. The default 800x600 surface puts the
  // pane's pinned action bar on top of the controls, and taps aimed at a jog
  // button land on 'Fault reset' instead.
  setUp(() {
    _registerAppMenu();
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
    view.devicePixelRatio = 1.0;
    view.physicalSize = const Size(1200, 1400);
  });

  tearDown(() {
    closeSidePane();
    RouteRegistry().menuItems.clear();
    TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!
        .resetPhysicalSize();
  });

  group('one key, two permissions', () {
    testWidgets(
        'an anonymous session jogs the belt and is refused the manual '
        'frequency', (tester) async {
      final fake = await _openPane(tester, resolver: _boundResolver());

      // `p_cmd_JogFwd -> operate`, and the session holds `operate`.
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await _settlePane(tester);

      expect(fake.writes, hasLength(1));
      expect(fake.writes.single.key, _key);
      expect(fake.writes.single.value['p_cmd_JogFwd'].asBool, isTrue);
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing,
          reason: 'an open member must not prompt');

      // `p_cfg_ManualFreq -> setpoints`, and the session does not hold it. The
      // field is locked, so there is no cursor to type into: the tap is the
      // whole gesture.
      expect(_lockedManualFreq, findsOneWidget);
      await tester.tap(_lockedManualFreq);
      await _settlePane(tester);

      expect(fake.writes, hasLength(1),
          reason: 'the refused change must never reach StateMan.write');
      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.text(kAccessDeniedGroupNote(AccessGroup.setpoints)),
          findsOneWidget);
      expect(find.text(kAccessDeniedItemNote(_key)), findsOneWidget);
    });

    testWidgets('the locked frequency field still shows its value',
        (tester) async {
      await _openPane(tester, resolver: _boundResolver());

      // The number is legible under the lock — not blanked, not greyed out of
      // existence, and not replaced by the word "Locked".
      expect(_lockedManualFreq, findsOneWidget);
      expect(tester.widget<Text>(_lockedManualFreq).data,
          _manualFreq.toStringAsFixed(2));
      expect(_editableManualFreq, findsNothing,
          reason: 'a locked field is not an editable one with a flag set');
    });

    testWidgets('nothing is thrown anywhere on the operator path',
        (tester) async {
      final fake = await _openPane(tester, resolver: _boundResolver());

      await tester.tap(find.byIcon(Icons.arrow_forward));
      await _settlePane(tester);
      await tester.tap(_lockedManualFreq);
      await _settlePane(tester);

      // The difference between this and 03-07's safety net, stated as an
      // assertion: the refusal never became an exception at all.
      expect(tester.takeException(), isNull);
      expect(fake.writes, hasLength(1));
    });

    testWidgets('the open members are not locked either', (tester) async {
      await _openPane(tester, resolver: _boundResolver());

      // `p_cfg_CleaningFreq` is a member the §7b template does not mention,
      // and the template carries no whole-key row — so it is unrestricted and
      // must render as an ordinary field.
      expect(find.byKey(const Key('cleaning_freq_field')), findsOneWidget);
      // `p_cfg_AutoFreq -> setpoints` is locked by the same rule as the manual
      // frequency, so the two lock together and the one comparison cannot pass
      // on a pane that locked everything.
      expect(find.byKey(const Key('auto_freq_field_locked_value')),
          findsOneWidget);
    });
  });

  group('with nothing bound', () {
    testWidgets('every control writes as before and nothing prompts',
        (tester) async {
      final fake = await _openPane(tester, resolver: _unboundResolver());

      await tester.tap(find.byIcon(Icons.arrow_forward));
      await _settlePane(tester);

      expect(_lockedManualFreq, findsNothing);
      expect(_editableManualFreq, findsOneWidget);

      await tester.enterText(_editableManualFreq, '41.00');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settlePane(tester);

      expect(fake.writes, hasLength(2));
      expect(fake.writes.first.value['p_cmd_JogFwd'].asBool, isTrue);
      expect(fake.writes.last.value['p_cfg_ManualFreq'].asDouble, 41.0);
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
