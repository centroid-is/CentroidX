/// The weigher link: read-only by protocol, judged by the same group, and
/// pointed at a real socket for the parts a double cannot prove.
///
/// **Why the smallest adapter matters most.** `M2400DeviceClientAdapter` is
/// ~55 lines. The device behind it accepts **exactly one TCP client** — which
/// is why `M2400Proxy` exists in `jbtm` at all, and why the plant has eight
/// weighers on 10.104.29.71–78 with one connection each to share out. That
/// makes it the single clearest example of this whole project's premise: the
/// gateway is the one process that talks to the device, and everything else
/// reads it through the pipe. An HMI panel that opens its own socket to a
/// weigher does not get a slow read, it gets *somebody else's* disconnect.
///
/// Two legs, and the split is deliberate:
///
///  * the shared `UpstreamLink` group, against a `DeviceClient` double, for the
///    same reason `modbus_link_test.dart` can run it — the levers are
///    synchronous and a socket cannot be;
///  * a real `M2400StubServer` + `M2400ClientWrapper` + `M2400DeviceClientAdapter`
///    for the record shaping, the four fault levers and the SRV-08 degradation,
///    none of which a double could establish.
library;

import 'dart:async';

import 'package:jbtm/jbtm.dart' show M2400ClientWrapper, M2400Field, M2400RecordType, M2400StubServer;
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

import 'modbus_link_test.dart'
    show DrivableModbusLink, FakeModbusDeviceClient, registerEntry;
import 'support/fake_upstream_link.dart';
import 'upstream_link_contract_test.dart'
    show contractFixtureKeys, runUpstreamLinkContract;

/// The weigher's alias, in the plant's own spelling (`keymap_fixtures.dart:63`
/// uses the same one).
const String weigherAlias = 'weigher1v';

/// The live weight, off a `STAT` record.
const String liveWeightKey = 'weigher1v.weight';

/// A completed weighing, off a `BATCH` record filtered to one status code.
const String batchWeightKey = 'weigher1v.batch_weight';

const Duration generous = Duration(seconds: 5);

/// A weigher mapping entry.
KeyMappingEntry weigherEntry({
  required M2400RecordType recordType,
  M2400Field? field,
  String? serverAlias = weigherAlias,
  int? statusFilter,
}) =>
    KeyMappingEntry(
      m2400Node: M2400NodeConfig(
        recordType: recordType,
        field: field,
        serverAlias: serverAlias,
        statusFilter: statusFilter,
      ),
    );

