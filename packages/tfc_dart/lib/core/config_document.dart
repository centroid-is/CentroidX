/// A `StateManConfig` document held as its decoded JSON tree and edited
/// through the typed classes — without losing what the classes do not model.
///
/// ## Why this exists (quick/20260908-unify-config-ui)
///
/// The unified Server Config page edits ONE document that may live in two
/// places: this station's own preferences (direct mode) or the backend's
/// config file, read and written over the relay (gateway mode,
/// `BackendConfigApi`). The backend's document can carry content this build
/// has never heard of — the read-only `relay` section, future top-level
/// sections, per-entry keys added by a newer build — and a form that went
/// `jsonDecode → StateManConfig.fromJson → edit → toJson → jsonEncode` would
/// SILENTLY DROP all of it: json_serializable ignores unknown keys on the way
/// in and cannot re-emit them on the way out. On the plant backend's config
/// that is a catastrophic failure mode, and this class is the mechanism that
/// prevents it. `test/core/config_document_test.dart` is the instrument.
///
/// ## The fidelity rule, stated once
///
/// Edits are applied as a **minimal diff against the original tree**:
///
///  * A known field the edit did not change keeps the original document's
///    representation — including its absence. A form save must not rewrite
///    every station's document into this build's dialect (defaults are never
///    materialised, formatting of untouched entries is never rewritten).
///  * A known field the edit DID change is written as the model serialises
///    it.
///  * Unknown keys — anything the typed classes do not own — travel with
///    their entry through edit, add, remove and reorder, verbatim.
///  * Top-level keys other than `opcua` / `jbtm` / `modbus` (the `relay`
///    section, anything future) are re-attached verbatim on [encode].
///
/// The boundary of the rule is depth-of-edit: an *untouched* substructure
/// survives verbatim at any depth (its serialised form deep-equals the
/// parsed one, so the original is kept), while an *edited* substructure is
/// the model's rewrite and loses unknown keys inside it. The test's arm 9
/// asserts that loss on purpose so the boundary is a stated fact rather than
/// a surprise.
///
/// ## Secrets (SECURITY FIX 3, 17-10)
///
/// A gateway read redacts `password` and `ssl_key` values behind
/// [kSecretPreservedSentinel]. The sentinel is not valid base64, so a naive
/// `OpcUAConfig.fromJson` of a redacted entry THROWS out of the
/// `Base64Converter` — the typed view therefore masks a sentinel `ssl_key`
/// to the sentinel's own bytes before parsing. On [ConfigEntry.update] the
/// minimal-diff rule restores the sentinel automatically: an untouched
/// secret's serialised form equals the parsed (masked) one, so the original
/// raw value — the sentinel — is what crosses back. A touched secret differs
/// and crosses as the new literal. [ConfigEntry.isSecretPreserved] is the
/// screen's predicate for "saved — leave blank to keep it".
///
/// This file decides nothing about validation or permission: the gateway's
/// `BackendConfigStore` validates server-side and the direct page validates
/// through the same `StateManConfig.fromJson` the backend boots with.
library;

import 'dart:convert';

import 'package:collection/collection.dart';

import 'relay/backend_config_store.dart' show kSecretPreservedSentinel;
import 'state_man.dart';

const _eq = DeepCollectionEquality();

/// The JSON keys whose values may be redacted behind the sentinel —
/// `BackendConfigStore`'s `_secretKeys`, restated here because that list is
/// private. Arm 2/3/4 of the test pin the behaviour for exactly these two,
/// so the lists cannot drift apart unnoticed.
const List<String> _secretKeys = ['password', 'ssl_key'];

/// What a sentinel `ssl_key` is masked to so the typed view can parse: the
/// sentinel's own bytes, base64-encoded. Reserved the same way the sentinel
/// itself is — a literal key equal to this cannot be told from the mask.
final String _sslKeySentinelMask =
    base64Encode(utf8.encode(kSecretPreservedSentinel));

