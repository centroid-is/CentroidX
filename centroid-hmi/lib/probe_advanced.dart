// Measurement probe: main_web's eight routes plus every advanced page that is
// currently excluded, to find out what adding them would actually cost.
import 'package:flutter/material.dart';
import 'package:tfc/pages/about_linux.dart';
import 'package:tfc/pages/config_list.dart';
import 'package:tfc/pages/dbus_login.dart';
import 'package:tfc/pages/ec_topology.dart';
import 'package:tfc/pages/first_user.dart';
import 'package:tfc/pages/history_view.dart';
import 'package:tfc/pages/ip_settings.dart';
import 'package:tfc/pages/ipc_connections.dart';
import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/pages/preferences.dart';
import 'package:tfc/pages/system.dart';
import 'package:tfc/pages/viewtheme.dart';

void main() {
  runApp(const MaterialApp(home: Placeholder()));
  print([
    AboutLinuxPage,
    ConfigListPage,
    LoginForm,
    EcTopologyPage,
    FirstUserPage,
    HistoryViewPage,
    IpSettingsPage,
    ConnectionsPage,
    KeyRepositoryPage,
    PreferencesPage,
    SystemsPage,
    ViewTheme,
  ]);
}
