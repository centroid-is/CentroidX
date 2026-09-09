/// Where the ONE `StateManConfig` document is read from and written to.
///
/// The unified Server Config page (quick/20260908-unify-config-ui) edits a
/// single [ConfigDocument] that may live in two places: this station's own
/// preferences (direct mode) or the backend's config file, read and written
/// over the relay (gateway mode, `BackendConfigApi`). The transport decides
/// WHERE — and nothing else: presentation is the same form either way, which
/// is the whole point ("backend configuration should be exactly the same UI
/// page as server config in direct to PLCs — it is the same data").
///
/// The contract is enforced by ONE suite run against BOTH implementations
/// (`test/core/config_source_contract_test.dart`), the same Local/Remote
/// discipline `StateManApi` is held to.
library;

import 'dart:convert';

import 'package:tfc_dart/core/config_document.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show BackendConfigApi, ConfigValidation;

import 'relayed_access_stores.dart' show relayedAccessErrors;

/// What a successful save MEANS on this transport, so the screen can say it.
enum ApplySemantics {
  /// The save is applied immediately: the direct source re-points the live
  /// `StateMan` through its apply hook (`stateManProvider` invalidation).
  appliedOnSave,

  /// The save lands in the backend's config file; the backend applies it on
  /// restart — restart-to-apply, said in the UI copy (17-13).
  restartToApply,
}

/// The document as raw text, plus which sections the UI must present
/// read-only — the escape-hatch view for a document that will not decode,
/// where [ConfigSource.read] can only refuse. The panel's raw recovery
/// editor is the alternative to SSH.
typedef RawConfig = ({String text, List<String> readOnlySections});

/// Where the ONE document is read from and written to. The transport decides
/// this and nothing else — presentation is the same form either way.
abstract interface class ConfigSource {
  /// The document plus which sections the UI must present read-only.
  Future<ConfigDocument> read();

  /// The document as stored/served, verbatim — even (especially) when it
  /// will not parse as a [ConfigDocument]. The screen shows it whole and
  /// lets the operator repair it; [read] answering a refusal must never
  /// mean the document cannot be seen.
  Future<RawConfig> readRaw();

  /// The authoritative check, in operator sentences. Gateway: the backend's
  /// own validate() (parser + relay compare + sentinel resolution). Direct:
  /// the same `StateManConfig.fromJson` the local StateMan boots with.
  Future<ConfigValidation> validate(ConfigDocument doc);

  /// Replace the whole document, or refuse. Never partially applied.
  Future<void> write(ConfigDocument doc, {String? reason});

  /// Undo affordance. Direct answers false (and [restorePrevious] refuses);
  /// the UI shows the restore button only when this is true. The signal is
  /// `read().hasPrevious` — NOT `previous()`, which may refuse by name on a
  /// never-written file (17-10 deviation 4), so asking it is not the same
  /// question.
  Future<bool> hasPrevious();
  Future<void> restorePrevious({String? reason});

  /// What a save means here: direct = applied on stateManProvider
  /// invalidate; gateway = restart-to-apply, said in the UI copy.
  ApplySemantics get applySemantics;

  /// Whether live per-server connection status exists on this station
  /// (direct: yes, from stateManProvider's clients; gateway: not yet — the
  /// backend's client health is not on the wire, and the chip row renders
  /// its honest absence rather than a grey guess).
  bool get hasLiveStatus;
}

/// The direct-mode source: this station's own preferences, the same key and
/// the same flags `StateManConfig.fromPrefs`/`toPrefs` use — but the raw
/// document string, never a `fromJson → toJson` round trip, because the
/// typed classes drop every key they do not model and fidelity must hold
/// client-side (the reason [ConfigDocument] exists).
final class LocalPrefsConfigSource implements ConfigSource {
  LocalPrefsConfigSource({
    required Future<Preferences> Function() prefs,
    void Function()? onApplied,
  })  : _prefs = prefs,
        _onApplied = onApplied;

  final Future<Preferences> Function() _prefs;

  /// Fired after every successful [write]: direct mode applies on save, and
  /// the page passes `() => ref.invalidate(stateManProvider)` here so the
  /// widget layer stays transport-agnostic.
  final void Function()? _onApplied;

