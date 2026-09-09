/// FB-DynamicValue poll-loop fallback (v1.1.x): the UMAS poll path must
/// detect FB-instance bindings (via [UmasNotScalarException]) and fall
/// back to a batched member fan-out read, producing a struct
/// [DynamicValue] (`{member: value}` LinkedHashMap) that subscribers
/// (FB-DynamicValue widget, Conveyor FB asset) can render directly.
///
/// Background — commit `8c03c68d` made `readVariableByName` on an
/// FB-instance root throw [UmasNotScalarException]. The intent was to
/// surface the bug instead of silently returning empty bytes. But the
/// poll loop in [ModbusDeviceClientAdapter.readUmasVariable] used to
/// just bubble the throw — every tick logged
///
///   UMAS fallback poll for key "K" failed: UmasNotScalarException ...
///
/// when an operator bound a key to an FB instance, and the subject never
/// emitted. The fix: catch the exception and route through the new
/// [UmasClient.readFbInstanceMembers] helper, producing a struct
/// DynamicValue with `value: LinkedHashMap<String, DynamicValue>`.
///
/// Run: `cd packages/tfc_dart && dart test test/core/umas_fb_dynamic_value_poll_test.dart`
@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/umas_client.dart';
import 'package:tfc_dart/core/umas_types.dart';

// ---------------------------------------------------------------------------
// Helpers — mirror the wire-level mocking patterns from
// umas_coils_registers_test.dart.
// ---------------------------------------------------------------------------

/// Build a minimal ReadVariable (0x22) success PDU.
///
/// Layout: FC(0x5A) + pairingKey(1) + status(0xFE) + concatenated value bytes.
/// The caller supplies the value bytes pre-laid-out in declaration order.
Uint8List _buildReadVariableSuccessPdu(Uint8List payload) {
  final pdu = Uint8List(3 + payload.length);
  pdu[0] = 0x5A;
  pdu[1] = 0x00;
  pdu[2] = 0xFE;
  pdu.setAll(3, payload);
  return pdu;
}

/// FB instance + 3 members. Mirrors the live PLC shape
/// `M_F2_RC_01.{HMI.p_Stat_xRunningFwd, HMI.p_Stat_xStopped, q_rVelocity}`
/// — two BOOLs at the head, one REAL at the tail.
void _injectFbAndMembers(UmasClient umas) {
  // FB root — classIdentifier 7. Reads on this path throw
  // UmasNotScalarException.
  umas.debugInjectSymbol(ResolvedSymbol(
    path: 'M_F2_RC_01',
    variable: const UmasVariable(
      name: 'M_F2_RC_01',
      blockNo: 0x30,
      offset: 0,
      dataTypeId: 0xB6,
    ),
    dataType: const UmasDataTypeRef(
      id: 0xB6,
      name: 'FB',
      byteSize: 0,
      classIdentifier: 7,
    ),
  ));
  umas.debugInjectSymbol(ResolvedSymbol(
    path: 'M_F2_RC_01.HMI.p_Stat_xRunningFwd',
    variable: const UmasVariable(
      name: 'p_Stat_xRunningFwd',
      blockNo: 0x30,
      offset: 0x10,
      dataTypeId: 1,
    ),
    dataType: const UmasDataTypeRef(
      id: 1,
      name: 'BOOL',
      byteSize: 1,
    ),
  ));
  umas.debugInjectSymbol(ResolvedSymbol(
    path: 'M_F2_RC_01.HMI.p_Stat_xStopped',
    variable: const UmasVariable(
      name: 'p_Stat_xStopped',
      blockNo: 0x30,
      offset: 0x11,
      dataTypeId: 1,
    ),
    dataType: const UmasDataTypeRef(
      id: 1,
      name: 'BOOL',
      byteSize: 1,
    ),
  ));
  umas.debugInjectSymbol(ResolvedSymbol(
    path: 'M_F2_RC_01.q_rVelocity',
    variable: const UmasVariable(
      name: 'q_rVelocity',
      blockNo: 0x30,
      offset: 0x20,
      dataTypeId: 6,
    ),
    dataType: const UmasDataTypeRef(
      id: 6,
      name: 'REAL',
      byteSize: 4,
    ),
  ));
}

