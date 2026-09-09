/// The two force grids, resolved at the tap.
///
/// Forcing an output is the highest-consequence thing an operator can do from
/// a panel, and it is `AccessGroup.force` by the spec's own group table
/// (§1: "forced I/O and overrides"). It is also the place where a control
/// going dead would be worst: a maintenance tech mid-commissioning, in front
/// of a grid of sixteen inert cells with nothing on screen saying why.
///
/// So each grid is asserted twice and in both directions:
///
///  * **unbound** — the station every panel is today. The cell writes exactly
///    the array it wrote before this plan, and nothing prompts.
///  * **bound and unheld** — the cell prompts at the tap, writes nothing,
///    stays on screen, stays hit-testable, and throws nothing anywhere on the
///    operator's path.
///
/// The EL9222 reset is here too, and it is the one write in either file that
/// names a struct member: `p_cmd_Reset`. It is also a pulse, so a refusal has
/// to suppress the falling edge as well — one refused press, one refusal.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/advantys_stb.dart'
    show STBDDI3725Config, STBDDO3705Config;
import 'package:tfc/page_creator/assets/beckhoff.dart'
    show BeckhoffEL9222Config, RowIOView;
import 'package:tfc/page_creator/assets/el9222.dart' show kEl9222ResetPulse;
import 'package:tfc/painter/advantys_stb/ddi3725.dart' show STBDDI3725Widget;
import 'package:tfc/painter/advantys_stb/ddo3705.dart' show STBDDO3705Widget;
import 'package:tfc/painter/beckhoff/io8.dart' show IO8Widget;
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc/widgets/access_denied_prompt.dart';
import 'package:tfc/widgets/panes/side_pane.dart' show closeSidePane;
import 'package:tfc/widgets/panes/standard_dialog.dart' show StandardDialog;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const String _rawKey = 'raw';
const String _forceKey = 'force';
const String _descKey = 'desc';
const String _onFiltersKey = 'on_filters';
const String _offFiltersKey = 'off_filters';
const String _el9222Key = 'ST101.A1.02.state';

const String _template = 'forced-io';

/// A station where the force array is bound at the key level — the shape a
/// commissioning engineer produces when they say "nobody forces this module
/// without the force permission".
///
/// [kWholeKeyMember] rather than a member name, and deliberately: the force
/// array is an `int8[16]`, not a struct. There is no member to name.
TagBindingResolver _boundForceResolver() => TagBindingResolver()
  ..setSnapshot(
    keyToTemplate: const {_forceKey: _template},
    templates: {
      _template: AccessTemplate(
        name: _template,
        rules: const {kWholeKeyMember: AccessGroup.force},
      ),
    },
  );

/// A station where the debounce filters are bound and the force array is not.
///
/// The point of binding only one of the two: an input grid has two kinds of
/// cell writing two different keys, and a blanket edit that got one of them
/// wrong would still pass a test that bound both.
TagBindingResolver _boundFilterResolver() => TagBindingResolver()
  ..setSnapshot(
    keyToTemplate: const {_onFiltersKey: _template},
    templates: {
      _template: AccessTemplate(
        name: _template,
        rules: const {kWholeKeyMember: AccessGroup.device},
      ),
    },
  );

/// The EL9222's reset, bound by the member it actually sets.
TagBindingResolver _boundResetResolver() => TagBindingResolver()
  ..setSnapshot(
    keyToTemplate: const {_el9222Key: _template},
    templates: {
      _template: AccessTemplate(
        name: _template,
        rules: const {'p_cmd_Reset': AccessGroup.force},
      ),
    },
  );

/// A station where nobody has bound anything: the shape every module on every
/// panel has today, and which this plan must not change.
TagBindingResolver _unboundResolver() => TagBindingResolver()
  ..setSnapshot(keyToTemplate: const {}, templates: const {});

/// Holds `operate` and not `force`, so a jog would pass and a force will not.
AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

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

/// Answers nothing, so `accessRepositoryProvider` never reaches
/// `databaseProvider` and the station keychain.
class _StubRepository extends Fake implements AccessRepository {}

