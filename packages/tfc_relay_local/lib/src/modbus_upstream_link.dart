/// The classic-Modbus and UMAS-by-name [UpstreamLink], and the machinery both
/// `DeviceClient`-backed adapters share.
///
/// **Wrap, do not rebuild.** `ModbusDeviceClientAdapter` is 1,506 lines sitting
/// on top of a 3,325-line `UmasClient`, with forty-odd dedicated test files
/// behind it. What is in there is not cleverness, it is *accumulated failure
/// knowledge*: the sticky M580 detection that skips a wasted `0x22 → 0xA1`
/// probe on every reconnect (TD-009), the single shared MonitorPlc table with
/// per-poll-group timers because the protocol allows exactly one table per
/// session (B-4), the symbol cache, the bit-mask read-modify-write, the
/// endianness matrix. Re-deriving that at the same fidelity is not a phase, and
/// every place it would be re-derived wrong is a plant behaviour nobody would
/// notice until a shift went bad.
///
/// What is *not* inherited is the layer above it — `StateMan`, whose `read` and
/// `write` throw, whose `subscribe` is a `Future<Stream<…>>`, and whose values
/// carry neither a quality nor a source time. Those are the semantics this
/// adapter exists to replace, and they live one layer up from everything worth
/// keeping. The seam is clean below and dirty above.
///
/// ## The timers, said out loud
///
/// The wrapped adapter owns several `Timer.periodic`s — a listener-gated health
/// timer (`modbus_device_client.dart:173`) and one per UMAS poll group, started
/// on connect and stopped on disconnect (`:393-395`, `:492-508`). **That is not
/// a violation of the day-one timer freeze**, which scopes `tfc_relay_local`'s
/// own `lib` and counts timers *this* package constructs. Wrapping a class that
/// owns timers does not construct one here. This paragraph exists so that a
/// future reader running the freeze sweep and finding four timers alive in the
/// process does not "fix" it by tearing the poll groups out of the adapter,
/// which would silently stop every UMAS-by-name key on the plant.
///
/// ## Two classes are called `DynamicValue`
///
/// The binding's is imported as `ua.`; the relay's — the one with a
/// [DynamicValue.quality] and a [DynamicValue.sourceTime] — is unprefixed.
/// [DeviceClientUpstreamLink.translateSample] is the one crossing point.
///
/// ## Where the shared base lives, and why here
///
/// [DeviceClientUpstreamLink] is in this file rather than in one of its own
/// because 08-10's file list is two adapters and an encoding module, and a
/// third source file for ~250 lines of shared cache/degrade/epoch bookkeeping
/// would be a filing decision made by a plan that did not make it. Modbus is
/// the first of the two `DeviceClient` wrappers, so the shared half sits with
/// it and `m2400_upstream_link.dart` imports it. If a third `DeviceClient`
/// protocol ever arrives, move it then.
library;

import 'dart:async';

import 'package:open62541/open62541.dart' as ua;
import 'package:tfc_dart/core/modbus_client_wrapper.dart'
    show ModbusAddressRefusal;
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man_types.dart';
import 'package:tfc_dart/core/umas_types.dart' show UmasException;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'ingest.dart';
import 'opcua_upstream_link.dart' show mapEffectiveStatus;
import 'upstream_link.dart';
import 'write_translation.dart';

/// The health signal a Modbus adapter has and `DeviceClient` does not.
///
/// `ModbusDeviceClientAdapter.effectiveStatus` (TD-004) is the combined
/// TCP + UMAS verdict, and it is the only thing that distinguishes a PLC whose
/// socket is up and whose Data Dictionary is off from a healthy one. It is not
/// on `DeviceClient`, so this two-member interface names it rather than the
/// link taking a concrete adapter — which would make every test double a
/// subclass of 1,506 lines.
abstract interface class EffectiveStatusSource {
  /// The combined TCP + protocol-layer health, synchronously.
  EffectiveDeviceStatus get effectiveStatus;

  /// Transitions of [effectiveStatus].
  Stream<EffectiveDeviceStatus> get effectiveStatusStream;
}

