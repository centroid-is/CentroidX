/// The write-outcome log, which now lives in `tfc_relay_protocol`.
///
/// This file was the class. It is a re-export because the class turned out to
/// exist twice: `tfc_dart`'s `BackendWriteOutcomeLog` was byte-identical to it
/// across nine members, with no comment on either side saying so. The shared
/// copy is `tfc_relay_protocol/lib/src/write_outcome_log.dart`, and the whole
/// argument — why `not_received` needs positive evidence, why the log outlives
/// every socket (04-REVIEW CR-02), and why `tfc_relay_local`'s five-answer log
/// is a third design that is deliberately NOT merged — is in that file's
/// library doc.
///
/// The re-export stays rather than the imports being rewritten, because every
/// existing `import 'write_outcome_log.dart'` in this package keeps working and
/// a mechanical edit across the package would have been a larger diff than the
/// move it was serving.
///
/// **One behaviour changed in the move, deliberately:** [WriteFingerprint] is
/// now **required and non-nullable** on `record`. This package's copy allowed a
/// null one and refused every replay of such an entry; the branch was already
/// dead in production — both record sites in `value_handlers.dart` have the
/// decoded `WriteParams` in scope — and `tfc_dart`'s shape, which made the
/// unsafe state unrepresentable, is the one that survived. See 18-04-SUMMARY.
library;

export 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show WriteFingerprint, WriteOutcomeEntry, WriteOutcomeLog;
