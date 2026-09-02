// The two halves of the report "the look of the trend for conveyor and box
// erector is not the same, also missing division line", pinned as assertions
// rather than as images.
//
// Goldens would catch a regression here too, but only on macOS and only by
// showing a reviewer two pictures and leaving them to spot the difference.
// These say what the difference IS, and they fail on Windows and in CI.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/conveyor.dart'
    show conveyorTrendTile, conveyorTrendColors, kConveyorFreqSeries;
import 'package:tfc/page_creator/assets/third_party.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart' show closeSidePane;

void main() {
  group('Trend tile parity — conveyor vs box erector', () {
    // Built through the real code, not re-declared here: if either pane's tile
    // is hand-tuned away from the other, these fail. That is the whole point —
    // the two used to be two sets of similar-looking numbers in two files, and
    // "similar-looking" is what an operator noticed from across the room.
    final conveyor = conveyorTrendTile(keyName: 'CVS01.CN01.FD01');
    final erector = boxErectorBpmTrendTile(keyName: 'BER01.CartonsPerMinute');

    test('the preview is the same height', () {
      // 84 vs 100. The erector's tile was built from the SENSOR's, which is a
      // two-state boolean timeline and is shorter for that reason; a numeric
      // line trend belongs at the conveyor's height.
      expect(erector.height, conveyor.height);
      expect(erector.height, kPaneTrendTileHeight);
    });

    test('tapping through opens the same size of window', () {
      // The erector took PaneGraphTile's 720x460 default, so the same gesture
      // on the machine next to it opened a visibly smaller chart.
      expect(erector.expandedSize, conveyor.expandedSize);
      expect(erector.expandedSize, kPaneTrendDialogSize);
    });

    test('both name their traces in the tile header, neither takes a label',
        () {
      // The erector's header was EMPTY: no label, no legend, just the size-up
      // glyph floating in a caption row. The conveyor's has carried its dots
      // since #384.
      expect(erector.legend, isNotEmpty,
          reason: 'the trace has to be named somewhere, and the chart legend '
              'is off in a preview this small');
      expect(conveyor.legend, isNotEmpty);
      expect(erector.label, isNull);
      expect(conveyor.label, isNull);
    });

    test('the primary trace is the same blue on both', () {
      // Was SolarizedColors.blue on the erector against Colors.blue
      // everywhere else — a near-match, which is worse than a contrast.
      expect(boxErectorBpmColors[kBoxErectorBpmSeries],
          conveyorTrendColors[kConveyorFreqSeries]);
    });

    test('every series name carries its unit, so the header explains itself',
        () {
      // The tile header replaces the chart's own legend, so it has to do the
      // legend's whole job. "Cartons/min", not "Cartons".
      for (final name in [...erector.legend.keys, ...conveyor.legend.keys]) {
        expect(name, matches(RegExp(r'[(/]')),
            reason: '"$name" names a series without naming its unit');
      }
    });
  });

  group('The division line between Equipment and Status', () {
    // The reported "missing division line". [PaneBody] draws a hairline
    // Divider between consecutive sections; the third-party pane used to
    // compose raw [PaneSection]s in a Column, which draws none — on EVERY
    // kind, since they all share one build method.
    //
    // Driven off the enum rather than a hardcoded list, so a sixth machine
    // added later has to answer this test too.
    //
    // It has to answer it in one of two ways, and both are asserted below. A
    // kind whose PLC publishes a handshake gets Equipment + Status and one
    // rule between them. A kind whose PLC publishes NOTHING — the Optimar
    // palletising row — gets Equipment alone, and therefore no rule at all:
    // there is no second section for one to sit between, and a hairline under
    // a lone section is a rule to nowhere. Skipping such a kind instead would
    // let a genuinely missing Status section pass unnoticed, so it is asserted
    // rather than excluded.
    for (final kind in ThirdPartyEquipmentKind.values.where(hasStatusTable)) {
      testWidgets('${kind.name} draws exactly one rule between its sections',
          (tester) async {
        addTearDown(closeSidePane);
        final config = ThirdPartyEquipmentConfig(runKey: '')
          ..kind = kind
          // Configured, so the Status section is present and there are two
          // sections for a rule to sit between. Struct kinds show the section
          // whatever the key says; the box erector needs the prefix.
          ..statusKey = 'BER02';

        await tester.pumpWidget(ProviderScope(
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
        await tester.tap(find.byType(ThirdPartyEquipment));
        await tester.pumpAndSettle();

        expect(find.text('EQUIPMENT'), findsOneWidget);
        expect(find.text('STATUS'), findsOneWidget);
        // Two sections, so exactly one rule. Zero was the bug; two — a section
        // wrapper plus a hand-rolled divider — is the other way to get this
        // wrong, and would fail here just as loudly.
        expect(
          find.descendant(
            of: find.byType(PaneBody),
            matching: find.byType(Divider),
          ),
          findsOneWidget,
          reason: '${kind.name} must have one hairline between Equipment and '
              'Status — no more, no fewer',
        );
      });
    }

    for (final kind
        in ThirdPartyEquipmentKind.values.where((k) => !hasStatusTable(k))) {
      testWidgets('${kind.name} draws no rule, having only one section',
          (tester) async {
        addTearDown(closeSidePane);
        final config = ThirdPartyEquipmentConfig(runKey: '')
          ..kind = kind
          // Set anyway, to prove it changes nothing: this kind has no table
          // for a status key to feed, so a leftover key from another kind must
          // not conjure a Status section.
          ..statusKey = 'BER02';

        await tester.pumpWidget(ProviderScope(
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
        await tester.tap(find.byType(ThirdPartyEquipment));
        await tester.pumpAndSettle();

        expect(find.text('EQUIPMENT'), findsOneWidget);
        expect(find.text('STATUS'), findsNothing,
            reason: '${kind.name} has no handshake to draw a Status section '
                'from, configured key or not.');
        expect(
          find.descendant(
            of: find.byType(PaneBody),
            matching: find.byType(Divider),
          ),
          findsNothing,
          reason: '${kind.name} has one section, so there is nothing for a '
              'hairline to divide.',
        );
      });
    }
  });

  group('No duplicate Running row', () {
    // Jon: "we don't need a diode for running, it is in the top". Asserted per
    // kind rather than for the box erector alone, because fixing one machine
    // and leaving the same duplication on the next one is the outcome to
    // avoid.
    for (final kind in ThirdPartyEquipmentKind.values) {
      test('${kind.name} has no Running diode', () {
        final labels = [
          for (final b in kStructStatusBits[kind] ?? const [])
            b.labelFor(equipmentShortName(kind)),
          for (final b in kEquipmentStatusBits[kind] ?? const [])
            b.labelFor(equipmentShortName(kind)),
        ];
        expect(labels, isNot(contains('Running')),
            reason: '${kind.name} draws its run state in the pane header and '
                'on the machine LED; a third statement of it costs a row');
      });
    }

    test('the box erector still subscribes and publishes its run key', () {
      // Removing the row must not unbind the key. `allKeys` used to compose it
      // out of the diode list, so deleting the bit would have taken
      // BER01.Running out of key discovery — and it is the asset's runKey, the
      // machine's LED and now the pane header's fallback.
      final config = ThirdPartyEquipmentConfig(
        kind: ThirdPartyEquipmentKind.boxErector,
        statusKey: 'BER01',
        runKey: '',
      );
      expect(config.allKeys, contains('BER01.$kBoxErectorRunSuffix'));
    });

    test('the header badge reads the run bit when no run key is configured',
        () {
      // The fallback that makes deleting the row strictly safe: a machine with
      // a status prefix but no runKey used to show "No key" beside a lit
      // Running diode. Now the badge reads the bit the pane is already holding.
      expect(
        boxErectorPaneStatus(
            const {kBoxErectorRunSuffix: true}, const PaneStatus.stale()),
        const PaneStatus.running(),
      );
      expect(
        boxErectorPaneStatus(
            const {kBoxErectorRunSuffix: false}, const PaneStatus.stale()),
        const PaneStatus.stopped(),
      );
      // Nothing heard: the fallback must not invent a reading.
      expect(
        boxErectorPaneStatus(const {}, const PaneStatus.stale()),
        const PaneStatus.stale(),
      );
    });
  });
}