/// The half of an [UpstreamLink] that is the same for every `DeviceClient`.
///
/// Both non-OPC-UA protocols in this plant reach Dart through
/// `DeviceClient` — a plain `Stream` subscribe, a synchronous cached `read`, a
/// `Future<void>` write and a `ConnectionStatus`. Everything an [UpstreamLink]
/// owes on top of that (a quality-carrying cache, the band-guarded mass
/// degrade, the restore, the epoch, the announcement discipline, the deadline
/// on every upstream await) is identical between them, so it is written once.
///
/// The subclasses supply the four things that genuinely differ: which keys they
/// claim ([claim]), which protocol answers a write ([protocolFor]), what a
/// write actually does ([performWrite]), and how an error is classified
/// ([classifyWriteError]).
///
/// **The extension surface below is production code, not a test hatch.**
/// [deliver]
/// is what the sample listener calls; [onEffectiveStatus] is what the status
/// stream calls; [degradeAll] is what a link loss calls. A test subject drives
/// those same entry points, which is the only way a control surface can prove
/// anything — a driver that reached past the link into its cache would be
/// asserting against its own writes.
abstract class DeviceClientUpstreamLink implements UpstreamLink {
  DeviceClientUpstreamLink({
    required this.alias,
    required this.client,
    String? answersTo,
    EffectiveStatusSource? health,
    bool supportsWrites = true,
    bool supportsBrowse = false,
    this.staleAfter = const Duration(seconds: 10),
  })  : answersTo = answersTo ?? alias,
        _health = health,
        _supportsWrites = supportsWrites,
        _supportsBrowse = supportsBrowse;

  @override
  final String alias;

  /// The keymapping `server_alias` this link serves; [alias] when omitted.
  ///
  /// `''` is the unnamed server, compared through
  /// `StateManConfig.normalizeAlias` in each subclass's [claim]. The name and
  /// the answers-to are two facts (`key_router.dart:163-176`), and the rig
  /// showed what conflating them costs (RIG-TEST-FINDINGS.md F1).
  final String answersTo;

  /// The wrapped client. Protected rather than private because a subclass's
  /// [performWrite] is the only thing that touches it.
  final DeviceClient client;

  /// The freshness deadline this link declares, for 08-05's sweep.
  final Duration staleAfter;

  final EffectiveStatusSource? _health;
  final bool _supportsWrites;
  final bool _supportsBrowse;

  @override
  bool get supportsWrites => _supportsWrites;

  /// False for both of these protocols.
  ///
  /// Neither Modbus nor the M2400 has a live address space to walk: a register
  /// map is configuration and a weigher emits four record types. That does
  /// **not** mean the alias has no browsable keys — the keymapping list is
  /// always browsable — it means there is nothing to ask the device.
  @override
  bool get supportsBrowse => _supportsBrowse;

  final Map<String, DynamicValue> _cache = <String, DynamicValue>{};
  final Map<String, Object?> _lastGoodValues = <String, Object?>{};
  final Map<String, StreamController<DynamicValue>> _feeds =
      <String, StreamController<DynamicValue>>{};
  final Map<String, StreamSubscription<ua.DynamicValue>> _upstream =
      <String, StreamSubscription<ua.DynamicValue>>{};

  /// Controllers handed to subscriptions taken out against a superseded epoch.
  /// Held so [dispose] can close them; never fed a value again.
  final List<StreamController<DynamicValue>> _staleFeeds =
      <StreamController<DynamicValue>>[];

  final Set<String> _dropped = <String>{};

  final StreamController<UpstreamLinkState> _states =
      StreamController<UpstreamLinkState>.broadcast();
  final StreamController<String> _epochs = StreamController<String>.broadcast();
  StreamSubscription<EffectiveDeviceStatus>? _healthSub;
  StreamSubscription<ConnectionStatus>? _tcpSub;

  UpstreamLinkState _state = UpstreamLinkState.disconnected;
  String _epoch = 'e0:unconnected';
  String? _lastError;
  DateTime? _lastDeathAt;
  int _birthCount = 0;
  int _subscriptionsCreated = 0;
  int _roundTrips = 0;
  int _stateAnnouncements = 0;
  int _sanitizeRefusals = 0;
  int _arrivalStamped = 0;
  bool _disposed = false;

  // ------------------------------------------------------------ diagnostics

  /// Read + write + subscribe-establish calls that reached the device.
  int get upstreamRoundTrips => _roundTrips;

