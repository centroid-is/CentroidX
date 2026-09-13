/// One golden: the conveyor's side pane, anonymous, with `p_cfg_ManualFreq`
/// **locked and still showing its number** while the jog buttons stay
/// ordinary.
///
/// `conveyor_locked_pane.png` — the phase's acceptance sentence as a picture.
/// `conveyor_tap_time_test.dart` already asserts it (one write for the jog,
/// none for the frequency, a prompt naming `setpoints`), but an assertion
/// cannot say whether the value beside the lock is *legible*, whether the lock
/// reads as a fault, or whether the two jog buttons look any different from
/// the locked field above them. Spec §9b: a passing golden is not review, so
/// this image exists to be opened and looked at.
///
/// **What the image is supposed to show**, so a later reader can check it
/// against the file rather than against a memory:
///
///  * `Manual frequency` rendered as a bordered field carrying `37.50` and a
///    small lock glyph on its right — not blanked, not greyed, not replaced
///    by the word "Locked",
///  * `Auto frequency` locked the same way (`45.00`) — the §7b template gates
///    both frequencies — and `Cleaning frequency` (`12.00`) **editable**, so
///    the lock cannot be a pane that locked everything,
///  * the jog buttons and the continuous switch drawn exactly as they are on
///    an unbound station: `p_cmd_JogFwd -> operate` and the session holds
///    `operate`.
///
/// **Fonts are loaded here, twice, deliberately.** `test/page_creator/` has no
/// `flutter_test_config.dart` of its own and the root one registers **no font
/// at all**; `lib/theme.dart:349` names `'roboto-mono'` as the theme's family.
/// Without both registrations every themed `Text` in this pane captures as
/// Ahem rectangles and the "is the number legible" question cannot be
/// answered. MaterialIcons comes out of the SDK cache for the lock, the
/// header glyph and the jog arrows.
///
/// **The themed app, not a bare `MaterialApp`.** `HmiStateColors.of` falls
/// back to `solarizedLight` when the theme carries no extension, which would
/// put violet into an image whose whole subject is a muted pane.
///
/// **Pinned with `withClock`** and with an overridden `accessSessionProvider`,
/// so nothing here depends on when it ran or on a controller chain settling:
/// the real session controller reaches the database, the preferences store and
/// the station keychain, and a frame captured before it resolves renders every
/// control in its loading state.
///
/// **Every fixture here is this file's own**, copied from
/// `conveyor_tap_time_test.dart` rather than imported. Importing another test
/// file executes its top-level state and makes a baseline nobody can
/// reproduce.
///
/// To update: flutter test test/page_creator/assets/conveyor_locked_pane_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart'
    show DynamicValue, EnumField, LocalizedText;
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

import '../../helpers/golden_tolerance.dart';
import '../../helpers/golden_platform.dart';

// ---------------------------------------------------------------------------
// Fixtures — this file's own
// ---------------------------------------------------------------------------

/// The key the whole phase is argued around: one struct carrying a jog command
/// an operator may issue and a drive frequency they may not set.
const String _key = 'ST101.CN01';

const String _templateName = 'conveyor';

/// Three numbers, all different, so a reader of the image can tell which field
/// is which without counting rows.
const double _manualFreq = 37.5;
const double _autoFreq = 45.0;
const double _cleaningFreq = 12.0;

/// The instant this image is frozen at. `BaseScaffold` is not in this tree,
/// but the pane's own widgets are free to read `clock.now()` and a golden that
/// depended on the wall clock would churn on every run.
final DateTime _frozen = DateTime.utc(2026, 8, 30, 9, 0);

/// Spec §7b's worked example, verbatim: jogging and the fault reset are
/// `operate`, the two frequencies are `setpoints`. `p_cfg_CleaningFreq` is
/// deliberately absent — the template carries no whole-key row, so that member
/// is unrestricted and must render as an ordinary field.
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

/// Nobody signed in, holding the seeded operator permission and nothing else.
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

/// Swallows the rows a refusal writes. This image drives no refusal; the sink
/// exists so a stray one would be silent rather than an exception in the
/// frame.
class _NullSink implements AuditSink {
  @override
  Future<void> record(AuditRecord entry) async {}
}

/// The `run_mode_e` value the belt itself is painted from.
///
/// The mimic reads `p_stat_RunMode` by **name**, so a bare integer — or a
/// struct with no such member at all — leaves the belt violet. Violet is a
/// legitimate muted-palette colour (`MutedColors.unknownViolet`, "nobody knows
/// what this belt is doing"), which is exactly why it must not appear here by
/// accident: a reviewer checking this image for the `solarizedLight` fallback
/// would have to tell the two violets apart by hex.
DynamicValue _runMode(String name) {
  const names = ['stopped', 'auto', 'manual', 'clean', 'fault'];
  final dv = DynamicValue(value: names.indexOf(name));
  dv.enumFields = {
    for (var i = 0; i < names.length; i++)
      i: EnumField(i, names[i], LocalizedText(names[i], 'en'),
          LocalizedText('', 'en')),
  };
  return dv;
}

