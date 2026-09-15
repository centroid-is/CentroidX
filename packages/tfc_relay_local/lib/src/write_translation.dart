/// The three-state write classifier — `translateWriteAnswer`, the `WriteAnswer`
/// sealed hierarchy, `UpstreamProtocol`, the refusal tables and the write-status
/// helpers — moved DOWN into tfc_dart in Phase 12 so tfc_dart (which cannot
/// depend on tfc_relay_local) holds the single source of truth. Re-exported here
/// so this package's own call sites and its barrel keep naming them unchanged.
/// This is a legal DOWNward import: tfc_relay_local depends on tfc_dart, never
/// the reverse.
///
/// The `redactUpstreamError` the classifier used to import from this package's
/// `upstream_link.dart` is inlined privately in the moved file (importing
/// upstream would be an illegal UPWARD edge). This package keeps its own
/// `redactUpstreamError` in `upstream_link.dart` for its link/lastError paths.
library;

export 'package:tfc_dart/core/write_translation.dart';
