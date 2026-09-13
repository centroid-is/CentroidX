/// The backend's own `StateManConfig` file, served for reading and writing
/// over the wire — ACCESS-04's server half (17-10, D-10).
///
/// This is a **new capability, not a port**: the panel's Server Config UI
/// reads `StateManConfig.fromPrefs(...)` — its own local preferences — while
/// the backend reads `StateManConfig.fromFile(CENTROID_STATEMAN_FILE_PATH)`
/// (`bin/main.dart:131`). Two stores with no path between them; until this
/// file, adding an OPC UA / M2400 / Modbus server to the backend meant
/// SSH-ing in and editing the file by hand.
///
/// ## Validation before persistence
///
/// A bad config can stop the backend coming back: the file this store writes
/// is the file the backend parses at its next boot. So [write] round-trips
/// the submitted document through `StateManConfig.fromJson` and refuses on
/// any throw, with the parser's own message — "invalid" is not an
/// operator-grade answer and the parser's message names the field. Nothing is
/// written before every check has passed, and the write itself goes to a temp
/// file in the same directory followed by a rename, so a crash mid-write
/// cannot leave a truncated config the backend would fail to parse. That is
/// not gold-plating: a truncated boot file is the exact failure this store
/// exists to prevent.
///
/// ## One level of undo
///
/// Every accepted [write] first copies the live file to `<path>.previous`,
/// byte-identical. [previous] returns that document and [restorePrevious]
/// swaps the two — the rejected config lands at `.previous` in turn, so the
/// operator can go forward again after a failed restart. **One level**, said
/// plainly: a second write overwrites `.previous` with the immediately
/// previous contents. This is an undo buffer, not a history.
///
/// ## The `relay` section is readable and not writable
///
/// D-10, ruled by Jón 2026-09-07: the `relay` section configures the very
/// socket the edit arrives on — its port, its TLS, its token file. Changing
/// it mid-edit is editing sshd_config over ssh: a config screen that can cut
/// itself off is a trap, and the operator who must change the relay port is
/// the operator who can reach the machine. [write] therefore refuses any
/// payload whose `relay` section differs from the live one — compared in
/// **both** directions including presence, because deleting the section is a
/// difference and a present-to-present diff would let a payload turn the
/// relay off. The section is still *readable*: [read] returns it, listed in
/// `readOnlySections`, so the screen shows it greyed rather than pretending
/// it does not exist.
///
/// ## Secrets are redacted on the way out and preserved on the way back
///
/// SECURITY FIX 3 (T-17-10g): the config blob carries cleartext credentials —
/// `OpcUAConfig.password`, and `ssl_key` is a private key's bytes. A naive
/// read would ship them whole to every screen that opens the config page, and
/// `OpcUAConfig.toString` prints the password, so any log of a decoded
/// config would leak it too. So [read] and [previous] replace each secret
/// **value** with [kSecretPreservedSentinel]; a [write] carrying the sentinel
/// means *keep the stored secret*, resolved server-side against the live file
/// by the entry's `endpoint`, so a read-modify-write round trip cannot blank
/// credentials. A sentinel that resolves to nothing — no such endpoint, an
/// ambiguous endpoint, or a stored entry holding no such secret — is a
/// refusal by name, never written as a literal credential. Paths still cross
/// whole (the relay section's `token_file` is a path, not a token): the
/// `TlsConfig` discipline is that paths cross and bytes do not.
///
/// ## No restart, no reload, no signal
///
/// Restart-to-apply, matching the existing config-watch behaviour and Phase
/// 15's ruling: a live switch means tearing down OPC UA sessions and a
/// Postgres pool while widgets hold subscriptions. This store writes the
/// file and does nothing else; the [BackendConfigStore.reloadSignal] seam
/// exists only so that property is a tested fact (arm 16) rather than a
/// comment. The UI copy says so too (17-13).
///
/// ## This file decides nothing about permission
///
/// The `administer` gate is the wire decorator's (`PolicyStateMan`, graded by
/// `AccessPolicy.groupForBackendConfig`), as everywhere else in this phase.
/// The grep arm holds this file's permission-check token count at zero. What
/// this file does record is the audit row — accepted **and refused** writes,
/// attributed to the session the server verified and never to anything a
/// payload contained (ACCESS-06, D-11).
library;

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../state_man_types.dart';
import 'backend_access.dart' show kRelayOrigin;