/// Serves one drive struct. It records writes only so that a stray one is
/// visible rather than silently swallowed — this image drives none.
class _FakeStateMan implements StateMan {
  _FakeStateMan(this.driveKey);

  final String driveKey;
  final List<String> writes = [];

  DynamicValue get _struct {
    final dv = DynamicValue();
    dv['p_stat_State'] = 2; // hmis_e.rdy
    dv['p_stat_LastFault'] = 0;
    // Stopped, matching the `Stopped` chip in the pane header: a belt painted
    // one state while its own header names another would be a worse picture
    // than a violet one.
    dv['p_stat_RunMode'] = _runMode('stopped');
    dv['p_stat_Frequency'] = 0.0;
    dv['p_stat_Current'] = 0.0;
    dv['p_stat_RunMinutes'] = 0;
    dv['p_stat_JogFwd'] = false;
    dv['p_stat_JogBwd'] = false;
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
  /// every refusal into a permitted write.
  @override
  String resolveKey(String key) => key;

  @override
  Future<void> write(String key, DynamicValue value) async =>
      writes.add(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_FakeStateMan: ${invocation.memberName} not in test scope',
      );
}

/// Loads the two families the theme needs plus the icon font.
///
/// `'Roboto'` is Flutter's default family and `'roboto-mono'` is what
/// `lib/theme.dart` asks for; the same file backs both, because the point is
/// that a glyph is drawn rather than which face draws it.
Future<void> _loadRealFonts() async {
  Future<void> loadFont(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await loadFont('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  for (final candidate in <String>[
    if (flutterRoot != null)
      '$flutterRoot/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
        'MaterialIcons-Regular.otf',
  ]) {
    if (File(candidate).existsSync()) {
      await loadFont('MaterialIcons', candidate);
      break;
    }
  }
}

void main() {
  final (light, _) = muted();

  useTolerantGoldenComparator();

  group('conveyor locked-pane golden',
      skip: goldenSkip, () {
    setUpAll(_loadRealFonts);

    tearDown(() {
      closeSidePane();
      TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!
          .resetPhysicalSize();
    });

    testWidgets('the locked manual frequency, its value, and a live jog',
        (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        final view =
            TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
        view.devicePixelRatio = 1.0;
        // Tall enough that the pane's four sections all fit without
        // scrolling: a golden whose setpoints section was below the fold would
        // show nothing this image is about. Measured rather than guessed — the
        // pane is the window height less 155 px of margin, the four sections
        // and the pinned footer come to ~830, and at 900 the whole SETPOINTS
        // section (with the two locked-vs-open frequencies this image is
        // about) fell off the bottom.
        view.physicalSize = const Size(900, 1020);

        final fake = _FakeStateMan(_key);
        final config = ConveyorConfig(key: _key)
          ..size = const RelativeSize(width: 1.0, height: 1.0);

        await tester.pumpWidget(ProviderScope(
          overrides: [
            // The pane's trend tile resolves the collector, which builds a
            // real Database with periodic timers that outlive the test.
            collectorProvider.overrideWith((ref) async => null),
            stateManProvider.overrideWith((ref) async => fake),
            tagBindingResolverProvider.overrideWith((ref) => _boundResolver()),
            // The loader is what `tagAccessProvider` watches. It must answer
            // without a database; the snapshot is already in the resolver.
            accessTemplatesProvider
                .overrideWith((ref) async => const <AccessTemplate>[]),
            accessSessionProvider.overrideWith(() => _FixedSession(_anonymous())),
            accessRepositoryProvider.overrideWith((ref) async => _StubRepository()),
            auditSinkProvider.overrideWith((ref) async => _NullSink()),
            stationNameProvider.overrideWithValue('test-station'),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: light,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: SizedBox(
                      width: 400, height: 80, child: Conveyor(config)),
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        await tester.tap(find.byType(Conveyor));
        // Past the slide-in, without waiting on the trend tile — which never
        // settles under a fake `StateMan`.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // The claims the image is supposed to make, asserted before the pixels
        // are compared. An eye can see a number beside a lock; it cannot see
        // that the field is a `Text` rather than a `TextFormField` with a flag
        // set, and it cannot see that nothing was written.
        final lockedManual =
            find.byKey(const Key('manual_freq_field_locked_value'));
        expect(lockedManual, findsOneWidget);
        expect(tester.widget<Text>(lockedManual).data,
            _manualFreq.toStringAsFixed(2),
            reason: 'the value is legible under the lock, not blanked');
        expect(find.byKey(const Key('manual_freq_field')), findsNothing,
            reason: 'a locked field is not an editable one with a flag set');
        expect(find.byKey(const Key('auto_freq_field_locked_value')),
            findsOneWidget);
        expect(find.byKey(const Key('cleaning_freq_field')), findsOneWidget,
            reason: 'a member the template does not mention stays editable, '
                'so the lock cannot be a pane that locked everything');
        expect(find.byIcon(Icons.arrow_forward), findsOneWidget,
            reason: 'the jog the anonymous session may use is on screen');
        expect(fake.writes, isEmpty);
        expect(tester.takeException(), isNull);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/conveyor_locked_pane.png'),
        );
      });
    });
  });
}
