/// The acquisition worker body and its supervisor now live in `lib/core/` so
/// that tests (and `bin/main.dart`) can reach them through a `package:` URI
/// like every other symbol in this package. This file stays only so the old
/// relative import in `bin/main.dart` keeps resolving.
export 'package:tfc_dart/core/data_acquisition_isolate.dart';