void main() {
  // ---------------------------------------------------------------------------
  // UmasClient.readFbInstanceMembers — public helper that walks the
  // already-built symbol cache for `<fbPath>.<...>` entries, issues a single
  // batched readVariables for the readable scalar leaves, and returns a
  // Map<String, TypedVariableValue> keyed by the member sub-path (the
  // suffix AFTER the FB root + `.`).
  // ---------------------------------------------------------------------------

  group('UmasClient.readFbInstanceMembers', () {
    test('returns one TypedVariableValue per scalar member, keyed by '
        'the member sub-path under the FB root', () async {
      final sent = <UmasRequest>[];
      final umas = UmasClient(
        sendFn: (req) async {
          if (req is! UmasRequest) {
            return ModbusResponseCode.requestRxFailed;
          }
          sent.add(req);
          // Two BOOLs (1 byte each, true/false) + one REAL (4 bytes, 12.5f).
          // Order MUST match the order readFbInstanceMembers walks the
          // symbol cache. We pin the order in the assertions below.
          final payload = Uint8List.fromList([
            0x01, // p_Stat_xRunningFwd = true
            0x00, // p_Stat_xStopped = false
            // 12.5f little-endian
            0x00, 0x00, 0x48, 0x41,
          ]);
          req.setFromPduResponse(_buildReadVariableSuccessPdu(payload));
          return ModbusResponseCode.requestSucceed;
        },
      );
      _injectFbAndMembers(umas);
      umas.debugSetProjectCrc(0xCAFEBABE);
      umas.debugSetBlockCrcs(const [0xDEADBEEF]);
      umas.debugSetSessionState(UmasSessionState.paired);

      final members = await umas.readFbInstanceMembers('M_F2_RC_01');

      // Must include every scalar leaf under the FB root.
      expect(members.keys, containsAll(<String>[
        'HMI.p_Stat_xRunningFwd',
        'HMI.p_Stat_xStopped',
        'q_rVelocity',
      ]));
      expect(members['HMI.p_Stat_xRunningFwd']!.value, isTrue);
      expect(members['HMI.p_Stat_xStopped']!.value, isFalse);
      expect((members['q_rVelocity']!.value as double), closeTo(12.5, 0.001));

      // One batched ReadVariable PDU — NOT N round-trips.
      final readReqs = sent
          .where((r) => r.umasSubFunction == UmasSubFunction.readVariable.code)
          .toList();
      expect(readReqs, hasLength(1),
          reason:
              'readFbInstanceMembers must issue a single batched 0x22 PDU');
    });

    test('throws UmasException when no scalar members are cached for '
        'the named FB root', () async {
      final umas = UmasClient(
        sendFn: (req) async => ModbusResponseCode.requestSucceed,
      );
      // Inject only the FB root — no children.
      umas.debugInjectSymbol(ResolvedSymbol(
        path: 'M_Empty',
        variable: const UmasVariable(
          name: 'M_Empty',
          blockNo: 0x40,
          offset: 0,
          dataTypeId: 0xC0,
        ),
        dataType: const UmasDataTypeRef(
          id: 0xC0,
          name: 'FB',
          byteSize: 0,
          classIdentifier: 7,
        ),
      ));
      umas.debugSetProjectCrc(0x0);
      umas.debugSetBlockCrcs(const [0x0]);
      umas.debugSetSessionState(UmasSessionState.paired);

      try {
        await umas.readFbInstanceMembers('M_Empty');
        fail('expected UmasException for FB with no enumerable members');
      } on UmasException catch (e) {
        expect(e.message, contains('M_Empty'));
        expect(e.message, contains('member'));
      }
    });

    test('skips unreadable members (e.g. VAR_IN_OUT) — they are NOT '
        'included in the returned map and do NOT show up in the wire '
        'PDU', () async {
      final sent = <UmasRequest>[];
      final umas = UmasClient(
        sendFn: (req) async {
          if (req is! UmasRequest) {
            return ModbusResponseCode.requestRxFailed;
          }
          sent.add(req);
          // Only ONE BOOL in the response — the unreadable member must NOT
          // be in the batch.
          req.setFromPduResponse(_buildReadVariableSuccessPdu(
            Uint8List.fromList([0x01]),
          ));
          return ModbusResponseCode.requestSucceed;
        },
      );

      umas.debugInjectSymbol(ResolvedSymbol(
        path: 'M_F2_RC_01',
        variable: const UmasVariable(
          name: 'M_F2_RC_01',
          blockNo: 0x30,
          offset: 0,
          dataTypeId: 0xB6,
        ),
        dataType: const UmasDataTypeRef(
          id: 0xB6,
          name: 'FB',
          byteSize: 0,
          classIdentifier: 7,
        ),
      ));
      umas.debugInjectSymbol(ResolvedSymbol(
        path: 'M_F2_RC_01.q_xActive',
        variable: const UmasVariable(
          name: 'q_xActive',
          blockNo: 0x30,
          offset: 0x10,
          dataTypeId: 1,
        ),
        dataType: const UmasDataTypeRef(
          id: 1,
          name: 'BOOL',
          byteSize: 1,
        ),
      ));
      umas.debugInjectSymbol(ResolvedSymbol(
        path: 'M_F2_RC_01.iq_handshake',
        variable: const UmasVariable(
          name: 'iq_handshake',
          blockNo: 0x30,
          offset: 0x14,
          dataTypeId: 6,
        ),
        dataType: const UmasDataTypeRef(
          id: 6,
          name: 'REAL',
          byteSize: 4,
        ),
        readable: false,
        unreadableReason: 'VAR_IN_OUT (PLC returns 0x94)',
      ));
      umas.debugSetProjectCrc(0xCAFEBABE);
      umas.debugSetBlockCrcs(const [0xDEADBEEF]);
      umas.debugSetSessionState(UmasSessionState.paired);

      final members = await umas.readFbInstanceMembers('M_F2_RC_01');

      expect(members.keys, equals(<String>['q_xActive']),
          reason: 'unreadable members must NOT be in the returned map');
      // The wire payload encoded exactly one ref (the readable BOOL).
      final readReqs = sent
          .where((r) => r.umasSubFunction == UmasSubFunction.readVariable.code)
          .toList();
      expect(readReqs, hasLength(1));
      expect(readReqs.single.umasPayload[4], equals(1),
          reason: 'exactly one ref in the batched ReadVariable PDU');
    });

    test('falls back to per-leaf reads when the batched ReadVariable '
        'response trips a parse error (live-PLC reality: STRING members '
        'inside an FB confuse the byteSize accounting in '
        'parseVariableValues — the FB members must still surface '
        'individually instead of disappearing wholesale)', () async {
      // Two BOOLs + one STRING under an FB. The first send (batched
      // 0x22) returns a too-short body, causing a "buffer underflow"
      // UmasException. The helper must then fall back to per-leaf
      // reads — each leaf gets its own 0x22, the per-leaf STRING
      // succeeds because parseVariableValues handles a single STRING
      // gracefully via the isStringy carve-out.
      var batchedCalls = 0;
      var perLeafCalls = 0;
      final umas = UmasClient(
        sendFn: (req) async {
          if (req is! UmasRequest) {
            return ModbusResponseCode.requestRxFailed;
          }
          if (req.umasSubFunction !=
              UmasSubFunction.readVariable.code) {
            return ModbusResponseCode.requestSucceed;
          }
          final refCount = req.umasPayload[4];
          if (refCount > 1) {
            batchedCalls++;
            // Return too-short body to simulate the live-PLC
            // STRING-in-FB underflow.
            req.setFromPduResponse(_buildReadVariableSuccessPdu(
              Uint8List.fromList([0x00]),
            ));
            return ModbusResponseCode.requestSucceed;
          }
          // Per-leaf path: refCount == 1. Reply with a plausible
          // single-leaf body (1 byte BOOL or 16-byte STRING — for
          // simplicity always return 1 byte true; STRING parser
          // accepts short reads).
          perLeafCalls++;
          req.setFromPduResponse(_buildReadVariableSuccessPdu(
            Uint8List.fromList([0x01]),
          ));
          return ModbusResponseCode.requestSucceed;
        },
      );
      umas.debugInjectSymbol(ResolvedSymbol(
        path: 'M_F2_RC_01',
        variable: const UmasVariable(
          name: 'M_F2_RC_01',
          blockNo: 0xB2,
          offset: 0,
          dataTypeId: 0xC1,
        ),
        dataType: const UmasDataTypeRef(
          id: 0xC1,
          name: 'FB',
          byteSize: 0,
          classIdentifier: 7,
        ),
      ));
      umas.debugInjectSymbol(ResolvedSymbol(
        path: 'M_F2_RC_01.i_xFwd',
        variable: const UmasVariable(
          name: 'i_xFwd',
          blockNo: 0xB2,
          offset: 1,
          dataTypeId: 1,
        ),
        dataType: const UmasDataTypeRef(
          id: 1,
          name: 'BOOL',
          byteSize: 1,
        ),
      ));
      umas.debugInjectSymbol(ResolvedSymbol(
        path: 'M_F2_RC_01.q_sStatus',
        variable: const UmasVariable(
          name: 'q_sStatus',
          blockNo: 0xB2,
          offset: 0x27,
          dataTypeId: 11,
        ),
        dataType: const UmasDataTypeRef(
          id: 11,
          name: 'STRING',
          byteSize: 16,
        ),
      ));
      umas.debugInjectSymbol(ResolvedSymbol(
        path: 'M_F2_RC_01.q_xMotorBrakeOff',
        variable: const UmasVariable(
          name: 'q_xMotorBrakeOff',
          blockNo: 0xB2,
          offset: 0x26,
          dataTypeId: 1,
        ),
        dataType: const UmasDataTypeRef(
          id: 1,
          name: 'BOOL',
          byteSize: 1,
        ),
      ));
      umas.debugSetProjectCrc(0xCAFEBABE);
      umas.debugSetBlockCrcs(const [0xDEADBEEF]);
      umas.debugSetSessionState(UmasSessionState.paired);

      final members = await umas.readFbInstanceMembers('M_F2_RC_01');

      expect(batchedCalls, equals(1),
          reason: 'must attempt the batched 0x22 first');
      expect(perLeafCalls, greaterThanOrEqualTo(2),
          reason: 'fall-back must issue per-leaf 0x22 reads');
      // The map must include every member whose per-leaf read succeeded.
      expect(members.keys, containsAll(<String>[
        'i_xFwd',
        'q_xMotorBrakeOff',
        'q_sStatus',
      ]));
    });

    test('throws UmasException when the FB root has no members in the '
        'already-primed symbol cache (no implicit browse)', () async {
      // Cache is primed (debugInjectSymbol marks it built), but the
      // requested FB root has no children. We MUST surface a clear
      // operator-facing error here rather than (a) silently returning an
      // empty map or (b) trying to do an implicit browse() — the poll
      // loop catches UmasNotScalarException from the FB root itself,
      // which means the root IS in the cache. If there are no readable
      // members, that's a configuration/PLC problem, not a missing-data
      // one. The error must name the path so operators know which key
      // is broken.
      final umas = UmasClient(
        sendFn: (req) async => ModbusResponseCode.requestSucceed,
      );
      // Inject ONE unrelated symbol so debugInjectSymbol marks the cache
      // built. The lookup for Unknown_FB.<...> finds nothing.
      umas.debugInjectSymbol(ResolvedSymbol(
        path: 'Unrelated_Symbol',
        variable: const UmasVariable(
          name: 'Unrelated_Symbol',
          blockNo: 0,
          offset: 0,
          dataTypeId: 6,
        ),
        dataType: const UmasDataTypeRef(
          id: 6,
          name: 'REAL',
          byteSize: 4,
        ),
      ));
      umas.debugSetProjectCrc(0x0);
      umas.debugSetBlockCrcs(const [0x0]);
      umas.debugSetSessionState(UmasSessionState.paired);

      try {
        await umas.readFbInstanceMembers('Unknown_FB');
        fail('expected UmasException for FB root with no cached members');
      } on UmasException catch (e) {
        expect(e.message, contains('Unknown_FB'));
        expect(e.message.toLowerCase(), contains('member'));
      }
    });
  });

  // ---------------------------------------------------------------------------
  // ModbusDeviceClientAdapter.readUmasVariable — FB fall-back integration
  //
  // When the bound symbol resolves to an FB instance (classIdentifier == 7),
  // readUmasVariable used to bubble UmasNotScalarException out of every poll
  // tick. The fix catches the exception and routes through
  // [UmasClient.readFbInstanceMembers], producing a struct DynamicValue
  // (value: LinkedHashMap<String, DynamicValue>) that FB consumers
  // (FB-DynamicValue widget, Conveyor FB asset) can render directly.
  // ---------------------------------------------------------------------------

  group('ModbusDeviceClientAdapter.readUmasVariable — FB fallback', () {
    UmasClient buildPrimedUmas() {
      final umas = UmasClient(
        sendFn: (req) async {
          if (req is! UmasRequest) {
            return ModbusResponseCode.requestRxFailed;
          }
          // Two BOOLs + one REAL — same layout as the helper happy-path.
          final payload = Uint8List.fromList([
            0x01,
            0x00,
            0x00, 0x00, 0x48, 0x41, // 12.5f LE
          ]);
          req.setFromPduResponse(_buildReadVariableSuccessPdu(payload));
          return ModbusResponseCode.requestSucceed;
        },
      );
      _injectFbAndMembers(umas);
      umas.debugSetProjectCrc(0xCAFEBABE);
      umas.debugSetBlockCrcs(const [0xDEADBEEF]);
      umas.debugSetSessionState(UmasSessionState.paired);
      return umas;
    }

    /// Build a connected wrapper + adapter routed for an FB-bound key.
    ({
      ModbusClientWrapper wrapper,
      ModbusDeviceClientAdapter adapter,
    }) buildAdapterForFb(UmasClient umas) {
      final wrapper = ModbusClientWrapper('mock', 0, 1,
          clientFactory: (h, p, u) => ModbusClientTcp(h,
              serverPort: p,
              unitId: u,
              connectionMode: ModbusConnectionMode.doNotConnect));
      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: const {},
        variableNames: const {'UppiInntokuband': 'M_F2_RC_01'},
        umasEnabled: true,
        serverAlias: 'plc1',
      );
      adapter.debugSetUmasClient(umas);
      return (wrapper: wrapper, adapter: adapter);
    }

    test('catches UmasNotScalarException and emits a struct DynamicValue '
        'with one entry per readable member', () async {
      final umas = buildPrimedUmas();
      final pair = buildAdapterForFb(umas);
      final adapter = pair.adapter;

      try {
        final dv = await adapter.readUmasVariable('UppiInntokuband');
        // Must be a struct DV — isObject true, asObject contains the
        // expected member sub-paths.
        expect(dv.isObject, isTrue,
            reason: 'FB fall-back must produce a struct DynamicValue '
                '(map of {member: value})');
        final asMap = dv.asObject;
        expect(asMap.keys, containsAll(<String>[
          'HMI.p_Stat_xRunningFwd',
          'HMI.p_Stat_xStopped',
          'q_rVelocity',
        ]));
        expect(asMap['HMI.p_Stat_xRunningFwd']!.asBool, isTrue);
        expect(asMap['HMI.p_Stat_xStopped']!.asBool, isFalse);
        expect(asMap['q_rVelocity']!.asDouble, closeTo(12.5, 0.001));
      } finally {
        adapter.dispose();
        pair.wrapper.dispose();
      }
    });

    test('caches the struct DynamicValue and pushes it onto the per-key '
        'BehaviorSubject so subscribers see the FB map', () async {
      final umas = buildPrimedUmas();
      final pair = buildAdapterForFb(umas);
      final adapter = pair.adapter;

      try {
        // subscribe() lazy-emits a one-shot read; assert the subject
        // catches the struct DV via the read path.
        final received = <DynamicValue>[];
        final sub = adapter.subscribe('UppiInntokuband').listen(received.add);
        await adapter.readUmasVariable('UppiInntokuband');
        // Give the synchronous subject add a microtask to flush.
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(received, isNotEmpty,
            reason: 'subject must emit the struct DV from the FB fallback');
        expect(received.last.isObject, isTrue);
        expect(received.last.asObject.keys, contains('q_rVelocity'));

        // Cached: a follow-up read() (sync) returns the same struct shape.
        final cached = adapter.read('UppiInntokuband');
        expect(cached, isNotNull);
        expect(cached!.isObject, isTrue);
      } finally {
        adapter.dispose();
        pair.wrapper.dispose();
      }
    });

    test('scalar binding is unaffected — UmasNotScalarException is NOT '
        'thrown for scalars, so the catch path does NOT engage', () async {
      // Mock send returns a 4-byte REAL = 7.25f.
      final umas = UmasClient(
        sendFn: (req) async {
          if (req is! UmasRequest) {
            return ModbusResponseCode.requestRxFailed;
          }
          // For session-init noise the only PDU we are asked is the read.
          req.setFromPduResponse(_buildReadVariableSuccessPdu(
            // 7.25f little-endian
            Uint8List.fromList([0x00, 0x00, 0xE8, 0x40]),
          ));
          return ModbusResponseCode.requestSucceed;
        },
      );
      umas.debugInjectSymbol(ResolvedSymbol(
        path: 'B_Elevator_F1_A',
        variable: const UmasVariable(
          name: 'B_Elevator_F1_A',
          blockNo: 0x10,
          offset: 0,
          dataTypeId: 6,
        ),
        dataType: const UmasDataTypeRef(
          id: 6,
          name: 'REAL',
          byteSize: 4,
        ),
      ));
      umas.debugSetProjectCrc(0xCAFEBABE);
      umas.debugSetBlockCrcs(const [0xDEADBEEF]);
      umas.debugSetSessionState(UmasSessionState.paired);

      final wrapper = ModbusClientWrapper('mock', 0, 1,
          clientFactory: (h, p, u) => ModbusClientTcp(h,
              serverPort: p,
              unitId: u,
              connectionMode: ModbusConnectionMode.doNotConnect));
      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: const {},
        variableNames: const {'speed': 'B_Elevator_F1_A'},
        umasEnabled: true,
        serverAlias: 'plc1',
      );
      adapter.debugSetUmasClient(umas);

      try {
        final dv = await adapter.readUmasVariable('speed');
        expect(dv.isObject, isFalse,
            reason: 'scalar reads must NOT produce a struct DV');
        expect(dv.asDouble, closeTo(7.25, 0.001));
      } finally {
        adapter.dispose();
        wrapper.dispose();
      }
    });

    test('readFbInstanceMembers errors are surfaced like scalar errors — '
        'caller sees the exception, subject keeps last value (SCADA '
        'semantics)', () async {
      // FB root resolved but fan-out call fails (e.g. transport error).
      // The adapter must NOT crash the poll loop; the exception bubbles
      // to the caller of readUmasVariable so the poll-loop log path
      // handles it. Subscribers retain their last value.
      //
      // backoffDelay short-circuited so the per-leaf fall-back's session
      // recovery doesn't drag the test out for tens of seconds.
      final umas = UmasClient(
        backoffDelay: (_) async {},
        sendFn: (req) async {
          if (req is! UmasRequest) {
            return ModbusResponseCode.requestRxFailed;
          }
          // Transport-level failure on the FB fan-out batched 0x22.
          return ModbusResponseCode.requestTimeout;
        },
      );
      _injectFbAndMembers(umas);
      umas.debugSetProjectCrc(0xCAFEBABE);
      umas.debugSetBlockCrcs(const [0xDEADBEEF]);
      umas.debugSetSessionState(UmasSessionState.paired);

      final wrapper = ModbusClientWrapper('mock', 0, 1,
          clientFactory: (h, p, u) => ModbusClientTcp(h,
              serverPort: p,
              unitId: u,
              connectionMode: ModbusConnectionMode.doNotConnect));
      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: const {},
        variableNames: const {'UppiInntokuband': 'M_F2_RC_01'},
        umasEnabled: true,
        serverAlias: 'plc1',
      );
      adapter.debugSetUmasClient(umas);

      try {
        try {
          await adapter.readUmasVariable('UppiInntokuband');
          fail('expected UmasException to bubble from FB fan-out failure');
        } on UmasException {
          // Expected — fan-out failure surfaces like a scalar read failure,
          // and the existing _pollUmasGroup catch handles it with a warn.
        } catch (e) {
          fail('expected UmasException, got ${e.runtimeType}');
        }
      } finally {
        adapter.dispose();
        wrapper.dispose();
      }
    });

    test('write to an FB-bound key still throws UmasNotScalarException — '
        'writes against FB roots are meaningless and must NOT silently '
        'no-op even with the read-side fall-back in place', () async {
      // Symmetry check: the catch lives in readUmasVariable, NOT in
      // writeUmasVariable. Writing into an FB root has no meaningful
      // semantics ("write the value of the whole FB"), so the symmetric
      // UmasNotScalarException gate in writeVariableByName must keep
      // firing.
      final umas = buildPrimedUmas();
      final pair = buildAdapterForFb(umas);
      final adapter = pair.adapter;

      try {
        try {
          await adapter.writeUmasVariable(
              'UppiInntokuband', DynamicValue(value: 0));
          fail('expected UmasNotScalarException on FB-root write');
        } on UmasNotScalarException catch (e) {
          expect(e.message, contains('M_F2_RC_01'));
        }
      } finally {
        adapter.dispose();
        pair.wrapper.dispose();
      }
    });
  });
}
