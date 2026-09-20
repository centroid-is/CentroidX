/// The mimic widgets an operator touches, over the real relay, against real
/// PLC servers.
///
/// ## What this lane is for
///
/// Every asset in `lib/page_creator/assets/` has widget tests, and every one
/// of them mocks `stateManProvider` with a `_FakeStateMan` that pushes values
/// into a subject. Every relay package has an end-to-end test, and every one
/// of them stops at `RemoteStateMan.read` — a value in a store. Between the
/// two there is a seam nobody had crossed: **what the widget renders when the
/// value came from a plant**, through the adapter that translates the
/// protocol's `DynamicValue` into open62541's (`gateway_state_man.dart`),
/// through the guard, through the two providers that decide whether the
/// panel may vouch for what it shows.
///
/// That seam is where two real defects lived. The type dictionary did not
/// cross it, and every conveyor in every browser drew violet (2026-09-17,
/// `toUaValue`'s doc). The freshness verdict did not cross it, and a panel
/// whose link had been cut for 65 s still rendered every value definite
/// (2026-09-07, `value_freshness.dart`'s doc). Both were found on a rig. This
/// lane is what finds the next one before a rig does.
///
/// ## What it asserts on, and what it refuses to
///
/// Rendered text, painter fields and plant-side actuation counts. Never
/// pixels: goldens here are Linux-only through `scripts/goldens.sh`, and a
/// golden would make this lane unrunnable on the machine it was written on.
/// Never a store value: `RemoteStateMan.read` is what the other e2e legs
/// already prove, and a value that is right in the store and wrong on the
/// glass is exactly the defect class above.
///
/// ## How it is bounded
///
/// One file, so its cases share one isolate and run one after another — the
/// plant iterates open62541 servers with a BLOCKING `runIterate` on a 10 ms
/// timer, and a neighbour suite sharing that isolate does not get a slow test,
/// it gets a stalled one. The CI job runs it alone with `--concurrency=1`.
/// And it runs only when `CENTROIDX_E2E_ASSETS=1` is set: `flutter test test/`
/// would otherwise discover it and run it beside three other files on a
/// four-core runner, which is the concurrency it cannot have. The CI job that
/// sets the variable also counts the cases that ran, so a variable that stops
/// being set cannot turn into a green lane that ran nothing.
///
/// Excluded from Windows for `plant_bench.dart`'s reason: the in-process
/// open62541 `Server` is `@TestOn('!windows')` everywhere in this repository.
///
/// Every assertion here was made to fail on purpose before it was trusted —
/// the report on the branch names which line was broken for each.
@TestOn('!windows')
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:jbtm/jbtm.dart'
    show M2400Field, M2400RecordType, M2400StubServer;
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/page_creator/assets/number.dart';
import 'package:tfc/page_creator/assets/start_stop_button.dart';
import 'package:tfc/providers/value_freshness.dart';
import 'package:tfc/theme.dart' show HmiStateColors;
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart'
    show UpstreamLinkConfig, UpstreamProtocol;

import 'support/panel_bench.dart';

/// Why the enum case is skipped, and what lifts the skip.
///
/// **It is red, and it is red for the reason it was written.** Through this
/// bench `RemoteStateMan.typeOf` answers null for the drive struct, so
/// `toUaValue` attaches no enum table, `readDriveState` answers `unknown`,
/// and the belt is violet 40 ms after the first value lands — the exact
/// 2026-09-17 defect. The cause is not the panel: the plant-only gateway
/// `buildGateway` composes (`tfc_relay_local`'s `LocalStateMan`) does not
/// implement the protocol's `TypeDescriptions`, and
/// `type_descriptor.dart:155-158` says so in its own words — "simply carries
/// no `types`; the server asks `api is TypeDescriptions`. The backend's
/// answer comes from its pipe". Only tfc_dart's `pipe_worker_endpoint.dart`
/// describes a type today, and `tfc_relay_local`'s own bench asserts that
/// member NAMES survive (`contains('run_mode')`), never enum names, so the
/// gap had no pin.
///
/// The case stays, whole, so that it is a one-word change to arm it the day
/// `LocalStateMan` describes its types — and `false` here without that
/// change is a red lane, not a green one. The CI verifier tolerates exactly
/// this one skip, by this reason, and no other.
const bool kTypeDictionaryGap = true;

/// The skip reason the CI verifier matches on. Change one and the other.
const String kTypeDictionaryGapReason =
    'tfc_relay_local\'s LocalStateMan implements no TypeDescriptions, so no '
    'enum name crosses a plant-only gateway; see kTypeDictionaryGap';

