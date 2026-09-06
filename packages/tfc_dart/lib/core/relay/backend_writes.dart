/// The write half of the backend adapter: an operator's command, carried from
/// a connected client through main and down the pipe with its three-state
/// outcome intact.
///
/// This file exists because of one sentence in `CLAUDE.md`: *writes are applied
/// / rejected / explicitly unknown — never silently lost, never silently
/// re-sent*. Phase 12 built that guarantee across the isolate boundary
/// (`kPipeWriteDeadline` 5 s, worker death resolving unknown, no replay across
/// a respawn). This class carries it up to `StateManApi` without weakening it,
/// and adds the two things the pipe does not have:
///
///  * **an outcome log**, so `writeStatus` can answer a client that reconnected
///    after the link died with the write still in the air; and
///  * **the hold-to-run deadman** (`backend_hold.dart`), which is write-shaped
///    and rides the same discipline.
///
/// ## The rules, in the order they are enforced
///
///  1. **Nothing on any path sends a command a second time.** Not on a
///    deadline, not on a worker death, not on a respawn. A wrapper that did
///    would be invisible from the API surface — same call, same result type, a
///    few hundred milliseconds later — which is why
///    [BackendWrites.upstreamAttempts] exists and why the contract asserts a
///    number rather than a behaviour.
///  2. **The outcome is returned unchanged in kind.** Applied stays applied,
///    rejected stays rejected, unknown stays unknown. Nothing collapses unknown
///    into a failure, and no member of this class throws to report an outcome.
///  3. **A supplied `cmd` is passed through.** `StateManApi.write` mints the id
///    at the operator's keyboard *except* on a relay, and this adapter is a
///    relay: "a relay passes the id it was given, and does not mint". An
///    implementation in the middle that minted a second id would have created a
///    write it can no longer reconcile — the client's `writeStatus` would ask
///    about an id this side never recorded.
///  4. **Readback is the only confirmation.** An applied write stores what the
///    plant reported, never what the caller typed.
///  5. **`not_received` needs four pieces of positive evidence.** Anything
///    short of all four is `WriteUnknown`: "I have no record of it" and "it
///    never happened" are the same sentence to a lookup table and very
///    different sentences to a machine.
///
/// ## The pipe's `cmd` is not an operator action id
///
/// `PipeMainEndpoint.write` answers with a `WriteResult` whose `cmd` is a
/// per-worker integer sequence number — a transport correlation id. It restarts
/// with the isolate and two workers issue the same numbers, so it cannot be the
/// thing a client reconciles by. Every result crossing this class is therefore
/// re-stamped with the operator's own id. **Re-stamping is not minting**: no
/// second id is created, the one the operator's action already carries is put
/// back on an answer that lost it at a transport boundary.
///
/// ## Why the outcome log is written here rather than reused
///
/// `tfc_relay_server` has a `WriteOutcomeLog` with exactly these semantics, and
/// it is deliberately **not** on that package's barrel — the barrel's own doc
/// says an embedder "configures and starts a server, it does not reach into a
/// session". Reaching past it with a `package:tfc_relay_server/src/…` import
/// trips `implementation_imports`, which `flutter_lints` has on, and adding the
/// export is an edit to a package this plan is scoped out of. So the evidence
/// rules are re-stated here, in [BackendWriteOutcomeLog], deliberately spelled
/// the same way so the two cannot drift on the one question that matters
/// (`witnessed` / `insideWindow`).
///
/// The two logs do **not** answer about the same command in the mounted
/// composition, and that is worth stating because it is not obvious:
/// `value_handlers.dart:720` answers a wire `writeStatus` entirely from the
/// gateway's own log and never delegates to `StateManApi.writeStatus`. So the
/// server's log answers clients; this one answers in-process callers and the
/// contract suite. See 13-10.
///
/// Protocol types are imported `as relay`, the house rule inside `tfc_dart`.
library;

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:meta/meta.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_hold.dart';
import 'package:tfc_dart/core/relay/backend_seams.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// How long this source remembers what became of a write.
///
/// The same 60 s `ServerConfig.writeOutcomeTtl` defaults to, and for the same
/// argument: it is the boundary of a *safety* claim rather than of a
/// convenience. `not_received` — the one verdict that tells an operator a
/// second press is safe — may only be given for a command minted inside this
/// window, because outside it this side cannot tell "never arrived" from
/// "arrived, and forgotten". 60 s is the reconnect budget (backoff capped at
/// 30 s, so one full cycle plus a resync) with room to spare.
const Duration kBackendWriteOutcomeTtl = Duration(seconds: 60);

