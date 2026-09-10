/// Where this station's [StateManConfig] is stored, split from the OPC UA
/// client that consumes it.
///
/// `fromPrefs`/`toPrefs` need the drift-backed [Preferences] — `secret:` and
/// `saveToDb:` are on that class and not on `PreferencesApi` — and `fromFile`
/// needs `dart:io`. None of that is a problem for a browser. What was a problem
/// is that they lived in `state_man.dart`, whose other occupant is
/// `OpcUaStateMan`, and that imports `package:open62541` — `dart:ffi`, which
/// dart2js will not compile. The Server Config page reads and writes this
/// config and has no business linking an OPC UA client to do it.
library;

import 'dart:convert';
import 'dart:io';

import 'preferences.dart';
import 'state_man_types.dart';

/// Reading and writing a [StateManConfig] through a local store.
///
/// These three are not on [StateManConfig] itself because they are the only
/// part of it that needs a filesystem or a database — `secret:` and
/// `saveToDb:` exist on the drift-backed `Preferences` and on nothing else. A
/// client whose preferences arrive over the relay has no use for any of them.
extension StateManConfigStorage on StateManConfig {
  static Future<StateManConfig> fromFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('Config file not found: $path');
    }
    final contents = await file.readAsString();
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(contents) as Map<String, dynamic>;
    } on FormatException catch (e) {
      throw Exception('Invalid JSON in config file: $path - ${e.message}');
    }
    return StateManConfig.fromJson(json);
  }

  static Future<StateManConfig> fromPrefs(Preferences prefs) async {
    var configJson = await prefs.getString(StateManConfig.configKey, secret: true);
    if (configJson == null) {
      configJson = jsonEncode(StateManConfig(opcua: [OpcUAConfig()]).toJson());
      await prefs.setString(StateManConfig.configKey, configJson,
          secret: true, saveToDb: false);
    }
    return StateManConfig.fromJson(jsonDecode(configJson));
  }

  Future<void> toPrefs(Preferences prefs) async {
    final configJson = jsonEncode(toJson());
    await prefs.setString(StateManConfig.configKey, configJson,
        secret: true, saveToDb: false);
  }
}
