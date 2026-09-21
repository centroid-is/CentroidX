/// One golden: the wagon drive pane with `reverseWagonDirection` on.
///
/// The image shows the wagon on its rail and the traverse drive's pane beside
/// it. The MANUAL section's left button points left and reads `Forward`; the
/// right one points right and reads `Reverse`. The rest of the pane is the
/// ordinary drive pane, unchanged.
///
/// `conveyor_wagon_direction_test.dart` asserts which command each button
/// sends. This image is here to be looked at.
@Tags(['golden'])
library;

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
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/golden_fonts.dart';
import '../../helpers/golden_platform.dart';
import '../../helpers/golden_tolerance.dart';

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

const _box = Size(360, 160);

void main() {
  final (_, dark) = muted();

  useTolerantGoldenComparator();

  group('wagon drive pane, direction reversed', skip: goldenSkip, () {
    setUpAll(loadGoldenFonts);

    tearDown(() {
      closeSidePane(immediate: true);
      TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!
          .resetPhysicalSize();
    });

    testWidgets('the left arrow is Forward', (tester) async {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
      view.devicePixelRatio = 1.0;
      view.physicalSize = const Size(900, 1020);

      final config = ConveyorConfig(
        onRails: true,
        wagonMotorKey: _motorKey,
        reverseWagonDirection: true,
      )..size = const RelativeSize(width: 1.0, height: 1.0);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          collectorProvider.overrideWith((ref) async => null),
          stateManProvider.overrideWith((ref) async => _FakeStateMan()),
          tagBindingResolverProvider.overrideWith((ref) => TagBindingResolver()
            ..setSnapshot(keyToTemplate: const {}, templates: const {})),
          accessTemplatesProvider
              .overrideWith((ref) async => const <AccessTemplate>[]),
          accessSessionProvider.overrideWith(_FixedSession.new),
          accessRepositoryProvider
              .overrideWith((ref) async => _StubRepository()),
          auditSinkProvider.overrideWith((ref) async => _NullSink()),
          stationNameProvider.overrideWithValue('station-1'),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: SizedBox(
                  width: _box.width,
                  height: _box.height,
                  child: Conveyor(config),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Bare rail at the left end, clear of the wagon parked mid-rail.
      final rail = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((cp) => cp.painter)
          .whereType<ConveyorPainter>()
          .first
          .railBandRect(_box)!;
      await tester.tapAt(
          tester.getTopLeft(find.byType(Conveyor)) + Offset(10, rail.center.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(SidePaneHost.openId, endsWith(':$_motorKey'));
      expect(tester.takeException(), isNull);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/conveyor_wagon_direction_reversed.png'),
      );
    });
  });
}