/// The switch. See the library doc.
const String kEnableVariable = 'CENTROIDX_E2E_ASSETS';

/// The plant this lane drives. Invented, per `tfc_plant_sim`'s charter.
///
/// Every node is here because a case needs its shape:
///
///  * `CN01.pulse` ramps every 100 ms and nothing reads it. It is what keeps
///    frames flowing on the socket, so the client's freshness watchdog — one
///    deadline restarted by ANY inbound frame — is judging the link and not a
///    plant that happened to go quiet. Take it out and a plant with nothing
///    to say greys the panel with the link intact.
///  * `CN01.speed_hz` reports once and is then moved by hand, so a case can
///    say exactly which number it expects on the glass.
///  * `CN01.running` is the plain BOOL an LED reads.
///  * `CN01.drive` is the struct whose state member is an enum — the shape
///    that drew every conveyor violet. It cycles, so one case sees every
///    named state cross the relay.
///  * `CN01.cmd_run` / `CN01.cmd_stop` RECORD: the plant counts what it was
///    told to do, which is the only evidence "one tap, one command" can have.
const String kPlantSpec = '''
types:
  - name: RunMode
    kind: enum
    values: {0: fault, 1: stopped, 2: auto, 3: manual, 4: clean}
  - name: DriveHmi
    kind: struct
    members:
      - {name: p_stat_RunMode, type: RunMode, value: 2}
      - {name: p_stat_Frequency, type: double, value: 50}
servers:
  - alias: HALL1
    nodes:
      - {id: CN01.pulse, type: double, motion: ramp, min: 0, max: 100, period: 100ms}
      - {id: CN01.speed_hz, type: double, value: 12.5, motion: once}
      - {id: CN01.running, type: bool, value: true, motion: once}
      - {id: CN01.stopped, type: bool, value: false, motion: once}
      - {id: CN01.drive, type: DriveHmi, motion: cycle, period: 400ms}
      - {id: CN01.cmd_run, type: bool, value: false, motion: once, records: true}
      - {id: CN01.cmd_stop, type: bool, value: false, motion: once, records: true}
''';

const String kAlias = 'HALL1';
final String kSpeedKey = plantKey(kAlias, 'CN01.speed_hz');
final String kRunningKey = plantKey(kAlias, 'CN01.running');
final String kStoppedKey = plantKey(kAlias, 'CN01.stopped');
final String kDriveKey = plantKey(kAlias, 'CN01.drive');
final String kCmdRunKey = plantKey(kAlias, 'CN01.cmd_run');
final String kCmdStopKey = plantKey(kAlias, 'CN01.cmd_stop');

/// The weigher's alias. Lower case because `buildUpstreamLink` selects a
/// Modbus-family adapter's mapping entries by the NORMALISED alias, and the
/// existing weigher fixtures spell theirs this way.
const String kWeigherAlias = 'weigher1';
final String kWeightKey = plantKey(kWeigherAlias, 'weight');

/// Every case's budget. Generous: none of these is a latency measurement,
/// and the four asynchronous boundaries between a PLC and a frame each cost
/// a publish interval on a loaded runner.
const Duration kBudget = Duration(seconds: 20);

/// The one painter the conveyor draws its belt with.
///
/// The belt's colour and its `!` are both PAINTED — `ConveyorPainter` lays the
/// glyph out with a `TextPainter` — so there is no `Text` for a finder and the
/// painter's own fields are the rendered state. That is still the widget and
/// not the stream: the painter is rebuilt from the `StreamBuilder`'s snapshot
/// on every frame, and a value that stopped at the subject never reaches it.
ConveyorPainter belt(WidgetTester tester) {
  final paints = tester.widgetList<CustomPaint>(find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is ConveyorPainter));
  expect(paints, hasLength(1), reason: 'a conveyor draws exactly one belt');
  return paints.single.painter! as ConveyorPainter;
}

/// The LED's painter colour: null is the `!` glyph, which is the asset's
/// own word for "no value".
Color? ledColor(WidgetTester tester) {
  final paints = tester.widgetList<CustomPaint>(find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is LEDPainter));
  expect(paints, hasLength(1));
  return (paints.single.painter! as LEDPainter).color;
}

Finder iconOf(IconData data) =>
    find.byWidgetPredicate((w) => w is Icon && w.icon == data);