/// Crockford base32, exactly as `ulid.dart` mints it: no I, L, O or U.
const String _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// The write this outcome was recorded for: the tag, the payload and the
/// compare-and-set guard.
///
/// One question — "is the frame in my hand the same operator action as the one
/// I already answered?" — so one record rather than three loose fields that can
/// drift apart. `expect` is in here deliberately: "set 1450" and "set 1450 only
/// if it still reads 1200" are two different operator intents, and answering
/// the unguarded one from the guarded one's entry would report that a check
/// passed which was never made.
typedef BackendWriteFingerprint = ({String key, Object? value, Object? expect});

/// One recorded outcome, and the instant it was recorded at.
final class BackendWriteOutcomeEntry {
  const BackendWriteOutcomeEntry(this.result, this.atMs, this.fingerprint);

  /// What became of the write. A write still upstream is recorded too, as
  /// [relay.WriteUnknown]: a `writeStatus` crossing a command on its way to a
  /// machine must not answer that it never arrived.
  final relay.WriteResult result;

  /// This source's clock when the outcome was recorded.
  final int atMs;

  /// The write the outcome is about.
  final BackendWriteFingerprint fingerprint;

  /// Whether [other] is the same operator action this outcome belongs to.
  ///
  /// Deep JSON equality on the payload and the guard (`json_equality.dart`),
  /// which is insensitive to object key order and holds numbers to their
  /// runtime type so a DINT `1` and a REAL `1.0` stay two different writes.
  bool matches(BackendWriteFingerprint other) =>
      fingerprint.key == other.key &&
      relay.jsonEquals(fingerprint.value, other.value) &&
      relay.jsonEquals(fingerprint.expect, other.expect);
}

/// Every write outcome this source is still prepared to speak about.
///
/// Pruned on access rather than by a clock of its own: it is data with a clock
/// passed in, not a scheduler, so a case models an aged entry with arithmetic
/// instead of a sleep.
final class BackendWriteOutcomeLog {
  BackendWriteOutcomeLog({required this.ttl, required this.now})
      : startedAtMs = now();

  /// How long an outcome is kept, and the width of the `not_received` window.
  final Duration ttl;

  /// Epoch milliseconds, injected: every promise here is arithmetic about
  /// *when*.
  final int Function() now;

  /// This source's own clock at the moment it began recording.
  ///
  /// The lower bound on every `not_received`. On a running backend that is boot
  /// time, so the window opens once and stays open across every client
  /// reconnect — which is the difference between "I was watching and it never
  /// came" and "I have only just started watching".
  final int startedAtMs;

  final Map<String, BackendWriteOutcomeEntry> _entries =
      <String, BackendWriteOutcomeEntry>{};

  /// How many outcomes are being held. The observable behind the bounded-log
  /// arm; nothing in production depends on it.
  int get recordedOutcomes => _entries.length;

  /// Records [result] for [cmd], replacing whatever was there.
  void record(String cmd, relay.WriteResult result,
      BackendWriteFingerprint fingerprint) {
    prune();
    _entries[cmd] = BackendWriteOutcomeEntry(result, now(), fingerprint);
  }

  /// The entry held for [cmd] after pruning, or null.
  BackendWriteOutcomeEntry? entryFor(String cmd) {
    prune();
    return _entries[cmd];
  }

