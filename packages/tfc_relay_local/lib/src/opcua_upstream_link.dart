/// The OPC UA [UpstreamLink]: real quality, real source time, one supervised
/// iterate loop.
///
/// **Wrap, do not rebuild.** This class owns a `ClientWrapper`
/// (`packages/tfc_dart/lib/core/state_man.dart:834`) and not a session manager
/// of its own, because that class encodes three dated, measured things:
///
///  * the **two-phase resubscribe** that fixed a monitored-item storm
///    (`:1458-1510`, and the ordering at `:1480-1501`),
///  * a **heartbeat-derived effective status** with a 15 s stale / 30 s grace
///    window (`:958-964`) — the only thing that catches the frozen-session
///    failure, where TCP is Established, the channel is formally open, and no
///    state event is ever emitted again,
///  * `isSubscriptionDead` (`:872`), which tells a transient `Inactivity` from
///    a fatal `SubscriptionDeleted` / `SecureChannelClosed`.
///
/// Rebuilding those to the same fidelity is not a phase, and the failure mode
/// is silent. What is *not* inherited is the composer above them: `StateMan`'s
/// throwing `read`/`write` (`:1876-1878`, `:2042-2044`), its
/// `Future<Stream<…>>` subscribe (`:2054`), its quality-less values, and its
/// two unawaited `() async {…}()` loops driving `runIterate` with a bare
/// `Logger()` and no error seam (`:1364`, `:1398`). Those are the four gaps
/// this adapter exists to close.
///
/// **Two classes are called `DynamicValue` in this solve.** The binding's is
/// imported as `ua.` throughout; the relay's — the one with
/// [DynamicValue.quality] and [DynamicValue.sourceTime] as first-class fields —
/// is the unprefixed one. Every value crossing this seam goes through
/// [translateOpcUaSample], which is the adapter's entire reason for existing
/// and therefore gets its own function, its own tests and its own doc.
/// `M2400DeviceClientAdapter._mapStatus` (`state_man.dart:1277-1286`) is the
/// idiom being copied.
///
/// ## Assumption A5, recorded rather than decided
///
/// `OpcUaStateMan.create(useIsolate: true)` is the app's default and keeps the
/// blocking FFI off the event loop the `LagMonitor` measures. The gateway's hot
/// path, though, is one isolate encoding once and fanning out (design §5), so
/// every isolate boundary is a copy. [useIsolate] is therefore a constructor
/// flag, defaulting to **true** — the safe half — and set false by the test
/// fixture so a leg can reach into the client. **Nothing in this phase measures
/// which is right.** That is A5, and it stays an assumption until somebody puts
/// a number on it.
library;

import 'dart:async';

import 'package:open62541/open62541.dart' as ua;
import 'package:tfc_dart/core/opcua_value_translation.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'epoch.dart';
import 'upstream_link.dart';
import 'write_translation.dart';

// The OPC-UA → relay-protocol value converter — the status-code constants,
// `qualityForOpcUaStatus`, `qualityForOpcUaErrorText` and `translateOpcUaSample`
// — moved DOWN into tfc_dart in Phase 12 so tfc_dart (which cannot depend on
// tfc_relay_local) holds the single source of truth. Re-exported here so this
// package's own call sites and its barrel keep naming them unchanged. This is a
// legal DOWNward import: tfc_relay_local depends on tfc_dart, never the reverse.
export 'package:tfc_dart/core/opcua_value_translation.dart';

/// `EffectiveDeviceStatus` → the five wire states.
///
/// The one distinction worth keeping, and the reason this is a named function
/// with its own test: **connected-but-the-subscription-is-dead is
/// [UpstreamLinkState.unhealthy], not [UpstreamLinkState.connected]**. That is
/// the frozen-session shape (`state_man.dart:820-825`), it is F27's shape, and
/// Phase 9 will want it. Collapsing it into `connected` puts a green badge on
/// a screen full of values nobody has measured for fifteen seconds.
///
/// [UpstreamLinkState.reprogrammed] is not produced here: it is an epoch fact,
/// not a session fact, and 08-08 owns it.
UpstreamLinkState mapEffectiveStatus(EffectiveDeviceStatus status) {
  switch (status) {
    case EffectiveDeviceStatus.disconnected:
      return UpstreamLinkState.disconnected;
    case EffectiveDeviceStatus.connecting:
      return UpstreamLinkState.connecting;
    case EffectiveDeviceStatus.connected:
      return UpstreamLinkState.connected;
    case EffectiveDeviceStatus.opcuaUnhealthy:
    case EffectiveDeviceStatus.umasUnhealthy:
      return UpstreamLinkState.unhealthy;
  }
}

/// One configured OPC UA server, behind the gateway's uniform surface.
final class OpcUaUpstreamLink implements UpstreamLink {
  OpcUaUpstreamLink({
    required this.alias,
    required String endpoint,
    String? answersTo,
    this.useIsolate = true,
    this.supportsWrites = true,
    this.supportsBrowse = true,
    this.staleAfter = const Duration(seconds: 10),
    Duration publishingInterval = const Duration(milliseconds: 100),
    Duration iteratePeriod = const Duration(milliseconds: 10),
    this.epochDeadline = const Duration(seconds: 5),
    EpochInputsReader epochReader = readEpochInputs,
    ua.NodeId? buildStampNode,
    ua.ClientApi? client,
    void Function(Object error, StackTrace stack)? onIterateError,
  })  : answersTo = answersTo ?? alias,
        _endpoint = endpoint,
        _iteratePeriod = iteratePeriod,
        _epochReader = epochReader,
        _buildStampNode = buildStampNode,
        _injectedClient = client,
        _onIterateError = onIterateError {
    _config = OpcUAConfig()
      ..endpoint = endpoint
      ..serverAlias = alias
      ..publishingIntervalMs = publishingInterval.inMilliseconds;
  }

  @override
  final String alias;

  /// The keymapping `server_alias` this link serves; [alias] when omitted.
  ///
  /// `''` is the unnamed server — the live plant file's spelling — and
  /// [resolve] compares through `StateManConfig.normalizeAlias`, which
  /// buckets it with null. See `UpstreamLinkConfig.answersTo` for why the
  /// name and the answers-to cannot be one field (RIG-TEST-FINDINGS.md F1).
  final String answersTo;

  @override
  final bool supportsWrites;

  @override
  final bool supportsBrowse;

  /// The freshness deadline this link declares, for 08-05's sweep.
  final Duration staleAfter;

  /// See the library doc: assumption A5, recorded and not decided.
  final bool useIsolate;

  /// The bound on one epoch reading.
  ///
  /// Separate from `connect`'s deadline because it bounds a different thing:
  /// `connect` waits for a session, this waits for three small reads on a
  /// session that is already up. It is short on purpose — a server that will
  /// not answer `ns=0;i=2257` in five seconds has told us what we needed to
  /// know, and the reading is [EpochInputs.unreadable], which the link
  /// deliberately does **not** adopt.
  final Duration epochDeadline;

  final String _endpoint;
  final Duration _iteratePeriod;
  final EpochInputsReader _epochReader;
  final ua.NodeId? _buildStampNode;
  final ua.ClientApi? _injectedClient;
  final void Function(Object error, StackTrace stack)? _onIterateError;

  late final OpcUAConfig _config;

  ua.ClientApi? _client;
  ClientWrapper? _wrapper;
  int? _subscriptionId;

  /// The iterate driver. **One periodic timer, owned by this class**, started
  /// on connect and cancelled on dispose — allow-listed in `freeze_test.dart`
  /// by name in the commit that created it.
  Timer? _iterateTimer;