void main() {
  // ------------------------------------------------------------ the contract
  runUpstreamLinkContract(
      'M2400UpstreamLink', () => DrivableM2400Link(alias: weigherAlias));

  // ------------------------------------------- read-only, and never a throw

  group('the weigher refuses writes politely', () {
    late M2400UpstreamLink link;
    late FakeModbusDeviceClient fake;

    setUp(() async {
      fake = FakeModbusDeviceClient();
      link = M2400UpstreamLink(alias: weigherAlias, client: fake);
      await link.connect(deadline: generous);
      addTearDown(link.dispose);
    });

    UpstreamRef refFor() => link.resolve(
        liveWeightKey,
        weigherEntry(
            recordType: M2400RecordType.recStat, field: M2400Field.weight))!;

    test('supportsWrites is false, declared rather than discovered', () {
      expect(link.supportsWrites, isFalse);
    });

    test('a write is a WriteRejected in the cert overlay\'s exact shape',
        () async {
      final result = await link.write(refFor(), DynamicValue.of(1),
          cmd: 'cmd-w', deadline: generous);

      expect(result, isA<WriteRejected>());
      final rejected = result as WriteRejected;
      expect(rejected.reason.status, 'Bad_NotWritable');
      expect(rejected.reason.kind, 'not_writable');
      expect(rejected.reason, same(notWritableReason),
          reason: 'ONE spelling of the read-only refusal in this whole '
              'gateway. An operator reading two different refusals from two '
              'layers of one process learns nothing from the difference');
      expect(rejected.cmd, 'cmd-w');
    });

    test('NOTHING escapes as an exception — the inverted throwsA case',
        () async {
      // The case that fails if any exception gets out.
      // `M2400DeviceClientAdapter.write` throws `UnsupportedError`
      // (state_man.dart:1266-1268) and `state_man_api.dart:114-117` names that
      // throw as what not to copy: a throw on the write path reads to the
      // operator as "the write failed", which is the one thing a refusal to
      // TRY does not prove about the plant.
      await expectLater(
          link.write(refFor(), DynamicValue.of(1),
              cmd: 'cmd-x', deadline: generous),
          completes);

      // And again through a stale handle, which is the other route into
      // `write` and the one a short-circuit could miss.
      final stale = refFor();
      link.debugBumpEpoch();
      await expectLater(
          link.write(stale, DynamicValue.of(1),
              cmd: 'cmd-y', deadline: generous),
          completes);
    });

    test('supportsBrowse is false: there is no live address space to walk', () {
      expect(link.supportsBrowse, isFalse,
          reason: 'a weigher emits four record types; that is configuration, '
              'not an address space. The keymapping list is still browsable');
    });
  });

  // -------------------------------------------------- against a real weigher

  group('against a real M2400StubServer', () {
    late M2400StubServer server;
    late M2400ClientWrapper wrapper;
    late M2400UpstreamLink link;

    setUp(() async {
      server = M2400StubServer();
      // 08-07's port rule: the stub binds an OS-assigned port and exposes it
      // after binding, so it is READ rather than chosen. A literal here fails
      // on the second parallel worktree.
      await server.start();
      wrapper = M2400ClientWrapper('127.0.0.1', server.port);
      link = M2400UpstreamLink(
          alias: weigherAlias,
          client: M2400DeviceClientAdapter(wrapper, serverAlias: weigherAlias));
      addTearDown(() async {
        await link.dispose();
        await server.shutdown();
      });
      await link.connect(deadline: generous);
      await _awaitConnected(link);
    });

    UpstreamRef liveWeightRef() => link.resolve(
        liveWeightKey,
        weigherEntry(
            recordType: M2400RecordType.recStat, field: M2400Field.weight))!;

    UpstreamRef batchRef({int? statusFilter}) => link.resolve(
        batchWeightKey,
        weigherEntry(
            recordType: M2400RecordType.recBatch,
            field: M2400Field.weight,
            statusFilter: statusFilter))!;

    test('a STAT record becomes the named field', () async {
      final ref = liveWeightRef();
      final first = link.subscribe(ref).first;

      server.pushStatRecord(weight: '12.37', unit: 'kg');

      final seen = await first.timeout(generous);
      expect(seen.quality, Quality.good);
      expect(seen.value.toString(), contains('12.37'));
    });

    test('a write against the REAL adapter refuses and does not throw',
        () async {
      // The read-only group above proves the refusal against a double, which
      // cannot throw `UnsupportedError` because it does not have one. This case
      // is the same claim with the genuine article underneath:
      // `M2400DeviceClientAdapter.write` really does
      // `throw UnsupportedError('M2400 does not support writes')`
      // (state_man.dart:1266-1268), and the only reason it never reaches the
      // caller is that `supportsWrites` is false and the base refuses above it.
      // Remove either half and this case fails with the exception in the log.
      final result = await link.write(liveWeightRef(), DynamicValue.of(1),
          cmd: 'cmd-real', deadline: generous);

      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).reason.status, 'Bad_NotWritable');
    });

    test('a record failing its status_filter produces NO value', () async {
      final ref = batchRef(statusFilter: 7);
      final seen = <DynamicValue>[];
      final sub = link.subscribe(ref).listen(seen.add);
      addTearDown(sub.cancel);

      server.pushWeightRecord(weight: '10.0', status: '0');
      await _settle();

      expect(seen, isEmpty,
          reason: 'a weighing that happened and does not match the configured '
              'status is not this key\'s weighing. A bad quality for it would '
              'put a red badge on the page every time the machine did '
              'something the operator did not ask to watch');
    });

    test('and one passing it yields the named field', () async {
      final ref = batchRef(statusFilter: 0);
      final seen = <DynamicValue>[];
      final sub = link.subscribe(ref).listen(seen.add);
      addTearDown(sub.cancel);

      server.pushWeightRecord(weight: '10.0', status: '0');
      await _settle();

      expect(seen, hasLength(1));
      expect(seen.single.quality, Quality.good);
      expect(seen.single.value.toString(), contains('10.0'));
    });

    group('the four poison levers', () {
      /// Each lever, with a valid record pushed after it.
      ///
      /// **A named refutation, and it is a finding rather than a shortfall.**
      /// The plan asks that each lever "produce a bad quality on the affected
      /// key". It cannot, and the reason is one line of jbtm:
      /// `m2400_client_wrapper.dart:109-113` filters `parseM2400Frame`'s nulls
      /// out of the pipeline and `_route` (`:240-258`) ends with "unknown
      /// record types are silently dropped". All four poisons die **below** the
      /// adapter, so no layer this plan owns ever sees them and no layer can
      /// mint a quality for something that did not arrive.
      ///
      /// What *is* assertable is the property T-08-40 actually cares about, and
      /// it is the stronger half: garbage from a weigher costs **nothing** — no
      /// exception through the session, no false-good value, and no wedged
      /// pipeline. The third is the one that would hurt: a parser that died on
      /// frame seven would stop the other seven weighers' worth of records
      /// behind it, and that is exactly the failure the arms below would catch.
      ///
      /// Surfacing malformed frames as a quality needs a counter or an error
      /// channel inside `jbtm`'s pipeline. That is a second additive change to
      /// a foreign package on the app's production path, which this plan's
      /// house rule budgets at exactly one — so it is a named follow-up.
      for (final lever in <({String name, void Function(M2400StubServer) fire})>[
        (name: 'raw garbage', fire: (s) => s.sendRawGarbage([0xFF, 0x00, 0xFE])),
        (name: 'a malformed record', fire: (s) => s.sendMalformedRecord()),
        (name: 'an unknown record type', fire: (s) => s.sendUnknownRecordType()),
        (name: 'a record with no type', fire: (s) => s.sendRecordWithoutType()),
      ]) {
        test('${lever.name}: no exception, no false good, no wedge', () async {
          final ref = liveWeightRef();
          final seen = <DynamicValue>[];
          final errors = <Object>[];
          final sub = link
              .subscribe(ref)
              .listen(seen.add, onError: errors.add, cancelOnError: false);
          addTearDown(sub.cancel);

          lever.fire(server);
          await _settle();

          expect(errors, isEmpty,
              reason: 'garbage from a weigher must not throw through the '
                  'session that fifteen other keys are riding on');
          expect(seen, isEmpty,
              reason: 'nothing arrived that this key could be a value of, and '
                  'inventing one would be the worse failure of the two');
          expect(link.peek(ref), isNull,
              reason: 'not-yet-known is a different statement from a known '
                  'value under a bad quality');

          // The wedge arm: the pipeline is still alive behind the poison.
          server.pushStatRecord(weight: '9.99');
          await _settle();

          expect(seen, hasLength(1));
          expect(seen.single.quality, Quality.good);
          expect(seen.single.value.toString(), contains('9.99'),
              reason: 'one bad frame costs one frame. A parser that died on '
                  'frame seven would stop everything behind it');
        });
      }
    });

    test('losing the weigher degrades THIS alias only, and announces once',
        () async {
      final other = DrivableModbusLink(alias: 'ST101');
      await other.connect(deadline: generous);
      addTearDown(other.dispose);
      final otherRef =
          other.resolve(contractFixtureKeys.first, registerEntry(contractFixtureKeys.first))!;
      other.setValue(contractFixtureKeys.first, 1);

      final ref = liveWeightRef();
      final sub = link.subscribe(ref).listen((_) {});
      addTearDown(sub.cancel);
      server.pushStatRecord(weight: '12.37');
      await _settle();
      expect(link.peek(ref)!.quality, Quality.good);
      final announcements = <UpstreamLinkState>[];
      final stateSub = link.stateStream.listen(announcements.add);
      addTearDown(stateSub.cancel);

      await server.shutdown();
      await _awaitState(link, UpstreamLinkState.disconnected);
      await _settle();

      expect(link.peek(ref)!.quality, Quality.badCommFault);
      expect(announcements, [UpstreamLinkState.disconnected],
          reason: 'one event is one announcement however many keys it cost. '
              'SRV-08 is re-asserted here for a second protocol because the '
              'degradation path is SHARED — a protocol-specific bypass would '
              'be invisible from the OPC UA suite');
      expect(other.state, UpstreamLinkState.connected,
          reason: 'the weigher went down, not the plant');
      expect(other.peek(otherRef)!.quality, Quality.good);
    });
  });
}

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Future<void> _awaitConnected(M2400UpstreamLink link) =>
    _awaitState(link, UpstreamLinkState.connected);

