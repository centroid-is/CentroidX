/// The two kinds of "not fresh", kept apart and proved apart.
///
/// Source: 04-RESEARCH Finding 5 — **121 tick notifications in 7001 ms**, with
/// wire-measured inter-tick deltas `[51, 50, 50, 49, 50, 51, …]`, dead flat at
/// **50.0 ms** over 121 samples, and **zero update frames** in that window
/// because nothing in the plant changed. Two things follow, and both are
/// asserted below rather than assumed.
///
/// First, the tick alone is the liveness signal, so a watchdog that only
/// counted *updates* would call a quiet plant dead. Second — and this is why
/// every deadline in this file is written as a multiple of an **injected**
/// period and never as a millisecond count copied from the wire — reading
/// CLI-04's "3× tick" against that measured 50 ms cadence yields a 150 ms
/// deadline. One garbage collection pause on the panel, or one Wi-Fi
/// retransmit on the plant WAN, and every value on the screen greys out at
/// once while the gateway is perfectly healthy. The operator learns within a
/// week that grey means nothing, and the freshness indicator — the whole
/// product — is dead. So the deadline is configured, defaulting to 3 s, and
/// what these cases pin is the **ratio**: stale at three times whatever period
/// the client was told to expect.
///
/// The other half is F25, the dead subscription on a live socket
/// (04-RESEARCH Finding 3): ticks keep arriving, the link is provably up, and
/// one subscription's `evaluatedAt` has stopped advancing because its
/// plant-side source stopped evaluating. Without the per-sub group below, that
/// value renders as current forever — a socket that is up is not a promise
/// that the number on the screen is. And the client must never "fix" it by
/// resyncing: the stream is fine, the plant is not, and a resync loop against
/// a healthy gateway is how one dead PLC tag takes out the whole panel.
library;

import 'dart:async';
import 'dart:io' show Directory, File, Platform;

import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/freshness_watchdog.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;
import 'package:test/test.dart';

// The socket companion below needs a real panel over a real gateway: the lie
// this file is about lives in `RemoteStateMan`'s getter, not in the watchdog's
// arithmetic, and no amount of driving the watchdog directly can reach it.
import 'support/client_harness.dart' show relayFixture;
import 'support/fault_fixture.dart' show until;
import 'support/runner_budget.dart';
import 'support/gate_bands.dart' show scenarioKey;

/// The injected heartbeat period the client is configured to expect.
///
/// Deliberately **not** the gateway's measured 50 ms fan-out cadence. Every
/// assertion here is a multiple of this local constant, so the suite says
/// nothing about the server's tuning and a change to the gateway's default
/// cannot quietly rewrite what these cases mean.
///
/// The client *does* learn the real cadence — `hello` advertises
/// `capabilities.tickMs` and `FreshnessWatchdog.learnedTickMs` takes it — but
/// only the per-subscription limit is derived from it. The link deadline stays
/// configured, and `learning the cadence does not move the link deadline` is
/// the arm that keeps it that way.
const Duration period = Duration(milliseconds: 100);

/// The configured freshness deadline, as a ratio of [period]. CLI-04's "3×".
final Duration deadline = period * 3;

/// A gateway wall-clock instant, verbatim from the tick payload captured in
/// 04-RESEARCH Finding 5 (`{serverTime: 1786711225813, subs: {s1: {seq: 0,
/// evaluatedAt: 1786711225813}}}`). Real epoch ms, because Finding 5b verified
/// live that `hello.serverTime`, `tick.serverTime` and `SubTick.evaluatedAt`
/// are all wall clock and can be subtracted from one another.
const int serverEpochMs = 1786711225813;

/// STATE.md Phase 2 handoff timing bands: Linux is the quiet CI box, every
/// other platform is a developer machine with a browser open.
final Duration slack =
    Platform.isLinux ? const Duration(milliseconds: 20) : const Duration(milliseconds: 75);
final Duration ceiling =
    Platform.isLinux ? const Duration(milliseconds: 100) : const Duration(milliseconds: 150);

/// A config whose freshness deadline is [deadline] — three injected periods.
///
/// `deadlineFloor` is lowered explicitly, which is the point of it being a
/// parameter (04-01): a suite that had to wait out the production 3 s floor to
/// watch one transition would take a minute to run and nobody would run it.
ClientConfig testConfig() => ClientConfig(
      freshnessDeadline: deadline,
      deadlineFloor: const Duration(milliseconds: 10),
    );

