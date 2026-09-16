/// The lid-inspection record store, resolved from the station database.
///
/// Null when this station has no database configured — the Lid inspection
/// asset then shows live state from OPC UA only and says that images are
/// unavailable, rather than failing. Tests override this with a fake.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/lid_inspection.dart';

import 'database.dart';

final lidInspectionStoreProvider =
    FutureProvider<LidInspectionStore?>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  if (db == null) return null;
  return DatabaseLidInspectionStore(db.db);
});
