import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/page_creator/assets/section_button.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart' show HmiStateColors;
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

/// Mutually exclusive sections, end to end.
///
/// ST201 and ST301 wire their two box-packing modes as mutual exclusion in
/// `MAIN`:
///
///   section.boxPackingFilm  (i_xPermissive := NOT section.boxPackingVacuum.q_xEnabled);
///   section.boxPackingVacuum(i_xPermissive := NOT section.boxPackingFilm.q_xEnabled);
///
/// so a button driving both was permanently split, and the split stopped
/// meaning "look at this" for every other button on the plant. These tests
/// pin what replaced it: the face reads the mode that has the line, the pane
/// asks one question instead of offering two toggles, and the hand-over
/// between modes is composed out of the only three commands
/// `ST_Section_HMI` has.
void main() {
  tearDown(() => closeSidePane(immediate: true));

  Widget wrap(Widget child, {List<Override> overrides = const []}) {
    return ProviderScope(
      overrides: overrides,
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// A film/vacuum pair on one line, declared as alternatives.
  SectionButtonConfig pair({bool allowModeSwitch = false}) =>
      SectionButtonConfig(
        allowModeSwitch: allowModeSwitch,
        sections: [
          SectionRef(
            key: 'film',
            label: 'Line 2 film',
            exclusiveGroup: 'Line 2 packing',
          ),
          SectionRef(
            key: 'vacuum',
            label: 'Line 2 vacuum',
            exclusiveGroup: 'Line 2 packing',
          ),
        ],
      )..text = 'Box packing';

  /// The live `/boxes/wet-area` index 150 shape: three transport peers and
  /// two exclusive pairs behind one button.
  SectionButtonConfig wetArea() => SectionButtonConfig(
        sections: [
          SectionRef(key: 'st101.t', label: 'Line 1 transport'),
          SectionRef(
              key: 'st201.film',
              label: 'Line 2 film',
              exclusiveGroup: 'Line 2 packing'),
          SectionRef(
              key: 'st201.vac',
              label: 'Line 2 vacuum',
              exclusiveGroup: 'Line 2 packing'),
          SectionRef(key: 'st201.t', label: 'Line 2 transport'),
          SectionRef(
              key: 'st301.film',
              label: 'Line 3 film',
              exclusiveGroup: 'Line 3 packing'),
          SectionRef(
              key: 'st301.vac',
              label: 'Line 3 vacuum',
              exclusiveGroup: 'Line 3 packing'),
          SectionRef(key: 'st301.t', label: 'Line 3 transport'),
        ],
      )..text = 'Before freezers';

  Future<void> pumpButton(
    WidgetTester tester,
    _FakeStateMan fake,
    SectionButtonConfig cfg,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(wrap(
      SizedBox(width: 80, height: 80, child: SectionButton(config: cfg)),
      overrides: [stateManProvider.overrideWith((_) async => fake)],
    ));
    await _settle(tester);
  }

  Future<void> openPane(
    WidgetTester tester,
    _FakeStateMan fake,
    SectionButtonConfig cfg,
  ) async {
    await pumpButton(tester, fake, cfg);
    await tester.tap(find.byType(SectionButton));
    await _settle(tester);
  }

  final faceFinder = find.byWidgetPredicate(
    (w) => w is CustomPaint && w.painter is PowerButtonPainter,
  );

  PowerButtonPainter painterOf(WidgetTester tester) =>
      tester.widget<CustomPaint>(faceFinder).painter as PowerButtonPainter;

  HmiStateColors palette(WidgetTester tester) =>
      HmiStateColors.of(tester.element(find.byType(SectionButton)));

  // -------------------------------------------------------------------------
  group('the face', () {
    testWidgets('a working exclusive pair is NOT disagreement', (tester) async {
      // Film has the line, vacuum is held off by it. That is the interlock
      // working exactly as designed, and it is the state this button spends
      // its whole life in. A permanent seam is a seam nobody reads.
      final fake = _FakeStateMan()
        ..push('film', enabled: true)
        ..push('vacuum', permissive: false);
      await pumpButton(tester, fake, pair());

      expect(painterOf(tester).splitWith, isNull,
          reason: 'the pair is one choice, and one of its modes has the line');
      expect(painterOf(tester).disc, palette(tester).green,
          reason: 'the colour of the mode that is running — the question an '
              'operator is asking is "is packing running", not "do film and '
              'vacuum agree", which they never can');
      expect(painterOf(tester).unreadable, isFalse);
    });

    testWidgets('the other way round is the same picture', (tester) async {
      final fake = _FakeStateMan()
        ..push('film', permissive: false)
        ..push('vacuum', enabled: true);
      await pumpButton(tester, fake, pair());
      expect(painterOf(tester).splitWith, isNull);
      expect(painterOf(tester).disc, palette(tester).green);
    });

    testWidgets('a pair in cleaning is blue, not split', (tester) async {
      final fake = _FakeStateMan()
        ..push('film', cleaning: true)
        ..push('vacuum');
      await pumpButton(tester, fake, pair());
      expect(painterOf(tester).splitWith, isNull);
      expect(painterOf(tester).disc, palette(tester).blue);
    });

    testWidgets('a pair with neither mode selected is grey', (tester) async {
      final fake = _FakeStateMan()
        ..push('film')
        ..push('vacuum');
      await pumpButton(tester, fake, pair());
      expect(painterOf(tester).splitWith, isNull);
      expect(painterOf(tester).disc, palette(tester).grey);
    });

    testWidgets('a pair held with NOTHING running is still yellow',
        (tester) async {
      // i_xPermissive := NOT other.q_xEnabled, and nothing here has
      // q_xEnabled. Whatever is holding these two is somewhere else, and that
      // is news the reduction must not swallow.
      final fake = _FakeStateMan()
        ..push('film', permissive: false)
        ..push('vacuum', permissive: false);
      await pumpButton(tester, fake, pair());
      expect(painterOf(tester).disc, palette(tester).yellow);
    });

    testWidgets('BOTH modes running is reported, not smoothed over',
        (tester) async {
      // Impossible while the ladder holds, so if it is ever seen the interlock
      // has stopped doing its job. The face cannot draw it — two sections in
      // the same mode is agreement, and it IS green because they ARE both
      // running — so the pane is where it has to be said.
      final fake = _FakeStateMan()
        ..push('film', enabled: true)
        ..push('vacuum', enabled: true);
      await openPane(tester, fake, pair(allowModeSwitch: true));

      expect(painterOf(tester).disc, palette(tester).green);
      expect(find.textContaining('the interlock in the PLC is not holding'),
          findsOneWidget);
      // ...and neither alternative is offered while the plant is in a state
      // this screen does not understand.
      expect(_enabled(tester, const Key('section-choice-0-0')), isFalse);
      expect(_enabled(tester, const Key('section-choice-0-1')), isFalse);
    });

    testWidgets('an unreadable alternative still marks and splits the button',
        (tester) async {
      final fake = _FakeStateMan()..push('film', enabled: true);
      await pumpButton(tester, fake, pair());
      expect(painterOf(tester).unreadable, isTrue);
      expect(painterOf(tester).splitWith, isNotNull,
          reason: 'a set that collapsed to the readable half would be '
              'claiming to know a state it cannot read');
    });

    testWidgets('genuine PEER disagreement still splits, alongside a working '
        'pair', (tester) async {
      // The signal the reduction exists to protect. Line 3 transport has
      // stopped while the other two run; the two packing choices are behaving.
      final fake = _FakeStateMan()
        ..push('st101.t', enabled: true)
        ..push('st201.film', enabled: true)
        ..push('st201.vac', permissive: false)
        ..push('st201.t', enabled: true)
        ..push('st301.film', enabled: true)
        ..push('st301.vac', permissive: false)
        ..push('st301.t'); // the odd one out
      await pumpButton(tester, fake, wetArea());

      expect(painterOf(tester).disc, palette(tester).green);
      expect(painterOf(tester).splitWith, palette(tester).grey,
          reason: 'a peer standing still is still the thing to notice');
    });

    testWidgets('the whole wet-area button agrees when the plant is behaving',
        (tester) async {
      // Seven sections, three relationships, one solid green disc. This is
      // the button that used to be split every minute of every shift.
      final fake = _FakeStateMan()
        ..push('st101.t', enabled: true)
        ..push('st201.film', enabled: true)
        ..push('st201.vac', permissive: false)
        ..push('st201.t', enabled: true)
        ..push('st301.vac', enabled: true)
        ..push('st301.film', permissive: false)
        ..push('st301.t', enabled: true);
      await pumpButton(tester, fake, wetArea());

      expect(painterOf(tester).splitWith, isNull);
      expect(painterOf(tester).disc, palette(tester).green);
      expect(painterOf(tester).unreadable, isFalse);
    });

    testWidgets('a button that declares nothing is untouched', (tester) async {
      // The non-exclusive case, asserted rather than assumed: three plain
      // peers, one of them stopped, still split exactly as before.
      final fake = _FakeStateMan()
        ..push('a', enabled: true)
        ..push('b', enabled: true)
        ..push('c');
      await pumpButton(
        tester,
        fake,
        SectionButtonConfig(sections: [
          SectionRef(key: 'a'),
          SectionRef(key: 'b'),
          SectionRef(key: 'c'),
        ])..text = 'Before freezers',
      );
      expect(painterOf(tester).disc, palette(tester).green);
      expect(painterOf(tester).splitWith, palette(tester).grey);
    });
  });

  // -------------------------------------------------------------------------
  group('the pane presents a choice', () {
    testWidgets('the choice is titled and the mode with the line is filled '
        'and inert', (tester) async {
      final fake = _FakeStateMan()
        ..push('film', enabled: true)
        ..push('vacuum', permissive: false);
      await openPane(tester, fake, pair());

      // The set is ONE entry in the Sections list now, headed by its own
      // name — not a second `PaneBodySection` repeating it.
      expect(find.textContaining('Line 2 packing — one at a time'),
          findsOneWidget);
      expect(find.text('LINE 2 PACKING'), findsNothing,
          reason: 'the separate choice section is what this collapse removed');
      // Filled, and dead: p_cmd_Start is a toggle, so a live button on the
      // running mode would stop the line it is reporting.
      expect(_enabled(tester, const Key('section-choice-0-0')), isFalse);
      expect(
        tester.widget(find.byKey(const Key('section-choice-0-0'))),
        isA<FilledButton>(),
      );
    });

    testWidgets('an alternative is one decision, not two toggles',
        (tester) async {
      final fake = _FakeStateMan()
        ..push('film', enabled: true)
        ..push('vacuum', permissive: false);
      await openPane(tester, fake, pair());

      // The pair is one entry: the members ARE the mode buttons, and Clean
      // and Stop belong to the set. No per-member row survives, so there is
      // no second place to start a section and no name written twice.
      for (final k in const [
        'section-0-run',
        'section-1-run',
        'section-0-clean',
        'section-1-clean',
        'section-0-stop',
        'section-1-stop',
      ]) {
        expect(find.byKey(Key(k)), findsNothing, reason: '$k is collapsed');
      }
      expect(find.byKey(const Key('section-choice-0-0')), findsOneWidget);
      expect(find.byKey(const Key('section-choice-0-1')), findsOneWidget);
      expect(find.byKey(const Key('section-set-0-clean')), findsOneWidget);
      expect(find.byKey(const Key('section-set-0-stop')), findsOneWidget);
      expect(find.textContaining('Line 2 packing — one at a time'),
          findsOneWidget);
    });

    testWidgets('"Allowed to start" stops crying wolf about the interlock',
        (tester) async {
      // The reported destruction of the signal: a pair that is working
      // normally used to read `No for 1 of 2`, permanently.
      final fake = _FakeStateMan()
        ..push('film', enabled: true)
        ..push('vacuum', permissive: false);
      await openPane(tester, fake, pair());

      expect(find.text('Yes'), findsOneWidget);
      expect(find.text('No for 1 of 2'), findsNothing);
    });

    testWidgets('a hold NOT explained by the choice is still reported',
        (tester) async {
      // Nothing in the set is running, so something else is holding vacuum.
      final fake = _FakeStateMan()
        ..push('film')
        ..push('vacuum', permissive: false);
      await openPane(tester, fake, pair());
      expect(find.text('No for 1 of 2'), findsOneWidget);
    });

    testWidgets('a peer hold is still reported alongside a working pair',
        (tester) async {
      final fake = _FakeStateMan()
        ..push('st101.t', enabled: true)
        ..push('st201.film', enabled: true)
        ..push('st201.vac', permissive: false)
        ..push('st201.t', enabled: true)
        ..push('st301.film', enabled: true)
        ..push('st301.vac', permissive: false)
        ..push('st301.t', permissive: false); // a peer, genuinely held
      await openPane(tester, fake, wetArea());
      expect(find.text('No for 1 of 7'), findsOneWidget,
          reason: 'one peer held, and neither of the two working pairs '
              'counted against it');
    });

    testWidgets('the header says the mode, not "Mixed"', (tester) async {
      final fake = _FakeStateMan()
        ..push('film', enabled: true)
        ..push('vacuum', permissive: false);
      await openPane(tester, fake, pair());
      expect(find.text('Mixed'), findsNothing);
      expect(find.text('Running'), findsWidgets);
    });

    testWidgets('the Running count is still a count of SECTIONS',
        (tester) async {
      // The reduction is about disagreement, not about arithmetic: one of the
      // two packing sections is moving, and that is what this row says.
      final fake = _FakeStateMan()
        ..push('film', enabled: true)
        ..push('vacuum', permissive: false);
      await openPane(tester, fake, pair());
      expect(find.text('1 of 2'), findsOneWidget);
    });

    testWidgets('with switching off, the other mode is dead and the pane says '
        'why', (tester) async {
      final fake = _FakeStateMan()
        ..push('film', enabled: true)
        ..push('vacuum', permissive: false);
      await openPane(tester, fake, pair());

      expect(_enabled(tester, const Key('section-choice-0-1')), isFalse);
      expect(
          find.textContaining('Line 2 film has the line. Stop it, then the '
              'other mode can be started.'),
          findsOneWidget);
    });

    testWidgets('a free alternative is a plain start even with switching off',
        (tester) async {
      // Nothing to stop, so this is not a hand-over — it is the `Run` this
      // pane always had, with the same guard behind it.
      final fake = _FakeStateMan()
        ..push('film')
        ..push('vacuum');
      await openPane(tester, fake, pair());

      expect(_enabled(tester, const Key('section-choice-0-0')), isTrue);
      await tester.tap(find.byKey(const Key('section-choice-0-0')));
      await _settle(tester);

      expect(find.text('Switch'), findsNothing,
          reason: 'nothing is being stopped, so there is nothing to confirm');
      expect(fake.writes.map((w) => w.key), ['film']);
      expect(fake.writes.single.value[kSectionCmdStart].asBool, isTrue);
    });

    testWidgets('an unreadable member falls back to the separate rows',
        (tester) async {
      // `reduceExclusiveSet` cannot say what the set is, so the pane does not
      // pretend it is one thing — the same rule the face uses to decide
      // whether to draw a seam. The rows come back, without `Run`, because no
      // mode may be picked while a member's state is unknown.
      final fake = _FakeStateMan()..push('film');
      await openPane(tester, fake, pair(allowModeSwitch: true));

      expect(find.byKey(const Key('section-choice-0-0')), findsNothing);
      expect(find.byKey(const Key('section-choice-0-1')), findsNothing);
      expect(find.byKey(const Key('section-0-stop')), findsOneWidget);
      expect(find.byKey(const Key('section-1-stop')), findsOneWidget);
      expect(find.byKey(const Key('section-0-run')), findsNothing);
      expect(find.byKey(const Key('section-1-run')), findsNothing);
      expect(find.textContaining('One of these is not reading'), findsOneWidget);
    });

    testWidgets('a twin held while this one only CLEANS says what is really '
        'holding it', (tester) async {
      // `i_xPermissive := NOT other.q_xEnabled`, and cleaning does not set
      // `q_xEnabled` — so a vacuum held while film merely washes down is held
      // by something OUTSIDE this choice. `planModeSwitch` refuses (stopping
      // the cleaning would cost that and still not release the vacuum), so
      // the button is dead and the note beside it has to say why. Promising
      // "choosing the other mode stops the film first" next to a button that
      // will not do it is the dead-button problem this asset exists to avoid.
      final fake = _FakeStateMan()
        ..push('film', cleaning: true)
        ..push('vacuum', permissive: false);
      await openPane(tester, fake, pair(allowModeSwitch: true));

      expect(_enabled(tester, const Key('section-choice-0-1')), isFalse);
      expect(
          find.textContaining('something outside this choice is holding it'),
          findsOneWidget);
      expect(find.textContaining('Choosing the other mode stops'), findsNothing,
          reason: 'the switch it offers is exactly the one that is refused');
    });

    testWidgets('the same is said with switching off — it is not the opt-in '
        'that is holding it', (tester) async {
      final fake = _FakeStateMan()
        ..push('film', cleaning: true)
        ..push('vacuum', permissive: false);
      await openPane(tester, fake, pair());

      expect(_enabled(tester, const Key('section-choice-0-1')), isFalse);
      expect(
          find.textContaining('something outside this choice is holding it'),
          findsOneWidget);
      expect(find.textContaining('Stop it, then the other mode'), findsNothing,
          reason: 'stopping the film would not release the vacuum');
    });

    testWidgets('a pane with no switch handler offers no live choice',
        (tester) async {
      // A pane pumped without `onModeSwitch` can send nothing. The member
      // rows already go dead without their handler; the choice must too,
      // rather than look pressable and swallow the press — the per-row `Run`
      // was taken away from these sections for exactly that reason.
      useTallSurface(tester);
      await tester.pumpWidget(wrap(SectionPane(
        title: 'Box packing',
        refs: [
          SectionRef(
              key: 'film',
              label: 'Line 2 film',
              exclusiveGroup: 'Line 2 packing'),
          SectionRef(
              key: 'vacuum',
              label: 'Line 2 vacuum',
              exclusiveGroup: 'Line 2 packing'),
        ],
        modes: const [SectionMode.stopped, SectionMode.stopped],
        exclusiveSets: const [
          ExclusiveSet(name: 'Line 2 packing', members: [0, 1]),
        ],
        allowModeSwitch: true,
        onCommand: (_) async {},
      )));
      await _settle(tester);

      // Both are free to start, so the plan is there and only the missing
      // handler makes them dead.
      expect(_enabled(tester, const Key('section-choice-0-0')), isFalse);
      expect(_enabled(tester, const Key('section-choice-0-1')), isFalse);
    });

    testWidgets('a button with no alternatives grows no choice section',
        (tester) async {
      final fake = _FakeStateMan()
        ..push('a', enabled: true)
        ..push('b');
      await openPane(
        tester,
        fake,
        SectionButtonConfig(sections: [
          SectionRef(key: 'a', label: 'ST101'),
          SectionRef(key: 'b', label: 'ST201'),
        ])..text = 'Before freezers',
      );
      expect(find.byKey(const Key('section-choice-0-0')), findsNothing);
      // ...and every member keeps its own Run.
      expect(find.byKey(const Key('section-0-run')), findsOneWidget);
      expect(find.byKey(const Key('section-1-run')), findsOneWidget);
      expect(find.textContaining('Run all leaves'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  group('Run all never starts an alternative', () {
    testWidgets('an idle pair is left to the chooser', (tester) async {
      // Two p_cmd_Starts landing in one scan both pass `AND i_xPermissive`
      // (computed from the previous scan), so both modes latch — and the next
      // scan each one's permissive reads FALSE and FB_Section drops BOTH.
      // Run all would stop the line it was pressed to start.
      final fake = _FakeStateMan()
        ..push('st101.t')
        ..push('st201.film')
        ..push('st201.vac')
        ..push('st201.t')
        ..push('st301.film')
        ..push('st301.vac')
        ..push('st301.t');
      await openPane(tester, fake, wetArea());

      await _tapKey(tester, const Key('section-run'));
      await _settle(tester);

      expect(fake.writes.map((w) => w.key), ['st101.t', 'st201.t', 'st301.t'],
          reason: 'the transport peers start; the four packing modes do not');
      expect(find.textContaining('Run all leaves Line 2 packing and Line 3 '
          'packing alone'), findsOneWidget);
    });

    testWidgets('Run all is not drawn at all when it could never fire',
        (tester) async {
      // Every section on this button is an alternative, and `Run all` never
      // writes to one — so it is dead in every state, forever. It used to be
      // drawn dead AND (once the reduced view agreed on Running) wearing the
      // filled green of a live button.
      final fake = _FakeStateMan()
        ..push('film')
        ..push('vacuum');
      await openPane(tester, fake, pair());
      expect(find.byKey(const Key('section-run')), findsNothing);
      expect(find.byKey(const Key('section-clean')), findsOneWidget,
          reason: 'cleaning is not exclusive — Clean all still reaches both');
    });

    testWidgets('a permanently green Run all is gone from the running pair too',
        (tester) async {
      final fake = _FakeStateMan()
        ..push('film', enabled: true)
        ..push('vacuum', permissive: false);
      await openPane(tester, fake, pair());
      expect(find.byKey(const Key('section-run')), findsNothing);
    });

    testWidgets('Clean all still fans out to alternatives', (tester) async {
      // Cleaning is NOT exclusive: the permissive keys off q_xEnabled only,
      // so both modes may wash down at once and the PLC allows it.
      final fake = _FakeStateMan()
        ..push('film')
        ..push('vacuum');
      await openPane(tester, fake, pair());

      await tester.tap(find.byKey(const Key('section-clean')));
      await _settle(tester);
      expect(fake.writes.map((w) => w.key), ['film', 'vacuum']);
      for (final w in fake.writes) {
        expect(w.value[kSectionCmdStartClean].asBool, isTrue);
      }
    });

    testWidgets('Stop all still stops everything', (tester) async {
      final fake = _FakeStateMan()
        ..push('film', enabled: true)
        ..push('vacuum', permissive: false);
      await openPane(tester, fake, pair());
      await tester.tap(find.byKey(const Key('section-stop')));
      await _settle(tester);
      expect(fake.writes.map((w) => w.key), ['film', 'vacuum']);
    });

    testWidgets('a plain peer group still starts every stopped member',
        (tester) async {
      // The non-exclusive fan-out, unchanged: two running, one stopped, and
      // only the stopped one is sent a start.
      final fake = _FakeStateMan()
        ..push('a', enabled: true)
        ..push('b', enabled: true)
        ..push('c');
      await openPane(
        tester,
        fake,
        SectionButtonConfig(sections: [
          SectionRef(key: 'a'),
          SectionRef(key: 'b'),
          SectionRef(key: 'c'),
        ])..text = 'Before freezers',
      );
      await tester.tap(find.byKey(const Key('section-run')));
      await _settle(tester);
      expect(fake.writes.map((w) => w.key), ['c']);
    });
  });

  // -------------------------------------------------------------------------
  group('the guarded mode switch', () {
    /// Film is held off; vacuum has the line.
    _FakeStateMan vacuumRunning() => _FakeStateMan()
      ..push('film', permissive: false)
      ..push('vacuum', enabled: true);

    testWidgets('it cannot fire from a mis-tap — it asks first',
        (tester) async {
      final fake = vacuumRunning();
      await openPane(tester, fake, pair(allowModeSwitch: true));

      await tester.tap(find.byKey(const Key('section-choice-0-0')));
      await _settle(tester);

      expect(find.text('Switch to Line 2 film?'), findsOneWidget);
      expect(find.textContaining('Line 2 vacuum will be stopped first'),
          findsOneWidget);
      expect(fake.writes, isEmpty,
          reason: 'the press that starts machinery is the SECOND one');
    });

    testWidgets('cancelling writes nothing at all', (tester) async {
      final fake = vacuumRunning();
      await openPane(tester, fake, pair(allowModeSwitch: true));
      await tester.tap(find.byKey(const Key('section-choice-0-0')));
      await _settle(tester);

      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect(fake.writes, isEmpty);
      expect(find.text('Switch to Line 2 film?'), findsNothing);
    });

    testWidgets('confirming stops the mode that has the line, and WAITS',
        (tester) async {
      // The trap this whole sequence exists for: FB_Section gates both start
      // commands behind `AND i_xPermissive`, so a start fired before the
      // interlock releases is not refused, not reported and not queued — it
      // is simply gone.
      final fake = vacuumRunning();
      await openPane(tester, fake, pair(allowModeSwitch: true));
      await tester.tap(find.byKey(const Key('section-choice-0-0')));
      await _settle(tester);
      await tester.tap(find.text('Switch'));
      await _settle(tester);

      expect(fake.writes.map((w) => w.key), ['vacuum']);
      expect(fake.writes.single.value[kSectionCmdStop].asBool, isTrue);
      expect(
        fake.writes.where((w) => w.value[kSectionCmdStart].asBool),
        isEmpty,
        reason: 'the PLC has not handed the go-ahead over yet — a start sent '
            'now vanishes and the line just stops',
      );

      // Let the wait finish rather than leaving its timer running past the end
      // of the test; what happens when the PLC does answer is the next test.
      fake
        ..push('vacuum')
        ..push('film');
      await _settle(tester);
    });

    testWidgets('...and starts the chosen mode the moment the PLC releases it',
        (tester) async {
      final fake = vacuumRunning();
      await openPane(tester, fake, pair(allowModeSwitch: true));
      await tester.tap(find.byKey(const Key('section-choice-0-0')));
      await _settle(tester);
      await tester.tap(find.text('Switch'));
      await _settle(tester);

      // The PLC drops vacuum and hands film its permissive back.
      fake
        ..push('vacuum')
        ..push('film');
      await _settle(tester);

      expect(fake.writes.map((w) => w.key), ['vacuum', 'film']);
      expect(fake.writes.first.value[kSectionCmdStop].asBool, isTrue);
      expect(fake.writes.last.value[kSectionCmdStart].asBool, isTrue);
      expect(fake.writes.last.value[kSectionCmdStop].asBool, isFalse,
          reason: 'one command bit per write, as FB_Section expects');
    });

    testWidgets('a stop that does not take leaves the line stopped and SAYS '
        'so', (tester) async {
      // Degrading safely: no blind start, and no silence either — a line that
      // stopped and did not restart reads as machinery refusing unless the
      // screen says a command was withheld.
      final fake = vacuumRunning();
      await openPane(tester, fake, pair(allowModeSwitch: true));
      await tester.tap(find.byKey(const Key('section-choice-0-0')));
      await _settle(tester);
      await tester.tap(find.text('Switch'));

      // Nothing comes back from the PLC. Outlast kSectionSwitchTimeout.
      await _pumpFor(tester, kSectionSwitchTimeout + const Duration(seconds: 2));

      expect(fake.writes.map((w) => w.key), ['vacuum'],
          reason: 'the start is never sent blind');
      expect(find.text('Line 2 film did not start'), findsOneWidget);
      expect(find.textContaining('no start was sent'), findsOneWidget);
    });

    testWidgets('a mode that came up in the meantime is not stopped by a '
        'command labelled Start', (tester) async {
      // p_cmd_Start toggles. The guard is re-asked against what the PLC says
      // when the start is about to go out, not against the snapshot the
      // switch was planned from — a physical start button, or another
      // station, can beat the HMI to it.
      final fake = vacuumRunning();
      await openPane(tester, fake, pair(allowModeSwitch: true));
      await tester.tap(find.byKey(const Key('section-choice-0-0')));
      await _settle(tester);
      await tester.tap(find.text('Switch'));
      await _settle(tester);

      // Vacuum drops, and film comes up on its own before the HMI's start.
      fake
        ..push('vacuum')
        ..push('film', enabled: true);
      await _pumpFor(tester, kSectionSwitchTimeout + const Duration(seconds: 2));

      expect(
        fake.writes.where((w) => w.value[kSectionCmdStart].asBool),
        isEmpty,
        reason: 'sending Start to a running section STOPS it',
      );
    });

    testWidgets('switching is refused entirely when the button does not '
        'allow it', (tester) async {
      final fake = vacuumRunning();
      await openPane(tester, fake, pair());
      expect(_enabled(tester, const Key('section-choice-0-0')), isFalse);
      await tester.tap(find.byKey(const Key('section-choice-0-0')));
      await _settle(tester);
      expect(find.text('Switch to Line 2 film?'), findsNothing);
      expect(fake.writes, isEmpty);
    });

    testWidgets('a healthy choice says nothing at all', (tester) async {
      // The note that explained the hand-over was the only one that appeared
      // when nothing was the matter — a line of text under every working pair
      // on the plant, which is the noise this asset exists not to make. The
      // confirmation dialog is where the hand-over is explained, at the
      // moment it is about to happen.
      final fake = vacuumRunning();
      await openPane(tester, fake, pair(allowModeSwitch: true));

      expect(find.textContaining('Choosing the other mode'), findsNothing);
      expect(find.textContaining('has the line'), findsNothing);
      expect(find.textContaining('is not holding'), findsNothing);
      // ...and the switch it would have described is live regardless.
      expect(_enabled(tester, const Key('section-choice-0-0')), isTrue);
    });

    testWidgets('a switch away from a CLEANING mode stops it first too',
        (tester) async {
      final fake = _FakeStateMan()
        ..push('film')
        ..push('vacuum', cleaning: true);
      await openPane(tester, fake, pair(allowModeSwitch: true));

      await tester.tap(find.byKey(const Key('section-choice-0-0')));
      await _settle(tester);
      expect(find.text('Switch to Line 2 film?'), findsOneWidget);
      await tester.tap(find.text('Switch'));
      await _settle(tester);
      expect(fake.writes.map((w) => w.key), ['vacuum']);
      expect(fake.writes.single.value[kSectionCmdStop].asBool, isTrue);

      // Let the wait finish rather than leaving its timer behind.
      fake.push('vacuum');
      await _settle(tester);
    });
  });

  // -------------------------------------------------------------------------
  group('config', () {
    test('an existing saved asset loads with no exclusivity and no switch', () {
      // What a page saved before this change does on load: both fields absent,
      // so no sets are declared and the hand-over is off. Every peer button on
      // the plant keeps the behaviour #387 shipped.
      final legacy = (SectionButtonConfig(sections: [
        SectionRef(key: 'a', label: 'ST101', holdReason: 'Vacuum has it'),
        SectionRef(key: 'b'),
      ])
            ..text = 'Before freezers')
          .toJson();
      for (final s in (legacy['sections'] as List)) {
        (s as Map).remove('exclusiveGroup');
      }
      legacy.remove('allow_mode_switch');

      final back = SectionButtonConfig.fromJson(legacy);
      expect(back.allowModeSwitch, isFalse);
      expect(back.sections.every((s) => s.exclusiveGroup == null), isTrue);
      expect(exclusiveSetsOf(back.sections), isEmpty);
      expect(back.sections.first.holdReason, 'Vacuum has it',
          reason: 'the field the new one sits beside is untouched');
    });

    test('the declaration round-trips', () {
      final json = pair(allowModeSwitch: true).toJson();
      expect(json['allow_mode_switch'], isTrue);
      expect((json['sections'] as List).first['exclusiveGroup'],
          'Line 2 packing');

      final back = SectionButtonConfig.fromJson(json);
      expect(back.allowModeSwitch, isTrue);
      expect(exclusiveSetsOf(back.sections), [
        const ExclusiveSet(name: 'Line 2 packing', members: [0, 1])
      ]);
      expect(back.allKeys, ['film', 'vacuum'],
          reason: 'declaring exclusivity must not lose the keys');
    });

    testWidgets('the editor takes the tag and offers the switch only once a '
        'set exists', (tester) async {
      final cfg = SectionButtonConfig(sections: [
        SectionRef(key: 'film'),
        SectionRef(key: 'vacuum'),
      ]);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => cfg.configure(context)),
          ),
        ),
      ));
      await tester.pump();

      // No pair declared yet, so no question about handing a line over.
      expect(find.byKey(const Key('section-allow-mode-switch')), findsNothing);

      await tester.enterText(
          find.byKey(const Key('section-0-exclusive')), 'Line 2 packing');
      await tester.pump();
      expect(find.byKey(const Key('section-allow-mode-switch')), findsNothing,
          reason: 'one tagged section has no alternative — it is still a peer');

      await tester.enterText(
          find.byKey(const Key('section-1-exclusive')), 'Line 2 packing');
      await tester.pump();

      expect(cfg.sections[1].exclusiveGroup, 'Line 2 packing');
      expect(find.text('Choices: Line 2 packing'), findsOneWidget);
      expect(find.byKey(const Key('section-allow-mode-switch')), findsOneWidget);

      await _tapKey(tester, const Key('section-allow-mode-switch'));
      await tester.pump();
      expect(cfg.allowModeSwitch, isTrue);
    });
  });
}

/// Pumps frames without `pumpAndSettle`. Ten 100 ms frames outlast every
/// animation in the pane's opening.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Pumps for at least [total], for waits that outlast an animation — the
/// switch's own timeout, which is seconds rather than milliseconds.
Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 100);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

/// Scrolls [key] into view and taps it.
///
/// The pane body is a scroll view and this one carries seven sections plus two
/// choices, so the group commands at the bottom are off-screen on any surface
/// a test is going to use.
Future<void> _tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pump();
  await tester.tap(find.byKey(key));
}

/// Whether the button carrying [key] is live.
bool _enabled(WidgetTester tester, Key key) {
  final button = tester.widget(find.byKey(key));
  return (button as dynamic).onPressed != null;
}

typedef _Write = ({String key, DynamicValue value});

class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};
  final List<_Write> writes = [];

  /// Publishes an `ST_Section_HMI` struct with the given status bits and the
  /// three command bits cleared, the way `FB_Section` leaves them.
  void push(
    String key, {
    bool enabled = false,
    bool cleaning = false,
    bool permissive = true,
  }) {
    final value = DynamicValue();
    for (final field in [
      kSectionCmdStart,
      kSectionCmdStartClean,
      kSectionCmdStop,
    ]) {
      value[field] = DynamicValue(value: false, typeId: NodeId.boolean);
    }
    value[kSectionStatEnabled] =
        DynamicValue(value: enabled, typeId: NodeId.boolean);
    value[kSectionStatCleanEnabled] =
        DynamicValue(value: cleaning, typeId: NodeId.boolean);
    value[kSectionStatPermissive] =
        DynamicValue(value: permissive, typeId: NodeId.boolean);
    _streams.putIfAbsent(key, () => BehaviorSubject<DynamicValue>()).add(value);
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      _streams.putIfAbsent(key, () => BehaviorSubject<DynamicValue>()).stream;

  @override
  Future<void> write(String key, DynamicValue value) async {
    writes.add((key: key, value: value));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_FakeStateMan: ${invocation.memberName} not implemented in test scope',
      );
}
