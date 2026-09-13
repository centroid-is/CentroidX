/// The `{type, value}` payload of a `kind='preference'` row — the one
/// encoding, shared by the two stores that write one.
///
/// ## Why the type is written down and not inferred
///
/// `PreferencesApi` is typed across five types, and `'7'` and `7` are two
/// different preferences. The tag is what relocates that distinction into the
/// row. It also rescues the one case JSON alone cannot: `samePayload` compares
/// with `DeepCollectionEquality`, for which `1 == 1.0`, so writing `int 1` over
/// a stored `double 1.0` would look like no change at all, be skipped, and
/// leave `getInt` returning a `double` that throws at the call site.
/// `{"type":"int"}` and `{"type":"double"}` are not structurally equal, so the
/// write happens.
///
/// The five strings are exactly the ones `Preferences.loadFromPostgres`
/// switches on, which is what made moving `flutter_preferences` rows into
/// `config_item` a copy rather than a translation.
///
/// ## Why it lives here rather than in one of the stores
///
/// There are two preference stores now: `SqlitePreferences` over this
/// station's local rows, and `SharedRowPreferences` over the shared ones. They
/// differ in *where* a write goes — local rows are owned here and written
/// directly, shared rows are owned by Postgres and go through `ConfigStore`'s
/// compare-and-swap — and not at all in what a stored value looks like. A
/// second copy of this encoding would be a second answer to "what is on disk",
/// and the disagreement would surface as a preference that reads back as
/// absent on one path and present on the other.
///
/// **The wire bytes are frozen.** Every local `config.sqlite` on every station
/// already holds rows in this shape; a change here does not migrate them, it
/// makes them unreadable — which reads to a caller as "the setting was never
/// written". `shared_preferences_rows_test.dart` pins the bytes with fixtures.
///
/// FFI-free and Flutter-free on purpose: both stores import it, and one of
/// them must stay reachable from `tfc_dart_core.dart`'s import graph.
library;

import 'dart:convert';

/// The wire strings for the five types `PreferencesApi` carries. Permanent:
/// they are stored, and `Preferences.loadFromPostgres` already switches on
/// exactly these.
const String kPrefBoolType = 'bool';
const String kPrefIntType = 'int';
const String kPrefDoubleType = 'double';
const String kPrefStringType = 'String';
const String kPrefStringListType = 'List<String>';

/// The five tags, in the order the setters appear on `PreferencesApi`.
const List<String> kPreferenceTypeTags = [
  kPrefBoolType,
  kPrefIntType,
  kPrefDoubleType,
  kPrefStringType,
  kPrefStringListType,
];

/// The payload value for [value] tagged as [type], ready for
/// `ConfigItem.of(value: …)`.
///
/// A `Map` rather than an encoded string, because `ConfigItem.of` owns the
/// canonical encoding and two encoders would be two orderings of the same two
/// keys — structurally equal, textually different, and the textual difference
/// is what a naive diff would report as an edit.
Map<String, Object?> preferencePayload(String type, Object value) => {
      'type': type,
      'value': value,
    };

/// The tag [value]'s runtime type is stored under, or null when
/// `PreferencesApi` cannot carry it.
///
/// Null rather than a throw, and null for `null` itself: the callers are the
/// import of a legacy store and the copy of one store into another, both of
/// which must skip an entry they cannot represent rather than abandon the
/// whole job over it.
///
/// A `List` is accepted when every element is a `String`, including the empty
/// list — the raw-file fallback the legacy import reads decodes JSON, and JSON
/// has no typed lists, so a genuine `List<String>` arrives as `List<dynamic>`.
String? preferenceTypeOf(Object? value) {
  if (value is bool) return kPrefBoolType;
  if (value is int) return kPrefIntType;
  if (value is double) return kPrefDoubleType;
  if (value is String) return kPrefStringType;
  if (value is List && value.every((e) => e is String)) {
    return kPrefStringListType;
  }
  return null;
}

/// The Dart value [payload] holds, or null if it holds none this build
/// recognises.
///
/// Null covers three cases that all mean the same thing to a caller — the
/// payload is not JSON, its tag is one this version does not know, or its
/// value contradicts its tag. All three read as *absent*, so a row a local
/// user edited by hand costs a default and never the boot. A tag this build
/// *does* know but the caller did not ask for is a different matter: the cast
/// in the getter throws a `TypeError`, which is the contract
/// `InMemoryPreferences`' `as bool?` already has.
Object? decodePreferencePayload(String payload) {
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException {
    return null;
  }
  // A bare scalar is not a legal payload for any kind: `ConfigItem.decode()`
  // casts to `Map<String, dynamic>`.
  if (decoded is! Map) return null;
  final Object? value = decoded['value'];
  try {
    switch (decoded['type']) {
      case kPrefBoolType:
        return value! as bool;
      case kPrefIntType:
        return value! as int;
      case kPrefDoubleType:
        // `toDouble()` and not a cast: a whole-numbered double written by
        // something other than these stores may have been encoded as `7`.
        return (value! as num).toDouble();
      case kPrefStringType:
        return value! as String;
      case kPrefStringListType:
        // `.toList()` forces the element cast now, so a list holding a
        // non-string fails here as a corrupt row rather than later, at some
        // unrelated call site.
        return (value! as List).cast<String>().toList(growable: false);
      default:
        return null;
    }
  } on TypeError {
    return null;
  }
}