Future<void> _awaitState(UpstreamLink link, UpstreamLinkState wanted) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (link.state != wanted) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the link never reached $wanted; it is ${link.state}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// The production weigher link plus the shared group's control surface.
///
/// Identical in shape to `DrivableModbusLink` and for the same reason: every
/// lever drives a production entry point.
final class DrivableM2400Link extends M2400UpstreamLink
    implements UpstreamLinkDriver {
  factory DrivableM2400Link(
          {required String alias, FakeModbusDeviceClient? client}) =>
      DrivableM2400Link._(alias, client ?? FakeModbusDeviceClient());

  DrivableM2400Link._(String alias, FakeModbusDeviceClient double_)
      : fake = double_,
        super(alias: alias, client: double_, health: double_);

  /// The double underneath.
  final FakeModbusDeviceClient fake;

  bool _failNextResolve = false;

  /// **False in production and unconditionally.** The group's write cases need
  /// a subject that can succeed, so this is the one lever whose default the
  /// driver flips; the weigher's real answer is asserted four ways in the
  /// read-only group above, and by the real-socket leg.
  bool _writes = true;
  bool _browse = false;
  Duration _readLatency = Duration.zero;

  final List<({String key, Object? raw})> _rawEmissions =
      <({String key, Object? raw})>[];

  static final Map<String, KeyMappingEntry> _fixtureEntries =
      <String, KeyMappingEntry>{
    for (final key in contractFixtureKeys)
      key: weigherEntry(
          recordType: M2400RecordType.recStat, field: M2400Field.weight),
  };

  @override
  UpstreamRef? resolve(String key, Object mappingEntry) {
    if (_failNextResolve) {
      _failNextResolve = false;
      return null;
    }
    if (mappingEntry is KeyMappingEntry) return super.resolve(key, mappingEntry);
    if (mappingEntry is! Map || mappingEntry.isNotEmpty) {
      return super.resolve(key, mappingEntry);
    }
    final entry = _fixtureEntries[key];
    if (entry == null) return null;
    return super.resolve(key, entry);
  }

  /// The record stream is the gateway key here, because the double feeds one
  /// stream per key rather than one per record type.
  @override
  String upstreamKeyFor(UpstreamRef ref) => ref.key;

  /// Identity, because the double delivers already-shaped values — the shaping
  /// itself is judged against a real weigher record in the socket leg.
  @override
  DynamicValue? shapeSample(String key, DynamicValue value) => value;

  /// See [_writes]: the M2400 answers `UpstreamProtocol.m2400`, whose
  /// translation is an unconditional refusal. The group's three write-success
  /// cases are about the **shared** write path, so the subject reports the
  /// transport rather than the weigher while the driver has writes enabled.
  @override
  UpstreamProtocol protocolFor(UpstreamRef ref) =>
      _writes ? UpstreamProtocol.modbus : super.protocolFor(ref);

  @override
  bool get supportsWrites => _writes;

  @override
  bool get supportsBrowse => _browse;

  @override
  void setValue(String key, Object? value,
      {Quality quality = Quality.good, DateTime? sourceTime}) {
    deliver(
        key,
        DynamicValue(
            value: value,
            quality: quality,
            sourceTime: sourceTime ?? DateTime.now().toUtc()));
  }

  @override
  void setValues(Map<String, Object?> values) {
    values.forEach((key, value) => setValue(key, value));
  }

  @override
  void setQuality(String key, Quality quality) {
    final current = peekCached(key);
    deliver(
        key,
        DynamicValue(
            value: current?.value,
            quality: quality,
            sourceTime: current?.sourceTime ?? DateTime.now().toUtc()));
  }

  @override
  void dropKey(String key) => dropKeyUpstream(key);

  @override
  void disconnectUpstream() {
    fake.pushEffective(EffectiveDeviceStatus.disconnected);
    onEffectiveStatus(EffectiveDeviceStatus.disconnected);
  }

  @override
  void reconnectUpstream() {
    fake.pushEffective(EffectiveDeviceStatus.connected);
    onEffectiveStatus(EffectiveDeviceStatus.connected);
  }

  @override
  int get roundTrips => upstreamRoundTrips;

  @override
  int get statusNotifications => stateAnnouncements;

  @override
  void bumpEpoch() => debugBumpEpoch();

  @override
  void setNextWriteOutcome(WriteResult outcome) {
    switch (outcome) {
      case WriteApplied():
      case WriteNotReceived():
        fake.clearWriteFailure();
      case WriteRejected():
        fake.failWriteWith(StateError('Bad_NotWritable staged'));
      case WriteUnknown():
        fake.failWriteWith(TimeoutException('staged unknown'));
    }
  }

  @override
  Duration get readLatency => _readLatency;

  @override
  set readLatency(Duration value) => _readLatency = value;

  @override
  Duration get writeLatency => fake.writeLatency;

  @override
  set writeLatency(Duration value) => fake.writeLatency = value;

  @override
  void failNextResolve() => _failNextResolve = true;

  @override
  void setSupportsWrites(bool value) => _writes = value;

  @override
  void setSupportsBrowse(bool value) => _browse = value;

  @override
  void emitRaw(String key, Object? raw) {
    _rawEmissions.add((key: key, raw: raw));
    deliverRaw(key, raw, arrivedAt: DateTime.now().toUtc());
  }

  @override
  List<({String key, Object? raw})> get rawEmissions =>
      List<({String key, Object? raw})>.unmodifiable(_rawEmissions);

  @override
  void setLastError(String? raw) {
    if (raw != null) recordUpstreamError(raw);
  }

  @override
  Future<DynamicValue?> roundTrip(String key) async {
    if (_readLatency > Duration.zero) {
      await Future<void>.delayed(_readLatency);
    }
    return super.roundTrip(key);
  }
}
