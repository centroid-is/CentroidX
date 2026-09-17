/// Where this station's [StateManConfig] is stored, split from the types it
/// stores.
///
/// `fromPrefs`/`toPrefs` need the drift-backed [Preferences] — `secret:` and
/// `saveToDb:` are on that class and on nothing else — and `fromFile` needs
/// `dart:io`. Neither is a problem for a browser on its own. What was a
/// problem is that they sat on [StateManConfig], which every HMI asset names
/// through `page_creator/assets/common.dart`, and dragged the whole local
/// database in behind them.
///
/// Re-exported from `state_man.dart`, so a caller that builds a client and
/// reads its config still needs one import.
library;

import 'dart:convert';
import 'dart:io';

import 'preferences.dart';
import 'state_man_types.dart';

/// Reading and writing a [StateManConfig] through a local store.
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
    var configJson =
        await prefs.getString(StateManConfig.configKey, secret: true);
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
