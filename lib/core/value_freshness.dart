/// Whether the values on this panel are the current connection's, and what a
/// value stream carries while they are not.
///
/// **The gap this closes was measured on hardware, not theorised.** The
/// attended rig run of 2026-09-07 cut a connected panel's link and watched it:
/// at +25 s and again at +65 s the app-bar chip read yellow `No gateway` while
/// **every plant value on the home page still rendered definite** — no `!`, no
/// `--- °C`, no greying. The chip was the only thing on the screen that knew.
/// `CLAUDE.md`'s Core Value is *"values are fresh or visibly stale"*, and on a
/// real panel it did not hold.
///
/// The cause was never missing plumbing. 16-10-SUMMARY reported it plainly:
/// **`viewIsStale` and `viewFreshness` had no reader in any `lib/`.** Phase 16
/// built the verdict and the last hop was never wired. This file is that hop.
///
/// ## Which verdict, and why not the other one
///
/// `FreshnessWatchdog` computes two, and they are deliberately independent:
///
///  * **[ValueFreshness] wraps the link-level one** — `viewIsStale`. One
///    deadline (`ClientConfig.freshnessDeadline`, 3 s in production) restarted
///    by any inbound frame; true from `_linkWentQuiet`, and false again *only*
///    from `viewBecameFresh`, which the supervisor calls from
///    `_enter(LinkState.ready)` — after every page's snapshot has been adopted.
///    16-10 / S9 moved it there precisely so the promise reads "this view is
///    showing data from the current connection" rather than "a frame arrived".
///    That is the promise a screen needs, and it is why nothing here has to
///    think about resync windows: the client already thought about them.
///  * **`staleSubscriptions` / `isSubscriptionStaleNow` are not read here.**
///    They answer a different fault — F25, a provably live link with one
///    plant-side source that stopped evaluating — and the two are kept apart on
///    purpose (`latency_gate_test.dart:146-161` is emphatic that coupling them
///    would turn every slowly-evaluated tag into a grey panel). They are also
///    **pull-only**: computed on read with no timer and no transition stream,
///    by design, so there is no event a widget could repaint on. Wiring them
///    would mean inventing a poll — a second freshness model, and a timer this
///    repo's `timers-must-be-listener-gated` rule exists to prevent. Left
///    unread, and recorded as a finding rather than papered over.
///
/// ## Why this class exists at all rather than reading the client directly
///
/// Three reasons, and each of them is a defect avoided:
///
///  1. **Direct mode has no client.** A station in direct mode holds no gateway
///     and no link-level staleness of this kind, and must never grey out
///     because of one. [ValueFreshness.fresh] is that station's object: `false`
///     for ever, a stream that never fires, and nothing to dispose.
///  2. **`viewFreshness` publishes transitions and only transitions.** A key
///     stream opened *during* an outage — an operator navigating to another
///     page while the link is down — would attach to that stream and hear
///     nothing, for ever, because the transition it needed happened before it
///     existed. So [isStale] is held here and kept current, and a late reader
///     asks the object rather than the stream.
///  3. **One place to fake.** The verdict crosses into widgets through a plain
///     `Stream<bool>` and a `bool`, so an arm can drive it without a socket,
///     and the arms that *do* want a socket still go through the same door.
library;

import 'dart:async';

/// The reason a key stream is carrying no value.
///
/// **An exception, on the channel the asset library already speaks.** Every
/// value on every page arrives through `keyStreamProvider`, and every asset that
/// renders one already spells `(snapshot.hasData && !snapshot.hasError) ? … :
/// null` — beckhoff, schneider, advantys, festo, vtug, io_pane, section_button,
/// el9222, conveyor — and turns that `null` into the vocabulary an operator has
/// been taught to read: `number.dart`'s `---`, `led.dart`'s and
/// `conveyor.dart`'s `!`, the grey belt. The rig photographed exactly that in
/// the `notBuilt` state and recorded it as correct and legible across a room.
///
/// So a stale link does not need a new rendering; it needs to reach the one the
/// app already has. Nothing about the pixels moves, which is also why this
/// change cannot shift a golden frame.
///
/// **Why not a flag on the value instead.** There is nowhere to put one:
/// `gateway_state_man.dart:378-382` records that quality does not survive the
/// crossing because this open62541 version's `DynamicValue` has no field for it,
/// which is why a bad-quality reading already arrives as a null value. A new
/// carrier type would have to cross every asset in the library; the error
/// channel is already carried, already handled, and already renders correctly.
class StaleValues implements Exception {
  const StaleValues(this.key);

  /// The key whose value is being withheld.
  final String key;

  /// Written for a screen, because it can reach one: `table.dart:128-130`
  /// renders `snapshot.error.toString()` verbatim in its error widget.
  ///
  /// It says what is true and no more — the panel has not heard from the
  /// gateway, so it will not vouch for the number it last received. It does not
  /// say the plant stopped, and it does not name a cable: the chip and the
  /// Transport card own the diagnosis, and 15-08 pinned that the *local*
  /// failures must not talk about cables and switches.
  @override
  String toString() => 'No fresh value for "$key": this panel has not heard '
      'from the gateway inside its freshness deadline, so the value it last '
      'received is not being shown as current.';
}

