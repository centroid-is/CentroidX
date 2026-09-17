import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/section_button.dart';

/// The decisions the section button makes before any pixel is drawn.
///
/// All four functions here answer a question about `FB_Section`'s interface
/// (`SVNCoreComponents/Section/FB_Section.TcPOU`), and getting any of them
/// wrong is a command that does the opposite of its label or a moving line
/// painted as an idle one — so they are pinned here rather than only through
/// the widget.
void main() {
  group('resolveSectionMode', () {
    test('all three bits unread is unknown, not stopped', () {
      expect(
        resolveSectionMode(enabled: null, cleanEnabled: null, permissive: null),
        SectionMode.unknown,
      );
    });

    test('any single missing member is unknown', () {
      expect(
        resolveSectionMode(
            enabled: false, cleanEnabled: false, permissive: null),
        SectionMode.unknown,
        reason: 'a struct without p_stat_xPermissive cannot be read as safe',
      );
      expect(
        resolveSectionMode(
            enabled: null, cleanEnabled: false, permissive: true),
        SectionMode.unknown,
      );
      expect(
        resolveSectionMode(
            enabled: false, cleanEnabled: null, permissive: true),
        SectionMode.unknown,
      );
    });

    test('p_stat_xEnabled is running', () {
      expect(
        resolveSectionMode(
            enabled: true, cleanEnabled: false, permissive: true),
        SectionMode.running,
      );
    });

    test('p_stat_xCleanEnabled is cleaning', () {
      expect(
        resolveSectionMode(
            enabled: false, cleanEnabled: true, permissive: true),
        SectionMode.cleaning,
      );
    });

    test('idle with the permissive satisfied is stopped', () {
      expect(
        resolveSectionMode(
            enabled: false, cleanEnabled: false, permissive: true),
        SectionMode.stopped,
      );
    });

    test('idle without the permissive is blocked (waiting, not faulted)', () {
      expect(
        resolveSectionMode(
            enabled: false, cleanEnabled: false, permissive: false),
        SectionMode.blocked,
      );
    });

    test('a running section with a lost permissive still reads as running', () {
      // The PLC drops the outputs the same scan the permissive goes away, so
      // this combination is transient at worst. Painting a line that is still
      // moving as `Blocked` — which an operator reads as idle — is the one
      // wrong answer that could get somebody hurt.
      expect(
        resolveSectionMode(
            enabled: true, cleanEnabled: false, permissive: false),
        SectionMode.running,
      );
      expect(
        resolveSectionMode(
            enabled: false, cleanEnabled: true, permissive: false),
        SectionMode.cleaning,
      );
    });
  });

  group('command guards', () {
    // p_cmd_Start and p_cmd_StartClean TOGGLE their output in FB_Section.
    // Sending Start to a running section stops it; that button must not be
    // live while it would do the opposite of what it says.
    test('Run is offered from stopped and from cleaning only', () {
      expect(canStart(SectionMode.stopped), isTrue);
      expect(canStart(SectionMode.cleaning), isTrue,
          reason: 'p_cmd_Start switches a cleaning section straight to auto');
      expect(canStart(SectionMode.running), isFalse,
          reason: 'p_cmd_Start toggles — it would STOP a running section');
      expect(canStart(SectionMode.blocked), isFalse,
          reason: 'the PLC ignores start commands without the permissive');
      expect(canStart(SectionMode.unknown), isFalse);
    });

    test('Clean is offered from stopped and from running only', () {
      expect(canClean(SectionMode.stopped), isTrue);
      expect(canClean(SectionMode.running), isTrue,
          reason: 'p_cmd_StartClean switches a running section to cleaning');
      expect(canClean(SectionMode.cleaning), isFalse,
          reason: 'p_cmd_StartClean toggles — it would stop the cleaning');
      expect(canClean(SectionMode.blocked), isFalse);
      expect(canClean(SectionMode.unknown), isFalse);
    });

    test('Stop is offered whenever the state is known, permissive or not', () {
      expect(canStop(SectionMode.running), isTrue);
      expect(canStop(SectionMode.cleaning), isTrue);
      expect(canStop(SectionMode.stopped), isTrue);
      expect(canStop(SectionMode.blocked), isTrue);
      expect(canStop(SectionMode.unknown), isFalse);
    });
  });

  group('SectionGroup — several sections behind one button', () {
    SectionGroup g(List<SectionMode> m) => SectionGroup(m);

    test('one section is never mixed', () {
      expect(g([SectionMode.running]).mixed, isFalse);
      expect(g([SectionMode.running]).label, 'Running');
    });

    test('agreement keeps the single state and a solid face', () {
      final all = g([SectionMode.running, SectionMode.running]);
      expect(all.mixed, isFalse);
      expect(all.agreed, SectionMode.running);
      expect(all.busiest, SectionMode.running);
      expect(all.quietest, SectionMode.running,
          reason: 'both halves equal means the painter draws no split');
    });

    test('disagreement splits between the busiest and the quietest', () {
      // The case the split exists for: a solid green button saying "the line
      // is running" when one of the three is standing still.
      final some = g([
        SectionMode.running,
        SectionMode.running,
        SectionMode.stopped,
      ]);
      expect(some.mixed, isTrue);
      expect(some.label, 'Mixed');
      expect(some.busiest, SectionMode.running);
      expect(some.quietest, SectionMode.stopped);
      expect(some.movingCount, 2);
    });

    test('three different states still resolve to two halves', () {
      final three = g([
        SectionMode.cleaning,
        SectionMode.blocked,
        SectionMode.stopped,
      ]);
      expect(three.busiest, SectionMode.cleaning);
      expect(three.quietest, SectionMode.stopped);
    });

    test('running outranks cleaning, so an auto line owns the top half', () {
      final both = g([SectionMode.cleaning, SectionMode.running]);
      expect(both.busiest, SectionMode.running);
      expect(both.quietest, SectionMode.cleaning);
    });

    test('unreadable ranks below everything and is never the busy half', () {
      final mix = g([SectionMode.running, SectionMode.unknown]);
      expect(mix.busiest, SectionMode.running);
      expect(mix.quietest, SectionMode.unknown);
      expect(mix.anyUnreadable, isTrue,
          reason: 'a button speaking for two sections that can see one '
              'must wear the mark');
    });

    test('all unreadable is not mixed, just unreadable', () {
      final none = g([SectionMode.unknown, SectionMode.unknown]);
      expect(none.mixed, isFalse);
      expect(none.agreed, SectionMode.unknown);
      expect(none.anyUnreadable, isTrue);
    });

    test('cleaning counts as moving', () {
      expect(g([SectionMode.cleaning, SectionMode.stopped]).movingCount, 1);
      expect(g([SectionMode.stopped, SectionMode.blocked]).movingCount, 0);
    });

    test('an empty group reads unknown rather than throwing', () {
      expect(g(const []).agreed, SectionMode.unknown);
      expect(g(const []).busiest, SectionMode.unknown);
      expect(g(const []).mixed, isFalse);
    });
  });

  group('canSend — the per-section guard behind the fan-out', () {
    // A blind broadcast of p_cmd_Start to a half-running group would start
    // the stopped members and STOP the running ones, leaving the line as it
    // was, inverted. Every command is asked per section for this reason.
    test('Start is refused for the members already running', () {
      expect(canSend(kSectionCmdStart, SectionMode.stopped), isTrue);
      expect(canSend(kSectionCmdStart, SectionMode.running), isFalse);
    });

    test('Clean is refused for the members already cleaning', () {
      expect(canSend(kSectionCmdStartClean, SectionMode.running), isTrue);
      expect(canSend(kSectionCmdStartClean, SectionMode.cleaning), isFalse);
    });

    test('Stop is accepted by anything readable', () {
      expect(canSend(kSectionCmdStop, SectionMode.running), isTrue);
      expect(canSend(kSectionCmdStop, SectionMode.blocked), isTrue);
      expect(canSend(kSectionCmdStop, SectionMode.unknown), isFalse);
    });

    test('an unrecognised field is never sent', () {
      expect(canSend('p_cmd_Nonsense', SectionMode.stopped), isFalse);
    });
  });

  group('exclusiveSetsOf — what the config declares', () {
    SectionRef r(String key, [String? tag]) =>
        SectionRef(key: key, exclusiveGroup: tag);

    test('no tags is no sets, which is every page saved before this existed',
        () {
      expect(exclusiveSetsOf([r('a'), r('b'), r('c')]), isEmpty);
    });

    test('two sections sharing a tag are one set', () {
      final sets = exclusiveSetsOf([
        r('transport'),
        r('film', 'Line 2 packing'),
        r('vacuum', 'Line 2 packing'),
      ]);
      expect(sets, [
        const ExclusiveSet(name: 'Line 2 packing', members: [1, 2])
      ]);
    });

    test('a tag on its own section is not a set — it has no alternative', () {
      expect(exclusiveSetsOf([r('film', 'Line 2 packing'), r('t')]), isEmpty);
    });

    test('two lines are two sets, not one four-way choice', () {
      // The trap in a free-text tag: tagging all four modes `packing` would
      // declare that starting film on line 2 holds off film on line 3.
      final sets = exclusiveSetsOf([
        r('l2film', 'Line 2 packing'),
        r('l2vac', 'Line 2 packing'),
        r('l3film', 'Line 3 packing'),
        r('l3vac', 'Line 3 packing'),
      ]);
      expect(sets.map((s) => s.name), ['Line 2 packing', 'Line 3 packing']);
      expect(sets.map((s) => s.members), [
        [0, 1],
        [2, 3]
      ]);
    });

    test('tags are trimmed, so a stray space does not split a pair', () {
      final sets = exclusiveSetsOf([
        r('film', 'Line 2 packing'),
        r('vacuum', ' Line 2 packing '),
      ]);
      expect(sets, hasLength(1));
      expect(sets.single.members, [0, 1]);
    });

    test('a blank tag is a peer, not a set of blanks', () {
      expect(exclusiveSetsOf([r('a', '   '), r('b', '')]), isEmpty);
    });

    test('a set keeps the place of its first member', () {
      final sets = exclusiveSetsOf([
        r('film', 'B'),
        r('t1'),
        r('vac', 'B'),
        r('x', 'A'),
        r('y', 'A'),
      ]);
      expect(sets.map((s) => s.name), ['B', 'A']);
    });
  });

  group('reduceExclusiveSet — one choice, one state', () {
    const running = SectionMode.running;
    const cleaning = SectionMode.cleaning;
    const stopped = SectionMode.stopped;
    const blocked = SectionMode.blocked;
    const unknown = SectionMode.unknown;

    test('the mode that has the line, with its twin held off, IS the state',
        () {
      // The whole point. Film running / vacuum held is the interlock working,
      // not two sections disagreeing.
      expect(reduceExclusiveSet(const [running, blocked]), running);
      expect(reduceExclusiveSet(const [blocked, running]), running);
    });

    test('cleaning has the line too', () {
      expect(reduceExclusiveSet(const [cleaning, stopped]), cleaning);
    });

    test('running outranks cleaning — the line carrying product wins', () {
      // Reachable and legal: the permissive keys off q_xEnabled only, so a
      // section already cleaning stays cleaning when its twin starts in auto.
      expect(reduceExclusiveSet(const [cleaning, running]), running);
    });

    test('neither selected is stopped, not mixed', () {
      expect(reduceExclusiveSet(const [stopped, stopped]), stopped);
    });

    test('held with NOTHING running is still yellow — that is not the '
        'exclusion', () {
      // i_xPermissive := NOT other.q_xEnabled. Nothing here has q_xEnabled,
      // so whatever holds this section is elsewhere and is news.
      expect(reduceExclusiveSet(const [blocked, stopped]), blocked);
      expect(reduceExclusiveSet(const [blocked, blocked]), blocked);
    });

    test('a member held while its twin only CLEANS is not explained either',
        () {
      expect(reduceExclusiveSet(const [blocked, cleaning]), cleaning,
          reason: 'the cleaning member has the line, so this reduces');
    });

    test('two in auto still reads Running, because they both are', () {
      // Impossible while the ladder holds, and there is no seam to draw for
      // two sections in the same mode. The pane is where a failed interlock
      // gets reported — see the widget test.
      expect(reduceExclusiveSet(const [running, running]), running);
    });

    test('a member nobody can read stops the whole set collapsing', () {
      expect(reduceExclusiveSet(const [running, unknown]), isNull);
      expect(reduceExclusiveSet(const [stopped, unknown]), isNull);
    });

    test('a set of one is not a set', () {
      expect(reduceExclusiveSet(const [running]), isNull);
      expect(reduceExclusiveSet(const []), isNull);
    });
  });

  group('resolveFaceModes — what the face compares', () {
    const sets = [ExclusiveSet(name: 'Line 2 packing', members: [1, 2])];

    test('peers are passed straight through when nothing is declared', () {
      const modes = [
        SectionMode.running,
        SectionMode.stopped,
        SectionMode.blocked,
      ];
      expect(resolveFaceModes(modes, const []), same(modes),
          reason: 'the non-exclusive case must be untouched, not recomputed');
    });

    test('the live wet-area button: three peers running, both choices in a '
        'mode, reads as agreement', () {
      // ST101/ST201/ST301 transport + a film/vacuum pair, which is exactly
      // what /boxes/wet-area index 150 drives. This used to be permanently
      // split.
      final face = resolveFaceModes(const [
        SectionMode.running, // ST101 transport
        SectionMode.running, // ST201 film
        SectionMode.blocked, // ST201 vacuum, held by film
        SectionMode.running, // ST201 transport
      ], const [
        ExclusiveSet(name: 'Line 2 packing', members: [1, 2])
      ]);
      expect(face, [
        SectionMode.running,
        SectionMode.running,
        SectionMode.running,
      ]);
      expect(SectionGroup(face).mixed, isFalse);
    });

    test('a set that does not reduce still contributes every member', () {
      final face = resolveFaceModes(const [
        SectionMode.running,
        SectionMode.running,
        SectionMode.unknown,
      ], sets);
      // The set holds one section nobody can read, so it refuses to collapse
      // and the face sees all three — which is how the `!` reaches the disc.
      expect(face, hasLength(3));
      expect(SectionGroup(face).anyUnreadable, isTrue);
    });

    test('a genuine peer disagreement is untouched by any of this', () {
      final face = resolveFaceModes(const [
        SectionMode.running,
        SectionMode.blocked,
        SectionMode.running,
        SectionMode.stopped, // a peer standing still — the thing to notice
      ], sets);
      expect(SectionGroup(face).mixed, isTrue);
      expect(SectionGroup(face).busiest, SectionMode.running);
      expect(SectionGroup(face).quietest, SectionMode.stopped);
    });

    test('the set sits where its first member was configured', () {
      final face = resolveFaceModes(const [
        SectionMode.stopped,
        SectionMode.running,
        SectionMode.blocked,
      ], sets);
      expect(face, [SectionMode.stopped, SectionMode.running]);
    });
  });

  group('groupStartable — Run all never starts an alternative', () {
    const sets = [ExclusiveSet(name: 'Line 2 packing', members: [1, 2])];

    test('with nothing declared it is exactly the old modes.any(canStart)', () {
      for (final modes in [
        const [SectionMode.stopped],
        const [SectionMode.running],
        const [SectionMode.running, SectionMode.stopped],
        const [SectionMode.blocked, SectionMode.unknown],
        const <SectionMode>[],
      ]) {
        expect(groupStartable(modes, const []), modes.any(canStart),
            reason: 'the peer case must not change: $modes');
      }
    });

    test('an idle pair alone leaves Run all dead', () {
      // Both starts would land in one scan, both pass i_xPermissive computed
      // from the previous scan, both latch — and the NEXT scan FB_Section
      // drops both. Run all would stop the line it was pressed to start.
      expect(
          groupStartable(const [
            SectionMode.running,
            SectionMode.stopped,
            SectionMode.stopped,
          ], sets),
          isFalse);
    });

    test('a stopped peer still makes Run all live', () {
      expect(
          groupStartable(const [
            SectionMode.stopped,
            SectionMode.stopped,
            SectionMode.stopped,
          ], sets),
          isTrue);
    });
  });

  group('planModeSwitch — composed from the three commands that exist', () {
    const set = ExclusiveSet(name: 'Line 2 packing', members: [0, 1]);

    test('the hand-over: stop what has the line, start the other', () {
      expect(
        planModeSwitch(
          modes: const [SectionMode.running, SectionMode.blocked],
          set: set,
          target: 1,
        ),
        const SectionSwitchPlan(stop: [0], start: 1),
      );
    });

    test('a free alternative is a plain start, not a hand-over', () {
      final plan = planModeSwitch(
        modes: const [SectionMode.stopped, SectionMode.stopped],
        set: set,
        target: 1,
      );
      expect(plan, const SectionSwitchPlan(stop: [], start: 1));
      expect(plan!.isHandover, isFalse,
          reason: 'nothing is stopped, so nothing needs confirming — this is '
              'the Run this pane always had');
    });

    test('the mode that already has the line is not offered — Start toggles',
        () {
      expect(
        planModeSwitch(
          modes: const [SectionMode.running, SectionMode.blocked],
          set: set,
          target: 0,
        ),
        isNull,
        reason: 'p_cmd_Start on a running section STOPS it',
      );
      expect(
        planModeSwitch(
          modes: const [SectionMode.cleaning, SectionMode.stopped],
          set: set,
          target: 0,
        ),
        isNull,
      );
    });

    test('a cleaning alternative is stopped first, like a running one', () {
      // Cleaning is not exclusive in the PLC, but the target still cannot be
      // started while the other mode is in it — and leaving a washdown running
      // under a line that just went to auto is not what "switch" means.
      expect(
        planModeSwitch(
          modes: const [SectionMode.cleaning, SectionMode.stopped],
          set: set,
          target: 1,
        ),
        const SectionSwitchPlan(stop: [0], start: 1),
      );
    });

    test('a member nobody can read cancels the whole switch', () {
      expect(
        planModeSwitch(
          modes: const [SectionMode.unknown, SectionMode.stopped],
          set: set,
          target: 1,
        ),
        isNull,
        reason: 'stopping a section whose state cannot be read is blind',
      );
    });

    test('held by something OUTSIDE the set buys nothing and is refused', () {
      // Neither alternative is running, so the exclusion is not what holds
      // the target. Stopping the twin would cost the line and change nothing.
      expect(
        planModeSwitch(
          modes: const [SectionMode.stopped, SectionMode.blocked],
          set: set,
          target: 1,
        ),
        isNull,
      );
      expect(
        planModeSwitch(
          modes: const [SectionMode.cleaning, SectionMode.blocked],
          set: set,
          target: 1,
        ),
        isNull,
        reason: 'a cleaning twin does not take the permissive away',
      );
    });

    test('a target outside the set is refused', () {
      expect(
        planModeSwitch(
          modes: const [SectionMode.running, SectionMode.stopped],
          set: set,
          target: 5,
        ),
        isNull,
      );
    });
  });

  group('shortMemberNames — what tells a set\'s members apart', () {
    // The four buttons on a set's row have about eighty pixels each. Full
    // labels ellipsised to "Line …" twice over and the operator could not
    // tell film from vacuum; inside one entry the shared half is already in
    // the heading above them.
    test('the words the members share are dropped', () {
      expect(shortMemberNames(const ['Line 2 film', 'Line 2 vacuum']),
          ['Film', 'Vacuum']);
    });

    test('nothing shared, nothing trimmed', () {
      expect(shortMemberNames(const ['Film', 'Vacuum']), ['Film', 'Vacuum']);
    });

    test('the last word is never eaten, even when every word is shared', () {
      // Two members labelled the same are indistinguishable however they are
      // printed; what must not happen is a button with nothing on it.
      final same = shortMemberNames(const ['Line 2 film', 'Line 2 film']);
      expect(same, ['Film', 'Film']);
      expect(same.every((n) => n.isNotEmpty), isTrue);
    });

    test('a trim that leaves a stub is refused', () {
      // "2" is not a button an operator can act on.
      expect(shortMemberNames(const ['Line 2', 'Line 2 vacuum']),
          ['Line 2', 'Line 2 vacuum']);
    });

    test('matching is case-insensitive, the kept text is not rewritten', () {
      expect(shortMemberNames(const ['ST201 Film wrap', 'st201 Vacuum seal']),
          ['Film wrap', 'Vacuum seal']);
    });

    test('a lone label is left alone', () {
      expect(shortMemberNames(const ['Line 2 film']), ['Line 2 film']);
    });
  });

  group('SectionRef.displayLabel', () {
    test('an explicit label wins', () {
      expect(SectionRef(key: 'a.b.c', label: 'ST101').displayLabel, 'ST101');
    });

    test('otherwise the tail of the key, which is the instance name', () {
      expect(
        SectionRef(key: 'ST101.section.beforeFreezers.HMI').displayLabel,
        'HMI',
      );
      expect(SectionRef(key: 'plain').displayLabel, 'plain');
    });

    test('blank label and blank key both fall back rather than render empty',
        () {
      expect(SectionRef(key: 'a.b', label: '   ').displayLabel, 'b');
      expect(SectionRef(key: '').displayLabel, 'Section');
    });
  });
}