  /// How many times this link announced a change of link state.
  ///
  /// **One per mass degradation, never one per key.** At 1500 keys a per-key
  /// status fan-out is a denial of service against the screen the operator is
  /// trying to read.
  int get stateAnnouncements => _stateAnnouncements;

  /// How many payloads the sanitizing constructor refused.
  int get sanitizeRefusals => _sanitizeRefusals;

  /// How many samples arrived with no instant of their own and were stamped
  /// with their arrival time.
  ///
  /// **Expected to equal the sample count on Modbus and on the M2400**, which
  /// is the opposite of the OPC UA link's `sourceTimeFallbacks` — there the
  /// number staying at zero is the healthy reading. Neither protocol puts a
  /// timestamp on the wire, so the honest thing is to stamp arrival, say so in
  /// this counter, and **not** degrade the quality for it: a device that never
  /// had a clock is not a device sending a bad reading (T-08-25's other half).
  int get arrivalStampedSamples => _arrivalStamped;

  // ------------------------------------------------------------- the surface

  @override
  UpstreamLinkState get state => _state;

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

  /// Whether this link claims [key], and with what payload — or null for
  /// "not mine".
  ///
  /// The subclass's whole protocol knowledge, in one method. Null rather than a
  /// throw is what makes the router's fallthrough order possible without the
  /// router knowing a single protocol (08-04).
  Object? claim(String key, KeyMappingEntry entry);

  @override
  UpstreamRef? resolve(String key, Object mappingEntry) {
    if (_dropped.contains(key)) return null;
    if (mappingEntry is! KeyMappingEntry) return null;
    final payload = claim(key, mappingEntry);
    if (payload == null) return null;
    return UpstreamRef(alias: alias, epoch: _epoch, payload: payload, key: key);
  }

  /// Whether [ref] still addresses something this link vouches for.
  bool isLive(UpstreamRef ref) =>
      ref.alias == alias && ref.epoch == _epoch && !_dropped.contains(ref.key);

  @override
  DynamicValue? peek(UpstreamRef ref) => isLive(ref) ? _cache[ref.key] : null;

  /// The cached value for [key] with no handle check. For a subclass and for a
  /// driver staging a quality on top of what is already there.
  DynamicValue? peekCached(String key) => _cache[key];

  @override
  Stream<DynamicValue> subscribe(UpstreamRef ref) {
    if (!isLive(ref)) {
      // A bad-quality value, and the stream stays OPEN. An ended stream is
      // indistinguishable to a widget from a key that stopped changing.
      final controller = StreamController<DynamicValue>();
      controller.add(_bad(Quality.badCommFault));
      _staleFeeds.add(controller);
      return controller.stream;
    }
    final existing = _feeds[ref.key];
    if (existing != null) return existing.stream;
    final controller = StreamController<DynamicValue>.broadcast();
    _feeds[ref.key] = controller;
    _subscriptionsCreated++;
    _roundTrips++;
    _upstream[ref.key] = client.subscribe(upstreamKeyFor(ref)).listen(
      (sample) {
        final translated =
            translateSample(sample, arrivedAt: DateTime.now().toUtc());
        final shaped = shapeSample(ref.key, translated);
        // **Null is "this sample is not for this key"**, which is a real
        // outcome rather than an error: a weigher record that fails its
        // configured `status_filter` is a weighing that happened and does not
        // belong to this key. Publishing a bad quality for it would put a red
        // badge on a page every time the machine did something the operator
        // did not ask to watch.
        if (shaped != null) deliver(ref.key, shaped);
      },
      onError: (Object error) {
        recordUpstreamError(error);
        publishDegraded(ref.key, Quality.badCommFault);
      },
    );
    return controller.stream;
  }

  @override
  Future<DynamicValue> read(UpstreamRef ref,
      {required Duration deadline}) async {
    if (!isLive(ref)) {
      // SRV-07: no stale-handle read ever returns a value.
      return _bad(Quality.badCommFault);
    }
    _roundTrips++;
    try {
      final seen = await roundTrip(ref.key).timeout(deadline);
      return seen ?? _bad(Quality.uncertainNotYetKnown);
    } on TimeoutException {
      return _bad(Quality.badCommFault);
    } catch (error) {
      recordUpstreamError(error);
      return _bad(Quality.badCommFault);
    }
  }

