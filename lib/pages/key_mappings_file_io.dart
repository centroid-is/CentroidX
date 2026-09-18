import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Writes [json] where the operator chooses, and answers where it went.
///
/// Null means they dismissed the dialog. The desktop platforms get a real save
/// dialog; anything else (the panel embedders, which have no file chooser) gets
/// a timestamped file in the documents directory, which is what this page has
/// always done.
Future<String?> saveKeyMappingsFile(String json) async {
  String? savePath;
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Key Mappings',
      fileName: 'key_mappings.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
  } else {
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    savePath = path.join(dir.path, 'key_mappings_$ts.json');
  }
  if (savePath == null) return null;

  final file = File(savePath);
  await file.writeAsString(json);
  return file.path;
}

/// The JSON text of a file the operator picked, or null if they dismissed it.
Future<String?> pickKeyMappingsFile() async {
  final pick = await FilePicker.platform.pickFiles(
    dialogTitle: 'Import Key Mappings',
    type: FileType.custom,
    allowedExtensions: ['json'],
  );
  if (pick == null || pick.files.isEmpty) return null;
  return File(pick.files.single.path!).readAsString();
}
