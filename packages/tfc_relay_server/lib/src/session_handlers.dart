/// The bodies of `subscribe` and `unsubscribe`.
///
/// Split out of `relay_session.dart` so that file stays about *wiring* — the
/// peer, the gate, the error armor, the teardown — exactly as
/// `served_state_man.dart` splits its handler bodies away from its plumbing.
/// The split is also what keeps the gate honest: nothing in here registers
/// anything. Handlers are handed to `RelaySession._on`, which is the one seam
/// where a method enters the table and therefore the one place gating and error
/// armor have to be applied. A handler that registered itself would be a
/// handler that arrived ungated, and the method that serves plant data to a
/// client which never said hello is not the one anybody wants to find that way.
/// `grep -c registerMethod` over this file is meant to return zero.
///
/// ## What one subscribe owes the client
///
/// Handles, metadata and a snapshot, **in the same response**. Every protocol
/// surveyed in 03-RESEARCH ended up needing an explicit "initial state
/// complete" moment, and the cheapest one is a subscribe that already carries
/// it. The alternative — handles now, values when they next change — leaves a
/// panel showing blank boxes for every tag that happens to be steady, which on
/// a plant is most of them, and the operator cannot tell a steady tag from a
/// broken binding.
///
/// A handle therefore never appears without a snapshot entry, including the
/// "no value yet" case: a *missing* map entry is indistinguishable from a key
/// the server dropped, so an unknown value is sent as a `WireValue` carrying
/// [Quality.uncertainNotYetKnown]. Uncertain, not error — nothing is
/// misconfigured; the value has simply not arrived.
///
/// ## Why a bad key is a rejection and not a failure
///
/// A page config carries up to ~1500 keys and is edited by hand. One typo among
/// them must cost that one tag. Failing the whole call turns a typo into a
/// blank control-room screen, which is why `SubscribeResult.rejected` exists at
/// all and why the per-key path here is the load-bearing one:
/// `KeyReject(kind, message)` — the kind for the client to branch on, the
/// message for whoever reads the log at three in the morning.
///
/// The call-level refusals are the denial-of-service ceilings (T-03-13,
/// T-03-14) and the shape errors: an empty `sub` name, an empty key list, a
/// non-positive `maxRateHz`. An empty subscription is a name the client waits
/// on forever.
///
/// A *duplicate* name is not among them, and used to be. Two subscriptions
/// behind one `seq` would indeed read to the client as a permanent gap — so
/// this handler keeps exactly one, by re-establishing the name rather than by
/// refusing it (04-REVIEW CR-03; the argument is at the call site). The
/// refusal's cost was that a client whose only recovery move is "ask for the
/// page again" could never complete one.
///
/// ## Per-key authorization is not here
///
/// Deciding *which* keys a client may read is Phase 6 (SEC-03, threat T-03-15).
/// It attaches at [_classify], and because the rejection path already exists
/// the later change is a policy edit rather than a change of shape.
library;

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'error_codes.dart';
import 'handle_table.dart';
import 'server_config.dart';
import 'subscription_registry.dart';

/// Why a single key could not be subscribed. The client branches on these, so
/// they are wire values with the stability that implies.
abstract final class KeyRejectKinds {
  /// The source does not serve this key. Almost always a typo in a page
  /// config; occasionally a tag that was renamed upstream.
  static const unknownKey = 'unknownKey';

  /// Empty, blank, or otherwise not a key at all. Distinct from
  /// [unknownKey] because it means the *client* built the list wrong rather
  /// than the plant having changed.
  static const invalidKey = 'invalidKey';

  /// The value could not be turned into something the wire can carry. Per key
  /// (STATE.md: gateway ingest must fail one tag, not one call).
  static const unencodable = 'unencodable';
}

/// The handler bodies for one session's subscription methods.
///
/// Holds no state of its own: everything it touches belongs to the session or
/// to the server. That is what lets it be constructed inside `_start` without
/// creating a second place where subscription state can live.
final class SessionHandlers {
  SessionHandlers({
    required this.api,
    required this.config,
    required this.handles,
    required this.buffer,
    required this.subscriptions,
    required this.epochOf,
  });

  final StateManApi api;
  final ServerConfig config;

  /// The **server-global** table. Two sessions asking for one key get one
  /// integer — Finding 3's property, and the reason the encode-once body is
  /// byte-identical across clients.
  final HandleTable handles;

  final ConflatingSendBuffer buffer;
  final SubscriptionRegistry subscriptions;

  /// The session's epoch, which only exists after a hello. Read lazily through
  /// a callback rather than captured, because these handlers are built during
  /// `_start` and the epoch is minted later.
  final String Function() epochOf;

