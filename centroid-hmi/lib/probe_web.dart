// Measurement probe: pulls in exactly the eight web routes so `flutter build
// web` reports what their import closure actually drags in. Not shipped.
import 'package:flutter/material.dart';
import 'package:tfc/pages/access_admin.dart';
import 'package:tfc/pages/alarm_editor.dart';
import 'package:tfc/pages/alarm_view.dart';
import 'package:tfc/pages/audit_trail.dart';
import 'package:tfc/pages/page_editor.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/widgets/access_sign_in_dialog.dart';

void main() {
  runApp(const MaterialApp(home: Placeholder()));
  // Keep every route reachable so tree-shaking cannot hide a blocker.
  print([
    AccessAdminPage,
    AlarmEditorPage,
    AlarmViewPage,
    AuditTrailPage,
    PageEditor,
    PlantPageView,
    ServerConfigPage,
    AccessSignInDialog,
  ]);
}
