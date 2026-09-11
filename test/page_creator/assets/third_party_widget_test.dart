import 'dart:async' show Completer, StreamController;
import 'dart:collection' show LinkedHashMap;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/page_creator/assets/number.dart';
import 'package:tfc/page_creator/assets/ratio_number.dart';
import 'package:tfc/page_creator/assets/sensor.dart';
import 'package:tfc/page_creator/assets/third_party.dart';
import 'package:tfc/theme.dart'
    show AppColorScheme, HmiColorRole, HmiStateColors, MutedColors, themesForScheme;
import 'package:tfc/page_creator/assets/third_party_painter.dart';
import 'package:tfc/providers/database.dart' show databaseProvider;
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/database.dart' show Database;
import 'package:tfc_dart/core/state_man.dart' show StateMan;

void main() {
  // ProviderScope + MaterialApp so showDialog has a Navigator. No provider
  // overrides — these tests exercise the stale path (no value from the stream
  // yet), so no real StateMan is needed. Mirrors `sensor_widget_test.dart`.
  Widget wrap(Widget child) {
    return ProviderScope(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  // For panes that embed the live readout widgets: their timeseries mixin
  // arms timers only once `databaseProvider` resolves, and a widget test has
  // neither a database nor the prefs it would read the config from. A future
  // that never completes parks the mixin at its first await — the readout
  // still builds and shows `---`, which is all these tests need.
  Widget wrapWithParkedDatabase(Widget child) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) => Completer<Database?>().future),
      ],
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  LEDPainter ledPainterOf(WidgetTester tester) {
    final paints = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where((c) => c.painter is LEDPainter);
    expect(paints, hasLength(1),
        reason: 'Exactly one run-status LED per asset.');
    return paints.single.painter! as LEDPainter;
  }

  group('Run-status LED', () {
    testWidgets('renders the unknown state when no run key is configured',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(runKey: '');
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 160,
        child: ThirdPartyEquipment(config: config),
      )));

      // A null colour is LEDPainter's unknown state (grey + "!"). Claiming
      // "stopped" when we simply have no signal would be a lie on an HMI.
      expect(ledPainterOf(tester).color, isNull);
    });

    testWidgets('renders the unknown state while the stream has no value',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(runKey: 'ST301.MV01.Running');
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 160,
        child: ThirdPartyEquipment(config: config),
      )));

      expect(ledPainterOf(tester).color, isNull);
    });

    testWidgets('body resolves running and stopped to the configured colours',
        (tester) async {
      // ThirdPartyEquipmentBody is the seam the live widget feeds — asserting
      // here keeps the colour mapping covered without a StateMan.
      for (final entry in {
        Colors.green: 'running',
        Colors.red: 'stopped',
      }.entries) {
        await tester.pumpWidget(wrap(ThirdPartyEquipmentBody(
          painter: thirdPartyPainterFor(ThirdPartyEquipmentKind.multivac,
              color: Colors.blueGrey, strokeWidth: 2),
          paintSize: const Size(300, 100),
          ledColor: entry.key,
        )));
        expect(ledPainterOf(tester).color, entry.key,
            reason: 'LED must show the ${entry.value} colour.');
      }
    });
  });

  group('Stream lifecycle', () {
    testWidgets('the stream is hoisted once and survives rebuilds',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(runKey: 'ST301.MV01.Running');
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 160,
        child: ThirdPartyEquipment(config: config),
      )));

      final dynamic state = tester.state(find.byType(ThirdPartyEquipment));
      final first = state.debugRunStream;
      expect(first, isNotNull);

      // Rebuild with the same config instance — the editor mutates configs in
      // place, so this is the common case. Recreating the stream here would
      // mean an OPC UA monitored-item create/cancel every frame.
      await tester.pump();
      expect(identical(state.debugRunStream, first), isTrue);
    });

    testWidgets('changing the run key re-hoists the stream', (tester) async {
      final config = ThirdPartyEquipmentConfig(runKey: 'ST301.MV01.Running');
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 160,
        child: ThirdPartyEquipment(config: config),
      )));

      final dynamic state = tester.state(find.byType(ThirdPartyEquipment));
      final first = state.debugRunStream;

      config.runKey = 'ST301.MV01.Stopped';
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 160,
        child: ThirdPartyEquipment(config: config),
      )));

      expect(identical(state.debugRunStream, first), isFalse);
    });

    testWidgets('clearing the run key drops the stream entirely',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(runKey: 'ST301.MV01.Running');
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 160,
        child: ThirdPartyEquipment(config: config),
      )));

      final dynamic state = tester.state(find.byType(ThirdPartyEquipment));
      config.runKey = '';
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 160,
        child: ThirdPartyEquipment(config: config),
      )));

      expect(state.debugRunStream, isNull);
    });
  });

  group('Tap opens the side pane', () {
    // A docked SidePane rather than a dialog: this is equipment on a running
    // line, and a modal barrier would hide the machine being diagnosed.
    tearDown(closeSidePane);

    testWidgets('tap opens a read-only pane, not the editor', (tester) async {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.strappingLine,
        strapMachines: 2,
        runKey: 'ST301.PK01.STRAP01.Running',
        tag: 'STRAP-01',
        notes: 'Two StrapX heads in series.',
      );
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 200,
        child: ThirdPartyEquipment(config: config),
      )));

      await tester.tap(find.byType(ThirdPartyEquipment));
      await tester.pumpAndSettle();

      expect(find.byType(SidePane), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing,
          reason: 'The pane must not be a modal dialog.');

      // Header carries the tag, and the machine name follows the head count
      // into a real model number. showTag is off (the default), so the tag
      // reaches the operator through the pane while the page label — which
      // scales with the asset's big bounding box — stays unpainted.
      expect(config.showTag, isFalse);
      expect(config.text, isNull,
          reason: 'AssetStack must see no label while showTag is off.');
      expect(find.text('STRAP-01'), findsOneWidget);
      expect(
          find.textContaining('2 x StrapX'), findsWidgets,
          reason: 'Strapper count must reach the pane title.');
      expect(find.text('NOTES'), findsOneWidget);

      // Negative locks — the runtime tap must never expose editor controls.
      expect(find.byType(DropdownButton<ThirdPartyEquipmentKind>), findsNothing,
          reason: 'Runtime tap must NOT open the config editor.');
      expect(find.text('Run Status Key'), findsNothing,
          reason: 'The editor KeyField label must not appear at runtime.');
    });

    testWidgets('the palletising row pane names the station count and shows '
        'no Status section', (tester) async {
      // The row publishes no handshake — see [hasStatusTable] — so the pane
      // must omit the Status section entirely rather than draw a column of
      // permanently-unknown diodes. The station count reaches the title the
      // same way the strapper count does.
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.optimarPalletiser,
        robotStations: 3,
        runKey: 'ST301.PK01.PAL01.Running',
        notes: 'Guarded row — key the gate before entering.',
      );
      await tester.pumpWidget(wrap(SizedBox(
        width: 320,
        height: 220,
        child: ThirdPartyEquipment(config: config),
      )));

      await tester.tap(find.byType(ThirdPartyEquipment));
      await tester.pumpAndSettle();

      expect(find.byType(SidePane), findsOneWidget);
      expect(find.textContaining('3 stations'), findsWidgets,
          reason: 'Station count must reach the pane title.');
      expect(find.textContaining('Optimar'), findsWidgets,
          reason: 'The supplier names the machine on the pane.');
      expect(find.text('STATUS'), findsNothing,
          reason: 'No handshake to read, so no Status section.');
      // The rest of the pane is unaffected.
      expect(find.text('NOTES'), findsOneWidget);
      expect(find.text('EQUIPMENT'), findsOneWidget);
    });

    testWidgets('tapping the same machine again toggles the pane shut',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(runKey: '');
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 160,
        child: ThirdPartyEquipment(config: config),
      )));

      await tester.tap(find.byType(ThirdPartyEquipment));
      await tester.pumpAndSettle();
      expect(isSidePaneOpen(), isTrue);

      await tester.tap(find.byType(ThirdPartyEquipment));
      await tester.pumpAndSettle();
      expect(isSidePaneOpen(), isFalse);
    });

    testWidgets('pane status chip reflects an unconfigured key',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(runKey: '');
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 160,
        child: ThirdPartyEquipment(config: config),
      )));

      await tester.tap(find.byType(ThirdPartyEquipment));
      await tester.pumpAndSettle();

      expect(find.text('No key'), findsOneWidget);
    });

    testWidgets('pane status chip is Stale while the stream has no value',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(runKey: 'ST301.MV01.Running');
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 160,
        child: ThirdPartyEquipment(config: config),
      )));

      await tester.tap(find.byType(ThirdPartyEquipment));
      await tester.pumpAndSettle();

      // Not "Stopped" — we have no signal, which is a different thing.
      expect(find.text('Stale'), findsOneWidget);
      expect(find.text('Stopped'), findsNothing);
    });

    testWidgets(
        'the pane reads the machine, not its wiring: live figures per '
        'checkweigher, no key names, no footprint, no polarity',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        runKey: 'ST201.SB01.Running',
        children: buildSpeedBatcherStationChildren(acceptWindowMinutes: 30),
      );
      await tester.pumpWidget(wrapWithParkedDatabase(SizedBox(
        width: 300,
        height: 600,
        child: ThirdPartyEquipment(config: config),
      )));

      await tester.tap(find.byType(ThirdPartyEquipment));
      await tester.pumpAndSettle();

      // One live accept-rate and one live weight row per checkweigher. The
      // figures are the point — the operator opens the pane to read the
      // machine.
      expect(find.text('Accept rate, checkweigher 1'), findsOneWidget);
      expect(find.text('Accept rate, checkweigher 2'), findsOneWidget);
      // The averaging window is stated once for both, on its own row: a
      // rolling figure must never read as "right now".
      expect(find.text('Accept rate window'), findsOneWidget);
      expect(find.text('Weight, checkweigher 1'), findsOneWidget);
      expect(find.text('Weight, checkweigher 2'), findsOneWidget);
      // No PLC in this test, so the value is `---`, but the unit must be
      // there: the belt readout has no room for it, the pane does. kg is
      // the default when the child has no unit configured.
      expect(find.text('--- kg'), findsNWidgets(2));

      // Each figure carries a visible way into its chart — the readout's own
      // tap-through is invisible, and an operator should not have to guess.
      expect(find.byIcon(Icons.bar_chart), findsNWidgets(2),
          reason: 'One accept/reject chart button per checkweigher.');
      expect(find.byIcon(Icons.show_chart), findsNWidgets(2),
          reason: 'One weight-trend button per checkweigher.');

      // Wiring and boilerplate stay out: no key strings, no polarity
      // wording, no footprint, no inventory of the box's children.
      expect(find.text('INSIDE THE BOX'), findsNothing);
      expect(find.text('RUN STATUS'), findsNothing);
      expect(find.textContaining('ST201.SB01'), findsNothing,
          reason: 'Key names are wiring, not operator information.');
      expect(find.textContaining('running when'), findsNothing);
      expect(find.text('Footprint'), findsNothing);
    });

    testWidgets('the accept-rate window can be picked from the pane',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        runKey: 'ST201.SB01.Running',
        children: buildSpeedBatcherStationChildren(acceptWindowMinutes: 30),
      );
      await tester.pumpWidget(wrapWithParkedDatabase(SizedBox(
        width: 300,
        height: 600,
        child: ThirdPartyEquipment(config: config),
      )));

      await tester.tap(find.byType(ThirdPartyEquipment));
      await tester.pumpAndSettle();

      expect(find.text('Accept rate window'), findsOneWidget);
      // The chart's own chips, not a picker of the pane's invention — the
      // two surfaces must offer the same windows, spelled the same way.
      ChoiceChip chipFor(String label) => tester
          .widgetList<ChoiceChip>(find.byType(ChoiceChip))
          .firstWhere((c) => (c.label as Text).data == label);
      expect(find.byType(ChoiceChip), findsNWidgets(6));
      // The pane opens on the configured window.
      expect(chipFor('30m').selected, isTrue);

      await tester.tap(find.widgetWithText(ChoiceChip, '4h'));
      await tester.pumpAndSettle();

      // One picker, both scales: reading the two checkweighers over
      // different windows would compare nothing to nothing.
      expect(chipFor('4h').selected, isTrue);
      expect(chipFor('30m').selected, isFalse);
      // The two in the pane carry the override; the two painted on the mimic
      // are the same configs and must be left on their configured window.
      final paneRatios = tester
          .widgetList<RatioNumberWidget>(find.byType(RatioNumberWidget))
          .where((w) => w.intervalOverride != null)
          .toList();
      expect(paneRatios, hasLength(2),
          reason: 'Both readouts count over the picked window.');
      expect(
          paneRatios
              .every((w) => w.intervalOverride == const Duration(minutes: 240)),
          isTrue);
      // Every window the picker offers, so the cache the count comes from is
      // filled to the widest of them rather than to the configured one.
      expect(paneRatios.first.intervalOptions, contains(240));

      // Pane-local: widening the view to see whether a bad minute was a blip
      // is a question, not a page edit.
      expect(config.acceptWindowMinutes, 30);
      expect(
          config.children
              .map((e) => e.child)
              .whereType<RatioNumberConfig>()
              .every((r) => r.sinceMinutes == const Duration(minutes: 30)),
          isTrue);
    });

    testWidgets('a single window is stated, not offered as a picker',
        (tester) async {
      // A readout stripped down to one preset has nothing to pick between,
      // and an empty dropdown is worse than no dropdown.
      final children = buildSpeedBatcherStationChildren(acceptWindowMinutes: 30);
      for (final entry in children) {
        final child = entry.child;
        if (child is RatioNumberConfig) child.intervalPresets = [30];
      }
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        runKey: 'ST201.SB01.Running',
        children: children,
      );
      await tester.pumpWidget(wrapWithParkedDatabase(SizedBox(
        width: 300,
        height: 600,
        child: ThirdPartyEquipment(config: config),
      )));

      await tester.tap(find.byType(ThirdPartyEquipment));
      await tester.pumpAndSettle();

      // The row stays — the window must always be on the pane — but there is
      // nothing to pick between, so it reads as a plain value.
      expect(find.text('Accept rate window'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('30\u{00A0}min'), findsOneWidget);
    });

    testWidgets('a SpeedBatcher pane carries the Status section with all '
        'five diodes', (tester) async {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        runKey: '',
        statusKey: '',
      );
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 500,
        child: ThirdPartyEquipment(config: config),
      )));

      await tester.tap(find.byType(ThirdPartyEquipment));
      await tester.pumpAndSettle();

      // The section shows even unconfigured — five unknown diodes tell the
      // operator the feature exists; a silently absent section would not.
      expect(find.text('STATUS'), findsOneWidget);
      for (final bit in speedBatcherStatusBits) {
        expect(find.text(bit.label), findsOneWidget,
            reason: '${bit.member} must have its diode row.');
      }
    });

    // Used to assert the opposite: that only the SpeedBatcher had a Status
    // section, because only it has a `p_stat_*` handshake struct. Every other
    // machine now gets one too, built from the per-kind suffix list in
    // [kEquipmentStatusBits] appended to a statusKey *prefix* -- the permits
    // are separate globals per line rather than a struct.
    //
    // Driven off that map rather than a hardcoded list of kinds, so adding a
    // machine to it cannot leave this test describing the old world.
    for (final entry in kEquipmentStatusBits.entries) {
      testWidgets('${entry.key.name} gets a Status section', (tester) async {
        final config = ThirdPartyEquipmentConfig(runKey: '')
          ..kind = entry.key
          ..statusKey = 'BER02';
        await tester.pumpWidget(wrap(SizedBox(
          width: 300,
          height: 160,
          child: ThirdPartyEquipment(config: config),
        )));

        await tester.tap(find.byType(ThirdPartyEquipment));
        await tester.pumpAndSettle();

        expect(find.text('STATUS'), findsOneWidget,
            reason: '${entry.key.name} has ${entry.value.length} status bits '
                'configured, so the pane must show them');
      });
    }

    testWidgets('a lit diode follows the active colour scheme',
        (tester) async {
      // The complaint this pins: a hardcoded Colors.green (#4CAF50) ignores
      // the operator's scheme choice and paints Material's saturated green
      // beside a muted, gray-first UI. Under AppColorScheme.muted every lit
      // diode must resolve to MutedColors.runningGreen.
      final (lightMuted, _) = themesForScheme(AppColorScheme.muted);
      final status = DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
        'p_stat_InfeedPermitted': true,
      }));

      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: lightMuted,
          home: Scaffold(
            body: StructStatusDiodes(
              status: status,
              bits: const [
                StructStatusBit('p_stat_InfeedPermitted', 'Ready',
                    HmiColorRole.green),
              ],
              machine: 'strapping machine',
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final lit = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((c) => c.painter)
          .whereType<LEDPainter>()
          .where((p) => p.color != null)
          .toList();
      expect(lit, hasLength(1));
      expect(lit.single.color!.toARGB32(),
          MutedColors.runningGreen.toARGB32(),
          reason: 'a lit diode must come from HmiStateColors, not Colors.green');
    });

    test('no kind reads its status both ways', () {
      // The two maps are the whole switch between "one subscription for the
      // struct" and "one per bit". A kind in both would render two Status
      // sections and hold both sets of subscriptions open -- the machine
      // showing its handshake twice, in two vocabularies.
      for (final kind in ThirdPartyEquipmentKind.values.where(isStructBacked)) {
        expect(kEquipmentStatusBits[kind], isNull,
            reason: '${kind.name} is struct-backed; it must not also have a '
                'suffix list');
      }
    });

    // Driven off the map rather than a hardcoded list of kinds, so adding a
    // struct-backed machine cannot leave this test describing the old world.
    for (final entry in kStructStatusBits.entries) {
      testWidgets('${entry.key.name} draws struct diodes, not prefix ones',
          (tester) async {
        final config = ThirdPartyEquipmentConfig(runKey: '')
          ..kind = entry.key
          ..statusKey = 'STRUCT';
        await tester.pumpWidget(wrap(SizedBox(
          width: 300,
          height: 160,
          child: ThirdPartyEquipment(config: config),
        )));

        await tester.tap(find.byType(ThirdPartyEquipment));
        await tester.pumpAndSettle();

        expect(find.byType(StructStatusDiodes), findsOneWidget);
        expect(find.byType(EquipmentStatusDiodes), findsNothing,
            reason: '${entry.key.name} would be showing its handshake twice');
      });
    }

    testWidgets('a struct kind hoists the struct key, not per-bit keys',
        (tester) async {
      // The point of the struct path: the strapper costs ONE subscription for
      // every diode. Before this it appended .PermitInfeed/.PermitOutfeed to
      // the prefix, which was both three keys and the wrong member names --
      // FB_StrappingLine spells them p_stat_InfeedPermitted/OutfeedPermitted.
      final config = ThirdPartyEquipmentConfig(runKey: '')
        ..kind = ThirdPartyEquipmentKind.strappingLine
        ..statusKey = 'STM01';
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 160,
        child: ThirdPartyEquipment(config: config),
      )));
      await tester.pumpAndSettle();

      final dynamic state = tester.state(find.byType(ThirdPartyEquipment));
      expect(state.debugStatusStream, isNotNull,
          reason: 'the struct key must be hoisted');
      expect(state.debugStatusBitKeys, isEmpty,
          reason: 'a struct kind must open no per-bit subscriptions');
    });

    testWidgets('the pane does not outlive the asset that opened it',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(runKey: '');
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 160,
        child: ThirdPartyEquipment(config: config),
      )));

      await tester.tap(find.byType(ThirdPartyEquipment));
      await tester.pumpAndSettle();
      expect(isSidePaneOpen(), isTrue);

      // Navigating away disposes the asset. A docked pane lives in the root
      // overlay, so without the dispose hook it would keep showing a machine
      // that is no longer on screen.
      await tester.pumpWidget(wrap(const SizedBox(width: 300, height: 160)));
      await tester.pumpAndSettle();

      expect(isSidePaneOpen(), isFalse);
    });
  });

  group('Children inside the box', () {
    testWidgets('a child asset is built inside the machine area',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        children: [
          ThirdPartyChildEntry(
            offsetX: 0.25,
            offsetY: 0.65,
            child: ConveyorConfig.preview(),
          ),
        ],
      );
      await tester.pumpWidget(wrap(SizedBox(
        width: 320,
        height: 600,
        child: ThirdPartyEquipment(config: config),
      )));
      await tester.pump();

      expect(find.byType(Conveyor), findsOneWidget,
          reason: 'A live Conveyor must render inside the dotted box.');
    });

    testWidgets('an upright readout stays level when the machine is rotated',
        (tester) async {
      // The machine gets rotated to match the plant layout; the numbers must
      // not follow it round.
      const paintSize = Size(320, 600);
      await tester.pumpWidget(wrap(ThirdPartyEquipmentBody(
        painter: thirdPartyPainterFor(ThirdPartyEquipmentKind.speedBatcher,
            color: Colors.blueGrey, strokeWidth: 2),
        paintSize: paintSize,
        ledColor: Colors.green,
        parentAngleDegrees: 90,
        children: [
          ThirdPartyChildEntry(
            keepUpright: true,
            child: NumberConfig(key: ''),
          ),
        ],
      )));
      await tester.pump();

      final rotations = tester
          .widgetList<Transform>(find.byType(Transform))
          .map((t) => t.transform)
          .toList();
      // Somewhere in the subtree the readout is turned back by -90 degrees.
      expect(
        rotations.any((m) => (m.getRotation().entry(0, 1) - 1.0).abs() < 1e-6),
        isTrue,
        reason: 'A parent at 90 degrees must counter-rotate its readouts.',
      );
    });

    testWidgets('machinery children are NOT counter-rotated', (tester) async {
      const paintSize = Size(320, 600);
      await tester.pumpWidget(wrap(ThirdPartyEquipmentBody(
        painter: thirdPartyPainterFor(ThirdPartyEquipmentKind.speedBatcher,
            color: Colors.blueGrey, strokeWidth: 2),
        paintSize: paintSize,
        ledColor: Colors.green,
        parentAngleDegrees: 90,
        children: [
          ThirdPartyChildEntry(child: SensorConfig.preview()),
        ],
      )));
      await tester.pump();

      // A sensor belongs to the machine and must turn with it, so the body
      // adds no counter-rotation of its own.
      final counterRotations = tester
          .widgetList<Transform>(find.byType(Transform))
          .where((t) =>
              (t.transform.getRotation().entry(0, 1) - 1.0).abs() < 1e-6);
      expect(counterRotations, isEmpty);
    });

    testWidgets('the child sits within the drawing, clear of the LED header',
        (tester) async {
      const paintSize = Size(320, 600);
      final entry = ThirdPartyChildEntry(
        offsetX: 0.5,
        offsetY: 0.5,
        child: SensorConfig.preview(),
      );
      await tester.pumpWidget(wrap(ThirdPartyEquipmentBody(
        painter: thirdPartyPainterFor(ThirdPartyEquipmentKind.speedBatcher,
            color: Colors.blueGrey, strokeWidth: 2),
        paintSize: paintSize,
        ledColor: Colors.green,
        children: [entry],
      )));
      await tester.pump();

      final area = thirdPartyMachineArea(paintSize);
      final childCentre = tester.getCenter(find.byType(Sensor));
      final bodyTopLeft = tester.getTopLeft(find.byType(ThirdPartyEquipmentBody));
      final local = childCentre - bodyTopLeft;

      // offset 0.5/0.5 must land at the centre of the MACHINE AREA, not of
      // the whole asset rect — otherwise children drift when the LED header
      // changes height.
      expect(local.dx, closeTo(area.center.dx, 1.0));
      expect(local.dy, closeTo(area.center.dy, 1.0));
    });
  });

  group('SpeedBatcher status diodes', () {
    List<LEDPainter> diodePaintersOf(WidgetTester tester) => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where((c) => c.painter is LEDPainter)
        .map((c) => c.painter! as LEDPainter)
        .toList();

    testWidgets('each diode resolves its bit: on colour, off white, '
        'missing unknown', (tester) async {
      // Only Cleaning is confirmed present — BatchReady, DropOk and Dropped
      // are absent from the struct, the way a PLC that does not expose them
      // would hand it to us. (`p_stat_Running` is still in the struct and
      // still read, by [speedBatcherPaneStatus] for the header badge; it just
      // no longer draws a row of its own.)
      final status = DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
        'p_stat_Running': true,
        'p_stat_Cleaning': false,
      }));
      await tester.pumpWidget(wrap(SizedBox(
        width: 320,
        child: StructStatusDiodes(status: status, bits: speedBatcherStatusBits, machine: 'SpeedBatcher'),
      )));

      final painters = diodePaintersOf(tester);
      expect(painters, hasLength(speedBatcherStatusBits.length));
      // Column order == speedBatcherStatusBits order. The lit colour comes
      // from the scheme now, so it is compared against the same role the bit
      // declares rather than a hardcoded Colors.green -- `wrap` supplies no
      // HmiStateColors, so this resolves through theme.dart's Solarized
      // fallback.
      expect(painters[0].color, Colors.white, reason: 'Cleaning is false');
      for (var i = 1; i < painters.length; i++) {
        expect(painters[i].color, isNull,
            reason: 'A bit the PLC does not expose must render unknown, '
                'not off.');
      }
    });

    testWidgets('Cleaning lights blue, matching the retired flat asset',
        (tester) async {
      final status = DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
        'p_stat_Cleaning': true,
      }));
      await tester.pumpWidget(wrap(SizedBox(
        width: 320,
        child: StructStatusDiodes(status: status, bits: speedBatcherStatusBits, machine: 'SpeedBatcher'),
      )));

      final ctx = tester.element(find.byType(StructStatusDiodes));
      expect(diodePaintersOf(tester)[0].color, HmiColorRole.blue.resolve(ctx));
    });
  });

  group('Status stream lifecycle', () {
    testWidgets('a SpeedBatcher with a status key hoists the struct stream',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        statusKey: 'SB1',
      );
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 500,
        child: ThirdPartyEquipment(config: config),
      )));

      final dynamic state = tester.state(find.byType(ThirdPartyEquipment));
      expect(state.debugStatusStream, isNotNull);
    });

    testWidgets('no status key — no stream', (tester) async {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        statusKey: '',
      );
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 500,
        child: ThirdPartyEquipment(config: config),
      )));

      final dynamic state = tester.state(find.byType(ThirdPartyEquipment));
      expect(state.debugStatusStream, isNull);
    });

    // Driven off the map rather than naming one kind, because the naming is
    // what rotted: this read `multivac` until [kStructStatusBits] took the
    // Multivac in, and then asserted the opposite of the truth. Three kinds
    // have migrated in three PRs, so a kind now moves itself between this loop
    // and the struct one below instead of waiting on someone to retype a name.
    for (final kind in ThirdPartyEquipmentKind.values
        .where((k) => !isStructBacked(k))) {
      testWidgets(
          'a leftover status key on ${kind.name} holds no struct subscription',
          (tester) async {
        // The config keeps the string when the kind changes under it — a
        // prefix kind must not subscribe to a struct for a pane section it
        // never shows. Its diodes come from per-bit keys instead.
        final config = ThirdPartyEquipmentConfig(
          kind: kind,
          statusKey: 'SB1',
        );
        await tester.pumpWidget(wrap(SizedBox(
          width: 300,
          height: 160,
          child: ThirdPartyEquipment(config: config),
        )));

        final dynamic state = tester.state(find.byType(ThirdPartyEquipment));
        expect(state.debugStatusStream, isNull);
      });
    }

    // The other half of the same invariant, and the half that had no test at
    // all: [kStructStatusBits] exists to buy one subscription instead of one
    // per diode, so a struct kind must hoist the struct AND open no per-bit
    // keys. Both the strapper (#356) and the Multivac (#368) crossed over
    // with nothing asserting they landed.
    for (final kind in ThirdPartyEquipmentKind.values.where(isStructBacked)) {
      testWidgets('${kind.name} hoists the struct and no per-bit keys',
          (tester) async {
        final config = ThirdPartyEquipmentConfig(
          kind: kind,
          statusKey: 'SB1',
        );
        await tester.pumpWidget(wrap(SizedBox(
          width: 300,
          height: 500,
          child: ThirdPartyEquipment(config: config),
        )));

        final dynamic state = tester.state(find.byType(ThirdPartyEquipment));
        expect(state.debugStatusStream, isNotNull,
            reason: '${kind.name}: the struct stream is the subscription.');
        expect(state.debugStatusBitKeys, isEmpty,
            reason: '${kind.name}: a struct kind must not also open one '
                'subscription per diode.');
      });
    }

    testWidgets('changing the status key re-hoists; clearing it drops it',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
        statusKey: 'SB1',
      );
      Widget build() => wrap(SizedBox(
            width: 300,
            height: 500,
            child: ThirdPartyEquipment(config: config),
          ));
      await tester.pumpWidget(build());

      final dynamic state = tester.state(find.byType(ThirdPartyEquipment));
      final first = state.debugStatusStream;

      config.statusKey = 'SB2';
      await tester.pumpWidget(build());
      expect(identical(state.debugStatusStream, first), isFalse);

      config.statusKey = '';
      await tester.pumpWidget(build());
      expect(state.debugStatusStream, isNull);
    });
  });

  group('Config editor', () {
    testWidgets('kind dropdown lists every machine and switches the drawing',
        (tester) async {
      final config = ThirdPartyEquipmentConfig();
      await tester.pumpWidget(wrap(
        Builder(builder: (context) => config.configure(context)),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<ThirdPartyEquipmentKind>));
      await tester.pumpAndSettle();

      for (final kind in ThirdPartyEquipmentKind.values) {
        expect(find.text(kind.label), findsWidgets,
            reason: '${kind.name} must be offered in the dropdown.');
      }

      await tester.tap(find.text(ThirdPartyEquipmentKind.boxErector.label).last);
      await tester.pumpAndSettle();

      expect(config.kind, ThirdPartyEquipmentKind.boxErector);
    });

    testWidgets('SpeedBatcher box is static — no free-form add buttons',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.speedBatcher,
      );
      await tester.pumpWidget(wrap(
        Builder(builder: (context) => config.configure(context)),
      ));
      await tester.pumpAndSettle();

      // The station's contents are the scaffold and nothing else — the
      // operator points the scaffolded children at tags, but cannot place
      // arbitrary assets inside the box.
      expect(find.widgetWithText(FilledButton, 'Readout'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Conveyor'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Sensor'), findsNothing);
      // Scaffold recovery stays available.
      expect(find.text('Build checkweighers'), findsOneWidget);
    });

    testWidgets('other kinds keep the free-form add buttons', (tester) async {
      final config = ThirdPartyEquipmentConfig(); // multivac
      await tester.pumpWidget(wrap(
        Builder(builder: (context) => config.configure(context)),
      ));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Readout'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Conveyor'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Sensor'), findsOneWidget);
      expect(find.text('Build checkweighers'), findsNothing);
    });

    // Used to assert the field was SpeedBatcher-only. Every kind with a diode
    // table must be able to point those diodes at keys — with the field gated
    // to the SpeedBatcher the other machines' diodes could never leave the
    // unknown state. Driven off [hasStatusTable] rather than a kind list, for
    // the same reason the subscription loops above are: the naming is what
    // rots when a kind crosses over.
    testWidgets(
        'every kind with a diode table exposes a status key field that writes '
        'the config', (tester) async {
      for (final kind in ThirdPartyEquipmentKind.values.where(hasStatusTable)) {
        final config = ThirdPartyEquipmentConfig(kind: kind);
        await tester.pumpWidget(wrap(
          Builder(builder: (context) => config.configure(context)),
        ));
        await tester.pumpAndSettle();

        // A struct kind reads members of one node; the rest read separate
        // bools under a prefix, and the label says which it is.
        // Grouped kinds are struct-backed too -- the box erector reads one
        // node like the rest, it just draws the members as groups.
        final label = isStructBacked(kind)
            ? 'Status Struct Key'
            : 'Status Key Prefix';
        final field = find.widgetWithText(TextField, label);
        expect(field, findsOneWidget,
            reason: '${kind.name} has a Status section in its side pane, so '
                'its key must be settable in the editor.');

        await tester.enterText(field, 'CN22.Aligner');
        expect(config.statusKey, 'CN22.Aligner',
            reason: '${kind.name}: typing into the field must land in '
                'config.statusKey.');

        // Fresh tree per kind — the editor holds per-widget controllers.
        await tester.pumpWidget(const SizedBox());
      }
    });

    // The other half of that invariant. A kind the PLC publishes no handshake
    // for gets NO status key field: it would feed nothing, since the pane
    // draws no Status section for such a kind and the extra loose diodes read
    // complete keys of their own. A field that silently feeds nothing is the
    // failure this guards.
    testWidgets('a kind with no diode table offers no status key field',
        (tester) async {
      final tableless =
          ThirdPartyEquipmentKind.values.where((k) => !hasStatusTable(k));
      expect(tableless, isNotEmpty,
          reason: 'this test is vacuous if every kind has a table.');

      for (final kind in tableless) {
        final config = ThirdPartyEquipmentConfig(kind: kind);
        await tester.pumpWidget(wrap(
          Builder(builder: (context) => config.configure(context)),
        ));
        await tester.pumpAndSettle();

        expect(find.widgetWithText(TextField, 'Status Struct Key'), findsNothing,
            reason: '${kind.name} publishes no struct.');
        expect(find.widgetWithText(TextField, 'Status Key Prefix'), findsNothing,
            reason: '${kind.name} has no suffixes to append.');
        // The escape hatch is still there: a loose permit can be added as an
        // extra diode reading its own complete key.
        expect(find.text('Extra status diodes'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a struct kind help text names the members one node feeds',
        (tester) async {
      // A struct kind's key is one NODE, so the help text names the members it
      // carries — the engineer is picking a node, not composing key names.
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.multivac,
      );
      await tester.pumpWidget(wrap(
        Builder(builder: (context) => config.configure(context)),
      ));
      await tester.pumpAndSettle();

      for (final member in structMembersOf(ThirdPartyEquipmentKind.multivac)) {
        expect(find.textContaining(member), findsOneWidget,
            reason: 'the struct help text must name every member the one '
                'subscription feeds.');
      }
    });

    testWidgets('a prefix kind help text names the suffixes it appends',
        (tester) async {
      // The box erector reads ONE KEY PER PLC MEMBER, so its field is a
      // PREFIX and the help text has to spell out what gets appended to it —
      // those are the mappings the engineer then has to create. Naming
      // members instead would describe a struct that does not exist.
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.boxErector,
      );
      await tester.pumpWidget(wrap(
        Builder(builder: (context) => config.configure(context)),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('Status Key Prefix'), findsOneWidget,
          reason: 'the field is labelled as a prefix, not a struct key.');
      for (final bit
          in kEquipmentStatusBits[ThirdPartyEquipmentKind.boxErector]!) {
        expect(find.textContaining('.${bit.suffix}'), findsOneWidget,
            reason: 'the prefix help text must name every appended suffix.');
      }
      // And the two that are NOT diodes. They are named here or nowhere: an
      // engineer reading only the diode list would never create them, and the
      // link gate and the trend would quietly never appear.
      expect(find.textContaining('.$kBoxErectorCommsSuffix'), findsOneWidget);
      expect(find.textContaining('.$kBoxErectorBpmSuffix'), findsOneWidget);
    });
  });

  group('Status bit subscriptions', () {
    // One test per kind in the map: the diodes are only as real as the
    // subscriptions behind them. These went through keyStreamProvider with a
    // bare ref.read once — the autoDispose provider had no listener, was
    // disposed at end of frame, and closed the stream before the first value
    // arrived, so every diode sat at unknown no matter what was configured.
    for (final entry in kEquipmentStatusBits.entries) {
      testWidgets('${entry.key.name} holds a live subscription per diode',
          (tester) async {
        final stateMan = _RecordingStateMan();
        final config = ThirdPartyEquipmentConfig(runKey: '')
          ..kind = entry.key
          ..statusKey = 'CN22.Machine';
        await tester.pumpWidget(ProviderScope(
          overrides: [
            stateManProvider.overrideWith((ref) async => stateMan),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  height: 160,
                  child: ThirdPartyEquipment(config: config),
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        expect(
          stateMan.controllers.keys.toSet(),
          {
            for (final bit in entry.value) 'CN22.Machine.${bit.suffix}',
            // Not diodes, but they ride the same map and the same teardown.
            // The link-health key decides whether any of the others may be
            // believed; the run key drives the pane header and the machine's
            // LED, and lost its own diode BECAUSE those two already say it --
            // so it has to stay subscribed here, or removing a duplicate row
            // would have taken the run state away with it.
            if (entry.key == ThirdPartyEquipmentKind.boxErector) ...{
              'CN22.Machine.$kBoxErectorCommsSuffix',
              'CN22.Machine.$kBoxErectorRunSuffix',
            },
          },
          reason: '${entry.key.name}: every diode must subscribe its '
              'prefix.suffix key.',
        );

        // And the subscription is alive: a value pushed now reaches the
        // pane's diode row instead of hitting a closed stream.
        final first = entry.value.first;
        stateMan.controllers['CN22.Machine.${first.suffix}']!
            .add(DynamicValue(value: true));
        await tester.pump();

        await tester.tap(find.byType(ThirdPartyEquipment));
        await tester.pumpAndSettle();
        final diodes = tester.widget<EquipmentStatusDiodes>(
            find.byType(EquipmentStatusDiodes));
        expect(diodes.values[first.suffix], isTrue,
            reason: '${entry.key.name}: the ${first.suffix} value off the '
                'wire must light its diode.');
      });
    }
  });

  group('Extra loose status diodes', () {
    tearDown(closeSidePane);

    testWidgets(
        'a declared extra bit renders after the struct diodes and tracks its '
        'own key', (tester) async {
      // The immediate use: a struct-backed Multivac whose outfeed permit is a
      // separate global in a different namespace (MVC0n.PermitOutfeed), not a
      // member of SP_Packing_HMI. It reaches the pane only through extraBits.
      final stateMan = _RecordingStateMan();
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.multivac,
        runKey: '',
        statusKey: 'SPB02.Multivac',
        extraBits: const [
          ExtraStatusBit(
            key: 'MVC02.PermitOutfeed',
            label: '{m} may send boxes on',
            onRole: HmiColorRole.blue,
          ),
        ],
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => stateMan),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 400,
                child: ThirdPartyEquipment(config: config),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // The full key is subscribed directly, not appended to statusKey.
      final dynamic state = tester.state(find.byType(ThirdPartyEquipment));
      expect(state.debugExtraBitKeys, {'MVC02.PermitOutfeed'});

      // The subscription is alive: a value pushed now reaches the diode.
      stateMan.controllers['MVC02.PermitOutfeed']!
          .add(DynamicValue(value: true));
      await tester.pump();

      await tester.tap(find.byType(ThirdPartyEquipment));
      await tester.pumpAndSettle();

      // The kind's own struct diodes still show, and the extra diode is drawn
      // AFTER them, with its exact label and its live value.
      expect(find.byType(StructStatusDiodes), findsOneWidget);
      expect(find.byType(ExtraStatusDiodes), findsOneWidget);
      final diodes =
          tester.widget<ExtraStatusDiodes>(find.byType(ExtraStatusDiodes));
      expect(diodes.values['MVC02.PermitOutfeed'], isTrue,
          reason: 'the value off the wire must light the extra diode');
      // The '{m}' template rendered through the shared substitution -- the
      // instance stores the template, the pane shows the finished sentence.
      expect(find.text('Multivac may send boxes on'), findsOneWidget);
    });

    testWidgets('an empty extraBits renders exactly as before — no extra diodes',
        (tester) async {
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.multivac,
        runKey: '',
        statusKey: '',
      );
      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 400,
        child: ThirdPartyEquipment(config: config),
      )));

      await tester.tap(find.byType(ThirdPartyEquipment));
      await tester.pumpAndSettle();

      // The struct Status section is unchanged; no extra diode section appears.
      expect(find.byType(StructStatusDiodes), findsOneWidget);
      expect(find.byType(ExtraStatusDiodes), findsNothing);

      final dynamic state = tester.state(find.byType(ThirdPartyEquipment));
      expect(state.debugExtraBitKeys, isEmpty,
          reason: 'no extra bits declared means no extra subscriptions');
    });

    testWidgets('the lit extra diode resolves its role colour, not a literal',
        (tester) async {
      // Rendered directly, like the StructStatusDiodes scheme test, so the
      // colour mapping is covered without a StateMan.
      await tester.pumpWidget(wrap(SizedBox(
        width: 320,
        child: ExtraStatusDiodes(
          bits: const [
            ExtraStatusBit(
              key: 'MVC02.PermitOutfeed',
              label: '{m} may send boxes on',
              onRole: HmiColorRole.blue,
            ),
          ],
          values: const {'MVC02.PermitOutfeed': true},
          machine: 'Multivac',
        ),
      )));
      await tester.pumpAndSettle();

      final ctx = tester.element(find.byType(ExtraStatusDiodes));
      final lit = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((c) => c.painter)
          .whereType<LEDPainter>()
          .where((p) => p.color != null)
          .toList();
      expect(lit, hasLength(1));
      expect(lit.single.color, HmiColorRole.blue.resolve(ctx),
          reason: 'a lit extra diode must resolve its scheme role');
    });

    testWidgets('a missing value renders the unknown diode, an off value white',
        (tester) async {
      await tester.pumpWidget(wrap(SizedBox(
        width: 320,
        child: ExtraStatusDiodes(
          bits: const [
            ExtraStatusBit(key: 'a.Off', label: 'Off row'),
            ExtraStatusBit(key: 'b.Unknown', label: 'Unknown row'),
          ],
          values: const {'a.Off': false},
          machine: 'Multivac',
        ),
      )));
      await tester.pumpAndSettle();

      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((c) => c.painter)
          .whereType<LEDPainter>()
          .toList();
      expect(painters, hasLength(2));
      expect(painters[0].color, Colors.white, reason: 'false is off (white)');
      expect(painters[1].color, isNull,
          reason: 'a key with no value is the grey `!`, not off');
    });
  });

  group('Box erector carton-chute row colour', () {
    testWidgets('is the SAME yellow a belt in manual gets, in every scheme',
        (tester) async {
      // Not "a yellow" -- THE yellow. `conveyor.dart` maps DriveState.manual to
      // `HmiStateColors.of(context).yellow` and prints it in the belt legend,
      // so a waiting row must resolve to the IDENTICAL Color, per scheme. If
      // the two ever diverge, "stalled but healthy" looks like one thing on a
      // belt and another on a pane, which is the whole reason the colour was
      // chosen.
      //
      // The carton-chute rows are per-instance [ExtraStatusBit]s -- only BER01
      // has those sensors -- so this is the colour an engineer picks from the
      // editor's dropdown, and it has to be the same one the kind's own rows
      // would have used.
      const starveRow = ExtraStatusBit(
        key: 'BER01.NoCartonBottoms',
        label: 'No carton bottoms',
        onRole: HmiColorRole.yellow,
      );

      for (final scheme in AppColorScheme.values) {
        for (final theme in [
          themesForScheme(scheme).$1,
          themesForScheme(scheme).$2,
        ]) {
          await tester.pumpWidget(MaterialApp(
            theme: theme,
            home: Builder(builder: (context) {
              expect(
                starveRow.onRole.resolve(context),
                HmiStateColors.of(context).yellow,
                reason: 'a waiting diode must be the scheme yellow ($scheme)',
              );
              return const SizedBox();
            }),
          ));
        }
      }
    });
  });

}

/// Hands out one controllable stream per subscribed key, so tests can both
/// assert what was subscribed and push values down it afterwards.
class _RecordingStateMan extends Fake implements StateMan {
  final Map<String, StreamController<DynamicValue>> controllers = {};

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    return controllers
        .putIfAbsent(key, () => StreamController<DynamicValue>.broadcast())
        .stream;
  }
}