  /// The key the wrapped client knows this ref by.
  ///
  /// The same as the gateway key for Modbus, where one key is one register. Not
  /// the same for the M2400, where **many gateway keys share one record
  /// stream** — `weigher1v.weight` and `weigher1v.giveaway` are two fields of
  /// one `BATCH` record, and subscribing to a per-field key would ask the
  /// wrapper to split a struct it is about to hand over whole.
  String upstreamKeyFor(UpstreamRef ref) => ref.key;

  /// The last transform between the wire and the cache, or null to publish
  /// nothing.
  ///
  /// Identity for Modbus. For the M2400 this is the lifted `status_filter` and
  /// field extraction, which is the one place a record becomes a value.
  DynamicValue? shapeSample(String key, DynamicValue value) => value;

  /// One read from the device, unbounded — [read] applies the deadline.
  ///
  /// The default is the cache, and that is a statement about Modbus rather than
  /// a shortcut: `DeviceClient.read` is documented as "the last known value"
  /// and the adapter's own is a cached read (`state_man.dart:1212`). **The poll
  /// cycle is the round trip on this protocol**, so a `read` that dialled the
  /// register directly would be a second, unsynchronised reader racing the
  /// group timer that already owns that register. A UMAS-by-name link that
  /// wants a real `readVariable` overrides this.
  Future<DynamicValue?> roundTrip(String key) async => _cache[key];

  /// The protocol that answered a write through [ref].
  ///
  /// Per-ref rather than per-link, because one Modbus server serves both
  /// address spaces: a classic exception PDU and a typed `UmasException` are
  /// different vocabularies from the same socket.
  UpstreamProtocol protocolFor(UpstreamRef ref);

  /// The refusal this link owes before anything is sent, or null.
  ///
  /// [hasExpect] is the composer's compare-and-set bit, carried down for the
  /// same reason the OPC UA adapter takes it — see `UpstreamLink.write`.
  WriteResult? writeGuard(UpstreamRef ref, String cmd,
          {bool hasExpect = false}) =>
      null;

  /// Sends one write. May throw; [write] classifies whatever comes out.
  Future<void> performWrite(UpstreamRef ref, DynamicValue value) =>
      client.write(ref.key, ua.DynamicValue(value: value.value));