  /// Re-entrancy guard for the driver.
  ///
  /// `Client.runIterate` is a blocking FFI call and `ClientIsolate.runIterate`
  /// is a long-lived await; either way a second tick arriving while the first
  /// has not returned must not start a second loop.
  bool _iterating = false;

  /// How many times the driver has turned the crank. Diagnostics, and the
  /// thing a test reads to know the loop is running at all.
  int _iterateTicks = 0;

  /// Errors the driver saw, in order. **The seam that replaces the bare
  /// `Logger()`** at `state_man.dart:1364`/`:1398`: a supervised loop whose
  /// errors go nowhere a test can read is a loop that swallows the failure it
  /// was added to surface (threat T-08-27).
  final List<Object> _iterateErrors = <Object>[];

  final StreamController<UpstreamLinkState> _states =
      StreamController<UpstreamLinkState>.broadcast();
  final StreamController<String> _epochs = StreamController<String>.broadcast();
  StreamSubscription<EffectiveDeviceStatus>? _statusSub;

  UpstreamLinkState _state = UpstreamLinkState.disconnected;
  String _epoch = unconnectedEpoch;

  /// Latched between an epoch bump and the end of its re-browse.
  ///
  /// The announced state is [UpstreamLinkState.reprogrammed] for exactly that
  /// window, and it is a latch rather than a value of [_state] because
  /// `effectiveStatus` keeps reporting the *session*, which is fine — the
  /// session really is up. What is not fine is a green badge on a link whose
  /// every handle is stale, so this wins over the session while it is set.
  bool _reprogrammed = false;

  /// How many re-browses this link has run. **One per bump, never per key.**
  int _reBrowses = 0;
  int _birthCount = 0;
  DateTime? _lastDeathAt;
  String? _lastError;
  int _subscriptionsCreated = 0;
  int _sourceTimeFallbacks = 0;
  bool _disposed = false;

  /// Node ids by key, learned from the mapping entries `resolve` was handed.
  final Map<String, ua.NodeId> _nodes = <String, ua.NodeId>{};

  /// Array-element keys, and which element. 08-06's handoff: the guard belongs
  /// here, because this is the only layer that can see the `array_index`.
  final Map<String, int> _arrayIndices = <String, int>{};

  /// The last value each key delivered, for [peek].
  final Map<String, DynamicValue> _cache = <String, DynamicValue>{};

  final Map<String, _MonitoredKey> _monitors = <String, _MonitoredKey>{};

  /// Streams handed to subscribes taken out against a superseded epoch.
  ///
  /// Held so [dispose] can close them and never fed a value again — the
  /// Modbus base's `_staleFeeds`, which this adapter was missing (WR-09).
  final List<StreamController<DynamicValue>> _staleFeeds =
      <StreamController<DynamicValue>>[];

  // ------------------------------------------------------------ diagnostics

  /// Driver ticks so far.
  int get iterateTicks => _iterateTicks;

  /// Everything the driver's supervisor caught.
  List<Object> get iterateErrors => List<Object>.unmodifiable(_iterateErrors);

  /// How many **subscription** samples arrived with no source timestamp of
  /// their own.
  ///
  /// The recorded fact behind [translateOpcUaSample]'s fallback: a gateway
  /// silently substituting arrival time for source time is exactly threat
  /// T-08-25, and the difference between a mitigation and a hope is that this
  /// number exists.
  ///
  /// **Monitored items only, since 08-REVIEW IN-04.** `sourceTimestamp` is
  /// populated by the binding's monitor callback and by nothing else —
  /// `client.read` does not set it — so counting the read path here meant one
  /// tick per `readFresh`/`readMany` key regardless of what the server did.
  /// A counter that increments on every ordinary read is not measuring an
  /// anomaly, it is measuring traffic, and the number T-08-25 wants is one
  /// that stays at zero on a healthy plant. Reads have their own counter
  /// below, so the fact is still observable and simply is not conflated.
  int get sourceTimeFallbacks => _sourceTimeFallbacks;

  /// How many **read-path** answers were stamped with arrival time.
  ///
  /// Expected to equal the number of reads: the binding does not put a source
  /// timestamp on a `read` at all. It is here so the substitution is recorded
  /// rather than silent — which is the whole of T-08-25 — without drowning
  /// [sourceTimeFallbacks], whose value is that it stays at zero.
  int get readSourceTimeFallbacks => _readSourceTimeFallbacks;
  int _readSourceTimeFallbacks = 0;

  /// How many times this link has re-resolved its keys against a new address
  /// space.
  ///
  /// The number a test reads to prove T-08-31: **one per bump**, no matter how
  /// many keys the bump affected.
  int get reBrowses => _reBrowses;

  // ------------------------------------------------------------- the surface

  @override
  UpstreamLinkState get state {
    // The latch wins over the session, and only for the window between the
    // bump and the end of its re-browse. See [_reprogrammed].
    if (_reprogrammed) return UpstreamLinkState.reprogrammed;
    final wrapper = _wrapper;
    if (wrapper == null) return _state;
    return mapEffectiveStatus(wrapper.effectiveStatus);
  }

  @override
  Stream<UpstreamLinkState> get stateStream => _states.stream;

  @override
  String? get lastError => redactUpstreamError(_lastError);

  @override
  String get epoch => _epoch;

  @override
  Stream<String> get epochStream => _epochs.stream;

  @override
  int get birthCount => _birthCount;

  @override
  DateTime? get lastDeathAt => _lastDeathAt;

  @override
  int get upstreamSubscriptionsCreated => _subscriptionsCreated;

  @override
  UpstreamRef? resolve(String key, Object mappingEntry) {
    if (mappingEntry is! KeyMappingEntry) return null;
    final node = mappingEntry.opcuaNode;
    if (node == null) return null;
    // **The adapter checks the alias it answers to.** 08-04's handoff, in one
    // line: the router does not filter candidates by `server_alias`, it offers
    // the key to every link in order and takes the first claim. A resolve that
    // claims anything OPC-UA-shaped takes ST201's key on a two-PLC plant, and
    // the router's ambiguity check does not catch it because the two links
    // have different aliases. `_resolveM2400Key` (`state_man.dart:1774-1783`)
    // and `_resolveModbusDeviceClient` (`:1787-1799`) both do this and this is
    // why. Compared against [answersTo] and never [alias]: the live plant
    // file's entries all carry `server_alias: null`, a value the *name* can
    // never legally take (RIG-TEST-FINDINGS.md F1).
    if (StateManConfig.normalizeAlias(node.serverAlias) !=
        StateManConfig.normalizeAlias(answersTo)) {
      return null;
    }
    final (nodeId, arrayIndex) = node.toNodeId();
    _nodes[key] = nodeId;
    if (arrayIndex != null) {
      _arrayIndices[key] = arrayIndex;
    } else {
      _arrayIndices.remove(key);
    }
    return UpstreamRef(
        alias: alias, epoch: _epoch, payload: nodeId, key: key);
  }

  /// Whether [ref] still addresses something this link vouches for.
  bool _isLive(UpstreamRef ref) =>
      ref.alias == alias && ref.epoch == _epoch && _nodes.containsKey(ref.key);

  @override
  DynamicValue? peek(UpstreamRef ref) => _isLive(ref) ? _cache[ref.key] : null;

