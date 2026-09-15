/// Keymappings in the two shapes this repository actually holds.
///
/// **The repository holds two naming conventions on purpose, and a router that
/// works for only one of them is broken in production or broken in the suite.**
///
///  * The **live plant file** (`svn-key-mappings.json`, 430 entries) is
///    `Line1.Motor1` / `weigher1v.weight`. It is the single-server era's file:
///    the `server_alias` field is **null on every OPC UA entry**, resolved by
///    `_getClientWrapper` finding the wrapper whose `config.serverAlias` is
///    also null (`packages/tfc_dart/lib/core/state_man.dart:1670-1679`). That
///    null is a real shipped value, not a placeholder somebody forgot to fill
///    in, and a router that assumes a non-null alias fails on the first key of
///    the first plant it meets.
///  * The **contract kit** speaks `AREAnn.DEVnn.SUBnn` — root `ST101`, folder
///    `ST101.CN01.MOT01`, children `.speed` / `.running` / `.reset`
///    (`browse_contract.dart:110-123`) — which is the convention the new
///    installations use, with a named alias per PLC.
///
/// Both are here, and every routing case that matters is written against both.
///
/// The two live entries below are **verbatim** from the measured file
/// (08-PATTERNS §2), transcribed into the model rather than re-imagined:
///
/// ```json
/// "Line1.Motor1": {"opcua_node": {"namespace": 4,
///   "identifier": "GVL_BatchLines.Drives_Line1[1].HMI",
///   "array_index": null, "server_alias": null}, …}
///
/// "weigher1v.weight": {"opcua_node": null,
///   "m2400_node": {"record_type": "recStat", "field": "weight",
///     "server_alias": "weigher1v", "status_filter": null}, …}
/// ```
///
/// The model is `tfc_dart`'s, deliberately: `KeyMappings`, `KeyMappingEntry`,
/// `OpcUANodeConfig`, `M2400NodeConfig` and `ModbusNodeConfig` are what the
/// live file deserializes into and what the page editor writes. A parallel
/// model in this package would be a second migration path for every future
/// field.
library;

import 'package:jbtm/jbtm.dart' show M2400Field, M2400RecordType;
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/state_man.dart';

// ------------------------------------------------------- the live file's keys

/// An OPC UA drive struct on the unnamed server — the shape 430 live entries
/// share.
const String liveOpcUaKey = 'Line1.Motor1';

/// An M2400 weigher field on a *named* alias. The weighers are the one part of
/// the live file that carries a `server_alias`.
const String liveM2400Key = 'weigher1v.weight';

/// A classic-Modbus register.
const String liveModbusKey = 'Line1.Blower1.running';

/// A UMAS symbol, read by `variable_name` rather than by register address —
/// Schneider PLCs only expose `%MW`-located variables on the FC03 map.
const String liveUmasKey = 'Elevator.isAuto';

/// The alias the weighers are configured under.
const String weigherAlias = 'weigher1v';

/// The alias the Modbus PLC is configured under.
const String modbusAlias = 'plc-modbus';

/// The alias the UMAS PLC is configured under.
const String umasAlias = 'umas-elevator';

// -------------------------------------------------- the contract kit's keys

/// `AREAnn.DEVnn.SUBnn`, ST101 — the convention the contract fixture speaks.
const String st101Key = 'ST101.CN01.MOT01.speed';

/// The same shape on the second PLC. CN01–CN20 are before the freezer.
const String st201Key = 'ST201.CN04.MOT01.speed';

/// The alias for the first PLC.
const String st101Alias = 'st101';

/// The alias for the second PLC.
const String st201Alias = 'st201';

// --------------------------------------------------------------- the builders

/// The live plant file's shape: four entries, one per protocol the gateway
/// speaks, with `server_alias` null on the OPC UA one.
KeyMappings livePlantKeyMappings() => KeyMappings(nodes: {
      liveOpcUaKey: KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(
          namespace: 4,
          identifier: 'GVL_BatchLines.Drives_Line1[1].HMI',
        )
          // Both explicit, because both are the point of this fixture: the
          // live file writes them as JSON null and the router has to route
          // them anyway.
          ..arrayIndex = null
          ..serverAlias = null,
        collect: CollectEntry(
          key: liveOpcUaKey,
          name: liveOpcUaKey,
          sampleInterval: const Duration(seconds: 5),
        ),
      ),
      liveM2400Key: KeyMappingEntry(
        m2400Node: M2400NodeConfig(
          recordType: M2400RecordType.recStat,
          field: M2400Field.weight,
          serverAlias: weigherAlias,
        ),
        collect: CollectEntry(
          key: liveM2400Key,
          name: liveM2400Key,
          sampleInterval: const Duration(seconds: 5),
        ),
      ),
      liveModbusKey: KeyMappingEntry(
        modbusNode: ModbusNodeConfig(
          serverAlias: modbusAlias,
          registerType: ModbusRegisterType.holdingRegister,
          address: 100,
        ),
      ),
      liveUmasKey: KeyMappingEntry(
        modbusNode: ModbusNodeConfig(
          serverAlias: umasAlias,
          registerType: ModbusRegisterType.holdingRegister,
          address: 101,
        ),
        variableName: 'M_Elevator.i_isAuto',
      ),
    });

/// The `AREAnn.DEVnn.SUBnn` shape, one named alias per PLC.
///
/// One entry carries `sample_members`, because a struct the HMI binds to whole
/// while the timeseries keeps three of its members is the ordinary case at this
/// plant and the shape the lifted `extractSampleMembers` is written for.
KeyMappings contractKitKeyMappings() => KeyMappings(nodes: {
      st101Key: KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(
          namespace: 2,
          identifier: 'GVL.ST101.CN01.MOT01',
        )..serverAlias = st101Alias,
        collect: CollectEntry(
          key: st101Key,
          name: st101Key,
          sampleInterval: const Duration(seconds: 5),
          sampleMembers: const ['p_stat_xOutput', 'p_stat_tBlockedFor'],
        ),
      ),
      st201Key: KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(
          namespace: 2,
          identifier: 'GVL.ST201.CN04.MOT01',
        )..serverAlias = st201Alias,
      ),
    });

/// [count] generated OPC UA entries on [alias], named in the live convention.
///
/// Exists so "the rest of the file loads" can be asserted at a size a
/// hand-written fixture cannot reach: the live file is 430 entries and the
/// files this gateway will be pointed at run to 1,500. Three entries proving
/// per-key rejection prove nothing about a file.
KeyMappings generatedKeyMappings(int count, {String? alias}) =>
    KeyMappings(nodes: {
      for (var i = 0; i < count; i++)
        'Line$i.Motor1': KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(
            namespace: 4,
            identifier: 'GVL_BatchLines.Drives_Line$i[1].HMI',
          )..serverAlias = alias,
        ),
    });

/// One OPC UA entry on [alias], for the arms that need a single named key.
KeyMappingEntry opcUaEntry({String? alias, String identifier = 'GVL.Tag'}) =>
    KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 4, identifier: identifier)
        ..serverAlias = alias,
    );

/// A `KeyMappings` built from [keys], every entry on [alias].
KeyMappings keyMappingsOf(Iterable<String> keys, {String? alias}) =>
    KeyMappings(nodes: {
      for (final key in keys) key: opcUaEntry(alias: alias, identifier: key),
    });
