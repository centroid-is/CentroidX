/// **What type does a write carry into the plant?**
///
/// The OPC UA write service takes a `Variant`, and a Variant without a type is
/// not a value — it is a hole. The binding says so twice: `valueToVariant`
/// (`common.dart:112`) throws `Unable to determine type for …` when the
/// `DynamicValue` has no `typeId`, and the serializer under it
/// (`opcua_serializer.dart:331-335`) can auto-deduce only `bool` and `String`,
/// throwing for `int` and for `double` alike. So a gateway that hands the
/// binding an untyped value has not made a risky write — it has made **no
/// write**, and the operator is told `unknown`.
///
/// `unknown` is the right answer for a write whose fate nobody knows, and it is
/// the milestone's contract. It is the WRONG answer here: nothing was sent, the
/// reason is entirely inside this process, and an operator who correctly does
/// not retry an `unknown` has just had a Start command silently dropped.
///
/// Two claims, and both are per-type rather than by example:
///
///  1. **Every scalar type the plant writes reaches the server**, with the
///     value intact — bool, double, int, String, across the OPC UA numeric
///     widths a TwinCAT program actually declares (BOOL, REAL, LREAL, INT,
///     DINT, LINT, UINT, UDINT, BYTE, STRING).
///  2. **A write that cannot be represented in the tag's type is REJECTED, not
///     truncated.** `rejected` is the claim that needs evidence and it has it:
///     nothing was sent. A silently narrowed integer is the failure this file
///     exists to make impossible, because the server would answer Good.
///
/// `@TestOn('!windows')` and `@Tags(['opcua'])` for `opcua_link_test.dart:1-9`'s
/// reason: the CI matrix includes `windows-latest` and an in-process open62541
/// `Server` is not run there.
@TestOn('!windows')
@Tags(['opcua'])
library;

import 'package:open62541/open62541.dart' as ua;
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

import 'support/opcua_server_fixture.dart';

const String alias = 'ST101';
const Duration generous = Duration(seconds: 10);

/// A cmd of the shape the composer mints.
const String cmd = '01J0000000000000000000000W';

KeyMappingEntry mappingFor(String key) {
  final node = OpcUANodeConfig(namespace: fixtureNamespace, identifier: key)
    ..serverAlias = alias;
  return KeyMappingEntry()..opcuaNode = node;
}

/// One type the plant declares, the Dart value that reaches this gateway for
/// it, and what the server must end up holding.
///
/// `sent` and `expected` are separate fields on purpose: a `Float` tag written
/// 1.5 comes back 1.5, but written 0.1 comes back the nearest float, and a case
/// that could not say so would either skip the interesting types or assert a
/// lie.
typedef TypeCase = ({
  String label,
  ua.NodeId typeId,
  Object seed,
  Object sent,
  Object expected,
});

/// The scalar types SVN's PLCs actually expose, in IEC-61131 spelling.
///
/// Deliberately NOT "one int and one double": the defect this file was written
/// against typed every `int` as `Int32`, which is correct for exactly one of
/// the six integer rows below and wrong for the other five.
final List<TypeCase> typeMatrix = <TypeCase>[
  (
    label: 'BOOL → Boolean',
    typeId: _boolean,
    seed: false,
    sent: true,
    expected: true
  ),
  (
    label: 'REAL → Float',
    typeId: _float,
    seed: 0.0,
    sent: 1.5,
    expected: 1.5
  ),
  (
    label: 'LREAL → Double',
    typeId: _double,
    seed: 0.0,
    sent: 12.25,
    expected: 12.25
  ),
  (label: 'INT → Int16', typeId: _int16, seed: 0, sent: -3, expected: -3),
  (label: 'DINT → Int32', typeId: _int32, seed: 0, sent: 70000, expected: 70000),
  (
    label: 'LINT → Int64',
    typeId: _int64,
    seed: 0,
    // Above 2^31: the number an Int32-shaped write cannot carry, and the one
    // the old code would have narrowed.
    sent: 5000000000,
    expected: 5000000000
  ),
  (label: 'UINT → UInt16', typeId: _uint16, seed: 0, sent: 65535, expected: 65535),
  (
    label: 'UDINT → UInt32',
    typeId: _uint32,
    seed: 0,
    // Above 2^31-1, so an Int32 variant carrying it is a negative number.
    sent: 3000000000,
    expected: 3000000000
  ),
  (label: 'BYTE → Byte', typeId: _byte, seed: 0, sent: 200, expected: 200),
  (
    label: 'STRING → String',
    typeId: _uastring,
    seed: '',
    // Icelandic, because the plant's strings are (CLAUDE.md's wire hazards).
    sent: 'þristur',
    expected: 'þristur'
  ),
];

