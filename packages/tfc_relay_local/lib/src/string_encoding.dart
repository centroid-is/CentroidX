/// Per-server string encoding, and the quality code that makes a bad decode
/// visible.
///
/// ## The failure is not a crash
///
/// Every decode path in this stack today is
/// `utf8.decode(bytes, allowMalformed: true)` — the binding at
/// `extensions.dart:416`, jbtm at `m2400.dart:135`, UMAS at
/// `umas_types.dart:870-880`. Against a Latin-1 device that turns `Þ` into
/// U+FFFD and keeps going, under a **good** quality, with nothing in any log.
/// That is silent mojibake, and it is the worse of the two failures: an
/// exception gets somebody's attention, and a product name rendered
/// `<?>orskfl<?>k <?> raspi` on a packing-hall screen gets a shrug.
///
/// Design §6 rule 4 asks for per-server string encoding for exactly this, and
/// [Quality.uncertainEncoding] (260) — *"source bytes were not valid in the
/// configured string encoding; replacement characters were substituted"* — has
/// been defined and unreferenced in production since Phase 0 waiting for it.
///
/// ## Why Latin-1 and not "try harder"
///
/// `packages/tfc_mcp_server/lib/src/parser/source_encoding.dart:20-24` is the
/// one place in this repository that already reasoned this through, and the
/// reasoning is copied rather than re-derived: **every Icelandic letter — þ æ ö
/// ð and the rest — lives inside Latin-1**, so `latin1` is *exact* where
/// `allowMalformed` is lossy. Latin-1 also maps all 256 byte values, so it can
/// never itself throw: a buffer that is neither encoding degrades to mojibake
/// rather than being dropped.
///
/// ## Why the decision lives in this package
///
/// **This is the only layer that knows which server a byte came from.** The
/// binding does not; jbtm does not; both are shared with the app and neither
/// has a server alias in scope at the point of the decode. So the *policy* is
/// here and the two foreign packages get one additive optional parameter each,
/// whose default reproduces exactly what they did yesterday.
///
/// ## What is wired, and what is not
///
/// **Wired end to end, since 08-REVIEW WR-01:** the M2400 weighers and the
/// Modbus/UMAS devices. `buildUpstreamLink` is the one place that knows both
/// the alias and the client being constructed, so the decoder is threaded from
/// there into `M2400ClientWrapper.decodeBytes` and into
/// `buildModbusDeviceClients`' `decodeStringFor`, which reaches every
/// `UmasClient` the adapter builds — including the MonitorPlc (0x50) read path
/// the M580 prefers, because a decoder wired into only one of the two roads a
/// STRING takes out of a PLC is a per-server encoding that works until
/// somebody's controller picks the other one. `encoding_test.dart` proves it
/// over a real socket and `freeze_test.dart`'s freeze 7 pins that a caller
/// exists.
///
/// What shipped in 08-10 was the mechanism plus its unit tests with **no
/// caller anywhere in `lib/`** — the config field was parsed, validated and
/// echoed back in `toJson`, and every actual decode was still
/// `utf8.decode(…, allowMalformed: true)`. That is worth recording because it
/// is the failure shape this whole module is about: nothing errored, and the
/// symptom was plausible text.
///
/// **Still NOT wired: OPC UA.** Raw bytes are not reachable through
/// `ClientApi` — the binding decodes before Dart sees anything
/// (`extensions.dart:416`, `types/payloads.dart:235,266`) — so an encoding
/// hook there is a change to the binding, not to this package. It stays a
/// named follow-up. A deployment that sets `string_encoding: latin1` on an
/// **opcua** link today gets no effect from it, and that is the honest
/// statement of the remaining gap.
///
/// It is a completeness item rather than a plant-visible one: SVN's OPC UA
/// servers are TwinCAT, which emits UTF-8, and the plant's Latin-1 sources are
/// the M2400 weighers and the Saia-over-Modbus box erector — both now covered.
library;

