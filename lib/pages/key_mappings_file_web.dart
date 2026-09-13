import 'dart:convert';
import 'dart:js_interop';

import 'package:file_picker/file_picker.dart';
import 'package:web/web.dart' as web;

/// Hands [json] to the browser as a download.
///
/// Answers the filename rather than a path: there is no path to answer, the
/// browser decides where its downloads land, and the page's confirmation strip
/// says where the file went. Never null — a download cannot be "cancelled" from
/// here, and reporting a cancellation that did not happen would be worse than
/// the small imprecision of saying it was saved.
Future<String?> saveKeyMappingsFile(String json) async {
  final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
  final name = 'key_mappings_$ts.json';

  // A data: URL rather than a blob: the mappings are a few hundred kilobytes of
  // text at the outside, and a data URL needs no object-URL lifetime to manage
  // — nothing to revoke, nothing to leak if the tab closes mid-click.
  final href =
      'data:application/json;charset=utf-8,${Uri.encodeComponent(json)}';
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = href
    ..download = name
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  return name;
}

/// The JSON text of a file the operator picked, or null if they dismissed it.
///
/// `withData: true` because a browser hands over bytes, not a path —
/// `PlatformFile.path` is always null on web, and the io arm's `File(path)` is
/// exactly the line that could not come along.
Future<String?> pickKeyMappingsFile() async {
  final pick = await FilePicker.platform.pickFiles(
    dialogTitle: 'Import Key Mappings',
    type: FileType.custom,
    allowedExtensions: ['json'],
    withData: true,
  );
  if (pick == null || pick.files.isEmpty) return null;
  final bytes = pick.files.single.bytes;
  if (bytes == null) return null;
  return utf8.decode(bytes);
}