// `NodeId` getters are not const, and a const list cannot call them. These
// are the same values, resolved once.
final ua.NodeId _boolean = ua.NodeId.boolean;
final ua.NodeId _float = ua.NodeId.float;
final ua.NodeId _double = ua.NodeId.double;
final ua.NodeId _int16 = ua.NodeId.int16;
final ua.NodeId _int32 = ua.NodeId.int32;
final ua.NodeId _int64 = ua.NodeId.int64;
final ua.NodeId _uint16 = ua.NodeId.uint16;
final ua.NodeId _uint32 = ua.NodeId.uint32;
final ua.NodeId _byte = ua.NodeId.byte;
final ua.NodeId _uastring = ua.NodeId.uastring;

String keyFor(TypeCase c) =>
    'ST101.CN01.MOT01.${c.typeId.numeric}';

Future<void> awaitConnected(OpcUaUpstreamLink link,
    {Duration within = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(within);
  while (link.state != UpstreamLinkState.connected) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the link never reached connected; it is ${link.state}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  arrayElementGroup();

  late OpcUaServerFixture fixture;
  late OpcUaUpstreamLink link;

  setUp(() async {
    fixture = await OpcUaServerFixture.start(
      typedWriteKeys: <String, ua.DynamicValue>{
        for (final c in typeMatrix)
          keyFor(c): ua.DynamicValue(
              value: c.seed, typeId: c.typeId, name: keyFor(c)),
      },
    );
    addTearDown(fixture.dispose);
    link = OpcUaUpstreamLink(
      alias: alias,
      endpoint: fixture.endpoint,
      useIsolate: false,
    );
    addTearDown(link.dispose);
    await link.connect(deadline: generous);
    await awaitConnected(link);
  });

  group('every type the plant writes actually leaves the gateway', () {
    for (final c in typeMatrix) {
      test(c.label, () async {
        final key = keyFor(c);
        final ref = link.resolve(key, mappingFor(key))!;

        final result = await link.write(
          ref,
          DynamicValue(
              value: c.sent,
              quality: Quality.good,
              sourceTime: DateTime.now().toUtc()),
          cmd: cmd,
          deadline: generous,
        );

        expect(result, isA<WriteApplied>(),
            reason: 'the write must reach the server. An `unknown` here is not '
                'an ambiguous plant — it is this gateway failing to type its '
                'own Variant, and an operator who correctly does not retry an '
                '`unknown` has had a ${c.label} write silently dropped');
        expect(fixture.writeCount(key), 1,
            reason: 'exactly one crossing into the plant, and it happened');
        expect(fixture.writeLog(key).single.value, c.expected,
            reason: 'the server must hold what the operator typed, in the '
                "tag's own type — a value that arrived narrowed or widened is "
                'a confidently wrong write, which is worse than none');
      });
    }
  });

  group('the tag is asked its type once per key per epoch, and no more', () {
    // The cost argument against reading the tag's own DataType, measured. It
    // is a real round trip and it happens once; a number that tracked the
    // write count would mean a per-write round trip on the plant's hot path.
    final target = typeMatrix[4]; // DINT

    Future<WriteResult> writeOnce(UpstreamRef ref, Object v) => link.write(
          ref,
          DynamicValue(
              value: v,
              quality: Quality.good,
              sourceTime: DateTime.now().toUtc()),
          cmd: cmd,
          deadline: generous,
        );

    test('ten writes to one key cost one DataType read', () async {
      final key = keyFor(target);
      final ref = link.resolve(key, mappingFor(key))!;
      for (var i = 0; i < 10; i++) {
        expect(await writeOnce(ref, i), isA<WriteApplied>());
      }
      expect(link.writeTypeReads, 1,
          reason: 'a DataType cannot change while the address space stands, so '
              'asking again is asking a PLC a question it already answered');
      expect(fixture.writeCount(key), 10);
    });

    test('a subscribed key costs ZERO — the decode probe already asked',
        () async {
      final key = keyFor(target);
      final ref = link.resolve(key, mappingFor(key))!;
      // One sample proves the monitored item is up, which means the probe that
      // rides beside it has completed.
      await link.subscribe(ref).first;
      expect(await writeOnce(ref, 7), isA<WriteApplied>());
      expect(link.writeTypeReads, 0,
          reason: '`client.read` fetches the DataType attribute alongside the '
              'value, so the probe hands the write path the answer for free');
    });

    test('a new epoch asks again, because a download can change the type',
        () async {
      final key = keyFor(target);
      expect(await writeOnce(link.resolve(key, mappingFor(key))!, 1),
          isA<WriteApplied>());
      expect(link.writeTypeReads, 1);

      link.debugBumpEpoch();
      // The bump makes every outstanding handle stale, so the key is
      // re-resolved exactly as a composer would after a `reprogrammed`.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await writeOnce(link.resolve(key, mappingFor(key))!, 2),
          isA<WriteApplied>());

      expect(link.writeTypeReads, 2,
          reason: 'a reprogram is the one moment a tag genuinely can change '
              "type, and a cache that outlived it would type the plant's new "
              'address space from the old one');
    });
  });

  group('a value the tag cannot hold is rejected, never narrowed', () {
    // Each row: the tag, and a value outside its range. The server would
    // answer Good to every one of these if the gateway narrowed them first,
    // which is exactly why the refusal has to happen before the crossing.
    final overflows = <({String label, TypeCase target, Object sent})>[
      (
        label: 'INT (Int16) cannot hold 40000',
        target: typeMatrix[3],
        sent: 40000
      ),
      (
        label: 'BYTE cannot hold 300',
        target: typeMatrix[8],
        sent: 300
      ),
      (
        label: 'BYTE cannot hold -1',
        target: typeMatrix[8],
        sent: -1
      ),
      (
        label: 'UDINT (UInt32) cannot hold -5',
        target: typeMatrix[7],
        sent: -5
      ),
      (
        label: 'DINT (Int32) cannot hold 5000000000',
        target: typeMatrix[4],
        sent: 5000000000
      ),
    ];

    for (final o in overflows) {
      test(o.label, () async {
        final key = keyFor(o.target);
        final ref = link.resolve(key, mappingFor(key))!;

        final result = await link.write(
          ref,
          DynamicValue(
              value: o.sent,
              quality: Quality.good,
              sourceTime: DateTime.now().toUtc()),
          cmd: cmd,
          deadline: generous,
        );

        expect(result, isA<WriteRejected>(),
            reason: 'rejected is the claim that needs evidence and it has it: '
                'nothing was sent. `unknown` would tell the operator to worry '
                'about a write that never happened, and `applied` would be a '
                'lie about a number the tag cannot represent');
        expect(fixture.writeCount(key), 0,
            reason: 'the refusal must happen BEFORE the crossing — a server '
                'that silently narrows answers Good, and then nothing '
                'downstream can tell the operator the number changed');
      });
    }
  });
}