/// The marker [BackendConfigStore.read] puts where a secret value was, and
/// the marker [BackendConfigStore.write] resolves back to the stored value.
///
/// Reserved: a literal credential equal to this string cannot be written,
/// because the store cannot tell it from the marker. It is deliberately not a
/// string anybody would choose as a password.
const String kSecretPreservedSentinel = '__CENTROID_SECRET_PRESERVED__';

/// The top-level sections a stateman file may carry: the three
/// `StateManConfig` server lists plus the `relay` section `RelayBoot` reads
/// from the same file.
///
/// A payload carrying any other top-level key is refused by name rather than
/// silently stripped or silently written: a typo'd section name gets told,
/// and a smuggled key — arm 13 drives a stray `"who"` — reaches neither the
/// file nor the audit row's attribution.
const Set<String> _knownSections = {'opcua', 'jbtm', 'modbus', 'relay'};

/// The JSON keys whose values are secrets: `OpcUAConfig.password` and
/// `OpcUAConfig.sslKey` (`ssl_key`, a private key). `ssl_cert` is not here —
/// a certificate is presented to the peer anyway — and neither is `username`,
/// an identifier.
const List<String> _secretKeys = ['password', 'ssl_key'];

/// `BackendConfigApi` over the backend's stateman file (D-10's five members).
final class BackendConfigStore implements relay.BackendConfigApi {
  /// [path] nullable on purpose: a backend composed without one still
  /// answers, by refusing every member by name. [session] is the relay
  /// identity's session, kept as a callback (the shape every construction
  /// site of the access stores uses); [station] and the session's username
  /// are what every row this store writes is attributed to.
  ///
  /// [reloadSignal] is the seam a restart-signalling implementation would
  /// call after an accepted write. **This store never calls it** —
  /// restart-to-apply — and it exists only so arm 16 can hold the call count
  /// at zero. Production passes nothing.
  BackendConfigStore({
    required String? path,
    required AccessSession Function() session,
    required String station,
    required AuditSink audit,
    Logger? logger,
    void Function()? reloadSignal,
  })  : _path = path,
        _session = session,
        _station = station,
        _audit = audit,
        _logger = logger ?? Logger(),
        // Held so a mutation that wired it up would be visible to arm 16;
        // nothing in this class invokes it.
        _reloadSignal = reloadSignal;

  final String? _path;
  final AccessSession Function() _session;
  final String _station;
  final AuditSink _audit;
  final Logger _logger;
  // ignore: unused_field — the no-restart seam, deliberately never called.
  final void Function()? _reloadSignal;

  static const _eq = DeepCollectionEquality();
  static const _pretty = JsonEncoder.withIndent('  ');

  // --------------------------------------------------------------------- read

  @override
  Future<relay.BackendConfigDocument> read() async {
    final path = _require('read');
    return _document('read', path);
  }

  @override
  Future<relay.BackendConfigDocument?> previous() async {
    final path = _require('previous');
    final prevPath = '$path.previous';
    if (!File(prevPath).existsSync()) {
      throw StateError(
          'BackendConfigStore.previous has nothing to answer: no accepted '
          'write has ever replaced $path, so there is no previous document. '
          'Refusing rather than answering an empty config, because "nothing '
          'was ever overwritten" and "the previous config is empty" must not '
          'look the same from a screen.');
    }
    return _document('previous', prevPath);
  }