  /// Whether this log was recording when [mintedAtMs] was minted, and whether
  /// that instant is one this clock can vouch for.
  ///
  /// False for a command from before [startedAtMs] and for one from the future.
  /// Both are "forgetting is not evidence" wearing different clothes.
  bool witnessed(int mintedAtMs) =>
      mintedAtMs >= startedAtMs && mintedAtMs <= now();

  /// Whether [mintedAtMs] is inside the window this log still answers for.
  bool insideWindow(int mintedAtMs) =>
      now() - mintedAtMs <= ttl.inMilliseconds;

  /// Drops everything past the TTL.
  void prune() {
    final horizon = now() - ttl.inMilliseconds;
    _entries.removeWhere((_, entry) => entry.atMs < horizon);
  }
}

/// `BackendWriteSource` over [PipeMainEndpoint]. See the library doc.
final class BackendWrites implements BackendWriteSource {
  /// Composes the write half over an already-built pipe and value source.
  ///
  /// [now] is injectable epoch milliseconds so the TTL and the four evidence
  /// conditions can be aged by arithmetic rather than by a sleep —
  /// `RelayServer` does exactly this (`relay_server.dart:181-184`). It is
  /// deliberately the only injected clock: the write *deadline* belongs to the
  /// pipe and stays on the real one, because a source that never runs its own
  /// timeout passes every fake-clock case and hangs in the plant.
  BackendWrites({
    required PipeMainEndpoint pipe,
    required BackendValueSource values,
    Duration outcomeTtl = kBackendWriteOutcomeTtl,
    int Function()? now,
    Logger? logger,
  })  : _pipe = pipe,
        _values = values,
        _now = now ?? _wallClock,
        _logger = logger ?? Logger(),
        _log = BackendWriteOutcomeLog(
            ttl: outcomeTtl, now: now ?? _wallClock) {
    _holds = BackendHoldRegistry(feed: _feedDeadman, logger: _logger);
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final PipeMainEndpoint _pipe;
  final BackendValueSource _values;
  final int Function() _now;
  final Logger _logger;
  final BackendWriteOutcomeLog _log;

  /// The live holds this source is keeping. See `backend_hold.dart`.
  late final BackendHoldRegistry _holds;

  /// How many times each command has been handed to the pipe.
  ///
  /// **An observable, never a wire member**, for `backend_seams.dart`'s reason
  /// about `roundTrips`: it exists so a contract case can assert that one
  /// operator action cost exactly one upstream attempt, and a count a connected
  /// client could query would be an access-control decision rather than a
  /// testing convenience. Bounded by the outcome log's own window — an entry
  /// pruned there drops its counter here.
  final Map<String, int> _attempts = <String, int>{};

  /// Every id this source minted, in the order it minted them.
  ///
  /// A passed-through id is deliberately absent: the list is what distinguishes
  /// the relay case from a coincidence.
  final List<String> _mintedCmds = <String>[];

  bool _disposed = false;

  /// How many times [cmd] has been handed to the pipe. Must be one, forever.
  @visibleForTesting
  int upstreamAttempts(String cmd) => _attempts[cmd] ?? 0;

  /// Every id this source minted, in order. Test observable.
  @visibleForTesting
  List<String> get mintedCmds => List<String>.unmodifiable(_mintedCmds);

  /// How many outcomes the log is holding. Test observable.
  @visibleForTesting
  int get recordedOutcomes {
    _log.prune();
    return _log.recordedOutcomes;
  }

  // ----------------------------------------------------------------- the write

  /// Sends [value] to [key] and reports what became of it.
  ///
  /// Deliberately **not** an `async` function. The body has to reach
  /// [PipeMainEndpoint.write] and [BackendValueSource.markPending]
  /// synchronously, so that a caller which drops the link on the very next line
  /// finds a pending record already in the pipe's table, and a widget watching
  /// the key sees the badge before the caller's next `await`. An `async` body
  /// with a guard clause above the send would move both behind a microtask.
  @override
  Future<relay.WriteResult> write(String key, Object? value,
      {Object? expect, String? cmd}) {
    final id = cmd ?? _mint();

    if (_disposed) {
      // Loud, not silent. A command accepted by a torn-down router is accepted
      // and dropped, and at the panel silence and success look the same.
      return Future<relay.WriteResult>.value(relay.WriteRejected(
        id,
        const relay.WriteReason('source_disposed',
            message: 'this write router has been torn down, so nothing was '
                'sent and nothing could have moved'),
        at: _now(),
      ));
    }

    // The poison is defused at the boundary. Dart's jsonEncode throws on NaN
    // and ±Infinity rather than emitting null, so one open-circuit 4-20 mA
    // input would fail the frame for every other client on the pipe — and a
    // write that throws on the way in is an outcome the operator never learns.
    final sanitized = relay.sanitize(value);
    final fingerprint = (
      key: key,
      value: sanitized.value,
      expect: relay.sanitize(expect).value,
    );

    final held = _log.entryFor(id);
    if (held != null) {
      if (held.matches(fingerprint)) {
        // The same operator action, arriving again. One press of a jog button
        // is one movement of the machine, so the recorded outcome is replayed
        // and nothing crosses the pipe.
        return Future<relay.WriteResult>.value(held.result);
      }
      return Future<relay.WriteResult>.value(relay.WriteRejected(
        id,
        const relay.WriteReason('duplicate_cmd',
            message: 'this id has already been answered for a different '
                'write; one id covering two actuations would leave a single '
                'writeStatus answer for both, so nothing was sent'),
        at: _now(),
      ));
    }

    if (expect != null) {
      final current = _values.read(key);
      if (!relay.jsonEquals(current?.value, fingerprint.expect)) {
        // Compare-and-set exists so a concurrent change is NOT overwritten, so
        // the comparison happens BEFORE anything crosses the pipe. A write that
        // is sent and then judged has already overwritten it.
        final refusal = relay.WriteRejected(
          id,
          relay.WriteReason('compare_failed',
              message: 'the write was guarded on ${fingerprint.expect} and '
                  '"$key" holds ${current?.value}; nothing was sent'),
          at: _now(),
        );
        _log.record(id, refusal, fingerprint);
        return Future<relay.WriteResult>.value(refusal);
      }
    }

    // Recorded before the send, so a writeStatus arriving while this is in
    // flight answers unknown rather than "never received" about a command on
    // its way to a machine.
    _log.record(
      id,
      relay.WriteUnknown(
          id,
          const relay.WriteReason('in_flight',
              message: 'this command is upstream and has not been answered '
                  'yet; read the value back before acting')),
      fingerprint,
    );

    _attempts[id] = (_attempts[id] ?? 0) + 1;
    // The badge is a property of the value the widget is already watching, so
    // there is no second object for a call site to keep in sync.
    _values.markPending(key);

    final Future<relay.WriteResult> upstream;
    try {
      upstream = _pipe.write(
          key, relay.DynamicValue(value: sanitized.value));
    } catch (error, stack) {
      // The pipe promises not to throw here. If it ever does, the operator
      // still gets an outcome rather than an exception: the request may have
      // been built and sent before whatever failed.
      _logger.e('backend writes: the pipe threw on the way out for "$key"',
          error: error, stackTrace: stack);
      _values.clearPending(key);
      final lost = relay.WriteUnknown(
          id,
          const relay.WriteReason('write_path_failed',
              message: 'the write path failed on the way out; whether the '
                  'command reached the plant is not established'));
      _log.record(id, lost, fingerprint);
      return Future<relay.WriteResult>.value(lost);
    }

    return _settle(id, key, sanitized.hadNonFinite, fingerprint, upstream);
  }

  /// Waits for the pipe's answer and applies it to the store.
  Future<relay.WriteResult> _settle(
    String cmd,
    String key,
    bool poisoned,
    BackendWriteFingerprint fingerprint,
    Future<relay.WriteResult> upstream,
  ) async {
    var badgeHandled = false;
    try {
      final result = _restamp(cmd, await upstream);
      _applyOutcome(key, result, poisoned);
      badgeHandled = true;
      _log.record(cmd, result, fingerprint);
      return result;
    } catch (error, stack) {
      _logger.e('backend writes: settling the write to "$key" failed',
          error: error, stackTrace: stack);
      final lost = relay.WriteUnknown(
          cmd,
          const relay.WriteReason('write_path_failed',
              message: 'the outcome could not be settled on this side; '
                  'whether the plant applied the command is not established'));
      _log.record(cmd, lost, fingerprint);
      return lost;
    } finally {
      // T-13-08-e. Whatever happened above, the badge does not outlive this
      // call: a value stuck pending is a permanent amber box the operator
      // learns to ignore, on the one key they most need to trust.
      if (!badgeHandled) _values.clearPending(key);
    }
  }

  /// Puts the operator's id back on an answer that lost it at the transport
  /// boundary. See the library doc — this is not a mint.
  relay.WriteResult _restamp(String cmd, relay.WriteResult raw) =>
      switch (raw) {
        relay.WriteApplied(readback: final readback, at: final at) =>
          relay.WriteApplied(cmd,
              readback: relay.sanitize(readback).value,
              at: at > 0 ? at : _now()),
        relay.WriteRejected(reason: final reason, at: final at) =>
          relay.WriteRejected(cmd, reason, at: at ?? _now()),
        relay.WriteUnknown(reason: final reason) =>
          relay.WriteUnknown(cmd, reason),
        // The pipe never mints this one, and a lower layer claiming it would be
        // claiming the single verdict that licenses a second actuation. Unknown
        // is the conservative default and stays the conservative default.
        relay.WriteNotReceived() => relay.WriteUnknown(
            cmd,
            const relay.WriteReason('unrecognized_outcome',
                message: 'the write path answered with a verdict this side '
                    'cannot vouch for; read the value back before acting')),
      };

  /// What the store is told, given an outcome.
  void _applyOutcome(String key, relay.WriteResult result, bool poisoned) {
    switch (result) {
      case relay.WriteApplied(readback: final readback):
        if (poisoned) {
          // A non-finite value went in and a null came back. The operator must
          // see a fault, not a blank box that looks like an unbound tag.
          _values.applyReadback(
              key,
              relay.DynamicValue(
                  value: null, quality: relay.Quality.badNonFinite));
          return;
        }
        if (readback == null) {
          // Applied, and nobody said what the device now holds. The OPC UA
          // write service answers `Good` with no value, so this is the ordinary
          // shape upstream. Readback is the only confirmation there is, so what
          // stays on the screen is the last reading anybody measured — badged
          // uncertain, until the subscription carries the new one.
          _values.clearPending(key);
          return;
        }
        // Deliberately no sourceTime: an identical readback must stay equal to
        // the cached reading, or the unchanged-value guard the whole k-of-n
        // rebuild property rests on stops working (`harness.dart:50-58`).
        _values.applyReadback(
            key,
            relay.DynamicValue(
                value: readback, quality: relay.Quality.good));
      case relay.WriteRejected():
      case relay.WriteUnknown():
      case relay.WriteNotReceived():
        _values.clearPending(key);
    }
  }

  String _mint() {
    final id = relay.newUlid();
    _mintedCmds.add(id);
    return id;
  }

  // ----------------------------------------------------------- the re-query

  /// Re-asks what became of [cmds], **positionally aligned** with the argument.
  ///
  /// Built by walking the input in order rather than by keying a map, because
  /// the alignment IS the protocol: a short or reordered list shifts every
  /// later verdict onto the wrong command, and one of those verdicts could be
  /// the `not_received` that invites a second actuation.
  @override
  Future<List<relay.WriteResult>> writeStatus(List<String> cmds) async {
    _log.prune();
    return <relay.WriteResult>[for (final cmd in cmds) _statusOf(cmd)];
  }

  /// The answer for one cmd, after the log has been pruned.
  ///
  /// Four pieces of positive evidence stand between a missing entry and
  /// [relay.WriteNotReceived], and each one that fails answers
  /// [relay.WriteUnknown] instead:
  ///
  ///  1. the id is datable at all — 26 Crockford characters this side could
  ///     have issued an outcome for;
  ///  2. it was minted after this source started recording;
  ///  3. it is not in the future, which is a panel whose clock runs ahead and
  ///     which would otherwise buy itself a window of `ttl + skew`; and
  ///  4. it is still inside the TTL.
  relay.WriteResult _statusOf(String cmd) {
    final held = _log.entryFor(cmd);
    if (held != null) return held.result;

    final mintedAt = _mintedAtOf(cmd);
    if (mintedAt == null) {
      return relay.WriteUnknown(
          cmd,
          const relay.WriteReason('unrecognized_cmd',
              message: 'this is not an id this source could have issued an '
                  'outcome for, so nothing about it can be ruled out'));
    }
    if (!_log.witnessed(mintedAt)) {
      return relay.WriteUnknown(
          cmd,
          const relay.WriteReason('outcome_unwitnessed',
              message: 'this command was minted outside the window this '
                  'source can vouch for with its own clock — before it '
                  'started recording, or ahead of it. Nothing about it can be '
                  'ruled out; read the value back before acting'));
    }
    if (_log.insideWindow(mintedAt)) {
      // Inside the window, dated by a clock this side trusts, and nothing was
      // recorded: the command genuinely never arrived. The only re-send-safe
      // answer, and it is only safe because of the three checks above.
      return relay.WriteNotReceived(cmd);
    }
    return relay.WriteUnknown(
        cmd,
        relay.WriteReason('outcome_expired',
            message: 'this command is older than this source\'s '
                '${_log.ttl.inSeconds} s memory. Forgetting is not evidence '
                'that it never happened — read the value back before acting'));
  }

  /// The millisecond a ULID was minted at, or null if it is not one.
  ///
  /// Arithmetic rather than shifts, exactly as `ulid.dart` argues: JavaScript's
  /// bitwise operators coerce to signed 32 bits, so `<<` here would silently
  /// discard the top of the timestamp under `dart2js` and date every id wrong
  /// by up to 49.7 days — which on this path is the difference between
  /// `not_received` and `unknown`.
  static int? _mintedAtOf(String cmd) {
    if (cmd.length != 26) return null;
    var ms = 0;
    for (var i = 0; i < 10; i++) {
      final digit = _crockford.indexOf(cmd[i]);
      if (digit < 0) return null;
      ms = ms * 32 + digit;
    }
    return ms;
  }

  // ------------------------------------------------------------------- holds

  /// Engages the hold-to-run deadman on [key].
  ///
  /// The engage is a real write on this same path — same three states, same
  /// no-repeat rule, same outcome log — because 13-CONTEXT says in as many
  /// words that `holdToRun` is write-shaped and must not be silently
  /// unsupported. See `backend_hold.dart`.
  @override
  Future<relay.HoldHandle> holdToRun(String key) => _holds.engage(key);

  /// The registry, so an arm can engage a hold at a chosen counter.
  @visibleForTesting
  BackendHoldRegistry get holds => _holds;

  /// The one write a deadman counter travels on.
  ///
  /// A plain [write] with no `cmd` and no guard: every engage, tick and release
  /// is its own action with its own id, so the outcome log can be asked about
  /// the engage and the release independently. A guard would be wrong here for
  /// a reason worth stating — a compare-and-set on a counter the caller is
  /// itself advancing would refuse the tick after any dropped one, which is a
  /// deadman that stops feeding the moment the link hiccups.
  Future<relay.WriteResult> _feedDeadman(String key, int counter) =>
      write(key, counter);

  // ---------------------------------------------------------------- teardown

  /// Releases every live hold and stops taking commands.
  ///
  /// The release writes are **not** awaited: the machine stops when the counter
  /// stops, which happens synchronously inside `HoldHandle.release`, and a
  /// teardown that waited for a release to be confirmed would hang on exactly
  /// the dead link that caused it.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    // Before the flag, because a release IS a write and a disposed router
    // refuses those.
    _holds.releaseAll();
    _disposed = true;
  }
}