  @override
  Stream<DynamicValue> subscribe(UpstreamRef ref) {
    if (!_isLive(ref)) {
      // A bad-quality value, and the stream stays OPEN. An ended stream is
      // indistinguishable to a widget from a key that stopped changing —
      // `AutoDisposingStream`'s close-on-source-end (`state_man.dart:2691`) is
      // on the do-not-inherit list.
      final controller = StreamController<DynamicValue>();
      controller.add(DynamicValue(
          value: null,
          quality: Quality.badCommFault,
          sourceTime: DateTime.now().toUtc()));
      // Tracked so [dispose] can close it. It is not in `_monitors` and
      // nothing else walks it, so without this line every stale-handle
      // subscribe leaked a controller (08-REVIEW WR-09) — on the path that
      // runs once per key after a PLC download.
      _staleFeeds.add(controller);
      return controller.stream;
    }
    final existing = _monitors[ref.key];
    if (existing != null) return existing.controller.stream;
    final monitored = _MonitoredKey(ref.key);
    _monitors[ref.key] = monitored;
    _subscriptionsCreated++;
    unawaited(_establish(monitored).then<void>((_) {}, onError: (Object e, StackTrace s) {
      // `state_man.dart:2369`'s discipline, not just its shape: a
      // fire-and-forget future that can error gets a handler, or the zone
      // does.
      _recordError(e);
      monitored.controller.add(DynamicValue(
          value: null,
          quality: qualityForOpcUaErrorText(e.toString()),
          sourceTime: DateTime.now().toUtc()));
    }));
    return monitored.controller.stream;
  }

  Future<void> _establish(_MonitoredKey monitored) async {
    final client = _client;
    final subscriptionId = _subscriptionId;
    if (client == null || subscriptionId == null) {
      throw StateError('$alias: subscribe before connect');
    }
    final nodeId = _nodes[monitored.key]!;
    // **The opt-in delivery flag, and the reason this adapter and not
    // ClientWrapper owns the monitor call.** At the binding's default a sample
    // the server marked Bad is DROPPED and its code survives only as English on
    // the error channel — which means a key whose PLC has gone unhappy simply
    // stops updating, and the panel holds the last plausible number. 08-01
    // added `deliverBadStatus` for exactly this, and `false` is what the app
    // wants while `true` is what a gateway minting qualities wants.
    monitored.subscription = client
        .monitor(nodeId, subscriptionId,
            samplingInterval: _config.publishingInterval,
            deliverBadStatus: true)
        .listen(
      (sample) {
        final translated = translateOpcUaSample(
          sample,
          arrivedAt: DateTime.now().toUtc(),
          onSourceTimeFallback: () => _sourceTimeFallbacks++,
        );
        final shaped = _sliceArrayElement(monitored.key, translated);
        _cache[monitored.key] = shaped;
        if (shaped.quality == Quality.good) {
          _lastGoodValues[monitored.key] = shaped.value;
        }
        if (!monitored.controller.isClosed) {
          monitored.controller.add(shaped);
        }
      },
      onError: (Object error) {
        _recordError(error);
        _publishDegraded(
            monitored.key, qualityForOpcUaErrorText(error.toString()));
      },
    );
    // **The decode probe — because the monitor path CANNOT say "undecodable".**
    // The binding's monitor callback wraps its whole decode in a catch whose
    // only act is a write to stderr (`client.dart`, `_safeErr("Error
    // converting data for: …")`): a Guid/ByteString/LocalizedText/Range tag
    // produces neither a sample nor an `onError`, ever, and the key sits at
    // `uncertainNotYetKnown` for the life of the process. The 200-server
    // bench measured exactly that, on 4 of 28 type-matrix keys per server.
    // The READ path does propagate the throw, so one bounded read per key per
    // epoch is how this link learns the fact the subscription never will.
    unawaited(_probeDecode(monitored.key));
  }

  /// Keys already decode-probed, by the epoch they were probed under.
  ///
  /// One probe per key **per epoch**, not per establish: a reconnect inside an
  /// epoch is the same address space by definition, and re-probing fifty keys
  /// on every flap is a read storm against a PLC at its slowest. A reprogram
  /// (epoch bump) is the one moment a tag's type can genuinely change, so a
  /// new epoch probes again. A TRANSIENT probe failure does not mark the key
  /// — the question was not answered, and the next establish may ask again.
  final Map<String, String> _decodeProbed = <String, String>{};

  /// One bounded read whose only job is to catch what the monitor swallows.
  ///
  /// Publishes **error-band verdicts and nothing else**:
  ///
  ///  * `errorTypeMismatch` — the binding threw its decode-failure sentence
  ///    ([qualityForOpcUaErrorText] knows it by name). Non-transient; the
  ///    subscription will never deliver, and 258 would be a standing lie.
  ///  * `errorConfig` — the probe met `BadNodeIdUnknown`; the same verdict the
  ///    monitor-create path would reach, published a beat earlier. Harmless
  ///    and consistent.
  ///  * anything transient — **nothing is published**. A slow PLC, a timeout,
  ///    a comm hiccup: those belong to the link machinery, and a probe that
  ///    painted every un-arrived key red at boot would replace a quiet lie
  ///    with a loud one. This is the polarity the tests pin from both sides.
  ///
  /// A successful probe also publishes nothing: the value it read is the
  /// monitor's to deliver, with the monitor's quality and source time.
  Future<void> _probeDecode(String key) async {
    if (_disposed) return;
    if (_decodeProbed[key] == _epoch) return;
    final client = _client;
    final node = _nodes[key];
    if (client == null || node == null) return;
    try {
      await client.read(node).timeout(_probeDeadline);
      _decodeProbed[key] = _epoch;
    } on TimeoutException {
      // Unanswered is not evidence; do not mark, so a later establish asks.
    } catch (error) {
      final quality = qualityForOpcUaErrorText(error.toString());
      if (!quality.isError) return;
      _decodeProbed[key] = _epoch;
      // Once per key per epoch by construction (the map above), and
      // `_publishDegraded` refuses the duplicate anyway — this is the
      // "once per key, never per sample" discipline; a hot-path repeat of
      // either the event or the record is its own denial of service.
      _recordError(error);
      _publishDegraded(key, quality);
    }
  }

  /// The bound on one decode probe. Generous on purpose: the probe rides the
  /// same session as fifty monitored-item creates on a PLC that may have just
  /// restarted, and a tight deadline here would misread slow as unanswered.
  static const Duration _probeDeadline = Duration(seconds: 10);

  @override
  Future<DynamicValue> read(UpstreamRef ref,
      {required Duration deadline}) async {
    if (!_isLive(ref)) {
      // SRV-07: no stale-handle read ever returns a value. The handle
      // addresses a node that may now mean a different tag, and answering from
      // it is not a stale read but a confidently wrong one.
      return DynamicValue(
          value: null,
          quality: Quality.badCommFault,
          sourceTime: DateTime.now().toUtc());
    }
    final client = _client;
    if (client == null) {
      return DynamicValue(
          value: null,
          quality: Quality.badCommFault,
          sourceTime: DateTime.now().toUtc());
    }
    try {
      // The deadline is the whole reason this is an adapter and not a direct
      // call: `state_man.dart:1868` awaits `client.awaitConnect()` inside its
      // read with no bound, and a disconnected PLC pends that caller forever
      // (T-08-10). `ClientWrapper` does not bound it either, so the bound is
      // applied here rather than by editing tfc_dart.
      final sample = await client.read(_nodes[ref.key]!).timeout(deadline);
      final translated = translateOpcUaSample(
        sample,
        arrivedAt: DateTime.now().toUtc(),
        // The READ counter, not the subscription one — see IN-04 on
        // [sourceTimeFallbacks]. Every read contributes here by construction.
        onSourceTimeFallback: () => _readSourceTimeFallbacks++,
      );
      final shaped = _sliceArrayElement(ref.key, translated);
      _cache[ref.key] = shaped;
      return shaped;
    } on TimeoutException {
      return DynamicValue(
          value: null,
          quality: Quality.badCommFault,
          sourceTime: DateTime.now().toUtc());
    } catch (error) {
      _recordError(error);
      return DynamicValue(
          value: null,
          quality: qualityForOpcUaErrorText(error.toString()),
          sourceTime: DateTime.now().toUtc());
    }
  }

