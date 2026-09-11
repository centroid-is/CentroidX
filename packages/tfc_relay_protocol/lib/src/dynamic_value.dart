/// The value type every component of the pipe passes around.
///
/// Pure Dart: no FFI, no `package:open62541`, no codegen, no I/O — mandated by
/// CONTEXT D-08 ("It just can't have native bindings like the other impl", the
/// #107 lesson). A native-backed value type made the whole client tier depend
/// on a git-pinned FFI package shared with the native OPC UA client; this one
/// is 100% Dart and can be built for Flutter web.
///
/// Two invariants the constructor enforces, both operational:
///
///  * **Immutable and value-equal.** The value store's promise — unchanged
///    keys cost zero rebuilds with 1500 keys on one page (CLI-06) — is the
///    `if (next == current) return;` guard. A shared mutable object makes that
///    comparison meaningless, so every field is `final` and equality is
///    structural over nested children.
///  * **No non-finite double can exist inside one.** Dart's `jsonEncode`
///    throws on NaN/±Infinity, so one open-circuit 4-20 mA input would fail the
///    batch for every connected client. Construction runs [sanitize]; a poison
///    leaf becomes `null` with [Quality.badNonFinite].
///
/// [quality] and [sourceTime] are first-class fields (CONTEXT), mirroring OPC
/// UA's DataValue: one type at every call site, so a widget can never read a
/// number without being able to see whether it is trustworthy.
library;

import 'quality.dart';
import 'sanitize.dart';

/// Protocol-native value type tag.
///
/// Deliberately not OPC UA's `NodeId`: the pipe also carries Modbus, M2400 /
/// JBTM and UMAS values, for which a namespaced OPC UA node id is meaningless.
/// The original source type id (e.g. `"ns=2;s=X"`) round-trips opaquely in
/// [DynamicValue.sourceTypeId].
enum ValueType {
  unknown,
  boolean,
  integer,
  double,
  string,
  bytes,
  dateTime,
  object,
  array,
  null_,
}

/// A human-readable string with an optional locale (the Icelandic plant runs
/// `is` and `en` side by side).
final class LocalizedText {
  final String value;
  final String? locale;

  const LocalizedText(this.value, {this.locale});

  factory LocalizedText.fromJson(Map<String, Object?> json) {
    final text = json['text'];
    final locale = json['locale'];
    return LocalizedText(
      text is String ? text : '',
      locale: locale is String ? locale : null,
    );
  }

  Map<String, Object?> toJson() => {
        'text': value,
        if (locale != null) 'locale': locale,
      };

  @override
  bool operator ==(Object other) =>
      other is LocalizedText && other.value == value && other.locale == locale;

  @override
  int get hashCode => Object.hash(value, locale);

  @override
  String toString() => value;
}

/// One member of an enumeration declared upstream: the numeric code plus the
/// name operators actually read on screen.
final class EnumField {
  final int value;
  final String name;
  final LocalizedText? displayName;
  final LocalizedText? description;

  const EnumField({
    required this.value,
    required this.name,
    this.displayName,
    this.description,
  });

