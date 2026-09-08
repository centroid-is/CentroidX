import 'dart:convert';
import 'package:dbus/dbus.dart';
import 'generated/ipc-ruler.dart';

class SignalInfo {
  final String name;
  final String description;
  final int sigType;
  final String createdBy;
  final int createdAt;
  final int lastRegistered;

  SignalInfo({
    required this.name,
    required this.description,
    required this.sigType,
    required this.createdBy,
    required this.createdAt,
    required this.lastRegistered,
  });

  factory SignalInfo.fromJson(Map<String, dynamic> json) {
    return SignalInfo(
      name: json['name'],
      description: json['description'],
      sigType: json['type'],
      createdBy: json['created_by'],
      createdAt: json['created_at'],
      lastRegistered: json['last_registered'],
    );
  }
}

class SlotInfo {
  final String name;
  final String description;
  final int slotType;
  final String createdBy;
  final int createdAt;
  final int lastRegistered;
  final int lastModified;
  final String modifiedBy;
  final String connectedTo;

  SlotInfo({
    required this.name,
    required this.description,
    required this.slotType,
    required this.createdBy,
    required this.createdAt,
    required this.lastRegistered,
    required this.lastModified,
    required this.modifiedBy,
    required this.connectedTo,
  });

  factory SlotInfo.fromJson(Map<String, dynamic> json) {
    return SlotInfo(
      name: json['name'],
      description: json['description'],
      slotType: json['type'],
      createdBy: json['created_by'],
      createdAt: json['created_at'],
      lastRegistered: json['last_registered'],
      lastModified: json['last_modified'],
      modifiedBy: json['modified_by'],
      connectedTo: json['connected_to'],
    );
  }
}

class ConnectionChangeEvent {
  final String slotName;
  final String signalName;

  ConnectionChangeEvent({
    required this.slotName,
    required this.signalName,
  });
}

class IpcRulerClient {
  late final OrgFreedesktopDBusProperties _proxy;
  final DBusClient _client;

  // Stream controllers for the wrapped signals
  Stream<ConnectionChangeEvent>? _connectionChangeStream;

  static Future<IpcRulerClient> create(DBusClient client,
      [String serviceName = 'is.centroid.ipc_ruler']) async {
    final instance = IpcRulerClient._(client, serviceName);
    try {
      await instance._proxy.callPing();
      return instance;
    } on DBusServiceUnknownException {
      throw Exception(
          'IPC Ruler service is not running. Please start the service and try again.');
    } catch (e) {
      throw Exception('Failed to connect to IPC Ruler service: $e');
    }
  }

  // Private constructor
  IpcRulerClient._(this._client, String serviceName) {
    // final interface = IsCentroidConfig(_dbusClient, 'is.centroid.Ethercat',
    // DBusObjectPath('/is/centroid/Config/el3356/9'));
    _proxy = OrgFreedesktopDBusProperties(
        _client, serviceName, DBusObjectPath('/is/centroid/ipc_ruler'));
  }

  // Wrapper for connection change events
  Stream<ConnectionChangeEvent> get connectionChanges {
    _connectionChangeStream ??= _proxy.connectionChange
        .map((event) => ConnectionChangeEvent(
            slotName: event.slot_name, signalName: event.signal_name))
        .asBroadcastStream();

    return _connectionChangeStream!;
  }

  Future<List<SignalInfo>> getSignals() async {
    final jsonStr = await _proxy.getSignals();
    final List<dynamic> jsonList = json.decode(jsonStr);
    return jsonList.map((json) => SignalInfo.fromJson(json)).toList();
  }

  Future<List<SlotInfo>> getSlots() async {
    final jsonStr = await _proxy.getSlots();
    final List<dynamic> jsonList = json.decode(jsonStr);
    return jsonList.map((json) => SlotInfo.fromJson(json)).toList();
  }

  Future<void> registerSignal(SignalInfo signal) async {
    await _proxy.callRegisterSignal(
      signal.name,
      signal.description,
      signal.sigType,
    );
  }

  Future<void> registerSlot(SlotInfo slot) async {
    await _proxy.callRegisterSlot(
      slot.name,
      slot.description,
      slot.slotType,
    );
  }

  Future<void> connect(String slotName, String signalName) async {
    await _proxy.callConnect(slotName, signalName);
  }

  Future<void> disconnect(String slotName) async {
    await _proxy.callDisconnect(slotName);
  }

  Future<void> close() async {
    await _client.close();
  }
}
