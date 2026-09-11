/// One corruption: the `at` on an applied write answer, and nothing else.
///
/// **Why it is a support file rather than a private helper in one case.** Two
/// files need it — `write_readback_freshness_test.dart` ages the stamp, and
/// `write_answer_ingress_test.dart` puts values on it that this process could
/// not encode — and the alternative was one test library importing another,
/// which drags a second `main` and a second set of suite annotations into the
/// first one's compilation for the sake of a two-line function.
///
/// **Why it is a string substitution and not a decode / re-encode.** The point
/// of the instrument is to put numbers on the wire that this process would
/// *refuse to emit*: `jsonEncode` throws on `Infinity`, so a helper that
/// round-tripped through a `Map` could only produce stamps Dart is already
/// willing to write, and the hostile half of the ingress — the half `1e999`
/// occupies, which `jsonDecode` accepts in silence — would be inexpressible.
///
/// **Why it lands on the write answer alone.** `"outcome"` is
/// `WriteResult.toJson`'s discriminator and appears in no other message the
/// gateway sends, which is the argument `truncated_write_test.dart:44-47`
/// makes for the same match. So the ticks, the snapshot and the value
/// notifications around it are delivered verbatim and whatever the case
/// observes afterwards is attributable to this one change.
library;

import 'package:tfc_stateman_contract/channel_harness.dart';

/// The `at` field of an applied write answer, as it appears on the wire.
///
/// Anchored on the discriminator so a `rejected` or `unknown` answer — which
/// carry an optional `at` of their own — is left alone: a case that meant to
/// age an applied readback and silently aged a refusal instead would be
/// asserting about a path it never touched.
final RegExp _appliedAt = RegExp(r'"at":-?[0-9][0-9.eE+-]*');

/// Replaces the applied answer's `at` with [atLiteral], verbatim.
///
/// [atLiteral] is spliced in as raw JSON text and is deliberately not
/// validated: `1e999`, `100000000000000000` and `"tuesday"` are all things a
/// peer can put on this wire, and an instrument that only accepted stamps this
/// process considers reasonable could not test what happens when one is not.
MessageCorruption restampAppliedWriteAnswer(String atLiteral) => (message) {
      if (!message.contains('"outcome":"applied"')) return message;
      return message.replaceFirst(_appliedAt, '"at":$atLiteral');
    };