  /// `subscribe`: one call, one answer, everything in it.
  Future<Object?> subscribe(rpc.Parameters params) async {
    // Sanitize before decode, every time, on every ingress path:
    // `jsonDecode('1e999')` yields Infinity in silence, and an Infinity that
    // reaches an error response makes the *error* unencodable — the 02-05 hang.
    final decoded = sanitize(params.asMap).value as Map;
    final request =
        SubscribeParams.fromJson(decoded.cast<String, Object?>());

    if (request.sub.trim().isEmpty) {
      throw rpc.RpcException.invalidParams(
          'subscribe needs a non-empty "sub" name: it is what every '
          'subsequent push and every unsubscribe is addressed by');
    }
    if (request.keys.isEmpty) {
      throw rpc.RpcException.invalidParams(
          'subscribe needs at least one entry in "keys": an empty '
          'subscription is a name the client waits on forever');
    }
    if (request.keys.length > config.maxKeysPerSubscribe) {
      throw rpc.RpcException.invalidParams(
          'subscribe carried ${request.keys.length} keys, over this server\'s '
          'limit of ${config.maxKeysPerSubscribe}; split the page or raise '
          'maxKeysPerSubscribe');
    }
    final rate = request.maxRateHz;
    if (rate != null && !(rate > 0)) {
      throw rpc.RpcException.invalidParams(
          'maxRateHz must be a positive number of pushes per second; '
          '"$rate" would ask the gateway either for everything at once or '
          'for nothing ever, and the client could not tell which it got');
    }

    // **A subscribe naming a live subscription re-establishes it** (04-REVIEW
    // CR-03): one entry, one seq, a fresh snapshot, a new generation.
    //
    // This used to be a refusal, on the grounds that two subscriptions under
    // one name would share a `seq`. Re-establishing keeps exactly one, so that
    // reason is satisfied rather than overridden — and the refusal wedged the
    // client's own gap recovery permanently. A client whose sequence gapped
    // asks for the page again; the refusal threw before its `store.clear()`
    // could rebase `lastSeq`, so the next frame was another gap, which
    // triggered another refused resubscribe, for as long as the socket lived.
    // The page held pre-gap values under good quality with the link indicator
    // reading ready.
    //
    // The alternative — client `unsubscribe` then `subscribe` — is worse on the
    // axis this project optimises: two round trips on the recovery path, and a
    // failure between them leaves the page silently unsubscribed with its cache
    // intact, which renders as a healthy screen receiving nothing.
    //
    // After every validation that can refuse, so a refused re-establish never
    // destroys a subscription that was working; and before the capacity check,
    // so re-establishing at the ceiling cannot trip it.
    if (subscriptions.contains(request.sub)) {
      // Detaches its listeners, exactly as `unsubscribe` does.
      subscriptions.remove(request.sub);
      // And drops what the old establishment had queued. The snapshot below is
      // read from the source now; a pending change from before it is older
      // than the snapshot and would walk the mimic backwards on the next tick.
      buffer.dropSub(request.sub);
    }

    if (subscriptions.atCapacity) {
      throw rpc.RpcException.invalidParams(
          'this session already holds ${subscriptions.count} subscriptions, '
          'the limit of ${config.maxSubscriptionsPerSession}; unsubscribe '
          'before subscribing again');
    }

    final servable = api.keys.toSet();
    final accepted = <String>[];
    final rejected = <String, KeyReject>{};
    for (final key in request.keys) {
      final verdict = _classify(key, servable);
      if (verdict == null) {
        accepted.add(key);
      } else {
        rejected[key] = verdict;
      }
    }

    final state = SubscriptionState(
      sub: request.sub,
      epoch: epochOf(),
      maxRateHz: request.maxRateHz,
      // Minted here and nowhere else, from a counter that spans the whole
      // gateway — so a frame from the establishment just torn down can never
      // match the one that replaced it, whether the two share a socket or a
      // reconnect separates them.
      generation: subscriptions.nextGeneration(),
    );
    final minted = handles.handlesFor(accepted);
    final meta = <int, Object?>{};
    final snapshot = <int, WireValue>{};

    // **Everything from here to `put` rolls back as one** (03-REVIEW WR-08).
    // The per-key `try` below is the deliberate degradation — one typo costs
    // one tag — but `state.watch` and `api.listen` are outside it, and the
    // subscription does not enter the registry until the last line. So a
    // throw on the tenth of fifty keys left nine listeners attached to the
    // backing source with nothing able to reach them: `state` never entered
    // the registry, so `subscriptions.clear()` at teardown could not find it,
    // and the only other reference was the stack frame that was unwinding.
    // A permanent leak per failure, once per failure, forever.
    //
    // `FakeStateMan` never throws from `listen`, which is why the suite was
    // quiet about it; `LocalStateMan` over real DeviceClients (Phase 8) is a
    // different proposition.
    try {
      for (final entry in minted.entries) {
        final key = entry.key;
        final handle = entry.value;
        try {
          final current = api.read(key);
          meta[handle] = _meta(key, current);
          snapshot[handle] = _wire(current);
        } catch (error) {
          // One tag, not one call (STATE.md). A value the gateway cannot
          // render is a per-key problem even when it is the gateway's own
          // problem.
          rejected[key] = KeyReject(KeyRejectKinds.unencodable,
              message: 'the current value of "$key" could not be encoded: '
                  '$error');
          continue;
        }
        state.watch(key, handle, api.listen(key), (value) {
          buffer.putValue(request.sub, handle, _wire(value));
        });
      }

      // Anything that fell out during encode never got a listener, so it must
      // not appear in the answer as if it had.
      for (final key in rejected.keys) {
        final handle = minted.remove(key);
        if (handle == null) continue;
        meta.remove(handle);
        snapshot.remove(handle);
      }

      subscriptions.put(state);
    } on SubscriptionLimitExceeded catch (error) {
      // Unreachable today — there is no `await` between the `atCapacity`
      // check above and this `put`, so nothing can interleave. It is caught
      // anyway because the class's own doc promises "the handler turns it into
      // a JSON-RPC refusal that names the limit" and no handler did: the throw
      // would have surfaced through `_answer` as handlerFailed (-32011), whose
      // documented meaning is "possibly transient: retrying is legitimate,
      // with backoff". A client would retry a ceiling it can never get under.
      // Phase 6's per-key authorization is the obvious thing to introduce the
      // await that opens the race, and the code path should exist before then.
      state.detach();
      throw rpc.RpcException.invalidParams('$error');
    } catch (_) {
      state.detach();
      rethrow;
    }

    return SubscribeResult(
      sub: state.sub,
      epoch: state.epoch,
      seq: state.seq,
      generation: state.generation,
      handles: minted,
      meta: meta,
      snapshot: snapshot,
      rejected: rejected,
    ).toJson();
  }