/// The read-modify-write path, which was never *untyped* and truncates anyway.
///
/// `DynamicValue.operator []=` inherits the existing element's typeId
/// (`dynamic_value.dart:226`), so an element write always carried a type — the
/// server's own. That is right, and it is not enough: an `Int32` element with a
/// 5000000000 in front of it narrows to 705032704 and the server answers Good,
/// which is the same silently-wrong applied write the scalar path had. Reachable
/// only with `expect` supplied (`guardArrayElementWrite`), which is a smaller
/// door rather than a closed one.
void arrayElementGroup() {
  group('an element write is typed and range-checked like a scalar one', () {
    const arrayKey = 'plant.iData';
    late OpcUaServerFixture fixture;
    late OpcUaUpstreamLink link;

    setUp(() async {
      fixture = await OpcUaServerFixture.start(
        valueKeys: <String>[arrayKey],
        // Born an Int32 array: a scalar-seeded node coerces the write to a
        // scalar (the fixture's seedValues doc), and the element type is the
        // whole subject here.
        seedValues: <String, Object?>{
          arrayKey: ua.DynamicValue.fromList(<int>[1, 2, 3],
              typeId: ua.NodeId.int32, name: arrayKey),
        },
      );
      addTearDown(fixture.dispose);
      link = OpcUaUpstreamLink(
          alias: alias, endpoint: fixture.endpoint, useIsolate: false);
      addTearDown(link.dispose);
      await link.connect(deadline: generous);
      await awaitConnected(link);
    });

    KeyMappingEntry elementMapping(int at) {
      final node =
          OpcUANodeConfig(namespace: fixtureNamespace, identifier: arrayKey)
            ..serverAlias = alias
            ..arrayIndex = at;
      return KeyMappingEntry()..opcuaNode = node;
    }

    Future<WriteResult> writeElement(int at, Object v) => link.write(
          link.resolve(arrayKey, elementMapping(at))!,
          DynamicValue(
              value: v,
              quality: Quality.good,
              sourceTime: DateTime.now().toUtc()),
          cmd: cmd,
          deadline: generous,
          // The guard only steps aside with expect; without it there is no
          // element write to judge.
          hasExpect: true,
        );

    test('an in-range element write still lands, and spares its neighbours',
        () async {
      expect(await writeElement(1, 42), isA<WriteApplied>());
      final whole = await link.read(
          link.resolve(arrayKey, mappingFor(arrayKey))!,
          deadline: generous);
      expect(<Object?>[whole[0].value, whole[1].value, whole[2].value],
          <Object?>[1, 42, 3],
          reason: 'read-modify-write, unchanged: one element moves and two do '
              'not');
    });

    test('a value the ELEMENT type cannot hold is rejected, not narrowed',
        () async {
      final result = await writeElement(1, 5000000000);
      expect(result, isA<WriteRejected>(),
          reason: 'an Int32 element with 5000000000 in front of it narrows to '
              '705032704 and the server answers Good — the same silently '
              'wrong applied write the scalar path had, one door along');
      final whole = await link.read(
          link.resolve(arrayKey, mappingFor(arrayKey))!,
          deadline: generous);
      expect(<Object?>[whole[0].value, whole[1].value, whole[2].value],
          <Object?>[1, 2, 3],
          reason: 'nothing was written, so the array still holds what it held');
    });
  });
}
