import 'dart:convert';
import 'package:dbus/dbus.dart';
import 'generated/config.dart';

class ConfigClient {
  late final OrgFreedesktopDBusPeer _proxy;
  final DBusClient _client;

  static Future<ConfigClient> create(DBusClient client, DBusObjectPath path,
      [String serviceName = 'is.centroid.Config']) async {
    final instance = ConfigClient._(client, serviceName, path);
    try {
      await instance._proxy.callPing();
      return instance;
    } on DBusServiceUnknownException {
      throw Exception(
          'Config service is not running. Please start the service and try again.');
    } catch (e) {
      throw Exception('Failed to connect to Config service: $e');
    }
  }

  // Private constructor
  ConfigClient._(this._client, String serviceName, DBusObjectPath path) {
    _proxy = OrgFreedesktopDBusPeer(_client, serviceName, path);
  }

  /// Get the current schema
  Future<String> getSchema() async {
    return await _proxy.getSchema();
  }

  /// Get the current config value
  Future<String> getValue() async {
    return await _proxy.getValue();
  }

  /// Set a new config value
  Future<void> setValue(String value) async {
    await _proxy.setValue(value);
  }

  /// Get the config value as parsed JSON
  Future<dynamic> getValueAsJson() async {
    final value = await getValue();
    return json.decode(value);
  }

  /// Set a config value from a JSON object
  Future<void> setValueFromJson(dynamic value) async {
    final jsonStr = json.encode(value);
    await setValue(jsonStr);
  }

  /// Stream of property changes
  Stream<OrgFreedesktopDBusPeerPropertiesChanged> get propertiesChanged {
    return _proxy.customPropertiesChanged;
  }

  Future<void> close() async {
    await _client.close();
  }
}
