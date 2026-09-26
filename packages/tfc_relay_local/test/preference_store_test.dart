/// Properties of the preference store that are true without a server.
///
/// The database-backed behaviour lives in `preferences_read_test.dart` and
/// `preference_change_feed_test.dart`, both `db`-tagged. What is here is
/// everything a `db` tag would only make harder to run: the absent `secret`
/// parameter, which is a property of the SOURCE, and the de-duplication
/// window's arithmetic, which is a property of a clock nobody has to
/// provision. 10-07 and 10-08 both split their suites this way and for this
/// reason — gating a property behind Docker is gating a property nobody runs.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_local/src/data/preference_change_feed.dart';

/// Lines of [source] that are not `//` or `///` comments.
///
/// **The plan's acceptance criterion is `grep -c "secret" … == 0`, and it
/// cannot be met as written.** The file explains, at length, which parameter
/// it omits and why — the whole SEC-01 argument is unwriteable if the word may
/// not appear. 10-07 and 10-08 each hit the same shape and answered it the
/// same way: a sweep that flagged prose would make the honest explanation
/// impossible to write down, so the sweep reads code and the paragraph stays.
/// The property being defended is "no call site passes it", and that is what
/// is asserted below.
List<String> codeLines(String source) => source
    .split('\n')
    .where((line) {
      final trimmed = line.trimLeft();
      return !trimmed.startsWith('//') && !trimmed.startsWith('///');
    })
    .toList();

