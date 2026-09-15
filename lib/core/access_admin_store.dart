/// Moved to `tfc_dart` in Phase 17 so the backend serves the same class the
/// panel calls. Kept as an export so no call site changed and so a `grep` for
/// the old path still lands somewhere true.
///
/// The move, not a second implementation, is the whole of criterion ACCESS-01:
/// a backend copy would have re-derived the `users` gate and the
/// last-`users`-holder invariant that `AccessRepository` evaluates inside its
/// own transaction, and the two would have drifted.
/// `test/core/no_duplicate_access_stores_test.dart` refuses a second copy, and
/// refuses this file growing a declaration of its own.
library;

export 'package:tfc_dart/core/access/access_admin_store.dart';
