/// The weigher [UpstreamLink]: read-only by protocol, and the clearest case
/// this project has for existing at all.
///
/// **Why the smallest adapter matters most.** `M2400DeviceClientAdapter` is
/// fifty-five lines (`state_man.dart:1235-1302`). The device behind it accepts
/// **exactly one TCP client** — which is why `M2400Proxy` exists in `jbtm`, and
/// why the plant runs eight weighers on 10.104.29.71–78 with one connection
/// each to share out. Everything else in this repository can be argued as an
/// optimisation; this one cannot. The gateway is the one process that talks to
/// the weigher, and every panel reads it through the pipe. A panel that opens
/// its own socket does not get a slow read — it takes somebody else's.
///
/// ## Read-only is a refusal, never a throw
///
/// `M2400DeviceClientAdapter.write` throws `UnsupportedError`
/// (`state_man.dart:1266-1268`), and `state_man_api.dart:114-117` names that
/// throw as what not to copy. The distinction is not pedantry: a throw on the
/// write path reads to the operator as *"the write failed"*, and a refusal to
/// try is the one thing that proves nothing about the plant. So the answer is a
/// [WriteRejected] carrying [notWritableReason] — the same object the cert
/// overlay's refusal uses (`cert_health_state_man.dart:411-424`), so that the
/// gateway has **one spelling** of `Bad_NotWritable` rather than two that an
/// operator would have to tell apart.
///
/// The refusal happens in [DeviceClientUpstreamLink.write]'s
/// `supportsWrites` short-circuit, which is *above* `performWrite`, so the
/// throwing adapter method is never reached. That is deliberate and is why
/// there is no `try` around it: the safe behaviour comes from not calling it,
/// not from catching it.
library;

import 'package:jbtm/jbtm.dart' show M2400RecordType;
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'modbus_upstream_link.dart';
import 'upstream_link.dart';
import 'value_shaping.dart';
import 'write_translation.dart';

/// The wrapper's four subscribe keys, by record type.
///
/// Lifted from `state_man.dart:1745-1765`'s switch rather than re-derived: the
/// wrapper validates against exactly this set (`m2400_client_wrapper.dart:73`)
/// and throws `ArgumentError` for anything else, so a fifth spelling invented
/// here would be an exception on the subscribe path rather than a missing key.
const Map<M2400RecordType, String> m2400RecordKeys = <M2400RecordType, String>{
  M2400RecordType.recBatch: 'BATCH',
  M2400RecordType.recStat: 'STAT',
  M2400RecordType.recIntro: 'INTRO',
  M2400RecordType.recLua: 'LUA',
};

/// One configured M2400 weigher, behind the gateway's uniform surface.
class M2400UpstreamLink extends DeviceClientUpstreamLink {
  M2400UpstreamLink({
    required super.alias,
    required super.client,
    super.answersTo,
    super.health,
    super.staleAfter,
  }) : super(supportsWrites: false, supportsBrowse: false);

  /// The wrapper's record key per claimed gateway key.
  ///
  /// **Always the whole record, never `RECORD.field`.** The shipped code picks
  /// between the two depending on whether a `status_filter` is configured
  /// (`state_man.dart:1770-1772`), which means the same key subscribes to two
  /// different streams depending on a field it is not about. Here the record
  /// always arrives whole and [shapeSample] does the filtering and the
  /// extraction in one place, which is also the only shape that can tell "the
  /// status did not match" (no value) from "the field is not in the record"
  /// (a configuration error).
  final Map<String, String> _recordKeys = <String, String>{};
  final Map<String, int?> _statusFilters = <String, int?>{};
  final Map<String, String?> _fields = <String, String?>{};

  @override
  Object? claim(String key, KeyMappingEntry entry) {
    final node = entry.m2400Node;
    if (node == null) return null;
    // The adapter checks its own alias — 08-04's handoff. Eight weighers on one
    // plant is exactly the topology where a link that claims anything
    // M2400-shaped takes weigher3's key, and the router cannot see it because
    // the two links have different aliases. `_resolveM2400Key`
    // (`state_man.dart:1774-1783`) already does this and this is why.
    // Against `answersTo`, not `alias`: the live plant file spells the
    // unnamed server, which the name can never be (RIG-TEST-FINDINGS.md F1).
    if (StateManConfig.normalizeAlias(node.serverAlias) !=
        StateManConfig.normalizeAlias(answersTo)) {
      return null;
    }
    final recordKey = m2400RecordKeys[node.recordType];
    // `recWgt` and `unknown` have no stream on the wrapper. Null rather than a
    // throw, so a mapping naming one falls through to the next link and then to
    // the router's own "no link claims this key" answer, which names the key.
    if (recordKey == null) return null;
    _recordKeys[key] = recordKey;
    _statusFilters[key] = node.statusFilter;
    _fields[key] = node.field?.name;
    return '$recordKey.${node.field?.name ?? '*'}'
        '${node.statusFilter == null ? '' : '@${node.statusFilter}'}';
  }

  @override
  String upstreamKeyFor(UpstreamRef ref) => _recordKeys[ref.key] ?? ref.key;

  /// The status filter and the field extraction, in the lifted transform.
  ///
  /// [applyM2400Shaping] is `state_man.dart:2064-2073` and `:1819-1827` moved
  /// into one pure function by 08-04, and using it here rather than
  /// re-implementing the two `where`/`map` steps is the point of having lifted
  /// it. Its three outcomes are the three this link needs:
  ///
  ///  * **null** — the record failed its `status_filter`. Not this key's
  ///    weighing, so no value at all.
  ///  * **[Quality.errorConfig]** — the record does not carry the configured
  ///    field, or carries no `status` to filter on. The mapping and the device
  ///    disagree, and waiting will not fix it.
  ///  * **the field, carrying the record's quality** — worst-wins, through
  ///    `DynamicValue`'s own composition rather than a hand-rolled max.
  @override
  DynamicValue? shapeSample(String key, DynamicValue value) =>
      applyM2400Shaping(value,
          statusFilter: _statusFilters[key], field: _fields[key]);

  /// [UpstreamProtocol.m2400], whose translation is an unconditional refusal.
  ///
  /// Belt and braces on purpose: `supportsWrites` is false, so
  /// [DeviceClientUpstreamLink.write] refuses before it consults this. If a
  /// future constructor ever let a weigher be marked writable,
  /// `translateWriteAnswer`'s M2400 short-circuit still refuses — and it does
  /// so even for an *acknowledgement*, because a device with no write service
  /// cannot have applied one, and an "ack" from that direction is a bug in an
  /// adapter rather than news about a plant.
  @override
  UpstreamProtocol protocolFor(UpstreamRef ref) => UpstreamProtocol.m2400;

  /// Forces a new epoch, for the cases that need a stale handle without a
  /// device swap.
  ///
  /// **A lever, and named so**, exactly as the OPC UA link's is. The weigher's
  /// real epoch input is the `INTRO` record's device id and firmware, which the
  /// stub already emits on connect and which every real M2400 sends unasked —
  /// wiring it is 08-08's shape of work and is recorded as a follow-up rather
  /// than smuggled in here.
  void debugBumpEpoch() =>
      bumpEpochTo('e1:m2400-${DateTime.now().microsecondsSinceEpoch}');
}