void main() {
  group('SEC-01: the secret parameter is never passed', () {
    final source =
        File('lib/src/data/preference_store.dart').readAsStringSync();

    test('no line of code in the store spells the secret parameter', () {
      final offenders =
          codeLines(source).where((line) => line.contains('secret:')).toList();

      expect(offenders, isEmpty,
          reason: 'the concrete Preferences class carries a '
              '{bool secret = false} on twelve members, and it routes the '
              'call to the OS keychain instead of the table. Passing it would '
              'turn one client-supplied flag into remote retrieval of the '
              'secure store (T-10-35). The interface being mirrored omits it, '
              'and the obvious future edit is to add it back for symmetry');
    });

    test('the sweep can see an offender', () {
      // Non-vacuous on purpose: a sweep over a file that will never contain
      // the needle passes forever whether or not it works.
      const seeded = '/// A doc comment mentioning secret: which is fine.\n'
          'await prefs.getString(key, secret: true);\n';

      expect(codeLines(seeded).where((l) => l.contains('secret:')), hasLength(1),
          reason: 'the call site must be seen and the doc comment must not; a '
              'sweep that saw both would be the one that cannot be satisfied, '
              'and one that saw neither would be decoration');
    });

    test('no write in the store skips the database', () {
      // The concrete class also carries `saveToDb:`. A call passing
      // `saveToDb: false` would put a value in the memory cache and nowhere
      // else — a preference that vanishes the next time the cache is rebuilt
      // from the table, with nothing anywhere saying it was never stored.
      final offenders = codeLines(source)
          .where((line) => line.contains('saveToDb:'))
          .toList();

      expect(offenders, isEmpty,
          reason: 'a write that skips Postgres is a write that undoes itself');
    });
  });

  group('the de-duplication window, on a clock nobody has to provision', () {
    /// A feed with no database: the channel half cannot open, which is what a
    /// gateway looks like before the sink has connected. The local half must
    /// keep working regardless — a preference written through the pipe is
    /// still a preference written.
    ({
      PreferenceChangeFeed feed,
      StreamController<String> local,
      List<String> seen,
      void Function(Duration) advance,
    }) build() {
      // **Monotonic microseconds, not a DateTime** (10-REVIEW WR-02). The
      // feed's own anchor is a process `Stopwatch` now, and a fixture handing
      // it wall-clock instants would be testing a shape production no longer
      // has. The starting value is nonzero so a case can step it backwards
      // without going negative.
      var clock = const Duration(hours: 12).inMicroseconds;
      final local = StreamController<String>.broadcast();
      final feed = PreferenceChangeFeed(
        database: () => null,
        local: local.stream,
        clock: () => clock,
        window: const Duration(milliseconds: 250),
        // Short, so a case does not sit through the production backoff. The
        // channel can never open here, so this only bounds how often it
        // tries.
        relistenBackoff: const Duration(milliseconds: 50),
      );
      final seen = <String>[];
      addTearDown(feed.close);
      return (
        feed: feed,
        local: local,
        seen: seen,
        advance: (Duration d) => clock += d.inMicroseconds,
      );
    }

    test('the same key twice inside the window is announced once', () async {
      final f = build();
      final sub = f.feed.changes.listen(f.seen.add);
      addTearDown(sub.cancel);

      // Pumped between the two adds because a broadcast controller delivers
      // asynchronously: advancing the clock before the first event has been
      // delivered would stamp both with the same instant and the case would
      // be measuring nothing.
      f.local.add('theme');
      await pumpEventQueue();
      f.advance(const Duration(milliseconds: 249));
      f.local.add('theme');
      await pumpEventQueue();

      expect(f.seen, ['theme'],
          reason: 'a gateway-originated write reaches the local stream and '
              'comes back as its own NOTIFY a few milliseconds later. 250 ms '
              'is the bound on that round trip — the notify connection is '
              'idle, so delivery is one TCP hop after commit — with roughly '
              'fifty times the measured margin');
    });

    test('the same key again just outside the window is announced again',
        () async {
      final f = build();
      final sub = f.feed.changes.listen(f.seen.add);
      addTearDown(sub.cancel);

      f.local.add('theme');
      await pumpEventQueue();
      f.advance(const Duration(milliseconds: 251));
      f.local.add('theme');
      await pumpEventQueue();

      expect(f.seen, ['theme', 'theme'],
          reason: 'the half that keeps the window honest: two genuinely '
              'distinct edits must not collapse into one, or a panel keeps '
              'showing the first');
    });

    test('two different keys inside the window are both announced', () async {
      final f = build();
      final sub = f.feed.changes.listen(f.seen.add);
      addTearDown(sub.cancel);

      f.local.add('theme');
      f.local.add('language');
      await pumpEventQueue();

      expect(f.seen, ['theme', 'language'],
          reason: 'the window is per key. A clear() over five hundred keys '
              'is five hundred distinct keys, and collapsing them would lose '
              '499 of them — the coalescing that turns that burst into ONE '
              'frame is data_handlers.dart\'s job, not this one\'s');
    });

    test('a feed with no database keeps the local half working', () async {
      final f = build();
      final sub = f.feed.changes.listen(f.seen.add);
      addTearDown(sub.cancel);

      f.local.add('theme');
      await pumpEventQueue();

      expect(f.seen, ['theme'],
          reason: 'the sink connects in the background and the supplier '
              'answers null until it has. A feed that threw, or went quiet '
              'for good, would make every preference written in the first '
              'seconds after a restart invisible');
      expect(f.feed.channelUp, isFalse);
    });

    // 10-REVIEW WR-02, and the fourth time this doctrine has been written down
    // (08-CR-01, 08-CR-02, 09-WR-01). The production clock is a process
    // `Stopwatch` and cannot step; what these two arms defend is the
    // comparison, because the clock is injectable and an injected clock is a
    // caller's value.
    test('a clock that steps backwards does not silence the feed', () async {
      final f = build();
      final sub = f.feed.changes.listen(f.seen.add);
      addTearDown(sub.cancel);

      f.local.add('theme');
      await pumpEventQueue();
      // An NTP correction at boot on a plant PC — the ordinary case, which is
      // why the wall clock was the wrong anchor.
      f.advance(const Duration(minutes: -5));
      f.local.add('theme');
      await pumpEventQueue();

      expect(f.seen, ['theme', 'theme'],
          reason: 'with `at.difference(last) < window` the elapsed time is '
              'NEGATIVE after a backwards step, so every key already announced '
              'is suppressed for the whole of the step — five minutes of '
              'silence here. invalidate() still runs, so the gateway\'s cache '
              'is fresh while every connected panel renders a value nobody '
              'told it had changed. That is "the edit nobody saw", which is '
              'the failure DB-03 exists to prevent');
    });

    test('and the stale entry is evicted rather than pinned', () async {
      final f = build();
      final sub = f.feed.changes.listen(f.seen.add);
      addTearDown(sub.cancel);

      f.local.add('theme');
      await pumpEventQueue();
      f.advance(const Duration(minutes: -5));
      f.local.add('theme');
      await pumpEventQueue();
      // Back inside a window of the *re-anchored* entry: if the step left the
      // old timestamp in the map, this third event is compared against it and
      // the suppression is permanent rather than momentary.
      f.advance(const Duration(milliseconds: 10));
      f.local.add('theme');
      await pumpEventQueue();

      expect(f.seen, ['theme', 'theme'],
          reason: 'the prune uses the same comparison as the suppression, so '
              'an inverted one could not evict what it could not measure. '
              'After the step the key is re-anchored, and 10 ms later it is '
              'genuinely inside the window and genuinely suppressed — which '
              'is the arm that proves the fix re-anchored rather than simply '
              'stopped de-duplicating');
    });
  });
}