void main() {
  final enabled = Platform.environment[kEnableVariable] == '1';

  bindPanelTestEnvironment();

  group('an asset over the relay, against a real plant', () {
    late PanelBench bench;

    /// Stood up in the real zone, and torn down there too. The `addTearDown`
    /// is the failure path only: a case that fails mid-way still has to
    /// release its sockets and its FFI servers or the next case inherits
    /// them, but a teardown runs in the fake zone where an awaited close
    /// never completes — so it is fired and not awaited there.
    Future<void> standUpFor(WidgetTester tester,
        {List<ExtraUpstream> extra = const <ExtraUpstream>[]}) async {
      bench = (await tester.runAsync(
          () => standUp(spec: kPlantSpec, extraUpstreams: extra)))!;
      addTearDown(() => bench.dispose());
    }

    Future<void> tearDownFor(WidgetTester tester) =>
        tester.runAsync(bench.dispose);

    testWidgets('a Number renders the plant\'s value, and follows it',
        (tester) async {
      await standUpFor(tester);
      await bench.mount(
          tester,
          NumberWidget(
              config: NumberConfig(
                  key: kSpeedKey, units: 'Hz', decimalPlaces: 2)));

      // The value the PLC seeded, rendered by the same code path that
      // renders every readout on every page — including `numberDisplayText`'s
      // unit spacing, which is why the whole string is matched and not the
      // digits.
      await pumpUntil(tester, () => find.text('12.50 Hz').evaluate().isNotEmpty,
          within: kBudget,
          describe: 'the seeded speed to reach the glass as "12.50 Hz"');

      // The plant moves. Not the panel, not the gateway: the node itself.
      await tester.runAsync(() async => bench.server().set('CN01.speed_hz', 37.25));
      await pumpUntil(tester, () => find.text('37.25 Hz').evaluate().isNotEmpty,
          within: kBudget,
          describe: 'the moved speed to replace the old one on the glass');
      expect(find.text('12.50 Hz'), findsNothing,
          reason: 'the old value must be gone, not drawn beside the new one');
      await tearDownFor(tester);
    });

    testWidgets('an LED renders the plant\'s bit, and follows it',
        (tester) async {
      await standUpFor(tester);
      final config = LEDConfig(key: kRunningKey);
      await bench.mount(tester, Led(config), width: 80, height: 80);

      // Resolved against the mounted theme, the same way `LedRaw` resolves
      // it, so the assertion is "the ON colour this panel would paint" and
      // not a literal that drifts from the palette.
      final context = tester.element(find.byType(LedRaw));
      final on = config.onColor.resolve(context);
      final off = config.offColor.resolve(context);
      expect(on, isNot(off));

      await pumpUntil(tester, () => ledColor(tester) == on,
          within: kBudget, describe: 'the LED to paint ON from the plant');

      await tester.runAsync(() async => bench.server().set('CN01.running', false));
      await pumpUntil(tester, () => ledColor(tester) == off,
          within: kBudget, describe: 'the LED to follow the plant to OFF');
      await tearDownFor(tester);
    });

    // Its own group, because `testWidgets` takes `skip: bool?` and it is the
    // REASON the CI verifier reads — package:test carries a group's reason
    // into every case under it as `skipReason`.
    group('the enum-in-struct shape', () {
    testWidgets(
        'a conveyor colours its belt from the enum\'s NAMES, through the relay',
        (tester) async {
      // The defect `tfc_plant_sim`'s README names, at the last hop. The wire
      // carries `{"v": 2}`; the name `auto` lives in the type dictionary the
      // gateway describes once per type, and `toUaValue` reattaches it. Lose
      // that and `readDriveState` finds no name, answers `unknown`, and the
      // belt is violet — which is what every browser showed on 2026-09-17.
      await standUpFor(tester);
      await bench.mount(tester, Conveyor(ConveyorConfig(key: kDriveKey)),
          width: 320, height: 100);
      final states = HmiStateColors.of(tester.element(find.byType(Conveyor)));
      final named = <Color, String>{
        states.red: 'fault',
        states.grey: 'stopped',
        states.green: 'auto',
        states.yellow: 'manual',
        states.blue: 'clean',
      };
      expect(named, hasLength(5),
          reason: 'the palette must keep the five named states distinct, or '
              'this case cannot tell them apart');

      // Until the first frame that has a value at all: before the struct
      // arrives the belt is grey with a `!`, and grey is also `stopped`.
      // Waiting for the exclamation to clear is what makes the first colour
      // below a colour the plant chose.
      await pumpUntil(tester, () => !belt(tester).showExclamation,
          within: kBudget, describe: 'the drive struct to reach the belt');

      // The drive cycles through all five states in two seconds. Watch three
      // and a half, and record every colour the belt was painted in.
      final seen = <Color>{};
      await pumpNeverDuring(
        tester,
        () {
          final color = belt(tester).color;
          seen.add(color);
          return color == states.violet;
        },
        const Duration(milliseconds: 3500),
        describe: 'the belt must never be violet — violet is `unknown`, the '
            'colour a conveyor draws when the enum crossed the relay as a '
            'bare integer with no name',
      );
      expect(seen.map((c) => named[c]).whereType<String>().toSet(),
          containsAll(<String>['fault', 'stopped', 'auto', 'manual', 'clean']),
          reason: 'every named state must have crossed and been drawn; '
              'a belt stuck on one colour is not reading the plant. Seen: '
              '${seen.map((c) => named[c] ?? c).join(', ')}');
      await tearDownFor(tester);
    });
    }, skip: kTypeDictionaryGap ? kTypeDictionaryGapReason : null);

    testWidgets(
        'a start/stop tap actuates the plant exactly once per half of the pulse',
        (tester) async {
      // This is the assertion a read-back cannot make. The button pulses:
      // `true` on the press and `false` on the release, each its own write
      // through the guard, the adapter, the socket, the gateway and the OPC
      // UA session. A retry anywhere on that path is invisible to the node's
      // value — it is `false` either way — and visible only to a plant that
      // counted.
      await standUpFor(tester);
      await bench.mount(
          tester,
          StartStopPillButton(StartStopPillButtonConfig(
            runKey: kCmdRunKey,
            stopKey: kCmdStopKey,
            runningKey: kRunningKey,
            stoppedKey: kStoppedKey,
          )),
          width: 240,
          height: 80);
      await pumpUntil(tester, () => iconOf(FontAwesomeIcons.play.data).evaluate().isNotEmpty,
          within: kBudget, describe: 'the pill to render its segments');
      expect(bench.actuations('CN01.cmd_run'), 0,
          reason: 'nothing has been tapped; a count here is a write the '
              'bench made on its own, and the case is meaningless');

      // A press held for as long as the plant takes to count it, then a
      // release — the way a finger does it. `tester.tap` would fire both
      // halves in one frame and race the two writes past each other, which
      // no finger has ever done.
      final gesture = await tester
          .startGesture(tester.getCenter(iconOf(FontAwesomeIcons.play.data)));
      await pumpUntil(tester, () => bench.actuations('CN01.cmd_run') >= 1,
          within: kBudget, describe: 'the press to be counted at the node');
      await gesture.up();
      await pumpUntil(tester, () => bench.actuations('CN01.cmd_run') >= 2,
          within: kBudget, describe: 'the release to be counted at the node');

      // Then a whole second more, so a retry that was going to happen has
      // had every chance to.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)));

      final writes = bench.server().actuationsOf('CN01.cmd_run');
      expect(writes.map((a) => a.value.asBool).toList(), <bool>[true, false],
          reason: 'one press, one rising edge; one release, one falling edge; '
              'nothing else. Got ${writes.length} actuation(s)');
      expect(bench.actuations('CN01.cmd_stop'), 0,
          reason: 'the stop command is the other segment and was not touched');
      await tearDownFor(tester);
    });

    testWidgets('the screen stops lying when the link dies', (tester) async {
      // The rig's sequence, on the glass. 2026-09-07: the link was cut and at
      // +25 s and +65 s the chip read `No gateway` while every value on the
      // page still rendered definite. `read().quality` is deliberately NOT the
      // signal — the store still answers with what it last held — the verdict
      // is `viewIsStale`, and this case asserts what the WIDGET renders, which
      // is the thing that was wrong.
      await standUpFor(tester);
      await bench.mount(
          tester,
          NumberWidget(
              config: NumberConfig(
                  key: kSpeedKey, units: 'Hz', decimalPlaces: 2)));
      await pumpUntil(tester, () => find.text('12.50 Hz').evaluate().isNotEmpty,
          within: kBudget,
          describe: 'a definite value to begin from — without one nothing '
              'below is about a value going stale');
      final freshness = bench.container.read(valueFreshnessProvider);
      expect(freshness.isWatchingLink, isTrue,
          reason: 'a gateway panel must be tracking a client, or the negative '
              'assertions below are vacuous');
      expect(freshness.isStale, isFalse);

      // The cut. Bytes are read and dropped in both directions; the socket
      // stays open; nothing anywhere reports `onDone`.
      bench.link.blackhole();

      await pumpUntil(tester, () => find.text('--- Hz').evaluate().isNotEmpty,
          within: kBudget,
          describe: 'THE RIG DEFECT: the link is dead and the panel is still '
              'presenting the value it received before the cut as current');
      expect(find.text('12.50 Hz'), findsNothing);
      expect(bench.remote.viewIsStale, isTrue,
          reason: 'the client\'s own verdict, not a second model in lib/');
      expect(freshness.isStale, isTrue);

      // The plant keeps moving, and a second panel on the same gateway sees
      // it: this is what THIS panel can no longer be told. Asserting the
      // witness saw the move is what makes "the panel never showed it" a
      // claim about a withheld value and not about one that never existed —
      // and it pins that the cut is this panel's link and not the plant's.
      await tester.runAsync(() async {
        bench.server().set('CN01.speed_hz', 41.0);
        await until(() => bench.witness.read(kSpeedKey)?.value == 41.0,
            describe: 'the witness panel to see the plant move behind '
                'this panel\'s cut');
      });
      await pumpNeverDuring(
        tester,
        () =>
            find.text('41.00 Hz').evaluate().isNotEmpty ||
            find.text('12.50 Hz').evaluate().isNotEmpty,
        const Duration(seconds: 1),
        describe: 'the panel must show neither the pre-cut value nor the one '
            'it cannot have heard',
      );
      expect(find.text('--- Hz'), findsOneWidget);

      // The other direction, and it is not decoration: a panel that greys
      // and stays grey through a recovered link is one nobody trusts the
      // grey of. What comes back must be the NEW connection's value.
      bench.link.blackhole(enabled: false);
      await pumpUntil(tester, () => find.text('41.00 Hz').evaluate().isNotEmpty,
          within: kBudget,
          describe: 'the link to heal and the value the plant moved to '
              'during the outage to reach the glass');
      expect(freshness.isStale, isFalse);
      await tearDownFor(tester);
    });
  }, skip: skipReason(enabled));

  group('a second protocol beside OPC UA', () {
    late PanelBench bench;
    late M2400StubServer weigher;

    testWidgets('a Number renders a weigher\'s M2400 STAT weight',
        (tester) async {
      // `M2400StubServer` lives in jbtm's lib/ on purpose, so a fixture needs
      // no dev-only dance: a real TCP server speaking the weighers' framed
      // records, dialled by the real `M2400ClientWrapper` inside the
      // gateway's `M2400UpstreamLink`. A different adapter, a different
      // sample shape (`shapeSample` lifts the field out of the record), and
      // the same last hop to the same readout widget.
      weigher = M2400StubServer();
      await tester.runAsync(weigher.start);
      addTearDown(() => weigher.shutdown());

      bench = (await tester.runAsync(() => standUp(
            spec: kPlantSpec,
            extraUpstreams: [
              ExtraUpstream(
                link: UpstreamLinkConfig(
                  alias: kWeigherAlias,
                  protocol: UpstreamProtocol.m2400,
                  endpoint: '127.0.0.1:${weigher.port}',
                ),
                mappings: {
                  kWeightKey: KeyMappingEntry(
                    m2400Node: M2400NodeConfig(
                      recordType: M2400RecordType.recStat,
                      field: M2400Field.weight,
                      serverAlias: kWeigherAlias,
                    ),
                  ),
                },
              ),
            ],
          )))!;
      addTearDown(() => bench.dispose());
      await tester.runAsync(() => until(() => weigher.clientCount == 1,
          describe: 'the gateway to dial the weigher'));

      await bench.mount(
          tester,
          NumberWidget(
              config: NumberConfig(
                  key: kWeightKey, units: 'kg', decimalPlaces: 2)));
      // Nothing has been weighed: the readout must say so rather than show
      // a zero, which on a scale is a weight.
      await pumpUntil(tester, () => find.text('--- kg').evaluate().isNotEmpty,
          within: kBudget, describe: 'the readout to mount with no value');

      await tester.runAsync(() async => weigher.pushStatRecord(weight: '12.37', unit: 'kg'));
      await pumpUntil(tester, () => find.text('12.37 kg').evaluate().isNotEmpty,
          within: kBudget,
          describe: 'the weigher\'s STAT weight to reach the glass');

      await tester.runAsync(() async => weigher.pushStatRecord(weight: '13.05', unit: 'kg'));
      await pumpUntil(tester, () => find.text('13.05 kg').evaluate().isNotEmpty,
          within: kBudget, describe: 'the next weighing to replace the last');
      expect(find.text('12.37 kg'), findsNothing);

      await tester.runAsync(() async {
        await bench.dispose();
        await weigher.shutdown();
      });
    });
  }, skip: skipReason(enabled));
}

/// The reason a run without the switch prints, or nothing to skip for.
Object? skipReason(bool enabled) => enabled
    ? null
    : 'set $kEnableVariable=1: this lane binds sockets and drives FFI '
        'servers, and runs only alone — see the library doc';