  /// The file at [filePath], secrets redacted, as a wire document.
  Future<relay.BackendConfigDocument> _document(
      String member, String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw StateError(
          'BackendConfigStore.$member found no file at $filePath. Refusing '
          'rather than answering an empty config: "no servers configured" '
          'and "the config file is missing" must not look the same from a '
          'screen. Seed the file on the machine (CENTROID_STATEMAN_FILE_PATH).');
    }
    final raw = await file.readAsString();
    final decoded = _decodeObject(raw,
        onBad: (why) => throw StateError(
            'BackendConfigStore.$member cannot decode $filePath: $why. The '
            'file on disk is not valid JSON; fix it at the machine.'));
    final redacted = _redactInPlace(decoded);
    return relay.BackendConfigDocument(
      // Verbatim when nothing was redacted — the operator's formatting is
      // theirs. Re-encoded when a secret was masked: redaction wins over
      // formatting preservation, deliberately (SECURITY FIX 3).
      configJson: redacted ? _pretty.convert(decoded) : raw,
      readOnlySections: const ['relay'],
      hasPrevious: File('${_path!}.previous').existsSync(),
    );
  }

  // ----------------------------------------------------------------- validate

  @override
  Future<relay.ConfigValidation> validate(String configJson) async {
    final path = _require('validate');
    final prepared = _prepare(path, configJson);
    return relay.ConfigValidation(
      ok: prepared.problems.isEmpty,
      problems: prepared.problems,
    );
  }

  // -------------------------------------------------------------------- write

  @override
  Future<void> write(String configJson, {String? reason}) async {
    final path = _require('write');
    if (!File(path).existsSync()) {
      // No deny row: this is a composition/deployment defect, not a request
      // the trail needs — there is no live config to have protected.
      throw StateError(
          'BackendConfigStore.write found no live file at $path to validate '
          'against and preserve. Seed the file on the machine '
          '(CENTROID_STATEMAN_FILE_PATH); a first config is written where '
          'the backend runs, not over the socket.');
    }
    final prepared = _prepare(path, configJson);
    if (prepared.problems.isNotEmpty) {
      final message = 'BackendConfigStore.write refused: '
          '${prepared.problems.join(' ')}';
      // The deny row goes in BEFORE the throw — a refusal that leaves no
      // trace is the one kind of guard nobody can audit afterwards (D-05).
      await _record(_row(member: 'write', allowed: false, reason: message));
      throw StateError(message);
    }

    // Order is the design: everything above wrote nothing. The previous copy
    // happens before the replace, and the replace is temp-file-then-rename so
    // a crash between any two steps leaves either the old file whole or the
    // new file whole — never a truncated one.
    final original = await File(path).readAsBytes();
    await File('$path.previous').writeAsBytes(original, flush: true);
    await _replaceAtomically(path, utf8.encode(prepared.text!));

    await _record(_row(member: 'write', allowed: true, reason: reason));
  }

  @override
  Future<void> restorePrevious({String? reason}) async {
    final path = _require('restorePrevious');
    final prevFile = File('$path.previous');
    if (!prevFile.existsSync()) {
      const message =
          'BackendConfigStore.restorePrevious has nothing to restore: no '
          'accepted write has ever replaced this file, so there is no '
          'previous document to put back.';
      await _record(
          _row(member: 'restorePrevious', allowed: false, reason: message));
      throw StateError(message);
    }
    // The swap: previous -> live (atomically), then the rejected config ->
    // .previous, so the operator can go forward again after a failed restart.
    final rejected = await File(path).readAsBytes();
    final restored = await prevFile.readAsBytes();
    await _replaceAtomically(path, restored);
    await prevFile.writeAsBytes(rejected, flush: true);
    await _record(_row(member: 'restorePrevious', allowed: true, reason: reason));
  }

  // -------------------------------------------------- validation, in one place

  /// Every check [write] refuses on and [validate] reports, in the order the
  /// plan fixes: decode, section whitelist, sentinel resolution, the
  /// `StateManConfig.fromJson` round trip, the relay comparison. None of
  /// these writes anything.
  _Prepared _prepare(String path, String configJson) {
    final problems = <String>[];

    Object? submittedRaw;
    try {
      submittedRaw = jsonDecode(configJson);
    } on FormatException catch (e) {
      return _Prepared(problems: ['The document is not valid JSON: '
          '${e.message}.']);
    }
    if (submittedRaw is! Map<String, dynamic>) {
      return _Prepared(problems: ['The document\'s top level must be a JSON '
          'object with the configuration sections, not '
          '${submittedRaw.runtimeType}.']);
    }
    final submitted = submittedRaw;

    final unknown = submitted.keys.where((k) => !_knownSections.contains(k));
    if (unknown.isNotEmpty) {
      // Refused by name rather than silently stripped: a typo'd section gets
      // told, and a smuggled key (arm 13's stray `who`) reaches neither the
      // file nor anything downstream of it.
      problems.add('Unknown top-level section(s) '
          '${unknown.map((k) => '`$k`').join(', ')} — the file carries only '
          '${_knownSections.map((k) => '`$k`').join(', ')}.');
      return _Prepared(problems: problems);
    }

    // The live file, needed for sentinel resolution and the relay compare.
    final Map<String, dynamic> live;
    try {
      live = _decodeObject(File(path).readAsStringSync(),
          onBad: (why) => throw FormatException(why));
    } on Object catch (e) {
      problems.add('The live file at $path could not be read for '
          'comparison: $e.');
      return _Prepared(problems: problems);
    }

    final resolvedAny = _resolveSentinels(submitted, live, problems);
    _refuseLeftoverSentinels(submitted, problems);
    if (problems.isNotEmpty) return _Prepared(problems: problems);

    try {
      // The validator is the parser the backend will run at its next boot.
      StateManConfig.fromJson(submitted);
    } on Object catch (e) {
      problems.add('The configuration does not parse: $e');
    }

    final relayProblem = _relayDifference(submitted, live, path);
    if (relayProblem != null) problems.add(relayProblem);
    if (problems.isNotEmpty) return _Prepared(problems: problems);

    return _Prepared(
      problems: const [],
      // Verbatim when no sentinel was resolved — the operator's bytes are
      // the operator's. Re-encoded when secrets were substituted back in.
      text: resolvedAny ? _pretty.convert(submitted) : configJson,
    );
  }

  /// The D-10 refusal, or null when the `relay` sections agree.
  ///
  /// Compared in **both** directions including presence: an absent section
  /// against a present one is a difference in either order, because deleting
  /// the section turns the relay off and adding one turns it on — both are
  /// edits to the socket carrying the edit.
  String? _relayDifference(
      Map<String, dynamic> submitted, Map<String, dynamic> live, String path) {
    final submittedRelay = submitted['relay'];
    final liveRelay = live['relay'];
    final String kind;
    if (submittedRelay == null && liveRelay == null) return null;
    if (submittedRelay == null) {
      kind = 'is absent from the submitted document but present in';
    } else if (liveRelay == null) {
      kind = 'is present in the submitted document but absent from';
    } else if (_eq.equals(submittedRelay, liveRelay)) {
      return null;
    } else {
      kind = 'differs from';
    }
    return 'The `relay` section $kind the live configuration, and it is not '
        'remotely editable: it configures the very socket this edit arrived '
        'on, and you do not edit the socket over the socket. Change it at '
        'the machine ($path) and restart the backend.';
  }

  // ------------------------------------------------------------------ secrets

  /// Replaces every secret value under [_secretKeys] with the sentinel,
  /// anywhere in the tree. Returns whether anything was replaced. Null and
  /// absent secrets stay as they are: a sentinel means "keep the stored
  /// secret", and an entry holding none has nothing to keep.
  bool _redactInPlace(Object? node) {
    var redacted = false;
    if (node is Map) {
      for (final key in _secretKeys) {
        final value = node[key];
        if (value is String && value.isNotEmpty) {
          node[key] = kSecretPreservedSentinel;
          redacted = true;
        }
      }
      for (final value in node.values) {
        redacted = _redactInPlace(value) || redacted;
      }
    } else if (node is List) {
      for (final value in node) {
        redacted = _redactInPlace(value) || redacted;
      }
    }
    return redacted;
  }

  /// Resolves each sentinel in [submitted]'s `opcua` entries back to the
  /// stored value in [live], matched by the entry's `endpoint`. Appends a
  /// problem — and resolves nothing — for a sentinel that matches no stored
  /// server, more than one, or a stored entry holding no such secret: the
  /// marker must never be guessed about and never written as a literal.
  bool _resolveSentinels(Map<String, dynamic> submitted,
      Map<String, dynamic> live, List<String> problems) {
    var resolvedAny = false;
    final submittedOpcua = submitted['opcua'];
    final liveOpcua = live['opcua'];
    if (submittedOpcua is! List) return false;
    for (final entry in submittedOpcua) {
      if (entry is! Map) continue;
      for (final key in _secretKeys) {
        if (entry[key] != kSecretPreservedSentinel) continue;
        final endpoint = entry['endpoint'];
        final matches = liveOpcua is List
            ? liveOpcua
                .whereType<Map>()
                .where((s) => s['endpoint'] == endpoint)
                .toList()
            : const <Map>[];
        if (matches.isEmpty) {
          problems.add('A preserved-secret marker on `$key` references a '
              'server the stored configuration does not have '
              '(endpoint: $endpoint). The marker means "keep the stored '
              'secret" and there is nothing stored to keep — submit the '
              'secret explicitly for a new server.');
        } else if (matches.length > 1) {
          problems.add('A preserved-secret marker on `$key` is ambiguous: '
              'the stored configuration has ${matches.length} servers at '
              'endpoint $endpoint, and the store will not guess which '
              'credential to attach.');
        } else if (matches.single[key] is! String) {
          problems.add('A preserved-secret marker on `$key` references a '
              'secret the stored server at $endpoint does not hold — submit '
              'it explicitly.');
        } else {
          entry[key] = matches.single[key];
          resolvedAny = true;
        }
      }
    }
    return resolvedAny;
  }

  /// After resolution no sentinel may remain anywhere: one that survived is
  /// one that would be written to disk as a literal credential.
  void _refuseLeftoverSentinels(Object? node, List<String> problems) {
    if (node is Map) {
      for (final e in node.entries) {
        if (e.value == kSecretPreservedSentinel) {
          problems.add('A preserved-secret marker survived on `${e.key}` '
              'where no stored secret exists to preserve; it will not be '
              'written as a literal value.');
        } else {
          _refuseLeftoverSentinels(e.value, problems);
        }
      }
    } else if (node is List) {
      for (final v in node) {
        _refuseLeftoverSentinels(v, problems);
      }
    }
  }

  // ----------------------------------------------------------------- plumbing

  /// Temp file in the same directory, then rename: [path] is what the
  /// backend parses at its next boot, and a crash mid-write must leave the
  /// old file whole or the new file whole — never a truncated one.
  Future<void> _replaceAtomically(String path, List<int> bytes) async {
    final temp = File('$path.tmp-${newActionId()}');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(path);
  }

  /// UTF-8 JSON object or [onBad] — the two failure shapes named apart.
  Map<String, dynamic> _decodeObject(String raw,
      {required Never Function(String why) onBad}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      onBad(e.message);
    }
    if (decoded is! Map<String, dynamic>) {
      onBad('the top level is ${decoded.runtimeType}, not a JSON object');
    }
    return decoded;
  }

  /// The refusal shape, from `backend_state_man.dart:90`: the member as it is
  /// spelled here, the collaborator that is missing, one sentence saying what
  /// to change.
  String _require(String member) {
    final path = _path;
    if (path == null) {
      throw UnsupportedError(
          'BackendConfigStore.$member is not available: this store was '
          'composed without the backend\'s config file path, so there is no '
          'file to serve or protect — and "no servers configured" and '
          '"nobody wired a path" must not look the same from a screen. Hand '
          'CENTROID_STATEMAN_FILE_PATH to the store where the relay identity '
          'is minted (bin/main.dart\'s relay block).');
    }
    return path;
  }

  /// One audit row. `who` comes from the session and from nowhere else —
  /// there is no parameter through which a payload could name somebody else
  /// (ACCESS-06, D-11). The config content itself is deliberately NOT in the
  /// row: the blob can carry credentials, and `oldValue`/`newValue` are not
  /// withheld from logs on this surface.
  AuditRecord _row({
    required String member,
    required bool allowed,
    String? reason,
  }) {
    final session = _session();
    return AuditRecord(
      at: DateTime.now(),
      who: session.user?.username ?? 'anonymous',
      station: _station,
      roleName: session.roleName,
      surface: AccessSurface.backendConfig.wireName,
      itemKey: _path!,
      member: member,
      groupRequired: const AccessPolicy().groupForBackendConfig(member).name,
      allowed: allowed,
      origin: kRelayOrigin,
      reason: reason,
      actionId: newActionId(),
    );
  }

  /// Append [row], and never let the sink's failure become the caller's —
  /// the same rule, in the same words, as the access stores: a plant write
  /// must not fail because the audit database blinked, but the lost row is
  /// logged loudly because an absent audit row is the one defect nobody
  /// notices.
  Future<void> _record(AuditRecord row) async {
    try {
      await _audit.record(row);
    } on Object catch (error, stack) {
      _logger.e(
        'AUDIT ROW LOST: action ${row.actionId}, ${row.who} on '
        '${row.surface}:${row.itemKey}, allowed: ${row.allowed}',
        error: error,
        stackTrace: stack,
      );
    }
  }
}

/// What [_prepare] answers: refusal sentences, or the exact text to write.
final class _Prepared {
  const _Prepared({required this.problems, this.text});

  /// Operator-readable sentences, empty when the document would be written.
  final List<String> problems;

  /// The bytes-to-be (as text): the submitted document verbatim, or the
  /// re-encoded tree when preserved secrets were resolved back in. Null when
  /// [problems] is non-empty.
  final String? text;
}