  /// The stored document string, seeded with fromPrefs' exact default when
  /// the key is absent — shared by [read] and [readRaw] so the typed and
  /// raw views cannot disagree about what an unconfigured station holds.
  Future<String> _readRawString() async {
    final prefs = await _prefs();
    var raw = await prefs.getString(StateManConfig.configKey, secret: true);
    if (raw == null) {
      // The same default fromPrefs seeds, persisted the same way, so the
      // page and the booting StateMan cannot disagree about what an
      // unconfigured station holds.
      raw = jsonEncode(StateManConfig(opcua: [OpcUAConfig()]).toJson());
      await prefs.setString(StateManConfig.configKey, raw,
          secret: true, saveToDb: false);
    }
    return raw;
  }

  @override
  Future<ConfigDocument> read() async =>
      ConfigDocument.parse(await _readRawString());

  @override
  Future<RawConfig> readRaw() async =>
      (text: await _readRawString(), readOnlySections: const <String>[]);

  @override
  Future<ConfigValidation> validate(ConfigDocument doc) async {
    try {
      StateManConfig.fromJson(
          jsonDecode(doc.encode()) as Map<String, dynamic>);
      return const ConfigValidation(ok: true);
    } catch (error) {
      // Deliberately the parser's own message, verbatim: it is the same
      // parser the backend runs at boot, so the two modes cannot disagree
      // about what parses.
      return ConfigValidation(ok: false, problems: [error.toString()]);
    }
  }

  @override
  Future<void> write(ConfigDocument doc, {String? reason}) async {
    final validation = await validate(doc);
    if (!validation.ok) {
      throw StateError('LocalPrefsConfigSource.write refused: '
          '${validation.problems.join(' ')}');
    }
    final prefs = await _prefs();
    await prefs.setString(StateManConfig.configKey, doc.encode(),
        secret: true, saveToDb: false);
    _onApplied?.call();
  }

  @override
  Future<bool> hasPrevious() async => false;

  @override
  Future<void> restorePrevious({String? reason}) async {
    throw StateError(
        'LocalPrefsConfigSource.restorePrevious refused: direct mode keeps '
        'no previous document — the preferences store holds exactly one.');
  }

  @override
  ApplySemantics get applySemantics => ApplySemantics.appliedOnSave;

  @override
  bool get hasLiveStatus => true;
}

/// The gateway-mode source: the backend's own config file over the relay.
///
/// Every call crosses through [relayedAccessErrors], so a domain-coded
/// refusal becomes the concrete exception the direct stores throw and
/// everything else — including the store's refusal sentences (D-10, the
/// sentinel resolution refusals) — propagates untouched, never swallowed
/// and never paraphrased.
final class GatewayConfigSource implements ConfigSource {
  GatewayConfigSource({required BackendConfigApi api}) : _api = api;

  final BackendConfigApi _api;

  @override
  Future<ConfigDocument> read() async {
    final document = await relayedAccessErrors(_api.read);
    return ConfigDocument.parse(document.configJson,
        readOnlySections: document.readOnlySections);
  }

  @override
  Future<RawConfig> readRaw() async {
    final document = await relayedAccessErrors(_api.read);
    return (
      text: document.configJson,
      readOnlySections: document.readOnlySections,
    );
  }

  @override
  Future<ConfigValidation> validate(ConfigDocument doc) =>
      relayedAccessErrors(() => _api.validate(doc.encode()));

  @override
  Future<void> write(ConfigDocument doc, {String? reason}) =>
      relayedAccessErrors(() => _api.write(doc.encode(), reason: reason));

  @override
  Future<bool> hasPrevious() async {
    // read().hasPrevious, NOT previous(): the latter may refuse by name on
    // a never-written file (17-10 deviation 4), so it answers a different
    // question — and it ships the whole previous document besides.
    final document = await relayedAccessErrors(_api.read);
    return document.hasPrevious;
  }

  @override
  Future<void> restorePrevious({String? reason}) =>
      relayedAccessErrors(() => _api.restorePrevious(reason: reason));

  @override
  ApplySemantics get applySemantics => ApplySemantics.restartToApply;

  @override
  bool get hasLiveStatus => false;
}