  factory EnumField.fromJson(Map<String, Object?> json) => EnumField(
        value: (json['value'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        displayName: json['displayName'] == null
            ? null
            : LocalizedText.fromJson(
                (json['displayName'] as Map).cast<String, Object?>()),
        description: json['description'] == null
            ? null
            : LocalizedText.fromJson(
                (json['description'] as Map).cast<String, Object?>()),
      );

  Map<String, Object?> toJson() => {
        'value': value,
        'name': name,
        if (displayName != null) 'displayName': displayName!.toJson(),
        if (description != null) 'description': description!.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is EnumField &&
      other.value == value &&
      other.name == name &&
      other.displayName == displayName &&
      other.description == description;

  @override
  int get hashCode => Object.hash(value, name, displayName, description);

  @override
  String toString() => '$name($value)';
}

/// An immutable value plus everything needed to judge it.
///
/// [value] is a primitive, a `Map<Object, DynamicValue>` (object members) or a
/// `List<DynamicValue>` (array elements) — never a raw nested map or list, so
/// indexing, equality and encoding are uniform at every depth.
final class DynamicValue {
  /// Sentinel distinguishing "argument omitted" from "explicitly set to null"
  /// in [copyWith] — the ported call sites need to clear `displayName` and
  /// `description`, not just replace them.
  static const Object _unset = Object();

  /// Maximum nesting [DynamicValue.fromJson] will decode, and the public
  /// constructor will normalize.
  ///
  /// The decoder is recursive and reads untrusted bytes from a peer, so an
  /// attacker-supplied 100k-deep object would exhaust the stack and take the
  /// gateway down for every client. The constructor is recursive too, and is
  /// what the OPC UA / Modbus / M2400 converters call on the gateway with
  /// structures the *upstream* controls — so it needs the same bound, and a
  /// self-referential structure from a converter stops here rather than at
  /// the end of the stack. 64 is far deeper than any real PLC structure.
  ///
  /// Past the limit the decoder throws [FormatException] (a peer's frame is
  /// malformed input) and the constructor throws [ArgumentError] (its caller
  /// is local code, so this is programmer error).
  static const int maxDepth = maxValueDepth;

  final Object? value;
  final Quality quality;
  final DateTime? sourceTime;
  final ValueType? typeId;

  /// Opaque round-trip of the source's own type id, e.g. `"ns=2;s=X"`. Never
  /// parsed here — the wire shape the existing converter uses does not change.
  final String? sourceTypeId;

  final LocalizedText? displayName;
  final LocalizedText? description;
  final Map<int, EnumField>? enumFields;

  const DynamicValue._({
    required this.value,
    required this.quality,
    required this.sourceTime,
    required this.typeId,
    required this.sourceTypeId,
    required this.displayName,
    required this.description,
    required this.enumFields,
  });

  /// Sanitizing constructor.
  ///
  /// Nested maps and lists are normalized into `Map<Object, DynamicValue>` /
  /// `List<DynamicValue>`; non-finite doubles anywhere become `null` and force
  /// [Quality.badNonFinite]; a parent's quality is worst-wins over its own and
  /// all of its children's — across bands and, against a plain-good parent,
  /// within one — so a healthy-looking header can never hide a dead member
  /// nor a member with a write in flight.
  factory DynamicValue({
    Object? value,
    Quality quality = Quality.good,
    DateTime? sourceTime,
    ValueType? typeId,
    String? sourceTypeId,
    LocalizedText? displayName,
    LocalizedText? description,
    Map<int, EnumField>? enumFields,
  }) {
    final normalized = _normalize(value, quality, 1);
    return DynamicValue._(
      value: normalized.value,
      quality: normalized.quality,
      sourceTime: _normalizeTime(sourceTime),
      typeId: typeId,
      sourceTypeId: sourceTypeId,
      displayName: displayName,
      description: description,
      enumFields: enumFields == null
          ? null
          : Map<int, EnumField>.unmodifiable(enumFields),
    );
  }

  /// Positional convenience mirroring `WireValue.of`.
  factory DynamicValue.of(
    Object? value, {
    Quality quality = Quality.good,
    DateTime? sourceTime,
  }) =>
      DynamicValue(value: value, quality: quality, sourceTime: sourceTime);

  /// Deep copy. Kept as a named constructor because the ported call sites read
  /// `DynamicValue.from(x)` today; with an immutable type the follow-up
  /// mutation becomes [copyWith].
  factory DynamicValue.from(DynamicValue other) => DynamicValue(
        value: _deepCopy(other.value),
        quality: other.quality,
        sourceTime: other.sourceTime,
        typeId: other.typeId,
        sourceTypeId: other.sourceTypeId,
        displayName: other.displayName,
        description: other.description,
        enumFields: other.enumFields == null
            ? null
            : Map<int, EnumField>.from(other.enumFields!),
      );

  /// Tolerant decode: unknown fields are ignored (a newer server must be able
  /// to add one without breaking deployed panels) and every read is an
  /// explicit cast through `num` / `Map` / `List`.
  factory DynamicValue.fromJson(Map<String, Object?> json) =>
      _fromJson(json, 1);

  /// Full encoding is `{typeId?, sourceTypeId?, displayName?, description?,
  /// enumFields?, q?, t?, type, value}` — the shape the existing converter
  /// already puts on the wire. With [slim] the bare value is returned instead:
  /// metadata rides once in the subscribe result, not on every push.
  Object? toJson({bool slim = false}) {
    final v = value;
    final String type;
    final Object? serialized;
    if (v == null) {
      type = 'null';
      serialized = null;
    } else if (v is Map<Object, DynamicValue>) {
      type = 'object';
      serialized = {
        for (final entry in v.entries)
          '${entry.key}': entry.value.toJson(slim: slim),
      };
    } else if (v is List<DynamicValue>) {
      type = 'array';
      serialized = [for (final child in v) child.toJson(slim: slim)];
    } else if (v is String) {
      type = 'string';
      serialized = v;
    } else if (v is int) {
      type = 'integer';
      serialized = v;
    } else if (v is double) {
      type = 'double';
      serialized = v;
    } else if (v is bool) {
      type = 'boolean';
      serialized = v;
    } else {
      type = 'unknown';
      serialized = v.toString();
    }

    if (slim) return serialized;

    return {
      if (typeId != null) 'typeId': typeId!.name,
      if (sourceTypeId != null) 'sourceTypeId': sourceTypeId,
      if (displayName != null) 'displayName': displayName!.toJson(),
      if (description != null) 'description': description!.toJson(),
      if (enumFields != null && enumFields!.isNotEmpty)
        'enumFields': _stringKeyed(enumFields!, (f) => f.toJson()),
      if (quality != Quality.good) 'q': quality.code,
      if (sourceTime != null) 't': sourceTime!.millisecondsSinceEpoch,
      'type': type,
      'value': serialized,
    };
  }

  static DynamicValue _fromJson(Map<String, Object?> json, int depth) {
    if (depth > maxDepth) {
      throw FormatException(
          'DynamicValue JSON nested deeper than maxDepth ($maxDepth)');
    }
    final typeName = json['type'];
    final type = typeName is String ? typeName : 'unknown';
    final raw = json['value'];

    // A leaf whose declared type and actual value disagree degrades on its
    // own rather than taking the batch with it. The old casts threw a
    // _TypeError, and on the notification path (`u` updates) there is no
    // JSON-RPC error response for one to land in: it surfaces as an unhandled
    // error and takes down the value pipeline for a frame that had one bad
    // field in it.
    var typeMismatch = false;
    Object? undecodable() {
      typeMismatch = true;
      return null;
    }

    final Object? decoded = switch (type) {
      'null' => null,
      'object' when raw is Map => {
          for (final entry in raw.cast<String, Object?>().entries)
            entry.key: _childFromJson(entry.value, depth + 1),
        },
      'array' when raw is List => [
          for (final element in raw) _childFromJson(element, depth + 1),
        ],
      'integer' when raw is num => _asInteger(raw),
      'double' when raw is num => raw.toDouble(),
      'boolean' when raw is bool => raw,
      // A number under a `string` tag is a representation difference, not a
      // disagreement about what the value is.
      'string' => raw is String ? raw : raw?.toString(),
      // An absent value under any tag is an absent reading, not a mismatch.
      'object' || 'array' || 'integer' || 'double' || 'boolean'
          when raw == null =>
        null,
      'object' || 'array' || 'integer' || 'double' || 'boolean' =>
        undecodable(),
      _ => raw,
    };

    // `isFinite` before `toInt()`: a `1e999` timestamp decodes to Infinity,
    // on which toInt() throws.
    final t = json['t'];
    final sourceTime = t is num && t.isFinite
        ? DateTime.fromMillisecondsSinceEpoch(t.toInt(), isUtc: true)
        : null;

    // Construction re-sanitizes: `1e999` in incoming JSON silently parses to
    // Infinity and would detonate on the next encode.
    return DynamicValue(
      value: decoded,
      quality: typeMismatch
          ? Quality.worst(
              [Quality.fromWire(json['q']), Quality.errorTypeMismatch])
          : Quality.fromWire(json['q']),
      sourceTime: sourceTime,
      typeId: _valueTypeNamed(json['typeId']),
      sourceTypeId: _stringOrNull(json['sourceTypeId']),
      displayName: _localizedOrNull(json['displayName']),
      description: _localizedOrNull(json['description']),
      enumFields: json['enumFields'] == null
          ? null
          : _intKeyed(
              json['enumFields'],
              (v) => v is Map
                  ? EnumField.fromJson(v.cast<String, Object?>())
                  : null),
    );
  }

  static DynamicValue _childFromJson(Object? raw, int depth) => raw is Map
      ? _fromJson(raw.cast<String, Object?>(), depth)
      : DynamicValue(value: raw);

  /// A non-finite `num` under an `integer` tag is left as a double so
  /// [sanitize] can null it: `Infinity.toInt()` throws.
  static Object? _asInteger(Object? raw) {
    final n = raw as num?;
    if (n == null || (n is double && !n.isFinite)) return n;
    return n.toInt();
  }

  /// An unrecognised tag from a newer peer is treated as absent, not as an
  /// error — forward compatibility, same rule as unknown fields.
  static ValueType? _valueTypeNamed(Object? name) {
    if (name is! String) return null;
    for (final candidate in ValueType.values) {
      if (candidate.name == name) return candidate;
    }
    return null;
  }

  /// Metadata is decorative: a peer that sends the wrong shape for it loses
  /// the label, not the value it was labelling.
  static String? _stringOrNull(Object? raw) => raw is String ? raw : null;

  static LocalizedText? _localizedOrNull(Object? raw) => raw is Map
      ? LocalizedText.fromJson(raw.cast<String, Object?>())
      : null;

  // ---------------------------------------------------------------- coercion

  /// Never null, never a throw — 44 call sites index the result directly.
  double get asDouble => _parseDouble(value) ?? 0.0;

  /// Never null, never a throw — 43 call sites index the result directly.
  int get asInt => _parseInt(value) ?? 0;

  String get asString => value?.toString() ?? '';

  bool get asBool => _parseBool(value) ?? false;

  static double? _parseDouble(Object? val) {
    if (val is num) return val.toDouble();
    if (val is bool) return val ? 1.0 : 0.0;
    if (val is String) return double.tryParse(val.trim());
    return null;
  }

  static int? _parseInt(Object? val) {
    if (val is int) return val;
    if (val is num) return val.toInt();
    if (val is bool) return val ? 1 : 0;
    if (val is String) {
      final trimmed = val.trim();
      return int.tryParse(trimmed) ?? double.tryParse(trimmed)?.toInt();
    }
    return null;
  }

  static bool? _parseBool(Object? val) {
    if (val is bool) return val;
    if (val is num) return val != 0;
    if (val is String) {
      final lc = val.trim().toLowerCase();
      return lc == 'true' || lc == '1';
    }
    return null;
  }

  // -------------------------------------------------------------- type tests

  bool get isNull => value == null;
  bool get isBoolean => value is bool;
  bool get isInteger => value is int;
  bool get isDouble => value is double;
  bool get isString => value is String;
  bool get isArray => value is List<DynamicValue>;
  bool get isObject => value is Map<Object, DynamicValue>;

  /// Object members. Throws [StateError] when this is not an object — an
  /// unexpected shape is a configuration fault worth surfacing, not one to
  /// paper over with an empty map.
  Map<Object, DynamicValue> get asObject {
    final v = value;
    if (v is Map<Object, DynamicValue>) return v;
    throw StateError('not an object: ${_shape()}');
  }

  /// Array elements. Throws [StateError] when this is not an array.
  List<DynamicValue> get asArray {
    final v = value;
    if (v is List<DynamicValue>) return v;
    throw StateError('not an array: ${_shape()}');
  }

  // ------------------------------------------------------ indexing / members

  /// Non-throwing membership test. Paired with the throwing [operator []] this
  /// is the guard idiom at `lib/page_creator/assets/sensor.dart:125-132`: an
  /// older PLC library revision missing a member must degrade, not crash the
  /// mimic.
  bool contains(Object key) {
    final v = value;
    if (v is Map<Object, DynamicValue>) return v.containsKey(key);
    if (v is List<DynamicValue>) {
      return key is int && key >= 0 && key < v.length;
    }
    return false;
  }

  /// Object members index by `String`, array elements by `int`.
  ///
  /// Throws [StateError] on a missing member. That throw is depended upon:
  /// returning a null-valued placeholder would let a renamed tag render as a
  /// plausible-looking zero forever.
  DynamicValue operator [](Object key) {
    final v = value;
    if (v is Map<Object, DynamicValue>) {
      final child = v[key];
      if (child == null) {
        throw StateError("no member '$key' (have: ${v.keys.join(', ')})");
      }
      return child;
    }
    if (v is List<DynamicValue>) {
      if (key is int && key >= 0 && key < v.length) return v[key];
      throw StateError('index $key out of range (length ${v.length})');
    }
    throw StateError('cannot index ${_shape()} with $key');
  }

  /// Object children in insertion order; array elements keyed by index.
  Iterable<MapEntry<Object, DynamicValue>> get entries {
    final v = value;
    if (v is Map<Object, DynamicValue>) return v.entries;
    if (v is List<DynamicValue>) {
      return v.asMap().entries.map(
            (e) => MapEntry<Object, DynamicValue>(e.key, e.value),
          );
    }
    throw StateError('${_shape()} has no entries');
  }

  /// Number of members or elements.
  int get length {
    final v = value;
    if (v is Map<Object, DynamicValue>) return v.length;
    if (v is List<DynamicValue>) return v.length;
    throw StateError('${_shape()} has no length');
  }

  // ----------------------------------------------------------------- copying

  /// Returns a new instance; the receiver is untouched. Pass an explicit
  /// `null` to clear an optional field.
  DynamicValue copyWith({
    Object? value = _unset,
    Quality? quality,
    Object? sourceTime = _unset,
    Object? typeId = _unset,
    Object? sourceTypeId = _unset,
    Object? displayName = _unset,
    Object? description = _unset,
    Object? enumFields = _unset,
  }) =>
      DynamicValue(
        value: identical(value, _unset) ? this.value : value,
        quality: quality ?? this.quality,
        sourceTime: identical(sourceTime, _unset)
            ? this.sourceTime
            : sourceTime as DateTime?,
        typeId: identical(typeId, _unset) ? this.typeId : typeId as ValueType?,
        sourceTypeId: identical(sourceTypeId, _unset)
            ? this.sourceTypeId
            : sourceTypeId as String?,
        displayName: identical(displayName, _unset)
            ? this.displayName
            : displayName as LocalizedText?,
        description: identical(description, _unset)
            ? this.description
            : description as LocalizedText?,
        enumFields: identical(enumFields, _unset)
            ? this.enumFields
            : enumFields as Map<int, EnumField>?,
      );

  // ---------------------------------------------------------------- equality

  @override
  bool operator ==(Object other) =>
      other is DynamicValue &&
      other.quality == quality &&
      other.sourceTime == sourceTime &&
      other.typeId == typeId &&
      other.sourceTypeId == sourceTypeId &&
      other.displayName == displayName &&
      other.description == description &&
      _enumFieldsEqual(other.enumFields, enumFields) &&
      _valuesEqual(other.value, value);

  @override
  int get hashCode => Object.hash(
        _deepHash(value),
        quality,
        sourceTime,
        typeId,
        sourceTypeId,
        displayName,
        description,
        _enumFieldsHash(enumFields),
      );

  @override
  String toString() {
    if (value == null) return 'null';
    final fields = enumFields;
    if (fields != null) return '${fields[value]?.name}($value)';
    final label = displayName == null ? '' : '${displayName!.value}: ';
    final q = quality == Quality.good ? '' : ' [q=${quality.code}]';
    return '$label$value$q';
  }

  // ----------------------------------------------------------------- helpers

  String _shape() {
    if (isNull) return 'null';
    if (isObject) return 'object';
    if (isArray) return 'array';
    return '${value.runtimeType}';
  }

  /// Rebuilds [raw] into the normalized shape and composes the quality.
  ///
  /// [depth] is threaded rather than left implicit because this recursion is
  /// what a converter's structure drives — see [maxDepth].
  static ({Object? value, Quality quality}) _normalize(
      Object? raw, Quality own, int depth) {
    if (depth > maxDepth) {
      throw ArgumentError.value(
          raw,
          'value',
          'nested deeper than maxDepth ($maxDepth), or self-referential — '
              'either way normalizing it does not terminate on the stack it '
              'has, and a stack overflow on the gateway is every client\'s '
              'problem rather than one tag\'s');
    }
    if (raw is DynamicValue) {
      return (value: raw.value, quality: _compose(own, [raw.quality]));
    }
    if (raw is Map) {
      final members = <Object, DynamicValue>{};
      for (final entry in raw.entries) {
        members[entry.key as Object] = _wrap(entry.value, depth + 1);
      }
      return (
        value: Map<Object, DynamicValue>.unmodifiable(members),
        quality: _compose(own, members.values.map((c) => c.quality)),
      );
    }
    if (raw is List) {
      final elements = List<DynamicValue>.unmodifiable(
          [for (final element in raw) _wrap(element, depth + 1)]);
      return (
        value: elements,
        quality: _compose(own, elements.map((c) => c.quality)),
      );
    }
    // Leaf: `1e999` from outside and a divide-by-zero rate from a weigher both
    // land here, and both must not reach jsonEncode.
    final s = sanitize(raw);
    return (
      value: s.value,
      quality:
          s.hadNonFinite ? Quality.worst([own, Quality.badNonFinite]) : own,
    );
  }

  static DynamicValue _wrap(Object? raw, int depth) {
    if (raw is DynamicValue) return raw;
    final normalized = _normalize(raw, Quality.good, depth);
    return DynamicValue._(
      value: normalized.value,
      quality: normalized.quality,
      sourceTime: null,
      typeId: null,
      sourceTypeId: null,
      displayName: null,
      description: null,
      enumFields: null,
    );
  }

  /// Worst-wins over own and children, and within a band the more specific
  /// code beats plain `good`.
  ///
  /// The band rule alone made a struct whose member carries
  /// [Quality.goodWritePending] report plain `good`, so a widget bound to the
  /// struct rather than to the leaf showed no pending badge while a write to
  /// one of its members was in flight — the case CONTEXT D-04 exists to make
  /// visible.
  static Quality _compose(Quality own, Iterable<Quality> children) {
    var result = own;
    for (final q in children) {
      if (q.band > result.band) {
        result = q;
      } else if (q.band == result.band && result == Quality.good) {
        result = q;
      }
    }
    return result;
  }

  /// Timestamps are normalized to UTC milliseconds — the precision the wire
  /// carries — so `fromJson(toJson())` is `==` to the original.
  static DateTime? _normalizeTime(DateTime? t) => t == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch,
          isUtc: true);

  static Object? _deepCopy(Object? v) {
    if (v is Map<Object, DynamicValue>) {
      return {
        for (final e in v.entries) e.key: DynamicValue.from(e.value),
      };
    }
    if (v is List<DynamicValue>) {
      return [for (final child in v) DynamicValue.from(child)];
    }
    return v;
  }

  static bool _valuesEqual(Object? a, Object? b) {
    if (a is Map<Object, DynamicValue>) {
      if (b is! Map<Object, DynamicValue> || a.length != b.length) return false;
      for (final entry in a.entries) {
        final other = b[entry.key];
        if (other == null || other != entry.value) return false;
      }
      return true;
    }
    if (a is List<DynamicValue>) {
      if (b is! List<DynamicValue> || a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    return a == b;
  }

  static int _deepHash(Object? v) {
    if (v is Map<Object, DynamicValue>) {
      var acc = 0;
      for (final entry in v.entries) {
        acc ^= Object.hash(entry.key, entry.value);
      }
      return Object.hash('object', acc, v.length);
    }
    if (v is List<DynamicValue>) return Object.hash('array', Object.hashAll(v));
    return v.hashCode;
  }

  static bool _enumFieldsEqual(
      Map<int, EnumField>? a, Map<int, EnumField>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  static int _enumFieldsHash(Map<int, EnumField>? fields) {
    if (fields == null) return 0;
    var acc = 0;
    for (final entry in fields.entries) {
      acc ^= Object.hash(entry.key, entry.value);
    }
    return Object.hash(acc, fields.length);
  }
}

// JSON objects key by String; enum codes are ints. Convert at the boundary,
// skipping anything that is not an int-keyed entry rather than throwing: a
// peer's malformed enum table costs the labels, not the value they label.
Map<int, V> _intKeyed<V extends Object>(
    Object? raw, V? Function(Object?) decode) {
  if (raw is! Map) return const {};
  final out = <int, V>{};
  for (final entry in raw.entries) {
    final code = int.tryParse('${entry.key}');
    if (code == null) continue;
    final decoded = decode(entry.value);
    if (decoded != null) out[code] = decoded;
  }
  return out;
}

Map<String, Object?> _stringKeyed<V>(
        Map<int, V> map, Object? Function(V) encode) =>
    map.map((k, v) => MapEntry('$k', encode(v)));
