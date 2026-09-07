import 'package:jbtm/src/m2400_field_parser.dart';
import 'package:jbtm/src/m2400_fields.dart';
import 'package:open62541/open62541.dart'
    show DynamicValue, EnumField, LocalizedText;

/// Pre-built enum field map for WeigherStatus values.
///
/// Maps each [WeigherStatus] code to an [EnumField] with display name.
/// Attached to status-type child DynamicValues so consumers can resolve
/// the integer code to a human-readable label.
final Map<int, EnumField> _statusEnumFields = {
  for (final ws in WeigherStatus.values)
    ws.code: EnumField(
      ws.code,
      ws.name,
      LocalizedText(ws.displayName, ''),
      LocalizedText('', ''),
    ),
};

/// Whether a field represents weigher status and should carry enum metadata.
bool _isStatusField(M2400Field field) =>
    field == M2400Field.status || field == M2400Field.weighingStatus;

/// Convert an [M2400ParsedRecord] into a [DynamicValue] object tree.
///
/// The returned DynamicValue is a structured object (LinkedHashMap) with:
/// - One child per known typed field, keyed by the [M2400Field] enum name
///   (e.g., 'weight', 'unit', 'siWeight', 'field6')
/// - One child per unknown field, keyed by numeric ID string (e.g., '99')
/// - 'receivedAt' child with an **int**: microseconds since the Unix epoch
/// - 'deviceTimestamp' child with an **int**: microseconds since the Unix
///   epoch (only if non-null)
///
/// Both timestamps were ISO 8601 strings until #99 ("perf: reduce CPU usage
/// across paint pipeline"), which switched them to ints to cut string
/// allocation on the hot acquisition path. The doc here said "ISO 8601
/// string" for five months after that; if you are reading rows written before
/// #99 out of the collector's `jsonb` value column, expect strings there and
/// ints after.
///
/// Note the two are not equally well defined. [M2400ParsedRecord.receivedAt]
/// comes from `DateTime.timestamp()` and is UTC, so its epoch value is
/// unambiguous. [M2400ParsedRecord.deviceTimestamp] is recombined by
/// `extractTimestamp` from the device's date/time fields, which carry no zone,
/// so it is a **local** `DateTime` — converting it to epoch microseconds bakes
/// in the *host's* UTC offset. That is correct on the SVN stations (Iceland is
/// UTC+0 year round, no DST) and would shift on a host in another zone.
///
/// Status fields ([M2400Field.status], [M2400Field.weighingStatus]) have
/// their [DynamicValue.enumFields] populated with [WeigherStatus] entries.
///
/// **[DynamicValue.sourceTimestamp] is set here, and which clock it came from
/// depends on the record.** The backend's value path substitutes its own
/// arrival instant for any value that reaches it unstamped, and then labels the
/// alarm row `ts_source='plant'` regardless — so leaving this null makes the
/// weigher fleet report a backend receipt as plant time. Of the two protocols
/// that were doing that, the M2400 is the one with a real device instant, so it
/// is used:
///
///  * [M2400ParsedRecord.deviceTimestamp] present -> the **weigher's own
///    clock**. This is a genuine source instant.
///  * absent -> [M2400ParsedRecord.receivedAt], the **backend's** clock at the
///    moment the frame was parsed. A weigher that stops sending its date/time
///    fields must not silently start reporting a backend clock as a device
///    clock, so note that this branch is the approximation: it is one socket
///    read away from the wire, not one weighment away from the scale.
///
/// The device instant is not clamped or corrected against the backend's. It is
/// recombined by `extractTimestamp` from zone-less device fields, so it is a
/// *local* `DateTime` and a weigher whose clock is wrong stays wrong here on
/// purpose — `resolveAlarmStamp`'s skew guard is what reports that, and hiding
/// it behind a substitution is the failure this whole change exists to end.
///
/// Every child is stamped with the same instant as the parent.
/// `M2400ClientWrapper.subscribe` supports dot-notation keys ('BATCH.weight')
/// and hands back the *child* DynamicValue, so a parent-only stamp would leave
/// every dotted key in the key mapping unstamped and the substitution still
/// firing for all of them.
DynamicValue convertRecordToDynamicValue(M2400ParsedRecord record) {
  final parent = DynamicValue(name: record.type.name);

  // Add typed fields
  for (final entry in record.typedFields.entries) {
    final field = entry.key;
    final value = entry.value;
    final child = DynamicValue(value: value, name: field.displayName);

    if (_isStatusField(field)) {
      child.enumFields = _statusEnumFields;
    }

    parent[field.name] = child;
  }

  // Add unknown fields as string children
  for (final entry in record.unknownFields.entries) {
    parent[entry.key.toString()] = DynamicValue(value: entry.value);
  }

  // Add metadata timestamps as microseconds (avoids string allocation)
  parent['receivedAt'] =
      DynamicValue(value: record.receivedAt.microsecondsSinceEpoch);

  if (record.deviceTimestamp != null) {
    parent['deviceTimestamp'] =
        DynamicValue(value: record.deviceTimestamp!.microsecondsSinceEpoch);
  }

  // The device's own clock when it sent one; the backend's parse instant when
  // it did not. See the doc above for why the two are not interchangeable.
  final sourceTimestamp = record.deviceTimestamp ?? record.receivedAt;
  parent.sourceTimestamp = sourceTimestamp;
  final children = parent.value;
  if (children is Map) {
    for (final child in children.values) {
      if (child is DynamicValue) child.sourceTimestamp = sourceTimestamp;
    }
  }

  return parent;
}