  /// What a thrown [error] says about whether the device refused.
  ///
  /// The default is the text branch, which 08-06's `_fromText` reads
  /// conservatively: a sentence this gateway cannot parse as a refusal is
  /// **not** evidence of one, and "rejected" is the one answer that invites a
  /// second press of the button.
  WriteAnswer classifyWriteError(Object error) =>
      WriteErrorText(error.toString());

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
    if (!isLive(ref)) {
      // A stale-handle write is REJECTED, not unknown: nothing was sent, so it
      // is definitively no effect (08-03's ruling).
      return WriteRejected(
        cmd,
        WriteReason('stale_handle',
            message: 'this handle was resolved under epoch ${ref.epoch} and '
                'the link is now at $_epoch; nothing was sent — re-resolve '
                'the key and try again'),
        at: DateTime.now().millisecondsSinceEpoch,
      );
    }
    final refusal = writeGuard(ref, cmd, hasExpect: hasExpect);
    if (refusal != null) return refusal;
    _roundTrips++;
    // ONE crossing into the plant, and no retry shape anywhere near it.
    WriteAnswer answer;
    try {
      await performWrite(ref, value).timeout(deadline);
      answer = WriteAcknowledged(at: DateTime.now().millisecondsSinceEpoch);
    } on TimeoutException {
      answer = const WriteDeadlineExpired();
    } catch (error) {
      recordUpstreamError(error);
      answer = classifyWriteError(error);
    }
    return translateWriteAnswer(
        protocol: protocolFor(ref), cmd: cmd, answer: answer);
  }

  @override
  Future<void> connect({required Duration deadline}) async {
    if (_disposed) throw StateError('$alias: connect after dispose');
    final health = _health;
    if (health != null) {
      _healthSub = health.effectiveStatusStream.listen(onEffectiveStatus);
    } else {
      _tcpSub = client.connectionStream.listen(
          (status) => onEffectiveStatus(_fromTcp(status)));
    }
    setLinkState(UpstreamLinkState.connecting);
    client.connect();
    // **The current status is adopted, not invented.** Unlike the OPC UA link,
    // whose `connected` must wait for a heartbeat to prove the data plane, the
    // Modbus adapter's `effectiveStatus` already *is* the derived health
    // verdict — reading it here is asking the thing that knows rather than
    // guessing on its behalf.
    onEffectiveStatus(health?.effectiveStatus ?? _fromTcp(client.connectionStatus));
  }

  static EffectiveDeviceStatus _fromTcp(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.connected:
        return EffectiveDeviceStatus.connected;
      case ConnectionStatus.connecting:
        return EffectiveDeviceStatus.connecting;
      case ConnectionStatus.disconnected:
        return EffectiveDeviceStatus.disconnected;
    }
  }

  // ------------------------------------------------------------- the ingest

  /// One translated sample arrived for [key].
  void deliver(String key, DynamicValue value) {
    _cache[key] = value;
    if (value.quality == Quality.good) _lastGoodValues[key] = value.value;
    final feed = _feeds[key];
    if (feed != null && !feed.isClosed) feed.add(value);
  }

  /// One **unsanitized** payload arrived for [key].
  ///
  /// The standing constraint, and the reason the `try` is here rather than
  /// around the poll loop: a sanitize failure costs **one tag, never a poll
  /// cycle**. A struct-heavy PLC is exactly where `DynamicValue`'s depth bound
  /// bites, and taking the cycle down with it would blank a whole plant screen
  /// for one bad tag.
  void deliverRaw(String key, Object? raw,
      {required DateTime arrivedAt, Quality quality = Quality.good}) {
    try {
      deliver(key,
          DynamicValue(value: raw, quality: quality, sourceTime: arrivedAt));
    } catch (error) {
      _sanitizeRefusals++;
      recordUpstreamError(error);
      deliver(
          key,
          DynamicValue(
              value: null,
              quality: refusedSampleQuality,
              sourceTime: arrivedAt));
    }
  }

  /// One binding value, translated — quality, payload and instant.
  ///
  /// Neither of these protocols carries a status code or a source timestamp of
  /// its own, so in production this is: good quality, the payload as it came,
  /// and **arrival time**, counted in [arrivalStampedSamples]. The two `if`s
  /// exist because a sample that *does* carry either is a sample this function
  /// must not overwrite — the M2400 record shaping in the sibling adapter can
  /// produce both.
  DynamicValue translateSample(ua.DynamicValue sample,
      {required DateTime arrivedAt}) {
    final stamped = sample.sourceTimestamp;
    if (stamped == null) _arrivalStamped++;
    final code = sample.statusCode;
    final quality =
        (code == null || code == 0) ? Quality.good : Quality.badCommFault;
    try {
      return DynamicValue(
        value: quality == Quality.good ? _plainValueOf(sample) : null,
        quality: quality,
        sourceTime: stamped ?? arrivedAt,
      );
    } catch (error) {
      _sanitizeRefusals++;
      recordUpstreamError(error);
      return DynamicValue(
          value: null,
          quality: refusedSampleQuality,
          sourceTime: stamped ?? arrivedAt);
    }
  }

  /// The tag is gone upstream: [key] stops resolving and reports
  /// [Quality.errorConfig], and its stream **does not end**.
  void dropKeyUpstream(String key) {
    _dropped.add(key);
    publishDegraded(key, Quality.errorConfig, force: true);
  }

  // ------------------------------------------------------- state and degrade

  /// The adapter's health said something. **The one entry point for a state
  /// change**, so the announcement and the degradation stay one pair of acts.
  void onEffectiveStatus(EffectiveDeviceStatus status) {
    final next = mapEffectiveStatus(status);
    final was = _state;
    setLinkState(next);
    if (was == next) return;
    if (next == UpstreamLinkState.disconnected ||
        next == UpstreamLinkState.unhealthy) {
      degradeAll();
    } else if (next == UpstreamLinkState.connected &&
        (was == UpstreamLinkState.disconnected ||
            was == UpstreamLinkState.unhealthy)) {
      markRestored();
    }
  }

  void setLinkState(UpstreamLinkState next) {
    if (_state == next) return;
    if (next == UpstreamLinkState.connected) _birthCount++;
    if (next == UpstreamLinkState.disconnected ||
        next == UpstreamLinkState.unhealthy) {
      _lastDeathAt = DateTime.now().toUtc();
    }
    _state = next;
    _stateAnnouncements++;
    if (!_states.isClosed) _states.add(next);
  }

  /// Every key on this link degrades to [Quality.badCommFault], in one pass.
  void degradeAll() {
    for (final key in _cache.keys.toList()) {
      publishDegraded(key, Quality.badCommFault);
    }
  }

  /// Puts [quality] on [key] **unless the key is already worse**.
  ///
  /// `errorConfig` means the tag is gone and waiting will not fix it;
  /// `badCommFault` means the link is down and waiting might. Overwriting the
  /// first with the second tells the operator to wait for something that is
  /// never coming back.
  void publishDegraded(String key, Quality quality, {bool force = false}) {
    final current = _cache[key];
    if (!force && current != null) {
      if (current.quality.isError && quality == Quality.badCommFault) return;
      if (current.quality == quality) return;
    }
    final degraded = DynamicValue(
      value: null,
      quality: quality,
      sourceTime: current?.sourceTime ?? DateTime.now().toUtc(),
    );
    _cache[key] = degraded;
    final feed = _feeds[key];
    if (feed != null && !feed.isClosed) feed.add(degraded);
  }

  /// The link is back; the numbers are not vouched for until each is re-read.
  void markRestored() {
    for (final entry in _cache.entries.toList()) {
      final current = entry.value;
      if (current.quality.isError) continue;
      final restored = DynamicValue(
        value: current.value ?? _lastGoodValues[entry.key],
        quality: Quality.uncertainLastKnown,
        sourceTime: current.sourceTime,
      );
      _cache[entry.key] = restored;
      final feed = _feeds[entry.key];
      if (feed != null && !feed.isClosed) feed.add(restored);
    }
  }

  // --------------------------------------------------------------- the epoch

  /// The PLC's identity changed: every [UpstreamRef] this link ever issued is
  /// stale, in one assignment.
  ///
  /// **No production caller yet, and the honest name for that is a gap.** The
  /// input this protocol has is the UMAS **project CRC**, which the adapter
  /// already watches (`_umasProjectCrcSub`) precisely because a Unity download
  /// moves it; wiring it to this method is the Modbus half of 08-08's epoch and
  /// is recorded in 08-10's summary as a follow-up rather than smuggled in
  /// here. Until then a Modbus link has one epoch per process, which is *safe*
  /// (no handle is ever wrongly invalidated) and *incomplete* (a download is
  /// not detected).
  ///
  /// The order below is the part that matters and the part a sabotage can break
  /// invisibly.
  void bumpEpochTo(String next) {
    // 1. Every ref becomes stale — one assignment, no list of handles to miss.
    _epoch = next;
    // 2. ONE batch of degradation.
    degradeAll();
    // 3. And THEN the announcement, kept a separate act.
    if (!_states.isClosed) _states.add(UpstreamLinkState.reprogrammed);
    _stateAnnouncements++;
    if (!_epochs.isClosed) _epochs.add(next);
  }

  /// Records an upstream error. Redacted on the way **out**, not here — the
  /// gateway's own log is not a key and keeps the whole sentence.
  void recordUpstreamError(Object error) => _lastError = error.toString();

  DynamicValue _bad(Quality quality) => DynamicValue(
      value: null, quality: quality, sourceTime: DateTime.now().toUtc());

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // No `.timeout` anywhere on this path: a dispose that gives up half way
    // leaves the thing it was disposing in a state nobody owns.
    for (final sub in _upstream.values) {
      await sub.cancel();
    }
    _upstream.clear();
    for (final feed in _feeds.values) {
      if (!feed.isClosed) await feed.close();
    }
    _feeds.clear();
    for (final feed in _staleFeeds) {
      if (!feed.isClosed) await feed.close();
    }
    _staleFeeds.clear();
    await _healthSub?.cancel();
    await _tcpSub?.cancel();
    client.dispose();
    if (!_states.isClosed) await _states.close();
    if (!_epochs.isClosed) await _epochs.close();
  }
}