/// A monotonic clock the case moves by hand.
///
/// The watchdog's elapsed-time seam, injected so a case can watch a
/// subscription age without waiting out a real staleness limit. A `Stopwatch`
/// would do everything except stand still.
final class FakeElapsed {
  int ms = 0;
  int read() => ms;
}

/// Records every fresh/stale transition the watchdog announces, in order.
final class TransitionLog {
  final List<bool> staleFlags = <bool>[];
  final Completer<Duration> _firstStale = Completer<Duration>();
  final Completer<Duration> _firstFreshAgain = Completer<Duration>();
  final Stopwatch _since = Stopwatch()..start();

  /// When the view first went stale, measured from construction.
  Future<Duration> get firstStale => _firstStale.future;

  /// When the view first came back, measured from construction.
  Future<Duration> get firstFreshAgain => _firstFreshAgain.future;

  void record(bool stale) {
    staleFlags.add(stale);
    if (stale && !_firstStale.isCompleted) {
      _firstStale.complete(_since.elapsed);
    }
    if (!stale && _firstStale.isCompleted && !_firstFreshAgain.isCompleted) {
      _firstFreshAgain.complete(_since.elapsed);
    }
  }
}

void main() {
  useRunnerBudgets();

  group('the link watchdog: one timer, reset by any inbound frame', () {
    test('frames every period keep the view fresh across ten periods', () async {
      final log = TransitionLog();
      final watchdog =
          FreshnessWatchdog(config: testConfig(), onViewFreshnessChanged: log.record);
      addTearDown(watchdog.dispose);

      watchdog.sawFrame(InboundFrame.tick);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(period);
        watchdog.sawFrame(InboundFrame.tick);
      }

      expect(watchdog.viewIsStale, isFalse,
          reason: 'a link delivering a frame every period was called dead, so '
              'the operator saw a grey screen in front of a running plant');
      expect(log.staleFlags, isEmpty,
          reason: 'a healthy link produced a freshness transition at all: '
              'grey that flickers is grey the operator stops reading');
    });

    test('the view goes stale at three times the injected period', () async {
      final log = TransitionLog();
      final watchdog =
          FreshnessWatchdog(config: testConfig(), onViewFreshnessChanged: log.record);
      addTearDown(watchdog.dispose);

      watchdog.sawFrame(InboundFrame.tick);
      final wentStaleAt = await within(
        log.firstStale,
        'the view going stale after the frames stopped',
        budget: deadline + ceiling + period,
      );

      expect(wentStaleAt, greaterThanOrEqualTo(deadline - slack),
          reason: 'the view greyed before the configured deadline had passed, '
              'which is how a GC pause greys a whole plant');
      expect(wentStaleAt, lessThanOrEqualTo(deadline + ceiling),
          reason: 'a dead link kept rendering as live past its deadline, and a '
              'stale number the operator believes is the failure this whole '
              'product exists to prevent');
      expect(log.staleFlags, equals(<bool>[true]),
          reason: 'one death produced more than one transition');
    });

    test('a recovered view comes back exactly once — and on data, not on a frame',
        () async {
      // **Retargeted by 16-10 (finding S9), and the property is unchanged.**
      // This arm has always been about "exactly one death and one recovery".
      // What moved is *who announces the recovery*. It used to be `sawFrame`,
      // which is the finding: a frame arriving proves the link is alive and
      // proves nothing about whether the values on the screen came from it, so
      // the `hello` response cleared the badge seconds before the first
      // snapshot landed. The supervisor now calls `viewBecameFresh` from
      // `_enter(LinkState.ready)`, which is reached only once every page has
      // adopted its snapshot.
      //
      // Both halves are asserted here, at the unit, because a unit that only
      // checked the new caller would go green again the day somebody put the
      // old one back.
      final log = TransitionLog();
      final watchdog =
          FreshnessWatchdog(config: testConfig(), onViewFreshnessChanged: log.record);
      addTearDown(watchdog.dispose);

      watchdog.sawFrame(InboundFrame.tick);
      await within(log.firstStale, 'the view going stale after the frames stopped',
          budget: deadline + ceiling + period);

      // A frame arrives. The link deadline restarts — but the badge does not
      // move, because nothing yet says the screen is showing this connection's
      // data.
      watchdog.sawFrame(InboundFrame.tick);
      await Future<void>.delayed(period);
      expect(watchdog.viewIsStale, isTrue,
          reason: 'an inbound frame cleared the view badge on its own. That is '
              'S9: the hello response is a frame, and it answers seconds '
              'before the first page snapshot lands');
      expect(log.staleFlags, equals(<bool>[true]),
          reason: 'and it announced a recovery that had not happened');

      // The pages are holding their snapshots.
      watchdog.viewBecameFresh();
      await within(log.firstFreshAgain, 'the view coming back once its data did',
          budget: ceiling);

      expect(log.staleFlags, equals(<bool>[true, false]),
          reason: 'a link that died and recovered did not read as exactly one '
              'death and one recovery');
      expect(watchdog.viewIsStale, isFalse,
          reason: 'the view is holding current data and is still grey');

      // Idempotent: reaching `ready` twice without an intervening death is one
      // recovery, not two indicator repaints.
      watchdog.viewBecameFresh();
      expect(log.staleFlags, equals(<bool>[true, false]));
    });

    test('a tick frame alone keeps the view fresh, so an idle plant is never called dead',
        () async {
      await expectKindKeepsViewFresh(InboundFrame.tick);
    });

    test('an update frame alone keeps the view fresh, so a busy plant is never called dead',
        () async {
      await expectKindKeepsViewFresh(InboundFrame.update);
    });

    test('an rpc response alone keeps the view fresh, so a polling panel is never called dead',
        () async {
      await expectKindKeepsViewFresh(InboundFrame.rpcResponse);
    });

    test('one timer serves the whole link no matter how many frames land', () {
      final watchdog =
          FreshnessWatchdog(config: testConfig(), onViewFreshnessChanged: (_) {});
      addTearDown(watchdog.dispose);

      expect(watchdog.debugTimerCount, 0,
          reason: 'a watchdog armed itself before a single frame had arrived, '
              'so a panel greys before it has even connected');
      for (var i = 0; i < 50; i++) {
        watchdog.sawFrame(InboundFrame.update);
      }
      expect(watchdog.debugTimerCount, 1,
          reason: 'the link is one link: N timers is N cancellations to get '
              'right on every reconnect, and the one that is missed fires '
              'against a socket that no longer exists');
    });

    test('disposal cancels the timer and no transition fires afterwards', () async {
      final log = TransitionLog();
      final watchdog =
          FreshnessWatchdog(config: testConfig(), onViewFreshnessChanged: log.record);

      watchdog.sawFrame(InboundFrame.tick);
      expect(watchdog.debugTimerCount, 1);
      watchdog.dispose();
      expect(watchdog.debugTimerCount, 0,
          reason: 'a disposed watchdog left a timer running, which keeps the '
              'isolate alive and fires a callback into a torn-down page');

      await Future<void>.delayed(deadline + ceiling);
      expect(log.staleFlags, isEmpty,
          reason: 'a disposed watchdog still announced a transition');
    });
  });

  // 04-REVIEW CR-06 and WR-06/WR-08. Two halves that used to be missing: the
  // expiry did nothing but flip a bool, and the per-subscription verdict
  // borrowed the *link* deadline as its limit.
  group('the watchdog acts, and knows whose clock it is judging', () {
    test('a link that goes quiet asks for something to be done about it',
        () async {
      var quiet = 0;
      final watchdog = FreshnessWatchdog(
          config: testConfig(), onViewFreshnessChanged: (_) {})
        ..onQuiet = () => quiet++;
      addTearDown(watchdog.dispose);

      watchdog.sawFrame(InboundFrame.tick);
      await Future<void>.delayed(deadline + ceiling);

      expect(quiet, 1,
          reason: 'a socket that has said nothing for a whole freshness '
              'deadline is one the client must stop believing in. Announcing '
              'it and doing nothing leaves LinkState reading ready over '
              'frozen values, which is the half-open case the product exists '
              'for');
      expect(watchdog.viewIsStale, isTrue);
    });

    test('the per-subscription limit follows the cadence the gateway '
        'advertised, not the link deadline', () {
      final watchdog = FreshnessWatchdog(
          config: testConfig(), onViewFreshnessChanged: (_) {});
      addTearDown(watchdog.dispose);
      // What a `hello` carries: `capabilities: {'tickMs': …}`. The multiple is
      // the config's default of 30, so the limit is thirty injected periods.
      watchdog.learnedTickMs(period.inMilliseconds);

      // Five periods without re-evaluation — comfortably past the *link*
      // deadline of three, which is the number this verdict used to borrow.
      var serverTime = serverEpochMs;
      for (var i = 0; i <= 5; i++) {
        watchdog.sawTick(TickParams(serverTime: serverTime, subs: {
          's1': const SubTick(seq: 0, evaluatedAt: serverEpochMs),
        }));
        serverTime += period.inMilliseconds;
      }
      expect(watchdog.isSubscriptionStale('s1'), isFalse,
          reason: 'a page whose plant-side source is evaluated more slowly '
              'than the socket ticks was marked permanently stale — the grey '
              'that cries wolf, and the operator stops reading grey');

      // Past thirty periods it is stale, which is the anti-vacuity half: a
      // limit that never fires reports a dead sensor as a healthy one.
      watchdog.sawTick(TickParams(
        serverTime: serverEpochMs + period.inMilliseconds * 31,
        subs: const {'s1': SubTick(seq: 0, evaluatedAt: serverEpochMs)},
      ));
      expect(watchdog.isSubscriptionStale('s1'), isTrue);
    });

    test('learning the cadence does not move the link deadline', () async {
      // The 04-CONTEXT ruling, asserted rather than trusted: reading "3x tick"
      // against the measured 50 ms fan-out gives a 150 ms deadline, and one GC
      // pause then greys every value on the screen at once.
      final log = TransitionLog();
      final watchdog = FreshnessWatchdog(
          config: testConfig(), onViewFreshnessChanged: log.record);
      addTearDown(watchdog.dispose);
      watchdog.learnedTickMs(period.inMilliseconds);

      watchdog.sawFrame(InboundFrame.tick);
      final wentStale = await within(log.firstStale, 'the view going stale',
          budget: deadline + ceiling);

      expect(wentStale, greaterThan(deadline - slack),
          reason: 'the link deadline moved when the client learned the '
              'gateway\'s cadence: it is configured, and it stays configured');
    });

    test('a gateway that advertises nothing leaves the limit where it was', () {
      final watchdog = FreshnessWatchdog(
          config: testConfig(), onViewFreshnessChanged: (_) {});
      addTearDown(watchdog.dispose);
      watchdog.learnedTickMs(null);

      watchdog.sawTick(TickParams(
        serverTime: serverEpochMs + period.inMilliseconds * 5,
        subs: const {'s1': SubTick(seq: 0, evaluatedAt: serverEpochMs)},
      ));

      expect(watchdog.tickMs, isNull);
      expect(watchdog.isSubscriptionStale('s1'), isTrue,
          reason: 'with no cadence to derive one from, the link deadline is '
              'the only horizon there is — over-reporting a dead subscription '
              'is the safe direction to be wrong in');
    });
  });

  group('per-subscription staleness: the dead subscription on a live socket', () {
    test('one frozen subscription is stale while the view and its neighbour are fresh', () {
      final log = TransitionLog();
      final watchdog =
          FreshnessWatchdog(config: testConfig(), onViewFreshnessChanged: log.record);
      addTearDown(watchdog.dispose);

      // Ticks keep arriving and s1 keeps being evaluated; s2's plant-side
      // source stopped at the first tick and never moved again. This is F25.
      var serverTime = serverEpochMs;
      const frozenAt = serverEpochMs;
      for (var i = 0; i <= 5; i++) {
        watchdog.sawTick(TickParams(serverTime: serverTime, subs: {
          's1': SubTick(seq: i, evaluatedAt: serverTime),
          's2': const SubTick(seq: 0, evaluatedAt: frozenAt),
        }));
        serverTime += period.inMilliseconds;
      }

      expect(watchdog.isSubscriptionStale('s2'), isTrue,
          reason: 'a subscription whose source stopped evaluating five periods '
              'ago still rendered as current, which is the operator trusting a '
              'dead number on a live screen');
      expect(watchdog.isSubscriptionStale('s1'), isFalse,
          reason: 'a healthy neighbour was condemned along with the dead one, '
              'so one dead PLC tag greys the values next to it');
      expect(watchdog.staleSubscriptions, equals(<String>{'s2'}));
      expect(watchdog.viewIsStale, isFalse,
          reason: 'the link is delivering ticks and the whole view was still '
              'called dead: link-down and one-value-dead are the two states '
              'CLI-04 exists to keep apart');
      expect(log.staleFlags, isEmpty,
          reason: 'a plant fault announced itself as a stream fault');
    });

    test('the live verdict ages on the monotonic clock between ticks', () {
      final elapsed = FakeElapsed();
      final watchdog = FreshnessWatchdog(
          config: testConfig(),
          onViewFreshnessChanged: (_) {},
          monotonic: elapsed.read);
      addTearDown(watchdog.dispose);
      watchdog.learnedTickMs(period.inMilliseconds);

      const frozenAt = serverEpochMs;
      final serverTime = serverEpochMs + period.inMilliseconds;
      watchdog.sawTick(TickParams(serverTime: serverTime, subs: {
        's1': SubTick(seq: 1, evaluatedAt: serverTime),
        's2': const SubTick(seq: 0, evaluatedAt: frozenAt),
      }));

      // A moment chosen so the frozen subscription is past the limit and its
      // still-evaluating neighbour is not. The case would prove nothing at an
      // instant where both were stale, or where neither was.
      final limitMs = period.inMilliseconds * 30;
      elapsed.ms += limitMs - period.inMilliseconds ~/ 2;

      expect(watchdog.staleSubscriptionsNow(), equals(<String>{'s2'}),
          reason: 'the frozen subscription was not caught between ticks, '
              'which is the whole of what this surface is for');
      expect(watchdog.isSubscriptionStaleNow('s2'), isTrue);
      expect(watchdog.isSubscriptionStaleNow('s1'), isFalse,
          reason: 'a healthy neighbour was condemned along with the dead one');
    });

    test('a panel\'s wall clock is not an input to the verdict', () {
      // **07-REVIEW CR-01, as a structural pin.** The shape this replaced read
      // `DateTime.now()` and converted it with a `clockOffset` captured once
      // per connection at `hello`. Reproduced before the fix: with the offset
      // held at its captured value — which is what happens, because nothing
      // re-derives it — a three-second backward RTC step made a subscription
      // the gateway had not evaluated for two whole limits read **fresh**.
      //
      // The behavioural cases in this group pin the replacement. This one pins
      // that the input is gone, because the replacement is only worth
      // anything for as long as nobody adds the wall clock back beside it: a
      // single `DateTime.now()` on this path re-opens the same hole and every
      // case around it stays green.
      for (final path in <String>[
        'lib/src/freshness_watchdog.dart',
        'lib/src/remote_state_man.dart',
      ]) {
        final source = File(path);
        expect(source.existsSync(), isTrue,
            reason: 'this case reads the implementation as text, so it must '
                'run with the tfc_relay_client package root as the working '
                'directory; dart test was invoked from '
                '${Directory.current.path} and found no $path');

        final lines = source.readAsLinesSync();
        final hits = <String>[
          for (var i = 0; i < lines.length; i++)
            if (lines[i].contains('DateTime.now()') &&
                !lines[i].trimLeft().startsWith('///') &&
                !lines[i].trimLeft().startsWith('//'))
              '$path:${i + 1}  ${lines[i].trim()}',
        ];

        expect(hits, isEmpty,
            reason: 'the staleness path reads this panel\'s wall clock '
                'again:\n${hits.map((hit) => '  $hit').join('\n')}\n\n'
                'A wall clock steps — NTP correcting a fish-factory panel\'s '
                'dead CMOS battery is the case `clock_offset.dart:19-21` '
                'describes — and a verdict computed from one steps with it: '
                'backwards, a dead subscription renders fresh, which is the '
                'one failure CLAUDE.md\'s Core Value forbids. Age against '
                'FreshnessWatchdog.serverNowMs, which is anchored on a '
                'Stopwatch and cannot step.');
      }
    });

    test('a late tick does not re-anchor the gateway\'s clock', () {
      // The arm that keeps F20 true across CR-01's fix. Re-deriving the
      // anchor from every tick is the obvious way to track the gateway, and it
      // is wrong in exactly the case this surface was wired for: on a
      // saturated link every sample arrives late, so an anchor that adopted
      // them would re-base onto the backlog and report the page this panel is
      // minutes behind on as current.
      final elapsed = FakeElapsed();
      final watchdog = FreshnessWatchdog(
          config: testConfig(),
          onViewFreshnessChanged: (_) {},
          monotonic: elapsed.read);
      addTearDown(watchdog.dispose);
      watchdog.learnedTickMs(period.inMilliseconds);

      watchdog.anchorServerClock(serverEpochMs);

      // Real time passes; the link falls behind by all of it but one tick, so
      // the frame that finally lands was built almost a whole limit ago.
      final limitMs = period.inMilliseconds * 30;
      elapsed.ms += limitMs * 2;
      final builtAt = serverEpochMs + period.inMilliseconds;
      watchdog.sawTick(TickParams(serverTime: builtAt, subs: {
        's1': SubTick(seq: 1, evaluatedAt: builtAt),
      }));

      expect(watchdog.staleSubscriptionsNow(), equals(<String>{'s1'}),
          reason: 'a tick that spent two staleness limits in a queue was taken '
              'as evidence of what time it is at the gateway, so the panel '
              'aged the frame against the moment the frame itself was built '
              'and called it current. That is F20 exactly, reintroduced '
              'through the clock rather than through sawTick');
      expect(watchdog.staleSubscriptions, isEmpty,
          reason: 'the last-tick verdict is the blind one by construction, and '
              'this case is only a contrast if the two disagree here');
    });

    test('an on-time tick re-anchors, so a long connection tracks drift', () {
      // The other side of the asymmetry. A monotonic clock cannot step but it
      // does drift — tens of ppm against a disciplined gateway is seconds a
      // day, and the limit is seconds — so an anchor taken at `hello` and
      // never refined would grey a healthy plant on a connection the heartbeat
      // now keeps up for days.
      final elapsed = FakeElapsed();
      final watchdog = FreshnessWatchdog(
          config: testConfig(),
          onViewFreshnessChanged: (_) {},
          monotonic: elapsed.read);
      addTearDown(watchdog.dispose);
      watchdog.learnedTickMs(period.inMilliseconds);

      watchdog.anchorServerClock(serverEpochMs);

      // This panel's crystal has run fast: a whole limit of local time passed
      // while the gateway advanced by a limit less half a tick period. The
      // shortfall is inside one tick period, so it is drift and is adopted.
      final limitMs = period.inMilliseconds * 30;
      elapsed.ms += limitMs;
      final gatewayNow = serverEpochMs + limitMs - period.inMilliseconds ~/ 2;
      watchdog.sawTick(TickParams(serverTime: gatewayNow, subs: {
        's1': SubTick(seq: 1, evaluatedAt: gatewayNow),
      }));

      expect(watchdog.serverNowMs, gatewayNow,
          reason: 'the anchor did not follow a sample that arrived on time, so '
              'this panel\'s estimate of the gateway\'s clock is now half a '
              'tick ahead of it and every hour of connection adds more. A '
              'panel that has been up a week greys a running plant');
      expect(watchdog.staleSubscriptionsNow(), isEmpty);
    });

    test('fifty subscriptions add no timers — one link, one deadline', () {
      final watchdog =
          FreshnessWatchdog(config: testConfig(), onViewFreshnessChanged: (_) {});
      addTearDown(watchdog.dispose);

      final subs = <String, SubTick>{
        for (var i = 0; i < 50; i++)
          's$i': const SubTick(seq: 0, evaluatedAt: serverEpochMs),
      };
      watchdog.sawTick(TickParams(serverTime: serverEpochMs, subs: subs));

      expect(watchdog.debugTimerCount, 1,
          reason: 'per-subscription staleness grew a timer per subscription: a '
              '1500-key page is then 1500 cancellations to get right on every '
              'reconnect, and the one that is missed fires into a dead page');
    });

    test('a subscription that starts evaluating again is fresh again, with nothing resynced',
        () {
      final log = TransitionLog();
      final watchdog =
          FreshnessWatchdog(config: testConfig(), onViewFreshnessChanged: log.record);
      addTearDown(watchdog.dispose);

      const frozenAt = serverEpochMs;
      final lateTime = serverEpochMs + deadline.inMilliseconds * 2;
      watchdog.sawTick(TickParams(serverTime: lateTime, subs: {
        's1': const SubTick(seq: 0, evaluatedAt: frozenAt),
      }));
      expect(watchdog.isSubscriptionStale('s1'), isTrue);

      watchdog.sawTick(TickParams(serverTime: lateTime, subs: {
        's1': SubTick(seq: 1, evaluatedAt: lateTime),
      }));

      expect(watchdog.isSubscriptionStale('s1'), isFalse,
          reason: 'a source that started evaluating again stayed condemned, so '
              'the operator has to reload the page to believe a live value');
      expect(log.staleFlags, isEmpty,
          reason: 'a plant fault that healed itself moved the whole view, which '
              'is the resync this class must never ask for');
    });

    test('an unsubscribed subscription stops being reported', () {
      final watchdog =
          FreshnessWatchdog(config: testConfig(), onViewFreshnessChanged: (_) {});
      addTearDown(watchdog.dispose);

      final lateTime = serverEpochMs + deadline.inMilliseconds * 2;
      watchdog.sawTick(TickParams(serverTime: lateTime, subs: {
        's1': const SubTick(seq: 0, evaluatedAt: serverEpochMs),
      }));
      expect(watchdog.staleSubscriptions, equals(<String>{'s1'}));

      watchdog.forgetSubscription('s1');

      expect(watchdog.staleSubscriptions, isEmpty,
          reason: 'an id nobody is subscribed to any more kept raising a fault '
              'about a value no screen displays');
    });
  });

  // -------------------------------------------------------------------------
  // 07-RESEARCH §B.4, and 07-CONTEXT user ruling 1.
  // -------------------------------------------------------------------------

  group('the verdict a screen reads ages between ticks', () {
    test('the last-tick verdict and the live verdict disagree once local time '
        'has passed, and the live one is the honest one', () {
      final elapsed = FakeElapsed();
      final watchdog = FreshnessWatchdog(
          config: testConfig(),
          onViewFreshnessChanged: (_) {},
          monotonic: elapsed.read);
      addTearDown(watchdog.dispose);
      watchdog.learnedTickMs(period.inMilliseconds);

      // One tick, in which the subscription was evaluated at that very
      // instant, and then nothing. This is a saturated link exactly: the panel
      // is holding a frame that agreed with itself when it was built, and no
      // newer frame has arrived to disagree with it.
      watchdog.sawTick(TickParams(serverTime: serverEpochMs, subs: const {
        's1': SubTick(seq: 0, evaluatedAt: serverEpochMs),
      }));

      // The limit is the advertised cadence times the multiple, floored at the
      // link deadline. Both halves are read below well past it.
      final limitMs = period.inMilliseconds * 30;
      elapsed.ms += limitMs * 2;

      expect(watchdog.staleSubscriptions, isEmpty,
          reason: 'the last-tick verdict is the arithmetic of one frame '
              'against itself: `sawTick` compares `tick.serverTime` with the '
              '`evaluatedAt` carried in the same frame, so a frame that is a '
              'minute old is internally consistent and reports fresh. This '
              'expectation is not a property anybody wants — it is the '
              'measurement of the surface that must never be the one a screen '
              'reads');
      expect(watchdog.staleSubscriptionsNow(), equals(<String>{'s1'}),
          reason: 'the live verdict ages the same subscription against the '
              'gateway clock estimated from elapsed time, and ${limitMs * 2} '
              'ms after its last evaluation it did not report it stale. That '
              'is the arithmetic this whole surface exists for');
    });

    test('a panel whose frames have stopped reports its subscription stale', () async {
      // **The RED this plan was written for** (07-RESEARCH §B.4). The panel is
      // not disconnected in any way it can detect from a frame: it holds a
      // snapshot the gateway really sent, and the frame it is holding agrees
      // with itself. What has stopped is the arrival of newer ones.
      //
      // The starvation is a blackhole rather than a throttle because this is
      // the *unit* companion to F20's clause 3: the socket-level row measures
      // the same lie under a metered link over thirty seconds, and this one
      // has to fail in under two so it runs on every commit.
      final fixture = relayFixture(
        withProxy: true,
        clientConfig: ClientConfig(
          controlDeadline: const Duration(seconds: 2),
          writeDeadline: const Duration(seconds: 2),
          // Short, so the whole case is about a second. The link deadline is
          // the floor under the per-subscription limit, so lowering the
          // multiple alone would not move it.
          freshnessDeadline: const Duration(milliseconds: 600),
          backoffBase: const Duration(milliseconds: 20),
          backoffCap: const Duration(milliseconds: 200),
          deadlineFloor: const Duration(milliseconds: 50),
          subscriptionStalenessMultiple: 4,
        ),
      );
      await fixture.ready;

      final tap = fixture.client.subscribe(scenarioKey).listen((_) {});
      addTearDown(tap.cancel);
      fixture.served.setValues(const {scenarioKey: 7});
      await until('the panel to be shown a value for $scenarioKey',
          () => fixture.client.read(scenarioKey)?.value == 7,
          budget: const Duration(seconds: 5));

      // **The precondition, established rather than assumed.** The verdict
      // below ages `evaluatedAt` against the gateway clock this panel
      // estimates from tick frames, and a panel with no such estimate reports
      // nothing stale at all — correctly, because there is no clock for
      // anything to be late against. From outside that is indistinguishable
      // from a panel that has an anchor and judges everything fresh, so a case
      // that starves the link first waits five seconds for a verdict that can
      // never arrive and fails having never reached the state it is named for.
      //
      // A value having arrived does not establish it: values ride `u` frames
      // and the clock sample comes from `tick`, which are separate frames. On
      // an unloaded machine the tick has always landed by now; that is luck,
      // not a guarantee, and this is the shape of the failure this case showed
      // on windows-latest. Split out so the two failures read differently —
      // this one says the panel never got a clock, the one below says it got
      // one and did not use it.
      // **The clock is not the precondition, and the old wait said it was.**
      // `debugHasServerClock` is true from `hello` — `anchorServerClock` has
      // exactly one caller, `connection_supervisor.dart:712`, and it is the
      // hello handler. So this wait returned several frames before the thing
      // the case needs.
      //
      // What it needs is an `evaluatedAt` to age. Those ride `tick` frames, and
      // `staleSubscriptionsNow` ages the map they fill; with the map empty it
      // returns the empty set for as long as the link stays quiet, which is
      // correct — the panel has not been told what to age — and indistinguish-
      // able from a panel that judges everything fresh. That is what starved
      // the case on windows-latest: it blackholed before the first tick and
      // then waited out its budget, twenty seconds of it once the runner
      // factor applied, for a verdict that could not arrive.
      await until('the panel to take a gateway clock sample',
          () => fixture.client.debugHasServerClock,
          budget: const Duration(seconds: 5));
      await until(
          'the panel to record an evaluatedAt from a tick frame, which is what '
          'a stale verdict is computed against',
          () => fixture.client.debugEvaluatedSubCount > 0,
          budget: const Duration(seconds: 5));

      // Nothing crosses the proxy in either direction from here. No close, no
      // reset: the panel's socket stays open and readyState goes on saying so
      // (CLAUDE.md's known-bugs list — `readyState` lies).
      fixture.proxy.blackhole();

      await until(
          'the panel to report the subscription it has stopped hearing about '
          'as stale',
          () => fixture.client.staleSubscriptions.isNotEmpty,
          budget: const Duration(seconds: 5));

      expect(fixture.client.staleSubscriptions, isNotEmpty, // window-exempt: the until() immediately above completed on this same predicate, so this is the value of the set the window already established rather than a second bet on the deadline
          reason: 'the panel reported every subscription current while no '
              'frame had reached it for several deadlines. `staleSubscriptions` '
              'delegated to the set `sawTick` stored, which is a comparison '
              'between two fields of the same delayed frame and therefore '
              'detects nothing — the panel one minute behind reads as live, '
              'which is the product\'s one unforgivable failure arriving '
              'through a door the link watchdog does not cover');
    });
  });
}

/// Drives [kind] alone, once per [period], and fails if the view ever greys.
///
/// Written as one helper over the frame vocabulary because the bite is in the
/// *alone*: a watchdog rescheduling only on ticks passes the idle-link cases
/// above and dies here, on the plant that is busy enough that updates have
/// displaced the tick.
Future<void> expectKindKeepsViewFresh(InboundFrame kind) async {
  final log = TransitionLog();
  final watchdog =
      FreshnessWatchdog(config: testConfig(), onViewFreshnessChanged: log.record);
  addTearDown(watchdog.dispose);

  watchdog.sawFrame(kind);
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(period);
    watchdog.sawFrame(kind);
  }

  expect(watchdog.viewIsStale, isFalse,
      reason: 'a link carrying nothing but ${kind.name} frames was called dead, '
          'so the plant greyed while data was arriving');
  expect(log.staleFlags, isEmpty,
      reason: 'a ${kind.name} frame did not reset the freshness clock');
}