import 'dart:convert';

import 'package:tfc_dart/core/state_man.dart' show StateManConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The two encodings a configured server may declare.
///
/// Deliberately two and not "any `Encoding`". A plant configuration file that
/// can name `shift_jis` is a configuration file that can name a typo, and the
/// answer to a third real encoding is a third enum value plus the case that
/// proves it — not an open door.
enum ServerStringEncoding {
  /// The default, and what every path in this stack does today.
  utf8,

  /// The plant's Latin-1 devices: the weighers, and the Saia-over-Modbus box
  /// erector (08-RESEARCH §H.3).
  latin1,
}

/// Which encoding each configured server speaks.
///
/// **Per alias.** One Latin-1 weigher does not make the TwinCAT PLC beside it
/// Latin-1, and a global switch is how the wrong half of a plant gets mojibake
/// instead of the right half getting fixed.
final class StringEncodingConfig {
  const StringEncodingConfig({
    Map<String, ServerStringEncoding> byAlias =
        const <String, ServerStringEncoding>{},
    this.fallback = ServerStringEncoding.utf8,
  }) : _byAlias = byAlias;

  final Map<String, ServerStringEncoding> _byAlias;

  /// What an alias with no entry gets. UTF-8, because that is what the stack
  /// does today and a silent change of default is the thing this whole module
  /// exists to prevent.
  final ServerStringEncoding fallback;

  /// The encoding configured for [alias], or [fallback].
  ///
  /// Normalised through `StateManConfig.normalizeAlias`, which is what every
  /// other alias comparison in this gateway uses. A table that matched
  /// case-sensitively would silently miss the server it was configured for and
  /// the symptom would be… mojibake, which is the symptom it was added to fix.
  ServerStringEncoding encodingFor(String alias) {
    final wanted = StateManConfig.normalizeAlias(alias);
    for (final entry in _byAlias.entries) {
      if (StateManConfig.normalizeAlias(entry.key) == wanted) return entry.value;
    }
    return fallback;
  }
}

/// One decoded string and the quality it earned.
typedef DecodedPlantString = ({String text, Quality quality});

/// A byte decoder, as the two foreign packages take it.
typedef PlantStringDecoder = String Function(List<int> bytes);

/// Decodes [bytes] under [encoding], reporting whether it had to guess.
///
/// Three outcomes, and the middle one is the point:
///
///  * **[Quality.good]** — the bytes decoded **without loss** in the
///    configured encoding. On the `utf8` branch that also means they were
///    valid UTF-8, which is real evidence. On the `latin1` branch it means
///    only that: Latin-1 maps all 256 byte values, so *every* buffer decodes
///    without loss and `good` is **not** evidence the text is correct
///    (08-REVIEW WR-10). The only defence against an alias configured to the
///    wrong encoding is the configuration.
///  * **[Quality.uncertainEncoding]** — the bytes were not valid UTF-8 on a
///    `utf8` alias (replacement characters were substituted), **or** they look
///    like UTF-8 on a `latin1` alias. See below for the second case; it is the
///    cheap half of the defence WR-10 asked for.
///  * There is no bad/error outcome. A string that will not decode is still a
///    reading, and blanking it would throw away the only information there is.
///
/// ## The misconfiguration signal, and why it has no false positives
///
/// A UTF-8 device wrongly configured as `latin1` used to be *silent*:
/// `Þorskflök` arrived as `ÃžorskflÃ¶k` under a good quality with nothing
/// anywhere saying so — the same mojibake this module exists to end, relocated
/// from "wrong default" to "wrong config", and the more likely mistake now
/// that the encoding is a per-alias field somebody types.
///
/// A buffer that is **also valid multi-byte UTF-8** on a `latin1` alias is
/// strong evidence of that mistake, because valid multi-byte UTF-8 sequences
/// do not occur by accident in genuine Latin-1 text: they require a lead byte
/// in `0xC2–0xF4` followed by exactly the right number of `0x80–0xBF`
/// continuation bytes, which in Latin-1 reads as `Â`, `Ã`, `Ð` and friends
/// followed by control characters and punctuation. Pure ASCII cannot trigger
/// it — the check requires at least one byte above 0x7F — so the ordinary case
/// is untouched.
///
/// The **text is still the Latin-1 decode**: the configuration is what says
/// which encoding this server speaks, and this function's job is to flag a
/// doubt rather than to overrule it. A quality an operator can see beats a
/// guess they cannot.
///
/// S7-style NUL padding is stripped first: a fixed-width `STRING` buffer is
/// padded to its declared size and the padding is not part of the product name.
/// Everything at and after the first NUL goes, which is also what
/// `umas_types.dart:876-878` already does and must keep doing.
DecodedPlantString decodePlantString(
  List<int> bytes, {
  required ServerStringEncoding encoding,
}) {
  final trimmed = _beforeFirstNul(bytes);
  switch (encoding) {
    case ServerStringEncoding.latin1:
      // Cannot throw: all 256 byte values map. Exact for every Icelandic
      // letter, which is the entire reason this branch exists — and it is also
      // why `good` here cannot mean "correct", only "without loss".
      return (
        text: latin1.decode(trimmed),
        quality: _looksLikeUtf8(trimmed)
            ? Quality.uncertainEncoding
            : Quality.good,
      );
    case ServerStringEncoding.utf8:
      try {
        return (text: utf8.decode(trimmed), quality: Quality.good);
      } on FormatException {
        return (
          text: utf8.decode(trimmed, allowMalformed: true),
          quality: Quality.uncertainEncoding,
        );
      }
  }
}