/// The payload of a binding value, as something the relay's sanitizing
/// constructor will accept.
Object? _plainValueOf(ua.DynamicValue sample) {
  final raw = sample.value;
  if (raw is ua.DynamicValue) return _plainValueOf(raw);
  if (raw is List) {
    return <Object?>[
      for (final element in raw)
        element is ua.DynamicValue ? _plainValueOf(element) : element,
    ];
  }
  if (raw is Map) {
    return <String, Object?>{
      for (final entry in raw.entries)
        '${entry.key}': entry.value is ua.DynamicValue
            ? _plainValueOf(entry.value as ua.DynamicValue)
            : entry.value,
    };
  }
  return raw;
}

/// One configured Modbus/UMAS server, behind the gateway's uniform surface.
class ModbusUpstreamLink extends DeviceClientUpstreamLink {
  ModbusUpstreamLink({
    required super.alias,
    required super.client,
    super.answersTo,
    super.health,
    super.supportsWrites,
    super.staleAfter,
    Stream<ModbusAddressRefusal>? refusals,
  }) : super(supportsBrowse: false) {
    // Taken out at construction rather than in `connect`: the stream is a
    // broadcast seam and nothing flows on it before polling starts, so there
    // is no ordering to get wrong — and a link that only listened after a
    // successful connect would drop a refusal raced against a reconnect.
    _refusalSub = refusals?.listen(_onRefusal);
  }