/// The live link-level freshness verdict, as `lib/` reads it.
///
/// Two shapes, and the constructor names which station it is:
/// [ValueFreshness.fresh] for a direct station, [ValueFreshness.watching] for a
/// gateway one.
final class ValueFreshness {
  /// A station whose values are never in doubt from a *link's* side.
  ///
  /// Direct mode, and the two gateway cases that are indistinguishable from it
  /// for this purpose: a transport row still being read, and a client that
  /// could not be built at all. In the last one there is no socket, so no value
  /// ever arrives and every asset already renders `---` — greying it a second
  /// way would add nothing and would need a verdict nothing computes.
  ///
  /// [changes] is a stream that never fires rather than `null`, so every reader
  /// is written once. It costs a direct station one closed-over controller and
  /// no timer, no subscription and no listener.
  ///
  /// **One shared instance, because identity is load-bearing.**
  /// `keyStreamProvider` watches `valueFreshnessProvider`, and Riverpod rebuilds
  /// a dependent when the value changes by `==`. That provider is rebuilt
  /// whenever the transport row or `stateManProvider` resolves, so a fresh
  /// object per build would hand out a new identity on a station whose answer
  /// had not moved — and every key on the panel would drop and re-open its
  /// subscription behind it. That is precisely the ~130 KiB/s churn
  /// `keyStreamProvider`'s own doc exists to prevent, re-introduced by the back
  /// door. It is not theoretical: wiring the gate with a per-build object
  /// doubled every subscribe count in `key_stream_provider_test.dart`, which is
  /// how this constructor became a factory.
  factory ValueFreshness.fresh() => _fresh;

  static final ValueFreshness _fresh = ValueFreshness._direct();

  ValueFreshness._direct()
      : _isStale = false,
        _watching = false;

  /// A gateway station, tracking one client's link-level verdict.
  ///
  /// [stale] is the client's `viewIsStale` at this moment and [transitions] its
  /// `viewFreshness`. **Both are read in one synchronous step** — the argument
  /// is evaluated and the listener attached with no `await` between them — so
  /// there is no window for a transition to fall into. That is the same F-5
  /// hazard `lib/providers/gateway_link.dart` documents at length for
  /// `linkStates`, and the reason it is only a paragraph here is that this
  /// constructor cannot be interleaved, not that the hazard was overlooked.
  ValueFreshness.watching({
    required bool stale,
    required Stream<bool> transitions,
  })  : _isStale = stale,
        _watching = true {
    _source = transitions.listen(
      _adopt,
      // A verdict stream that errored is not a verdict that values are fine.
      // Nothing downstream can act on the error itself, and an unhandled one
      // would surface as a zone failure in an unrelated widget test, so the
      // last verdict stands and the link's own surfaces — the chip, the
      // Transport card — keep reporting the link.
      onError: (Object _) {},
    );
  }

  bool _isStale;

  /// Whether this object is tracking a client, as opposed to being a direct
  /// station's constant.
  ///
  /// **The anti-vacuity observable.** "A direct station does not grey out" is
  /// also true of a station whose verdict was never wired to anything, and the
  /// two are indistinguishable from [isStale] alone. An arm asserting the
  /// negative reads this to show it had something that *could* have gone stale.
  final bool _watching;

  StreamSubscription<bool>? _source;

  /// Re-broadcast rather than the client's own stream handed straight through:
  /// a direct station has no stream to hand through, and de-duplicating here
  /// means a reader can trust that every event is a change.
  final StreamController<bool> _out = StreamController<bool>.broadcast();

  /// Whether the panel is currently unable to vouch for its values.
  ///
  /// Live, not a construction-time snapshot — see reason 2 in the library doc.
  bool get isStale => _isStale;

  /// Whether a client's verdict is behind [isStale]. See [_watching].
  bool get isWatchingLink => _watching;

  /// Every transition of [isStale], and only the transitions.
  Stream<bool> get changes => _out.stream;

  void _adopt(bool stale) {
    if (stale == _isStale) return;
    _isStale = stale;
    if (!_out.isClosed) _out.add(stale);
  }

  /// Drops the client subscription and closes [changes].
  ///
  /// Called from the provider's `onDispose`, and a **no-op on the shared
  /// direct-station verdict** — that one is process-wide by construction (see
  /// [ValueFreshness.fresh]), so closing its stream on behalf of one container
  /// would leave every later container listening to a closed controller.
  /// Nothing is leaked by declining: it holds no subscription, no timer and no
  /// listener, and its controller is never fed.
  Future<void> dispose() async {
    if (!_watching) return;
    final source = _source;
    _source = null;
    await source?.cancel();
    await _out.close();
  }
}
