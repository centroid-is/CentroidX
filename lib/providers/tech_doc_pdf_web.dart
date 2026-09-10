import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Always null: the knowledge base is not part of the web client, so no
/// document has bytes here.
///
/// Null rather than an error because null is what the real provider answers
/// for a document that is not in the index, and `drawing_viewer.dart` already
/// handles that by leaving the drawing pane empty.
final techDocPdfBytesProvider =
    FutureProvider.family<Uint8List?, int>((ref, docId) async => null);