  @override
  Future<WriteResult> write(
    UpstreamRef ref,
    DynamicValue value, {
    required String cmd,
    required Duration deadline,
    bool hasExpect = false,
  }) async {
    if (!supportsWrites) {
      return WriteRejected(cmd, notWritableReason,
          at: DateTime.now().millisecondsSinceEpoch);
    }
    if (!_isLive(ref)) {
      // A stale-handle write is REJECTED, not unknown: nothing was sent, so it
      // is definitively no effect (08-03's ruling, and what the fake does).
      return WriteRejected(
        cmd,
        WriteReason('stale_handle',
            // The stale epoch is NAMED, and the current one beside it. Neither
            // is parsed by anybody — they are two opaque tokens in a sentence
            // an engineer reads at three in the morning, and "these two
            // differ" is the whole diagnosis.
            message: 'this handle was resolved under epoch ${ref.epoch} and '
                'the link is now at $_epoch; nothing was sent — re-resolve '
                'the key and try again'),
        at: DateTime.now().millisecondsSinceEpoch,
      );
    }
    // 08-06's handoff: `guardArrayElementWrite` had no caller because the
    // router does not surface the mapping entry. This adapter resolved the ref
    // from that entry, so it is the layer that can see the `array_index`, and
    // the refusal happens before anything is sent.
    if (_arrayIndices.containsKey(ref.key)) {
      // The flag is the composer's, carried down (08-REVIEW WR-02). It used to
      // be the literal `false`, which made the documented compare-and-set
      // escape unreachable and told an operator who HAD supplied `expect` to
      // supply `expect`.
      final refusal = guardArrayElementWrite(cmd: cmd, hasExpect: hasExpect);
      if (refusal != null) return refusal;
    }
    final client = _client;
    if (client == null) {
      return translateWriteAnswer(
          protocol: UpstreamProtocol.opcUa,
          cmd: cmd,
          answer: const WriteDeadlineExpired(requestSent: false));
    }
    // ONE crossing into the plant, and no retry shape anywhere near it. The
    // three-state outcome is what makes a re-send the operator's decision, and
    // readback is the only confirmation.
    WriteAnswer answer;
    try {
      final index = _arrayIndices[ref.key];
      if (index != null) {
        // The read-modify-write the shipped StateMan does
        // (`state_man.dart:2033-2039`), and the reason the guard above only
        // steps aside with `expect`: this reads the whole array, replaces one
        // element and writes it back, so a concurrent change to a *different*
        // element between the two crossings is silently overwritten unless
        // the caller pinned the value it is racing. Both crossings share the
        // one deadline.
        final whole =
            await client.read(_nodes[ref.key]!).timeout(deadline);
        whole[index] = value.value;
        await client.write(_nodes[ref.key]!, whole).timeout(deadline);
      } else {
        await client
            .write(_nodes[ref.key]!, _toBindingValue(value))
            .timeout(deadline);
      }
      answer = WriteAcknowledged(at: DateTime.now().millisecondsSinceEpoch);
    } on TimeoutException {
      answer = const WriteDeadlineExpired();
    } catch (error) {
      _recordError(error);
      // 08-01's finding: the binding completes a failed write with a formatted
      // String, and under `useIsolate: true` a typed exception would be
      // flattened to one anyway. So the string branch is what this path feeds,
      // exactly as 08-06 planned for.
      answer = WriteErrorText(error.toString());
    }
    return translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa, cmd: cmd, answer: answer);
  }

  /// The relay's value, as something the binding will serialise.
  ///
  /// **An `int` carries no deducible OPC UA type** — the binding throws
  /// `'Unable to auto deduce type'` rather than guessing between Int16, Int32,
  /// Int64 and the unsigned family (`opcua_serializer.dart:334`), and it is
  /// right to. Int32 is the assumption this adapter makes, and it is written
  /// down here rather than buried: a plant tag that is genuinely Int16 or a
  /// UInt32 needs the type in its keymapping entry, which is a mapping-model
  /// change and therefore not this plan's. Until then a write of the wrong
  /// width comes back as `BadTypeMismatch` from the server — a named refusal,
  /// which is the safe way for this assumption to be wrong.
  ua.DynamicValue _toBindingValue(DynamicValue value) => ua.DynamicValue(
        value: value.value,
        typeId: value.value is int ? ua.NodeId.int32 : null,
      );

  /// Slices a whole-array sample down to the one element a key mapped with an
  /// `array_index` is about, keeping the sample's quality and source time.
  ///
  /// **The gateway's F7** (RIG-TEST-FINDINGS.md): the shipped StateMan does
  /// `value[idx]` on read (`state_man.dart:1871`), `.map((v) => v[idx])` on
  /// subscribe (`:2553`) and a read-modify-write on write (`:2033-2039`); the
  /// deployed gateway did none of it and streamed the whole array under every
  /// element key, storing `double precision[]` where the app stores scalars.
  ///
  /// A key with no `array_index` passes through untouched. An index that the
  /// value cannot satisfy — the tag is not an array, or the array is shorter
  /// than the mapping claims — is [Quality.errorTypeMismatch] with a null
  /// value: the mapping and the server disagree about the tag's shape, which
  /// is exactly what 771 says, and null under it is what stops the miss
  /// reading as a plausible zero. A bad-quality sample already carries null
  /// and is returned as-is; there is nothing to slice.
  DynamicValue _sliceArrayElement(String key, DynamicValue translated) {
    final index = _arrayIndices[key];
    if (index == null) return translated;
    final value = translated.value;
    if (value == null) return translated;
    if (value is! List || index < 0 || index >= value.length) {
      return DynamicValue(
        value: null,
        quality: Quality.errorTypeMismatch,
        sourceTime: translated.sourceTime,
      );
    }
    return DynamicValue(
      value: value[index],
      quality: translated.quality,
      sourceTime: translated.sourceTime,
    );
  }

  /// Opens the session, **bounded by [deadline] over the whole method**.
  ///
  /// Two things changed here in 08-REVIEW, and they are the same two hazards
  /// wearing different hats.
  ///
  /// **WR-04: it is tracked, and the disposal flag is re-read across every
  /// await.** [_inFlight] and [_reBrowseInFlight] exist because
  /// `client.delete()` frees the native client and a `connect` or a
  /// `subscriptionCreate` still crossing FFI against it walks freed memory and
  /// SEGVs the VM rather than failing — and `connect` itself, the method that
  /// *does both of those things*, was neither tracked nor re-guarded. It read
  /// `_disposed` once, before the first await, and `dispose()` knew nothing
  /// about its future. `LocalStateMan.start()` awaits one link at a time and a
  /// failing PLC holds it for tens of seconds, so a caller tearing down during
  /// start reached it; `bin/relay_gateway.dart` is safe today only because it
  /// registers its signal handlers after `start()` returns, which is not a
  /// property any other embedder owes.
  ///
  /// A separate field rather than sharing [_inFlight] with
  /// `_reopenSessionIfNeeded`: sharing is safe under the `_reopening` guard,
  /// and it is exactly the kind of safe-if-you-trace-it that stops being true
  /// when somebody adds a third writer.
  ///
  /// **WR-05: one budget, spent across the phases.** The single `deadline`
  /// argument used to be applied separately to `client.connect`, to
  /// `subscriptionCreate` and then handed whole to `_refreshEpoch`, which
  /// spent it three more times on its own reads — about five times the number
  /// a deployment typed, multiplied again by the link count in
  /// `LocalStateMan.start`. See [DeadlineBudget].
  @override
  Future<void> connect({required Duration deadline}) {
    if (_disposed) throw StateError('$alias: connect after dispose');
    return _connectInFlight = _connect(deadline);
  }

  Future<void> _connect(Duration deadline) async {
    final budget = DeadlineBudget(deadline);
    final client = _injectedClient ??
        (useIsolate
            ? await ua.ClientIsolate.create(
                logLevel: ua.LogLevel.UA_LOGLEVEL_ERROR)
            : ua.Client(logLevel: ua.LogLevel.UA_LOGLEVEL_ERROR));
    if (_disposed) {
      // Disposed while the client was being created. It is not in [_client],
      // so `dispose` cannot see it to release it, and an undeleted
      // `ClientIsolate` is a live worker isolate keeping the VM alive — WR-03's
      // failure, reached the other way round.
      await client.delete();
      return;
    }
    _client = client;
    final wrapper = ClientWrapper(client, _config);
    _wrapper = wrapper;
    _statusSub = wrapper.effectiveStatusStream.listen(_onEffectiveStatus);
    client.stateStream.listen(wrapper.updateConnectionStatus);
    _setState(UpstreamLinkState.connecting);
    // The driver first: `connect` does not complete until the session is
    // activated, and the session cannot activate unless somebody is turning
    // the crank.
    _startIterate();
    await client.connect(_endpoint).timeout(budget.remaining);
    if (_disposed) return;
    _subscriptionId = await client
        .subscriptionCreate(
            requestedPublishingInterval: _config.publishingInterval,
            requestedMaxKeepAliveCount: 30)
        .timeout(budget.remaining);
    if (_disposed) return;
    // The heartbeat is `ClientWrapper`'s, and it is the reason this class
    // wraps rather than rebuilds: a session that dies quietly still ages out
    // of `connected` because a clock says so, not because an event arrived.
    wrapper.startHeartbeat(_subscriptionId!);
    // The session is activated, which is the one moment the epoch is read. On
    // a first connect this ADOPTS an identity rather than bumping one — see
    // [_refreshEpoch] decision 3 — so no `reprogrammed` is announced for the
    // ordinary act of finding out who we are talking to.
    await _refreshEpoch(deadline: budget.remaining);
    // **`connect` returning is deliberately NOT the same as being connected.**
    // The state comes from `ClientWrapper.effectiveStatus` and nowhere else,
    // and until the first heartbeat tick that is `connecting` — a live session
    // whose data plane has not been observed to work yet. Forcing `connected`
    // here would put a green badge on a link before anything had arrived from
    // it, which is the frozen-session failure with a head start. It is
    // measured: this line used to be `_setState(connected)` and the first
    // assertion written against it read `connecting`.
  }

  /// The keys this link currently holds a monitored item for.
  ///
  /// A resubscribe must re-establish the **same set**. A set that grew means
  /// the old monitored items were never released and the PLC is carrying two
  /// of everything, which is the storm `state_man.dart:1480-1501` was written
  /// to stop.
  Iterable<String> get subscribedKeys => _monitors.keys;

  void _onEffectiveStatus(EffectiveDeviceStatus status) {
    final next = mapEffectiveStatus(status);
    final was = _state;
    _setState(next);
    if (was == next) return;
    if (next == UpstreamLinkState.disconnected ||
        next == UpstreamLinkState.unhealthy) {
      _degradeAll();
    }
  }

  /// Whether a resubscribe is already in flight.
  ///
  /// `SingleWorker`'s job in `ClientWrapper`, in one bool: two overlapping
  /// resubscribes are how one key's monitored-item id collides with another's.
  bool _resubscribing = false;

  /// Every key on this link degrades to [Quality.badCommFault], in one pass.
  ///
  /// **Band-guarded.** A key already worse keeps its own verdict: `errorConfig`
  /// means the tag is gone and waiting will not fix it, `badCommFault` means
  /// the link is down and waiting might, and overwriting the first with the
  /// second tells the operator to wait for something that is never coming back.
  ///
  /// One pass over the cache, and the *announcement* is [_setState]'s separate
  /// act — `fake_state_man.dart:598-605` keeps them apart and so does this. At
  /// 1500 keys a per-key status fan-out is a denial of service against the
  /// screen the operator is trying to read.
  /// Over the **monitored** set as well as the cache (08-REVIEW WR-13): a key
  /// with a monitored item that has not yet produced a sample is in
  /// `_monitors` and in neither `_cache` nor the composer's store, so losing
  /// the link used to stage nothing for it and its subscriber kept waiting for
  /// a link that was down.
  void _degradeAll() {
    for (final key in <String>{..._cache.keys, ..._monitors.keys}) {
      _publishDegraded(key, Quality.badCommFault);
    }
  }

  /// Puts [quality] on [key] **unless the key is already worse**.
  ///
  /// The band guard lives here rather than at each caller because both routes
  /// into a degrade need it and only one of them is obvious. The mass
  /// degradation on link loss is the obvious one; the second is a *per-key*
  /// subscription error, which arrives on the same link failure a beat earlier
  /// and would otherwise overwrite an `errorConfig` with a `badCommFault`
  /// before the mass pass ever ran. That was measured: the guard was in
  /// `_degradeAll` alone and the deleted tag still came out 522.
  void _publishDegraded(String key, Quality quality) {
    final current = _cache[key];
    if (current != null) {
      if (current.quality.isError && quality == Quality.badCommFault) return;
      if (current.quality == quality) return;
    }
    final degraded = DynamicValue(
      value: null,
      quality: quality,
      sourceTime: current?.sourceTime ?? DateTime.now().toUtc(),
    );
    _cache[key] = degraded;
    final monitored = _monitors[key];
    if (monitored != null && !monitored.controller.isClosed) {
      monitored.controller.add(degraded);
    }
  }

  /// The link is back; the numbers are not vouched for until each is re-read.
  ///
  /// [Quality.uncertainLastKnown] **with the old value still attached** — a
  /// stale number, openly labelled. Straight back to good would republish an
  /// hour-old reading as current the instant the socket reopened, and blanking
  /// it would throw away the only information there is.
  void _markRestored() {
    for (final entry in _cache.entries.toList()) {
      final current = entry.value;
      if (current.quality.isError) continue;
      final restored = DynamicValue(
        value: current.value ?? _lastGoodValues[entry.key],
        quality: Quality.uncertainLastKnown,
        sourceTime: current.sourceTime,
      );
      _cache[entry.key] = restored;
      final monitored = _monitors[entry.key];
      if (monitored != null && !monitored.controller.isClosed) {
        monitored.controller.add(restored);
      }
    }
  }

  /// Re-establishes every monitored key on a fresh subscription.
  ///
  /// **Two-phase, and the order is the whole point** (`state_man.dart:1480-
  /// 1501`): cancel every existing monitored item FIRST, then create the new
  /// subscription, then re-monitor. Interleaving them is what let one key's
  /// monitored-item id collide with another's and produced the storm this
  /// ordering was measured to fix.
  Future<void> _resubscribeAll() async {
    if (_resubscribing || _disposed) return;
    final client = _client;
    if (client == null) return;
    _resubscribing = true;
    try {
      // Phase one: let go of everything.
      for (final monitored in _monitors.values) {
        await monitored.subscription?.cancel();
        monitored.subscription = null;
      }
      // Phase two: a new subscription, and the heartbeat back on it.
      _subscriptionId = await client
          .subscriptionCreate(
              requestedPublishingInterval: _config.publishingInterval,
              requestedMaxKeepAliveCount: 30)
          .timeout(const Duration(seconds: 10));
      _wrapper?.startHeartbeat(_subscriptionId!);
      // Phase three: the same key set, never a bigger one.
      for (final monitored in _monitors.values) {
        _subscriptionsCreated++;
        try {
          await _establish(monitored);
        } catch (error) {
          // **ONE TAG fails, never the pass** — the standing constraint, and
          // it earns its keep here rather than in the abstract: a re-browse
          // after a reprogram is exactly when a key is most likely to have
          // left the address space, and a throw on the seventh of fifty would
          // leave forty-three keys with no monitored item and no error either.
          _recordError(error);
          _publishDegraded(
              monitored.key, qualityForOpcUaErrorText(error.toString()));
        }
      }
    } finally {
      _resubscribing = false;
    }
  }

  /// The last value each key was known to be good at.
  ///
  /// Kept beside the cache rather than inside it so a degrade can null the
  /// published value — which it must, because a bad sample has no payload —
  /// without losing the number a restore then labels uncertain.
  final Map<String, Object?> _lastGoodValues = <String, Object?>{};

  void _setState(UpstreamLinkState next) {
    if (_state == next) return;
    if (next == UpstreamLinkState.connected) _birthCount++;
    if (next == UpstreamLinkState.disconnected ||
        next == UpstreamLinkState.unhealthy) {
      _lastDeathAt = DateTime.now().toUtc();
    }
    _state = next;
    // The bookkeeping above still runs while a reprogram is latched —
    // `birthCount` and `lastDeathAt` are facts about the SESSION and a
    // reprogram does not make them stop being true — but the announcement does
    // not. A `connected` on the wire between the `reprogrammed` and the end of
    // the re-browse would tell a panel the link is fine while every handle it
    // holds is stale.
    if (_reprogrammed) return;
    if (!_states.isClosed) _states.add(next);
  }

  // ------------------------------------------------------------- the epoch
  //
  // SRV-07's second criterion. The epoch is re-read on **session activation**
  // and on nothing else: not on a timer, because a timer asks a healthy server
  // a question it already answered, and because the moment a handle can start
  // pointing at the wrong variable is the moment a new session comes up
  // (`state_man.dart:1458-1510` is where that transition already lives).

  /// Re-reads the server's identity and bumps the epoch if it changed.
  ///
  /// Returns whether a bump happened. Four decisions, in this order, and each
  /// one is a case in `epoch_test.dart`:
  ///
  ///  1. **The same reading is not a bump.** A reconnection that finds the
  ///     same server produces no event at all, which is what stops a flapping
  ///     link from being reported as forty reprogrammings (T-08-32).
  ///  2. **An unreadable reading is never adopted.** A server that answered
  ///     none of the three questions has told us nothing about its identity,
  ///     and absence of evidence is not evidence of change; adopting it would
  ///     turn every comms glitch into a plant-wide re-resolution. The keys are
  ///     already degrading for the honest reason — the link is down.
  ///  3. **The first reading is not a change.** Going from
  ///     [unconnectedEpoch] to a real epoch is this link learning who it is
  ///     talking to, not that PLC being reprogrammed.
  ///  4. Otherwise the server underneath us changed, and [_bump] runs.
  Future<EpochOutcome> _refreshEpoch(
      {Duration? deadline, bool sessionIsNew = false}) async {
    final client = _client;
    if (client == null || _disposed) return EpochOutcome.notAsked;
    EpochInputs inputs;
    try {
      inputs = await _epochReader(client,
          deadline: deadline ?? epochDeadline, buildStampNode: _buildStampNode);
    } catch (error) {
      // `readEpochInputs` does not throw; an injected one might, and a
      // detector that dies of its own exception is worse than one that says
      // it could not read.
      _recordError(error);
      inputs = EpochInputs.unreadable;
    }
    final next = inputs.combine();
    if (next == _epoch) return EpochOutcome.unchanged;
    if (isUnreadableEpoch(next)) return EpochOutcome.unreadable;
    if (_epoch == unconnectedEpoch) {
      _epoch = next;
      return EpochOutcome.adopted;
    }
    await _bump(next, sessionIsNew: sessionIsNew);
    return EpochOutcome.bumped;
  }

  /// The four things a bump does, in this order and once each.
  ///
  /// The **order** is the part that matters and the part a sabotage can break
  /// invisibly, so it is numbered here and asserted there.
  Future<void> _bump(String next, {required bool sessionIsNew}) async {
    // 1. Every ref this link ever issued becomes stale — and it is this single
    //    assignment that does it. `_isLive` compares a ref's epoch against
    //    this field, so there is no list of outstanding handles to walk and
    //    therefore none to miss.
    _epoch = next;
    // 2. ONE batch. `_degradeAll` is one pass over the cache; at 1500 keys a
    //    per-key fan-out is a denial of service against the screen the
    //    operator is trying to read.
    _degradeAll();
    // 3. And THEN the announcement, kept a separate act from the degradation
    //    for `fake_state_man.dart:598-605`'s reason and for a second one: a
    //    panel that receives `reprogrammed` and then reads a key that has not
    //    yet degraded sees a good value under a reprogrammed link, which is
    //    the exact combination the epoch exists to make impossible.
    _announceReprogrammed();
    if (!_epochs.isClosed) _epochs.add(next);
    // 4. One re-browse, whatever the key count.
    await _reBrowse(sessionIsNew: sessionIsNew);
  }

  void _announceReprogrammed() {
    _reprogrammed = true;
    // Deliberately NOT `_setState`: a reprogram is not a death and not a
    // birth, so neither `lastDeathAt` nor `birthCount` moves here.
    if (!_states.isClosed) _states.add(UpstreamLinkState.reprogrammed);
  }

  /// Ends the reprogrammed window and re-announces whatever the session says.
  void _clearReprogrammed() {
    if (!_reprogrammed) return;
    _reprogrammed = false;
    if (!_states.isClosed) _states.add(state);
  }

  /// Re-resolves every key this link owns against the new address space —
  /// **once**, in one pass.
  ///
  /// What it costs on a real PLC: one subscription create plus one monitored
  /// item per key, against a controller that has just restarted and is the
  /// slowest it will ever be. That is not free. It is still once, because the
  /// alternative is fifty of these — a browse storm at exactly the wrong
  /// moment (T-08-31), and the assertion that keeps it honest counts the
  /// re-browses across a fifty-key bump and expects 1.
  ///
  /// Two outcomes per key, and both are already implemented by the resubscribe
  /// path rather than by a second mechanism:
  ///
  ///  * a key that still resolves gets a fresh monitored item, and is marked
  ///    [Quality.uncertainLastKnown] until a sample actually arrives;
  ///  * a key that left the address space fails to monitor with
  ///    `BadNodeIdUnknown`, which `qualityForOpcUaErrorText` maps to
  ///    [Quality.errorConfig] — and it stays there, because `_publishDegraded`
  ///    refuses to relabel an error as a comms fault.
  ///
  /// **The value is dropped, not carried over.** `_markRestored` keeps the old
  /// number under an uncertain badge and is right to: after a reconnect it is
  /// still *this tag's* last reading. After a reprogram it is not — the
  /// address space was rebuilt, and a number from before the download is a
  /// number from a different variable wearing this key's name. That is the
  /// whole failure this phase exists to prevent, so the two paths differ here
  /// on purpose.
  ///
  /// ## Why [sessionIsNew] exists, and why it is not a test accommodation
  ///
  /// A reprogram arrives in two shapes, and they need different work:
  ///
  ///  * **The session died with the server** (a restart; the reopen path).
  ///    The old subscription id is meaningless, so the full resubscribe runs:
  ///    a new subscription, the heartbeat moved onto it, then the key set.
  ///  * **The session survived the reprogram** — which is *precisely* the A1
  ///    case this whole multi-input epoch exists for. TF6100 is a separate
  ///    Windows service and a PLC download restarts the runtime, not the
  ///    service, so the session, the subscription and the heartbeat are all
  ///    still perfectly good and the address space underneath them is not.
  ///    Here the right work is only to re-monitor the keys.
  ///
  /// Doing the heavy version on a live session is not merely wasteful, it is
  /// **measured to crash**: creating a second subscription and restarting the
  /// heartbeat onto it while fifty monitored-item creates are in flight makes
  /// the binding answer one of them `No results for create monitored item`,
  /// and its error path closes a `NativeCallable` that open62541 still holds —
  /// the VM then aborts inside `UA_Client_delete` with `Callback invoked after
  /// it has been deleted`. Reproducible on the fifty-key arm, absent from the
  /// same arm without a bump. Recorded here rather than worked around
  /// silently: the binding fix belongs upstream (the orphaned-monitored-item
  /// family, open62541_dart#92), and this is the shape that does not need it.
  Future<void> _reBrowse({required bool sessionIsNew}) async {
    _reBrowses++;
    try {
      for (final entry in _cache.entries.toList()) {
        // A tag that is already gone stays gone: `errorConfig` means waiting
        // will not fix it, and marking it uncertain would tell an operator to
        // keep waiting for a tag that no longer exists.
        if (entry.value.quality.isError) continue;
        _publishDegraded(entry.key, Quality.uncertainLastKnown);
      }
      if (sessionIsNew) {
        await _resubscribeAll();
      } else {
        await _remonitorAll();
      }
    } finally {
      _clearReprogrammed();
    }
  }

  /// Re-establishes every monitored key on the **existing** subscription.
  ///
  /// [_resubscribeAll] without the subscription create and without touching
  /// the heartbeat — the live-session half of [_reBrowse]. The two-phase
  /// ordering is kept exactly (`state_man.dart:1480-1501`): cancel every
  /// monitored item first, re-monitor second. Interleaving them is what let
  /// one key's monitored-item id collide with another's, and that ordering
  /// fixed a measured storm; it does not stop being true because the
  /// subscription is the same one.
  Future<void> _remonitorAll() async {
    if (_resubscribing || _disposed) return;
    final client = _client;
    if (client == null || _subscriptionId == null) return;
    _resubscribing = true;
    try {
      for (final monitored in _monitors.values) {
        await monitored.subscription?.cancel();
        monitored.subscription = null;
      }
      for (final monitored in _monitors.values) {
        _subscriptionsCreated++;
        try {
          await _establish(monitored);
        } catch (error) {
          // ONE TAG fails, never the pass. See `_resubscribeAll`.
          _recordError(error);
          _publishDegraded(
              monitored.key, qualityForOpcUaErrorText(error.toString()));
        }
      }
    } finally {
      _resubscribing = false;
    }
  }

  /// The re-browse currently running, if any.
  ///
  /// Tracked for [dispose]'s reason and only that one: `client.delete()` frees
  /// the native client, and a `subscriptionCreate` still crossing the FFI
  /// boundary against it walks freed memory and SEGVs the VM rather than
  /// failing. Same hazard as [_inFlight], different entry point.
  Future<void>? _reBrowseInFlight;

  /// Re-reads the epoch as a session activation would.
  ///
  /// **A lever, and named so.** Production re-reads on activation and on
  /// nothing else; a case about the bump *choreography* cannot force an
  /// activation on a healthy link, and restarting a server to test the
  /// ordering of four steps would test the fixture instead. The reading itself
  /// is proved against a server that genuinely restarted in
  /// `stale_handle_test.dart`.
  Future<void> debugRefreshEpoch() async {
    await _refreshEpoch();
  }

  void _recordError(Object error) {
    _lastError = error.toString();
    _wrapper?.recordError(_lastError!);
  }

  /// **The supervised iterate loop.**
  ///
  /// One `Timer.periodic` owned by this class, started on connect and cancelled
  /// on dispose, with its errors going to [_iterateErrors] and to the injected
  /// callback. The shape it replaces is `state_man.dart:1364`/`:1398`: two
  /// unawaited `() async {…}()` loops per client, logging to a bare `Logger()`,
  /// with nothing that can be read from a test and nothing that stops.
  void _startIterate() {
    _iterateTimer ??= Timer.periodic(_iteratePeriod, (_) => _pump());
  }

  void _pump() {
    if (_iterating || _disposed) return;
    final client = _client;
    if (client == null) return;
    _iterating = true;
    _iterateTicks++;
    _reopenSessionIfNeeded(client);
    if (client is ua.Client) {
      try {
        client.runIterate(_iteratePeriod);
      } catch (error, stack) {
        _superviseIterate(error, stack);
      } finally {
        _iterating = false;
      }
      return;
    }
    if (client is ua.ClientIsolate) {
      unawaited(client.runIterate(duration: _iteratePeriod).then<void>(
        (_) => _iterating = false,
        onError: (Object error, StackTrace stack) {
          _iterating = false;
          _superviseIterate(error, stack);
        },
      ));
      return;
    }
    // An injected fake: nothing to iterate.
    _iterating = false;
  }

  /// Reopens a lost session — **and nothing else**.
  ///
  /// The standing constraint is "no auto-retry anywhere upstream", and it is
  /// about the *plant*, not the socket: reads and subscriptions may keep their
  /// reconnect logic, writes may never be re-issued (08-CONTEXT's carry-forward
  /// list says so in those words). This is the reconnect half. It reopens the
  /// session and lets [_resubscribeAll] put the monitored items back; it does
  /// not remember, replay or re-send a single write, and the behavioural arm in
  /// `opcua_fault_test.dart` counts at the server to prove it.
  ///
  /// `state_man.dart:1364-1381` does this with a `while` loop and a bare
  /// `Logger()`. Here it rides the driver that is already running: no second
  /// timer, no second thing to cancel, and a floor on how often it may dial so
  /// a dead PLC is not hammered ten times a second.
  void _reopenSessionIfNeeded(ua.ClientApi client) {
    if (_reopening || _resubscribing) return;
    final wrapper = _wrapper;
    if (wrapper == null) return;
    // **The two honest "the session is gone" signals, and no third.** This was
    // measured rather than guessed: keying it on
    // `UpstreamLinkState.disconnected` alone left the link dead after a TCP
    // reset, because `effectiveStatus` reports `opcuaUnhealthy` — the channel
    // is formally still there. `sessionLost` is what `ClientWrapper` sets when
    // `isSubscriptionDead` classifies a heartbeat error as fatal (`:872`), and
    // it is precisely the frozen-session case that a new session is the only
    // cure for. Keying on "not connected" instead would dial over the top of a
    // healthy warm-up, which is a different bug.
    if (!wrapper.sessionLost &&
        wrapper.connectionStatus != ConnectionStatus.disconnected) {
      return;
    }
    final last = _lastReopenAt;
    final now = DateTime.now();
    if (last != null && now.difference(last) < _reopenFloor) return;
    _lastReopenAt = now;
    _reopening = true;
    _inFlight = client.connect(_endpoint).timeout(_connectDeadline).then<void>(
      (_) async {
        try {
          // **A new session is the one moment the epoch is re-read**, and the
          // read doubles as the activation probe. Ask before restoring
          // anything: if the server underneath is a different one, the bump
          // owns the recovery — it degrades, announces and re-browses — and
          // marking the old numbers "restored" first would relabel readings
          // from an address space that no longer exists.
          //
          // `sessionLost` is deliberately NOT cleared before this: a
          // `connect()` that completes is not proof of an activated session.
          // Measured, on a fixture restart: the channel reopens, the binding's
          // connect future completes, and the server answers
          // `ActivateSession: Session not found` — clearing the flag there
          // wedges the link permanently, because it is the only thing that
          // makes the driver dial again.
          switch (await _refreshEpoch(sessionIsNew: true)) {
            case EpochOutcome.unreadable:
              // The socket is back and the server will not answer its own
              // identity node. That is not a session. Say so and let the
              // driver try again.
              wrapper.sessionLost = true;
            case EpochOutcome.bumped:
              // The bump already degraded, announced and re-browsed.
              wrapper.sessionLost = false;
            case EpochOutcome.unchanged:
            case EpochOutcome.adopted:
            case EpochOutcome.notAsked:
              wrapper.sessionLost = false;
              // **Restored is marked HERE, not on the transition back to
              // connected.** The link being back is a fact about the socket;
              // the numbers are still the old ones and nothing has re-read
              // them. Doing it on the connected transition would run *after*
              // the resubscribe had already delivered fresh values and would
              // relabel a good reading as uncertain — the right badge on the
              // wrong sample.
              _markRestored();
              await _resubscribeAll();
          }
        } finally {
          // Held until the whole recovery is done, so a second dial cannot
          // start on top of an epoch read or a resubscribe.
          _reopening = false;
        }
      },
      onError: (Object error, StackTrace stack) {
        _reopening = false;
        _recordError(error);
      },
    );
    unawaited(_inFlight!.catchError(_recordError));
  }

  /// The reopen-and-resubscribe currently running, if any.
  ///
  /// **Awaited by [dispose], and that is a use-after-free fix rather than
  /// tidiness.** `client.delete()` frees the native client; a `connect` or a
  /// `subscriptionCreate` still in flight against it then walks freed memory
  /// and the VM SEGVs rather than failing — which is exactly what happened,
  /// intermittently, before this field existed. It is the same hazard 08-01
  /// hit reading a `UA_DataValue` across an await, one layer up.
  ///
  /// No `.timeout` is added at the dispose seam (project memory: a dispose
  /// that gives up half way leaves the thing it was disposing in a state
  /// nobody owns). None is needed: the connect inside carries
  /// [_connectDeadline] and the `subscriptionCreate` carries its own, so this
  /// future is bounded where the work is rather than where the waiting is.
  Future<void>? _inFlight;

  /// The [connect] currently running, if any. Awaited by [dispose] for
  /// [_inFlight]'s reason — see [connect]'s doc for why it is its own field.
  Future<void>? _connectInFlight;

  /// How often a disconnected link may dial.
  static const Duration _reopenFloor = Duration(seconds: 1);

  /// The bound on one dial, so a half-open socket cannot park the driver.
  static const Duration _connectDeadline = Duration(seconds: 10);

  bool _reopening = false;
  DateTime? _lastReopenAt;

  void _superviseIterate(Object error, StackTrace stack) {
    _iterateErrors.add(error);
    _recordError(error);
    _onIterateError?.call(error, stack);
  }

  /// Forces a new epoch, for the cases that need a stale handle without a PLC
  /// download.
  ///
  /// 08-07 left this as a placeholder over a per-session epoch; 08-08 kept the
  /// name and its one caller (`opcua_link_test.dart`'s stale-handle arm) and
  /// routed it through the **real** [_bump], so the lever now exercises the
  /// production choreography rather than a shortcut past it. Synchronous
  /// because its caller is; the re-browse it starts is tracked so [dispose]
  /// cannot delete the client out from under it.
  void debugBumpEpoch() {
    _reBrowseInFlight = _bump(
        'e1:debug-bump-${DateTime.now().microsecondsSinceEpoch}',
        sessionIsNew: false);
    unawaited(_reBrowseInFlight!.catchError(_recordError));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // The driver first, for the fixture's reason in reverse: a `runIterate`
    // racing a client `delete()` is native work against freed memory. No
    // `.timeout` anywhere on this path (project memory: a dispose that gives
    // up half way leaves the thing it was disposing in a state nobody owns).
    _iterateTimer?.cancel();
    _iterateTimer = null;
    // Then let any reopen/resubscribe already crossing the FFI boundary
    // finish, BEFORE the client is deleted underneath it. See [_inFlight].
    try {
      await _inFlight;
    } catch (_) {
      // A failed reopen is not a disposal failure.
    }
    try {
      // And an in-flight `connect`, which does a `connect`, a
      // `subscriptionCreate` and three epoch reads across the FFI boundary and
      // was not covered by either of the other two fields (08-REVIEW WR-04).
      await _connectInFlight;
    } catch (_) {
      // Neither is a connect that never landed. `start()` reports that as a
      // link state; it is not this method's news.
    }
    try {
      // And the same for a re-browse started by a bump that nobody awaited
      // (`debugBumpEpoch`). Same hazard, same reason: `subscriptionCreate` is
      // FFI, and deleting the client under it is a SEGV rather than an error.
      await _reBrowseInFlight;
    } catch (_) {
      // A failed re-browse is not a disposal failure either.
    }
    for (final monitored in _monitors.values) {
      await monitored.subscription?.cancel();
      await monitored.controller.close();
    }
    _monitors.clear();
    // The one-shot feeds handed to stale-handle subscribes. 08-REVIEW WR-09:
    // these were never tracked and `_monitors` cannot see them, so each one
    // leaked an unclosed controller — on the path that runs *exactly* when a
    // PLC has just been reprogrammed and every held handle is stale, which is
    // potentially once per subscribed key. The Modbus base got this right one
    // file over and the two adapters had no business differing on it.
    for (final feed in _staleFeeds) {
      await feed.close();
    }
    _staleFeeds.clear();
    await _statusSub?.cancel();
    _wrapper?.dispose();
    final client = _client;
    _client = null;
    // **An injected client is owned by the link**, and 08-REVIEW WR-03 is why
    // the `_injectedClient == null` guard is gone. `buildUpstreamLink` injects
    // a client whenever the config names a username/password or a certificate
    // pair, and at the default `useIsolate: true` that is a spawned
    // `ClientIsolate`. Nothing deleted it, so the worker isolate was still
    // alive when `main` completed `stopped.future` — a live isolate keeps the
    // VM alive, so a credentialed gateway logged "stopping", finished `stop()`
    // and then simply did not exit, until the container runtime escalated to
    // SIGKILL. The anonymous case was unaffected precisely because the adapter
    // built its own and therefore released it.
    //
    // Ownership follows "who is responsible for dispose", which
    // `upstream_link.dart:305-309` already says is the caller of `connect` —
    // and that is this class. The seam's doc now says so.
    if (client != null) {
      await client.delete();
    }
    if (!_states.isClosed) await _states.close();
    if (!_epochs.isClosed) await _epochs.close();
  }
}

/// One key's monitored item and the controller its values reach.
final class _MonitoredKey {
  _MonitoredKey(this.key);

  final String key;
  final StreamController<DynamicValue> controller =
      StreamController<DynamicValue>.broadcast();
  StreamSubscription<ua.DynamicValue>? subscription;
}