/// Swallows the rows a refusal writes. What they contain is
/// `tag_access_guard_test.dart`'s subject; this file is about the write that
/// did not happen.
class _NullSink implements AuditSink {
  @override
  Future<void> record(AuditRecord entry) async {}
}

typedef _Write = ({String key, DynamicValue value});

/// Serves one 16-channel module and records every write.
class _ForceStateMan implements StateMan {
  final List<_Write> writes = [];

  final DynamicValue _rawDv = DynamicValue(value: 0);
  final DynamicValue _forceDv = DynamicValue.fromList(
      List<DynamicValue>.generate(16, (_) => DynamicValue(value: 0)));
  final DynamicValue _descDv = DynamicValue.fromList(List<DynamicValue>.generate(
      16, (i) => DynamicValue(value: 'ch${i + 1}')));
  final DynamicValue _onFiltersDv = DynamicValue.fromList(
      List<DynamicValue>.generate(16, (_) => DynamicValue(value: 0)));
  final DynamicValue _offFiltersDv = DynamicValue.fromList(
      List<DynamicValue>.generate(16, (_) => DynamicValue(value: 0)));

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    switch (key) {
      case _rawKey:
        return Stream<DynamicValue>.value(_rawDv);
      case _forceKey:
        return Stream<DynamicValue>.value(_forceDv);
      case _descKey:
        return Stream<DynamicValue>.value(_descDv);
      case _onFiltersKey:
        return Stream<DynamicValue>.value(_onFiltersDv);
      case _offFiltersKey:
        return Stream<DynamicValue>.value(_offFiltersDv);
      default:
        return const Stream<DynamicValue>.empty();
    }
  }

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
        '_ForceStateMan: ${invocation.memberName} not in test scope',
      );
}

/// Serves the EL9222's one struct and records the levels written to the
/// channel's reset bit — the edge under test.
class _El9222StateMan implements StateMan {
  final List<_Write> writes = [];

  DynamicValue get _struct {
    final dv = DynamicValue();
    dv['p_stat_Enabled'] = false;
    dv['p_stat_Tripped'] = true;
    dv['p_stat_Cool_Down_Lock'] = false;
    dv['p_cmd_Reset'] = false;
    dv['p_stat_Enabled_2'] = true;
    dv['p_stat_Tripped_2'] = false;
    dv['p_stat_Cool_Down_Lock_2'] = false;
    dv['p_cmd_Reset_2'] = false;
    return dv;
  }

  /// The levels written to `p_cmd_Reset`, in order.
  List<bool> get resetLevels => [
        for (final w in writes)
          if (w.value.contains('p_cmd_Reset')) w.value['p_cmd_Reset'].asBool,
      ];

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async => key == _el9222Key
      ? Stream<DynamicValue>.value(_struct)
      : const Stream<DynamicValue>.empty();

  @override
  Future<DynamicValue> read(String key) async => _struct;

  @override
  String resolveKey(String key) => key;

  @override
  Future<void> write(String key, DynamicValue value) async =>
      writes.add((key: key, value: value));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_El9222StateMan: ${invocation.memberName} not in test scope',
      );
}

/// A plain shell with the prompt mounted over it, which is where a refusal
/// becomes something the operator can read.
Widget _shell({required Widget body, required List<Override> overrides}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: AccessDeniedPrompt(child: Scaffold(body: Center(child: body))),
      ),
    );

List<Override> _overrides(StateMan stateMan, TagBindingResolver resolver) => [
      stateManProvider.overrideWith((ref) async => stateMan),
      tagBindingResolverProvider.overrideWith((ref) => resolver),
      // The loader is what `tagAccessProvider` watches. It must answer without
      // a database; the snapshot is already in the resolver.
      accessTemplatesProvider
          .overrideWith((ref) async => const <AccessTemplate>[]),
      accessSessionProvider.overrideWith(() => _FixedSession(_anonymous())),
      accessRepositoryProvider.overrideWith((ref) async => _StubRepository()),
      auditSinkProvider.overrideWith((ref) async => _NullSink()),
      stationNameProvider.overrideWithValue('test-station'),
    ];