  StreamSubscription<ModbusAddressRefusal>? _refusalSub;

  /// The device refused [ModbusAddressRefusal.key]'s address space by name.
  ///
  /// **[Quality.errorConfig], and here is the argument written down.** 770's
  /// own doc reads "a configuration error, not a transient — waiting will not
  /// fix it", minted today for a key retired upstream. A register the device
  /// answers `IllegalDataAddress` for is the same statement arriving on a
  /// different wire: the far end parsed the request and affirmatively said
  /// the address does not exist as asked. It is deliberately NOT
  /// `errorTypeMismatch` (the two ends agree the register cannot be read at
  /// all — there is no type to disagree about), NOT `badCommFault` (the
  /// socket answered; waiting is the one instruction that is wrong), and not
  /// a new code (a band that already means "the upstream said no" is used
  /// honestly rather than a fifth spelling invented).
  ///
  /// The wrapper deduplicates per transition, so this handler stays dumb —
  /// and `publishDegraded`'s own equal-quality guard makes even a repeated
  /// event free. Recovery needs no path here: the first successful poll after
  /// the map is fixed delivers a good sample through [deliver], which
  /// overwrites the cache and the feed the ordinary way.
  void _onRefusal(ModbusAddressRefusal refusal) {
    recordUpstreamError('device refused ${refusal.key}: ${refusal.code.name} '
        '— the register map names an address this device does not serve');
    publishDegraded(refusal.key, Quality.errorConfig);
  }

  @override
  Future<void> dispose() async {
    await _refusalSub?.cancel();
    _refusalSub = null;
    await super.dispose();
  }

  /// Wraps the real adapter, which is the production path.
  ///
  /// A named constructor rather than the default one because
  /// `ModbusDeviceClientAdapter` supplies *two* of the link's inputs — it is
  /// the `DeviceClient` and it is the [EffectiveStatusSource] — and passing the
  /// same object twice at every call site is the kind of thing somebody
  /// eventually gets wrong in one of them.
  factory ModbusUpstreamLink.wrapping(
    ModbusDeviceClientAdapter adapter, {
    required String alias,
    String? answersTo,
    bool supportsWrites = true,
    Duration staleAfter = const Duration(seconds: 10),
  }) =>
      ModbusUpstreamLink(
        alias: alias,
        answersTo: answersTo,
        client: adapter,
        health: _AdapterHealth(adapter),
        supportsWrites: supportsWrites,
        staleAfter: staleAfter,
        // The third input the adapter supplies, and the reason the bench's
        // Illegal register sat at 258: without this wire a refused address
        // is a fact the wrapper names and nobody hears.
        refusals: adapter.registerRefusals,
      );

  /// The configured poll group per claimed key, **passed through untouched**.
  ///
  /// The adapter below already owns per-poll-group timers and the single shared
  /// MonitorPlc table; re-deriving the grouping here would be a second opinion
  /// about a cadence that is configured once. It is recorded rather than
  /// dropped because 08-05's freshness sweep wants to know how often a key is
  /// *expected* to move before it calls one stale.
  final Map<String, String> _pollGroups = <String, String>{};

