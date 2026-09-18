import 'package:jbtm/src/m2400_field_parser.dart';
import 'package:jbtm/src/m2400_fields.dart';
import 'package:open62541/open62541_types.dart'
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
/// **[DynamicValue.sourceTimestamp] is set here, and ONLY from the weigher's
/// own clock.**
///
///  * [M2400ParsedRecord.deviceTimestamp] present -> the **weigher's own
///    clock**, a genuine source instant. Stamped.
///  * absent -> **left null**, deliberately.
///
/// The null branch is the correction Jon ruled on 2026-09-07 after the
/// driver-stamp task measured its own outcome. That task stamped
/// `deviceTimestamp ?? receivedAt`, which fixed the honest half and made the
/// other half indistinguishable from it: [M2400ParsedRecord.receivedAt] is
/// *this process's* clock at the moment the frame was parsed, and a non-null
/// `sourceTimestamp` is read as "the source said so" by everything downstream --
/// `translateOpcUaSample`, `resolveAlarmStamp`, and finally the
/// `alarm_history.ts_source` column, which then said `plant`.
///
/// `package:open62541` states the field's contract in so many words
/// (`dynamic_value.dart:90-97`): *"The instant the SOURCE (the PLC, not this
/// process) says the value was produced, or null when the server sent no source
/// timestamp. Null is deliberate and load-bearing: a consumer that needs an
/// instant must substitute its own arrival time knowingly, and record that it
/// did."* Substituting here is exactly the "knowingly" this file cannot do on
/// the consumer's behalf, because a stamp carries no room to say which of the
/// two clocks it came from.
///
/// **The parse instant is not lost.** It is still the `receivedAt` child field
/// on every record, which is where a consumer that wants it should read it and
/// where nothing can mistake it for the scale's own clock.
///
/// The device instant is not clamped or corrected against the backend's. It is
/// recombined by `extractTimestamp` from zone-less device fields, so it is a
/// *local* `DateTime` and a weigher whose clock is wrong stays wrong here on
/// purpose — `resolveAlarmStamp`'s skew guard is what reports that, and hiding
/// it behind a substitution is the failure this whole change exists to end.
///
/// Every child is stamped exactly as the parent is -- including left null.
/// `M2400ClientWrapper.subscribe` supports dot-notation keys ('BATCH.weight')
/// and hands back the *child* DynamicValue, so a parent-only rule would leave
/// every dotted key in the key mapping disagreeing with its own parent about
/// where its instant came from.
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

  // The device's own clock, or nothing at all. NOT `?? record.receivedAt`:
  // that is this process's clock and there is no way to say so in this field.
  // See the doc above.
  final sourceTimestamp = record.deviceTimestamp;
  parent.sourceTimestamp = sourceTimestamp;
  final children = parent.value;
  if (children is Map) {
    for (final child in children.values) {
      if (child is DynamicValue) child.sourceTimestamp = sourceTimestamp;
    }
  }

  return parent;
}