/// The prompt, by the key the widget renders it under.
final Finder _prompt = find.byKey(kAccessDeniedBodyKey);

void main() {
  // ------------------------------------------------------------------
  // beckhoff.dart — the EL2008's 8-channel force grid
  // ------------------------------------------------------------------
  // The beckhoff force grid was here. Upstream #456 replaced the EL1008 /
  // EL2008 channel dialogs with a read-only side pane and deleted the force
  // controls outright — "the force *controls* are gone because the PLC
  // accepts no override" (`io_pane.dart`). There is no longer a beckhoff cell
  // to resolve at the tap, so the group that asserted it went with the UI it
  // described rather than being kept alive against a widget that no longer
  // exists. The advantys grids below are unchanged and still force, and they
  // are what keeps this plan's claim under test.
  group('the advantys force grid', () {
    tearDown(closeSidePane);

    Future<_ForceStateMan> open(
      WidgetTester tester, {
      required TagBindingResolver resolver,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final stateMan = _ForceStateMan();
      final config = STBDDO3705Config(
        nameOrId: 'DO-fwt',
        rawStateKey: _rawKey,
        forceValuesKey: _forceKey,
        descriptionsKey: _descKey,
      );

      await tester.pumpWidget(_shell(
        body: SizedBox(
          width: 200,
          height: 300,
          child: Builder(builder: (context) => config.build(context)),
        ),
        overrides: _overrides(stateMan, resolver),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(STBDDO3705Widget));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel detail'));
      await tester.pumpAndSettle();
      expect(find.byType(StandardDialog), findsOneWidget);
      return stateMan;
    }

    testWidgets('an unbound cell writes exactly the array it wrote before',
        (tester) async {
      final stateMan = await open(tester, resolver: _unboundResolver());

      await tester.tap(find.text('Low ').first);
      await tester.pumpAndSettle();

      expect(stateMan.writes, hasLength(1));
      final write = stateMan.writes.single;
      expect(write.key, _forceKey);
      expect(write.value.isArray, isTrue);
      expect(write.value[0].asInt, 1, reason: 'channel 1 forced low');
      for (int i = 1; i < 16; i++) {
        expect(write.value[i].asInt, 0, reason: 'channel ${i + 1} stays auto');
      }
      expect(_prompt, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a bound cell on a session without force prompts and writes nothing',
        (tester) async {
      final stateMan = await open(tester, resolver: _boundForceResolver());

      await tester.tap(find.text('Low ').first);
      await tester.pumpAndSettle();

      expect(stateMan.writes, isEmpty,
          reason: 'the cell refused before it composed a value');
      expect(_prompt, findsOneWidget);
      expect(
          find.text(kAccessDeniedGroupNote(AccessGroup.force)), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: 'nothing is thrown anywhere on the operator path');
    });

    testWidgets('a locked cell is still on screen and still hit-testable',
        (tester) async {
      await open(tester, resolver: _boundForceResolver());

      expect(find.byType(RowIOView), findsNWidgets(8));
      expect(find.text('Low '), findsNWidgets(16));

      final cells = tester.widgetList<SegmentedButton<int>>(
          find.byType(SegmentedButton<int>, skipOffstage: false));
      expect(cells, hasLength(16));
      for (final cell in cells) {
        expect(cell.onSelectionChanged, isNotNull,
            reason: 'a locked cell is refused at the tap, not disabled');
      }
      expect(find.text('Low ').hitTestable(), findsWidgets);
    });
  });

  // ------------------------------------------------------------------
  // advantys_stb.dart — the DDI3725's input grid, which has TWO kinds of
  // cell writing two different keys
  // ------------------------------------------------------------------
  group('the advantys input grid', () {
    tearDown(closeSidePane);

    Future<_ForceStateMan> open(
      WidgetTester tester, {
      required TagBindingResolver resolver,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final stateMan = _ForceStateMan();
      final config = STBDDI3725Config(
        nameOrId: 'DI-fwt',
        rawStateKey: _rawKey,
        forceValuesKey: _forceKey,
        descriptionsKey: _descKey,
        onFiltersKey: _onFiltersKey,
        offFiltersKey: _offFiltersKey,
      );

      await tester.pumpWidget(_shell(
        body: SizedBox(
          width: 200,
          height: 300,
          child: Builder(builder: (context) => config.build(context)),
        ),
        overrides: _overrides(stateMan, resolver),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(STBDDI3725Widget));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel detail'));
      await tester.pumpAndSettle();
      expect(find.byType(StandardDialog), findsOneWidget);
      return stateMan;
    }

    testWidgets('an unbound filter writes exactly the array it wrote before',
        (tester) async {
      final stateMan = await open(tester, resolver: _unboundResolver());

      await tester.enterText(find.widgetWithText(TextFormField, 'On filter').first, '25');
      await tester.pumpAndSettle();

      expect(stateMan.writes, hasLength(1));
      expect(stateMan.writes.single.key, _onFiltersKey);
      expect(stateMan.writes.single.value[0].asInt, 25);
      expect(_prompt, findsNothing);
    });

    testWidgets('a bound filter prompts and writes nothing, while the '
        'unbound force cell beside it still writes', (tester) async {
      final stateMan = await open(tester, resolver: _boundFilterResolver());

      await tester.enterText(find.widgetWithText(TextFormField, 'On filter').first, '25');
      await tester.pumpAndSettle();

      expect(stateMan.writes, isEmpty,
          reason: 'the filter refused before it composed a value');
      expect(_prompt, findsOneWidget);
      expect(find.text(kAccessDeniedGroupNote(AccessGroup.device)),
          findsOneWidget);
      expect(tester.takeException(), isNull);

      // Dismiss the prompt, then force a cell on the same grid. Only
      // `on_filters` is bound, so the force must still go through — a blanket
      // edit that locked the whole grid would fail here.
      await tester.tap(find.byKey(kAccessDeniedDismissKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Low ').first);
      await tester.pumpAndSettle();

      expect(stateMan.writes, hasLength(1));
      expect(stateMan.writes.single.key, _forceKey);
      expect(stateMan.writes.single.value[0].asInt, 1);
    });
  });

  // ------------------------------------------------------------------
  // beckhoff.dart — the EL9222 reset, the one member-bearing write here
  // ------------------------------------------------------------------
  group('the el9222 reset', () {
    tearDown(closeSidePane);

    Future<_El9222StateMan> open(
      WidgetTester tester, {
      required TagBindingResolver resolver,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final stateMan = _El9222StateMan();
      final config = BeckhoffEL9222Config(
        nameOrId: 'ST101.A1.02',
        stateKey: _el9222Key,
      );

      await tester.pumpWidget(_shell(
        body: SizedBox(
          width: 120,
          height: 400,
          child: Builder(builder: (context) => config.build(context)),
        ),
        overrides: _overrides(stateMan, resolver),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(IO8Widget));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('el9222-reset-1')));
      await tester.pumpAndSettle();
      return stateMan;
    }

    testWidgets('an unbound reset still pulses the member high then low',
        (tester) async {
      final stateMan = await open(tester, resolver: _unboundResolver());

      await tester.tap(find.byKey(const ValueKey('el9222-reset-1')));
      // Two pumps, not one: the rise reads the struct back before writing it.
      await tester.pump();
      await tester.pump();
      expect(stateMan.resetLevels, [true]);

      await tester.pump(kEl9222ResetPulse);
      await tester.pumpAndSettle();
      expect(stateMan.resetLevels, [true, false]);
      expect(_prompt, findsNothing);
    });

    testWidgets('a bound reset refuses at the tap and pulses neither edge',
        (tester) async {
      final stateMan = await open(tester, resolver: _boundResetResolver());

      await tester.tap(find.byKey(const ValueKey('el9222-reset-1')));
      await tester.pump();
      await tester.pump();
      await tester.pump(kEl9222ResetPulse);
      await tester.pumpAndSettle();

      // Both halves: a refused rise must not leave a lone falling edge behind
      // it, and one refused press is one refusal.
      expect(stateMan.writes, isEmpty);
      expect(_prompt, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
