/// Moved to `tfc_dart` in Phase 17 so the backend serves the same class the
/// panel calls. Kept as an export so no call site changed and so a `grep` for
/// the old path still lands somewhere true.
///
/// This store is read-only and ungated by construction — its enforcement is
/// the route gate `kRaisedRoutes['/advanced/audit-trail']` (05-07), not a store
/// check, because a guard here would write a row into the trail every time
/// somebody scrolled the trail. The move changes none of that: the source-text
/// assertions in `test/core/audit_trail_store_test.dart` follow the file to its
/// new path rather than staying pointed at this one, where they would have
/// passed vacuously against ten lines of export.
library;

export 'package:tfc_dart/core/access/audit_trail_store.dart';
