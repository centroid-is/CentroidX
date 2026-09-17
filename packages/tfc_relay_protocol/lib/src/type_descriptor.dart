/// What a value's **type** says beyond its JSON shape — the OPC UA metadata
/// a panel reads names off — carried **once per type**, never per sample.
///
/// ## The defect this closes (2026-09-17)
///
/// A conveyor's colour is `readDriveState`: read `p_stat_RunMode`, look its
/// integer up in the member's `enumFields`, switch on the name. On a station
/// the enum table rides on every `open62541` value, straight from the server's
/// DataTypeDefinition. Over the relay a value is slim JSON — `{"v": 2}` — and
/// the table was dropped at the worker edge (`translateOpcUaSample` keeps
/// value, quality and time and nothing else), so every browser resolved every
/// enum to *unknown* and every conveyor was purple, whatever its link did.
/// The same shape as the asset-registry bug: a station has metadata the
/// browser silently does not.
///
/// ## Why a dictionary per type, and not the table per value
///
/// The table belongs to the **type** (the FD struct, the RunMode enum), and a
/// plant has dozens of types under a thousand keys. Shipping it with each
/// sample would multiply every update by the size of the enum vocabulary;
/// shipping it once per subscribe, keyed by the type id the value already
/// carries (`sourceTypeId`), costs a few kilobytes at establishment and
/// nothing after. The value stays slim; the panel attaches the descriptor
/// when it rebuilds its `open62541` object graph.
///
/// ## What travels
///
/// [ua] is the OPC UA data type node id in its textual form
/// (`ns=4;i=3012`), the same string `sourceTypeId` carries, so a write can
/// still name the type the plant expects. [enumFields] is the enum table for
/// a scalar enum. [displayName] and [description] are the type's own. For a
/// struct, [members] describes each field by name — a field's enum table,
/// its display name — and for an array [element] describes one element.
/// Only types with at least one enum table somewhere in them are ever
/// described ([hasEnum]); a plain struct of numbers and booleans has nothing
/// a panel cannot already read off the value.
///
/// Everything is optional and decoding is forgiving: a descriptor a newer
/// gateway adds a field to still decodes, and a malformed member costs that
/// member, not the type — the same containment rule the snapshot has.
library;

import 'dynamic_value.dart' show EnumField, LocalizedText;

/// One type's metadata. See the library doc.
final class TypeDescriptor {
  const TypeDescriptor({
    this.ua,
    this.enumFields,
    this.displayName,
    this.description,
    this.members = const <String, TypeDescriptor>{},
    this.element,
  });

  /// The OPC UA data type node id, textual (`ns=4;i=3012`), or null.
  final String? ua;

  /// The enum table, for a scalar whose type is an enumeration.
  final Map<int, EnumField>? enumFields;

  final LocalizedText? displayName;
  final LocalizedText? description;

  /// A struct's fields, by member name.
  final Map<String, TypeDescriptor> members;

  /// An array's element type.
  final TypeDescriptor? element;

  /// Whether anything in this tree carries an enum table — the only reason
  /// a type is worth describing on the wire.
  bool get hasEnum =>
      enumFields != null ||
      members.values.any((m) => m.hasEnum) ||
      (element?.hasEnum ?? false);

  Map<String, Object?> toJson() => <String, Object?>{
        if (ua != null) 'ua': ua,
        if (enumFields != null)
          'enum': <String, Object?>{
            for (final entry in enumFields!.entries)
              '${entry.key}': entry.value.toJson(),
          },
        if (displayName != null) 'displayName': displayName!.toJson(),
        if (description != null) 'description': description!.toJson(),
        if (members.isNotEmpty)
          'members': <String, Object?>{
            for (final entry in members.entries)
              entry.key: entry.value.toJson(),
          },
        if (element != null) 'element': element!.toJson(),
      };

  /// Forgiving: unknown keys are ignored, a malformed enum entry or member is
  /// dropped, and anything that is not a map decodes to an empty descriptor.
  factory TypeDescriptor.fromJson(Object? raw) {
    if (raw is! Map) return const TypeDescriptor();
    final json = {for (final entry in raw.entries) '${entry.key}': entry.value};
    Map<int, EnumField>? enumFields;
    final rawEnum = json['enum'];
    if (rawEnum is Map) {
      enumFields = <int, EnumField>{};
      for (final entry in rawEnum.entries) {
        final code = int.tryParse('${entry.key}');
        final field = entry.value;
        if (code == null || field is! Map) continue;
        try {
          enumFields[code] = EnumField.fromJson(
              {for (final f in field.entries) '${f.key}': f.value});
        } on Object {
          // One bad entry costs one name, not the table.
        }
      }
    }
    final rawMembers = json['members'];
    final members = <String, TypeDescriptor>{};
    if (rawMembers is Map) {
      for (final entry in rawMembers.entries) {
        members['${entry.key}'] = TypeDescriptor.fromJson(entry.value);
      }
    }
    final rawElement = json['element'];
    return TypeDescriptor(
      ua: json['ua'] is String ? json['ua'] as String : null,
      enumFields: enumFields,
      displayName: _text(json['displayName']),
      description: _text(json['description']),
      members: members,
      element: rawElement == null ? null : TypeDescriptor.fromJson(rawElement),
    );
  }

  static LocalizedText? _text(Object? raw) {
    if (raw is! Map) return null;
    try {
      return LocalizedText.fromJson(
          {for (final entry in raw.entries) '${entry.key}': entry.value});
    } on Object {
      return null;
    }
  }

  @override
  String toString() => 'TypeDescriptor(${ua ?? '?'}'
      '${enumFields == null ? '' : ', ${enumFields!.length} enum field(s)'}'
      '${members.isEmpty ? '' : ', ${members.length} member(s)'})';
}

/// Where a source can say what type a key is, and describe a type.
///
/// Optional on purpose — it is **not** a member of `StateManApi`. A source
/// that has no type metadata (the in-memory fake, a channel leg, a plant
/// that speaks nothing but plain numbers) implements nothing and the wire
/// simply carries no `types`; the server asks `api is TypeDescriptions`. The
/// backend's answer comes from its pipe, which learns each type from the
/// first sample of it (`PipeTypeDescribed`), and the policy decorator
/// forwards the question only for keys the session may see.
abstract interface class TypeDescriptions {
  /// The type id [key]'s values carry, or null when the type has nothing to
  /// describe (no enum anywhere in it) or the key has not been sampled.
  String? typeIdOf(String key);

  /// The descriptor for [typeId], or null when unknown.
  TypeDescriptor? describe(String typeId);

  /// Bumped whenever a type is learned or a key's type changes.
  ///
  /// **A dictionary is not complete when a panel subscribes, and cannot be.**
  /// A type is learned when the first sample of it arrives, and the first
  /// sample arrives because somebody subscribed — so the first client after a
  /// backend restart is the very one whose subscription causes the learning,
  /// and it is the one guaranteed to miss it. Measured on the plant
  /// (2026-09-17): sign in immediately after a restart and every conveyor
  /// draws violet for "mode unknown" until the page is reloaded, because the
  /// enum names for `p_stat_RunMode` were learned a moment after the snapshot
  /// went out and nothing pushed them.
  ///
  /// A counter rather than a stream, and read once per tick: a session that
  /// sees the same number as last time has nothing to send and pays one
  /// integer comparison for knowing it. Implementations increment it; nobody
  /// reads its value for anything but inequality, so wrapping is not a
  /// property anything depends on.
  int get typesVersion;
}