/// From/to JSON for one server type, so [ConfigEntry] stays generic without
/// reflection.
final class _Codec<T> {
  const _Codec(this.fromJson, this.toJson);
  final T Function(Map<String, dynamic>) fromJson;
  final Map<String, dynamic> Function(T) toJson;
}

const _opcuaCodec = _Codec<OpcUAConfig>(OpcUAConfig.fromJson, _opcuaToJson);
Map<String, dynamic> _opcuaToJson(OpcUAConfig v) => v.toJson();

final _m2400Codec = _Codec<M2400Config>(M2400Config.fromJson, _m2400ToJson);
Map<String, dynamic> _m2400ToJson(M2400Config v) => v.toJson();

final _modbusCodec =
    _Codec<ModbusConfig>(ModbusConfig.fromJson, _modbusToJson);
Map<String, dynamic> _modbusToJson(ModbusConfig v) => v.toJson();

_Codec<T> _codecFor<T>() {
  final Object codec = switch (T) {
    const (OpcUAConfig) => _opcuaCodec,
    const (M2400Config) => _m2400Codec,
    const (ModbusConfig) => _modbusCodec,
    _ => throw ArgumentError(
        'ConfigEntry has no codec for $T — the document models OpcUAConfig, '
        'M2400Config and ModbusConfig entries only.'),
  };
  return codec as _Codec<T>;
}

/// One server entry: the raw JSON map it arrived as, plus the typed view a
/// form edits. Identity-carrying — reordering the enclosing list moves the
/// raw map (and every unknown key in it) with the entry.
final class ConfigEntry<T> {
  ConfigEntry._(this._raw, this._codec);

  /// A brand-new entry, created by the form's Add button: its raw map is
  /// exactly what the model writes, because there is no original to
  /// preserve anything of.
  factory ConfigEntry.fresh(T value) {
    final codec = _codecFor<T>();
    return ConfigEntry._(codec.toJson(value), codec);
  }

  Map<String, dynamic> _raw;
  final _Codec<T> _codec;

  /// Whether [jsonKey] currently holds the preserved-secret marker rather
  /// than a literal — the screen's "saved — leave blank to keep it" signal.
  bool isSecretPreserved(String jsonKey) =>
      _raw[jsonKey] == kSecretPreservedSentinel;

  /// The raw map with sentinel secrets masked just enough to parse. The mask
  /// never leaves this class: [update]'s minimal-diff rule puts the sentinel
  /// back for any secret the edit did not change.
  Map<String, dynamic> _masked() {
    if (!_secretKeys.any((k) => _raw[k] == kSecretPreservedSentinel)) {
      return _raw;
    }
    final masked = Map<String, dynamic>.of(_raw);
    if (masked['ssl_key'] == kSecretPreservedSentinel) {
      masked['ssl_key'] = _sslKeySentinelMask;
    }
    // A sentinel password parses as the string it is; no mask needed.
    return masked;
  }

  /// The typed view for the form. Rebuilt per call from the raw map — the
  /// raw map is the single source of truth, never a cached object.
  T get value => _codec.fromJson(_masked());

  /// Applies [edited] as a minimal diff against the raw map. See the library
  /// doc for the rule; the short version is: unchanged keys keep the
  /// original document's representation (including absence — defaults are
  /// not materialised), changed keys take the model's serialisation, unknown
  /// keys are carried verbatim.
  void update(T edited) {
    final editedJson = _codec.toJson(edited);
    final parsedJson = _codec.toJson(value);
    final result = <String, dynamic>{};
    for (final key in _raw.keys) {
      final known =
          parsedJson.containsKey(key) || editedJson.containsKey(key);
      if (!known) {
        // Unknown to the model: carried verbatim, in place.
        result[key] = _raw[key];
      } else if (_eq.equals(editedJson[key], parsedJson[key])) {
        // Known and untouched: the original representation wins — this is
        // also what restores a masked secret to its sentinel.
        result[key] = _raw[key];
      } else {
        result[key] = editedJson[key];
      }
    }
    for (final key in editedJson.keys) {
      if (result.containsKey(key) || _raw.containsKey(key)) continue;
      // Known, absent from the original: written only when it differs from
      // what parsing the original already answered — otherwise it is a
      // default, and materialising defaults rewrites every station's
      // document into this build's dialect.
      if (!_eq.equals(editedJson[key], parsedJson[key])) {
        result[key] = editedJson[key];
      }
    }
    _raw = result;
  }
}