  /// `unsubscribe`: release the state, and say so if there was none.
  Future<Object?> unsubscribe(rpc.Parameters params) async {
    final decoded = sanitize(params.asMap).value as Map;
    final sub = decoded['sub'];
    if (sub is! String || sub.isEmpty) {
      throw rpc.RpcException.invalidParams(
          'unsubscribe needs the "sub" name it is releasing');
    }
    if (!subscriptions.remove(sub)) {
      throw rpc.RpcException(ServerErrorCodes.unknownSubscription,
          'no subscription named "$sub" on this session');
    }
    return {'sub': sub, 'released': true};
  }

  /// Null when [key] is subscribable, a [KeyReject] when it is not.
  ///
  /// Phase 6's per-key authorization attaches here (T-03-15): one more arm,
  /// no change of shape.
  KeyReject? _classify(String key, Set<String> servable) {
    if (key.trim().isEmpty) {
      return const KeyReject(KeyRejectKinds.invalidKey,
          message: 'an empty key is not a tag; something built this list from '
              'a blank field');
    }
    if (!servable.contains(key)) {
      return KeyReject(KeyRejectKinds.unknownKey,
          message: 'this source does not serve "$key" — usually a typo in a '
              'page config, occasionally a tag renamed upstream');
    }
    return null;
  }

  /// The once-per-subscription metadata for [key]: everything the value's own
  /// encoding carries *except* the value and its current state, which ride in
  /// the snapshot and in every push after it.
  static Map<String, Object?> _meta(String key, DynamicValue? current) {
    final full = current?.toJson();
    return {
      'key': key,
      if (full is Map<String, Object?>)
        for (final entry in full.entries)
          if (entry.key != 'value' && entry.key != 'q' && entry.key != 't')
            entry.key: entry.value,
    };
  }

  /// A value on the wire. Null means "not known yet" — a distinct thing from a
  /// known-bad value, and it must still occupy its slot in the snapshot.
  static WireValue _wire(DynamicValue? value) {
    if (value == null) {
      return WireValue.of(null, quality: Quality.uncertainNotYetKnown);
    }
    return WireValue.of(
      value.toJson(slim: true),
      quality: value.quality,
      t: value.sourceTime?.millisecondsSinceEpoch,
    );
  }
}