  /// Keys whose mapping carries a bit mask, and are therefore a
  /// read-modify-write of a whole register.
  final Set<String> _bitMasked = <String>{};

  /// Keys routed by UMAS symbol rather than by register address.
  final Set<String> _bySymbol = <String>{};

  /// The poll group [key] was configured into, or null if it is not claimed.
  String? pollGroupOf(String key) => _pollGroups[key];

  @override
  Object? claim(String key, KeyMappingEntry entry) {
    final node = entry.modbusNode;
    if (node == null) return null;
    // **The adapter checks its own alias.** 08-04's handoff, in one `if`: the
    // router does not filter candidates by `server_alias`, it offers the key to
    // every link in order and takes the first claim. A resolve that claims
    // anything Modbus-shaped takes ST201's key on a two-PLC plant, and the
    // router's ambiguity check does not catch it because the two links have
    // different aliases.
    // Against [answersTo], not [alias]: the live plant file spells the
    // unnamed server, which the name can never be (RIG-TEST-FINDINGS.md F1).
    if (StateManConfig.normalizeAlias(node.serverAlias) !=
        StateManConfig.normalizeAlias(answersTo)) {
      return null;
    }
    _pollGroups[key] = node.pollGroup;
    if (entry.bitMask != null) {
      _bitMasked.add(key);
    } else {
      _bitMasked.remove(key);
    }
    final symbol = entry.variableName;
    if (symbol != null) {
      _bySymbol.add(key);
      // UMAS by symbol is a different **address space**, not a different link:
      // Schneider only exposes `%MW`-located variables on the FC03 register
      // map, so for these keys the symbol *is* the address.
      return symbol;
    }
    _bySymbol.remove(key);
    return '${node.registerType.name}:${node.address}';
  }

  @override
  UpstreamProtocol protocolFor(UpstreamRef ref) => _bySymbol.contains(ref.key)
      ? UpstreamProtocol.umas
      : UpstreamProtocol.modbus;

  /// A bit-masked write is a read-modify-write, and is refused without an
  /// `expect`.
  ///
  /// 08-06 wrote [guardArrayElementWrite] for the OPC UA array element and left
  /// it without a caller, because the router cannot see the mapping entry.
  /// **This is the second shape of the same hazard, and this is the layer that
  /// can see it**: `modbus_device_client.dart:1240-1252` reads the current
  /// register, merges the masked bits and writes the whole word back. Two
  /// operators toggling two bits of one status word lose one of the two edits,
  /// silently, and the loser is whoever read first. A named refusal is a
  /// page-editor bug report; a silent overwrite is a plant incident.
  ///
  /// The carrier arrived in 08-REVIEW WR-02: [hasExpect] is the composer's
  /// compare-and-set bit, evaluated against the last value the gateway heard
  /// and carried down through `write`. Under a comparison the read-modify-
  /// write may run, which is what `guardArrayElementWrite`'s own doc has
  /// always said and what nothing could reach while the flag was a literal.
  @override
  WriteResult? writeGuard(UpstreamRef ref, String cmd,
          {bool hasExpect = false}) =>
      _bitMasked.contains(ref.key)
          ? guardArrayElementWrite(cmd: cmd, hasExpect: hasExpect)
          : null;

  /// A typed [UmasException] is the device declining **by name**.
  ///
  /// The same standing as a classic Modbus exception PDU: the slave parsed the
  /// request and said no, and there is no service layer above the write that
  /// could have failed after the variable moved. Everything else stays a text
  /// answer, which 08-06 reads conservatively.
  @override
  WriteAnswer classifyWriteError(Object error) => error is UmasException
      ? WriteStatusAnswer(error.errorCode, text: error.message)
      : super.classifyWriteError(error);
}

/// `ModbusDeviceClientAdapter`'s TD-004 health, behind the two-member
/// interface the link consumes.
final class _AdapterHealth implements EffectiveStatusSource {
  _AdapterHealth(this._adapter);

  final ModbusDeviceClientAdapter _adapter;

  @override
  EffectiveDeviceStatus get effectiveStatus => _adapter.effectiveStatus;

  @override
  Stream<EffectiveDeviceStatus> get effectiveStatusStream =>
      _adapter.effectiveStatusStream;
}