/// [decodePlantString], as a value a link can publish.
///
/// The quality rides on the [DynamicValue] rather than being logged, because a
/// log is not something an operator reads and a quality badge is.
DynamicValue decodePlantStringValue(
  List<int> bytes, {
  required ServerStringEncoding encoding,
  DateTime? sourceTime,
}) {
  final decoded = decodePlantString(bytes, encoding: encoding);
  return DynamicValue(
    value: decoded.text,
    quality: decoded.quality,
    sourceTime: sourceTime ?? DateTime.now().toUtc(),
  );
}

/// The decoder to hand to `jbtm` or to `umas_types`, for a server on
/// [encoding].
///
/// The foreign packages take a plain `String Function(List<int>)` and know
/// nothing about aliases or qualities — that is the seam. What is lost across
/// it is the quality: a decoder returning a `String` cannot report that it fell
/// back, so a caller that needs the 260 uses [decodePlantString] directly and
/// this is for the paths where the framing owns the decode.
PlantStringDecoder latin1DecoderFor(ServerStringEncoding encoding) =>
    (bytes) => decodePlantString(bytes, encoding: encoding).text;

/// Whether [bytes] are valid **multi-byte** UTF-8 — the wrong-alias signal.
///
/// Two conditions, and both are load-bearing (08-REVIEW WR-10):
///
///  * at least one byte above 0x7F, so pure ASCII — which is valid in both
///    encodings and says nothing about either — can never trigger it; and
///  * the whole buffer decodes as strict UTF-8, so a genuine Latin-1 string
///    that happens to contain one accented letter does not either.
///
/// False negatives are fine and expected: this is a cheap signal, not a
/// detector. What it must not do is cry wolf on correct Latin-1, because a
/// quality code an operator learns to ignore is worse than no quality code.
bool _looksLikeUtf8(List<int> bytes) {
  if (!bytes.any((b) => b > 0x7f)) return false;
  try {
    utf8.decode(bytes);
    return true;
  } on FormatException {
    return false;
  }
}

/// Everything before the first NUL, or all of it if there is none.
List<int> _beforeFirstNul(List<int> bytes) {
  final nul = bytes.indexOf(0);
  return nul < 0 ? bytes : bytes.sublist(0, nul);
}