/// The whole document: three identity-carrying entry lists the form edits,
/// and everything else preserved verbatim. See the library doc.
final class ConfigDocument {
  ConfigDocument._(
    this._top,
    this.opcua,
    this.jbtm,
    this.modbus,
    this.readOnlySections,
  );

  /// Decodes [json]. Refuses a non-object top level with a sentence rather
  /// than a cast error, because the operator reading the refusal is standing
  /// at a panel. [readOnlySections] is carried for the screen (the gateway's
  /// `BackendConfigDocument.readOnlySections`, `['relay']` today); this
  /// class preserves those sections verbatim regardless — the parameter only
  /// says which ones the UI must present greyed.
  factory ConfigDocument.parse(String json,
      {List<String> readOnlySections = const []}) {
    final Object? decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
          'The document\'s top level must be a JSON object with the '
          'configuration sections, not ${decoded.runtimeType}.');
    }
    List<ConfigEntry<T>> section<T>(String key) {
      final raw = decoded[key];
      if (raw is! List) return <ConfigEntry<T>>[];
      final codec = _codecFor<T>();
      return <ConfigEntry<T>>[
        for (final entry in raw)
          if (entry is Map<String, dynamic>)
            ConfigEntry<T>._(Map<String, dynamic>.of(entry), codec),
      ];
    }

    return ConfigDocument._(
      decoded,
      section<OpcUAConfig>('opcua'),
      section<M2400Config>('jbtm'),
      section<ModbusConfig>('modbus'),
      List.unmodifiable(readOnlySections),
    );
  }

  /// The decoded top level as it arrived. The three section keys are
  /// superseded by the entry lists on [encode]; every other key crosses
  /// verbatim.
  final Map<String, dynamic> _top;

  /// The editable entries. Plain mutable lists on purpose: add, remove and
  /// reorder are list operations, and each [ConfigEntry] carries its own raw
  /// map (unknown keys included) wherever it moves.
  final List<ConfigEntry<OpcUAConfig>> opcua;
  final List<ConfigEntry<M2400Config>> jbtm;
  final List<ConfigEntry<ModbusConfig>> modbus;

  /// Which top-level sections the UI must present read-only (`relay` in
  /// gateway mode). Informational here — preservation does not depend on it.
  final List<String> readOnlySections;

  /// The raw content of top-level section [name], exactly as it arrived —
  /// the display path for the read-only cards (`relay`), so the screen
  /// renders exactly what [encode] will reproduce. Answers null for a
  /// section the document does not carry. The three modeled sections answer
  /// their raw lists as read; the entry lists supersede those on [encode].
  Object? rawSection(String name) => _top[name];

  /// The full document. Content-faithful, format-conceding: untouched
  /// entries keep their exact key set and values, but the document is
  /// re-indented — a form edit is an edit, and the gateway store already
  /// re-parses whatever it accepts.
  String encode() {
    final sections = <String, List<Map<String, dynamic>>>{
      'opcua': [for (final entry in opcua) entry._raw],
      'jbtm': [for (final entry in jbtm) entry._raw],
      'modbus': [for (final entry in modbus) entry._raw],
    };
    final result = <String, dynamic>{};
    for (final key in _top.keys) {
      final rebuilt = sections.remove(key);
      result[key] = rebuilt ?? _top[key];
    }
    for (final entry in sections.entries) {
      // A section the original document never had appears only once the
      // form actually put an entry in it.
      if (entry.value.isNotEmpty) result[entry.key] = entry.value;
    }
    return const JsonEncoder.withIndent('  ').convert(result);
  }
}
