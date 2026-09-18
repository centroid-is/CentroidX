// The wagon drive pane's jog arrows have to point the way the wagon goes.
//
// The pane always drew `Reverse <-` on the left and `Forward ->` on the
// right. That is only true when the drive's forward moves the wagon right on
// the mimic. On a line wired or drawn the other way round, `Forward ->` sent
// the wagon left, and the operator had nothing to fix it with.
//
// `ConveyorConfig.reverseWagonDirection` is that fix. The left button still
// points left, but it now sends `p_cmd_JogFwd` and says `Forward`. Each
// assertion below is on what the fake `StateMan` was sent, because the claim
// is about what the PLC hears.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/state_man.dart';

const _motorKey = 'line_a.wagon.traverse';

typedef _Write = ({String key, DynamicValue value});

/// Serves the traverse drive's struct and records every write.
class _FakeStateMan implements StateMan {
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
    // A tap latches, so one tap is one write.
    dv['p_stat_ManualStopOnRelease'] = false;
    dv['p_cfg_ManualFreq'] = 10.0;
    dv['p_cfg_AutoFreq'] = 20.0;
    dv['p_cfg_CleaningFreq'] = 5.0;
    return dv;
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async => key == _motorKey
      ? Stream<DynamicValue>.value(_struct)
      : const Stream<DynamicValue>.empty();

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

class _FixedSession extends AccessSessionController {
  @override
  Future<AccessSession> build() async =>
      AccessSession.anonymous(const {AccessGroup.operate});

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.ok;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

class _StubRepository extends Fake implements AccessRepository {}

class _NullSink implements AuditSink {
  @override
  Future<void> record(AuditRecord entry) async {}
}

const _box = Size(400, 300);

ConveyorPainter _painterOf(WidgetTester tester) {
  for (final cp in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    final painter = cp.painter;
    if (painter is ConveyorPainter) return painter;
  }
  fail('no ConveyorPainter was rendered');
}

/// Pumps a wagon whose only binding is its traverse drive, taps the bare
/// rail to open that drive's pane, and returns the fake it writes through.
Future<_FakeStateMan> _openWagonDrivePane(WidgetTester tester,
    {required bool? reverseWagonDirection}) async {
  final fake = _FakeStateMan();
  final config = ConveyorConfig(
    onRails: true,
    wagonMotorKey: _motorKey,
    reverseWagonDirection: reverseWagonDirection,
  )..size = const RelativeSize(width: 1.0, height: 1.0);

  await tester.pumpWidget(ProviderScope(
    overrides: [
      collectorProvider.overrideWith((ref) async => null),
      stateManProvider.overrideWith((ref) async => fake),
      tagBindingResolverProvider.overrideWith((ref) => TagBindingResolver()
        ..setSnapshot(keyToTemplate: const {}, templates: const {})),
      accessTemplatesProvider
          .overrideWith((ref) async => const <AccessTemplate>[]),
      accessSessionProvider.overrideWith(_FixedSession.new),
      accessRepositoryProvider.overrideWith((ref) async => _StubRepository()),
      auditSinkProvider.overrideWith((ref) async => _NullSink()),
      stationNameProvider.overrideWithValue('station-1'),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _box.width,
            height: _box.height,
            child: Conveyor(config),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();

  final rail = _painterOf(tester).railBandRect(_box)!;
  final topLeft = tester.getTopLeft(find.byType(Conveyor));
  await tester.tapAt(topLeft + Offset(10, rail.center.dy));
  await _settle(tester);
  expect(SidePaneHost.openId, endsWith(':$_motorKey'),
      reason: 'test setup: the tap must open the traverse drive');
  return fake;
}

/// Past the pane's slide-in, without waiting on the trend spinner.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// The label under the jog button carrying [icon].
String _labelUnder(WidgetTester tester, IconData icon) {
  final column = find.ancestor(
      of: find.byIcon(icon), matching: find.byType(Column)).first;
  final label = find.descendant(of: column, matching: find.byType(Text));
  return tester.widget<Text>(label.first).data!;
}

/// Taps the jog button carrying [icon] and returns the one command it sent.
Future<String> _commandFrom(
    WidgetTester tester, _FakeStateMan fake, IconData icon) async {
  fake.writes.clear();
  await tester.tap(find.byIcon(icon));
  await _settle(tester);
  expect(fake.writes, hasLength(1));
  expect(fake.writes.single.key, _motorKey);
  final value = fake.writes.single.value;
  // The pane clones the struct and sets one member, so the command is the
  // one jog member present in what was written.
  return ['p_cmd_JogFwd', 'p_cmd_JogBwd']
      .singleWhere((cmd) => value.contains(cmd) && value[cmd].asBool);
}

void main() {
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
    view.devicePixelRatio = 1.0;
    view.physicalSize = const Size(1200, 1400);
  });

  tearDown(() {
    closeSidePane(immediate: true);
    TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!
        .resetPhysicalSize();
  });

  testWidgets('by default forward points right, as it always has',
      (tester) async {
    final fake =
        await _openWagonDrivePane(tester, reverseWagonDirection: null);

    expect(_labelUnder(tester, Icons.arrow_back), 'Reverse');
    expect(_labelUnder(tester, Icons.arrow_forward), 'Forward');
    expect(await _commandFrom(tester, fake, Icons.arrow_back), 'p_cmd_JogBwd');
    expect(
        await _commandFrom(tester, fake, Icons.arrow_forward), 'p_cmd_JogFwd');
    expect(tester.takeException(), isNull);
  });

  testWidgets('reversed, the left arrow is Forward and sends the forward jog',
      (tester) async {
    final fake =
        await _openWagonDrivePane(tester, reverseWagonDirection: true);

    expect(_labelUnder(tester, Icons.arrow_back), 'Forward');
    expect(_labelUnder(tester, Icons.arrow_forward), 'Reverse');
    expect(await _commandFrom(tester, fake, Icons.arrow_back), 'p_cmd_JogFwd');
    expect(
        await _commandFrom(tester, fake, Icons.arrow_forward), 'p_cmd_JogBwd');
    expect(tester.takeException(), isNull);
  });

  test('the flag round-trips on both belt types and defaults to off', () {
    expect(ConveyorConfig().reverseWagonDirection, isNull);
    final box = ConveyorConfig(onRails: true, reverseWagonDirection: true);
    expect(ConveyorConfig.fromJson(box.toJson()).reverseWagonDirection,
        isTrue);
    final roller =
        RollerConveyorConfig(onRails: true, reverseWagonDirection: true);
    expect(RollerConveyorConfig.fromJson(roller.toJson()).reverseWagonDirection,
        isTrue);
    final legacy = ConveyorConfig(onRails: true).toJson()
      ..remove('reverseWagonDirection');
    expect(ConveyorConfig.fromJson(legacy).reverseWagonDirection, isNull);
  });
}
