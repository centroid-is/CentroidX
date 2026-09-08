import 'package:flutter/material.dart';
import 'package:dbus/dbus.dart';
import 'package:logger/logger.dart';
import 'dart:async';
import '../widgets/base_scaffold.dart';
import 'config_edit.dart';

class ConfigListPage extends StatefulWidget {
  final DBusClient dbusClient;

  const ConfigListPage({
    Key? key,
    required this.dbusClient,
  }) : super(key: key);

  @override
  State<ConfigListPage> createState() => _ConfigListPageState();
}

class _ConfigListPageState extends State<ConfigListPage> {
  bool _isLoading = false;
  String _error = '';
  List<_ConfigInterfaceInfo> _foundConfigs = [];
  final _logger = Logger();
  static const timeout = Duration(seconds: 1);

  @override
  void initState() {
    super.initState();
    _scanConfigs();
  }

  Future<void> _scanConfigs() async {
    _logger.d('Starting config scan...');
    setState(() {
      _isLoading = true;
      _error = '';
      _foundConfigs.clear();
    });

    try {
      // 1) Get all bus names
      _logger.d('Fetching bus names...');
      final reply = await widget.dbusClient.callMethod(
        destination: 'org.freedesktop.DBus',
        path: DBusObjectPath('/org/freedesktop/DBus'),
        interface: 'org.freedesktop.DBus',
        name: 'ListNames',
        values: <DBusValue>[],
      ).timeout(timeout);

      if (reply.returnValues.isEmpty) {
        throw Exception('No bus names returned!');
      }

      // Filter names early to reduce processing
      final allNames = (reply.returnValues.first as DBusArray)
          .children
          .map((e) => (e as DBusString).value)
          .where((name) =>
              !name.startsWith('org.freedesktop.') &&
              !name.startsWith(
                  ':')) // Skip both system services and unique names
          .toList();

      _logger.d('Found ${allNames.length} relevant bus names');

      // 3) Scan services in parallel with a limit
      final List<_ConfigInterfaceInfo> found = [];
      final seenPaths = <String>{};

      // Process services in batches to avoid overwhelming the system
      const batchSize = 5;
      for (var i = 0; i < allNames.length; i += batchSize) {
        final batch = allNames.skip(i).take(batchSize);
        final results = await Future.wait(
          batch.map((serviceName) => _scanService(serviceName, seenPaths)),
          eagerError: false, // Continue even if some fail
        );

        for (final configs in results) {
          if (configs != null) {
            // null means service scan failed
            found.addAll(configs);
          }
        }
      }

      _logger.i('Scan complete. Found ${found.length} total configs');
      if (mounted) {
        setState(() {
          _foundConfigs = found;
          _isLoading = false;
        });
      }
    } catch (err) {
      _logger.e('Scan failed with error: $err');
      if (mounted) {
        setState(() {
          _error = err.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<List<_ConfigInterfaceInfo>?> _scanService(
    String serviceName,
    Set<String> seenPaths,
  ) async {
    _logger.d('Introspecting service: $serviceName');
    try {
      final result = await widget.dbusClient
          .callMethod(
            destination: serviceName,
            path: DBusObjectPath('/'),
            interface: 'org.freedesktop.DBus.Introspectable',
            name: 'Introspect',
            replySignature: DBusSignature('s'),
          )
          .timeout(timeout);

      final node = parseDBusIntrospectXml(result.returnValues.first.asString());
      final configs = await _scanNodeForConfigInterfaces(
        serviceName,
        DBusObjectPath('/'),
        node,
      );

      final uniqueConfigs = configs.where((config) {
        final pathKey = '${config.serviceName}:${config.objectPath}';
        if (seenPaths.contains(pathKey)) return false;
        seenPaths.add(pathKey);
        return true;
      }).toList();

      _logger.d('Found ${uniqueConfigs.length} configs in $serviceName');
      return uniqueConfigs;
    } catch (e) {
      _logger.w('Failed to introspect $serviceName: $e');
      return null;
    }
  }

  Future<List<_ConfigInterfaceInfo>> _scanNodeForConfigInterfaces(
    String serviceName,
    DBusObjectPath path,
    DBusIntrospectNode node,
  ) async {
    final List<_ConfigInterfaceInfo> matches = [];

    // Skip filtered paths early
    if (path.value.contains('/Config/filters/')) {
      return matches;
    }

    // Check for config interface
    if (node.interfaces.any((iface) => iface.name == 'is.centroid.Config')) {
      matches.add(_ConfigInterfaceInfo(serviceName, path.value));
    }

    // Process child nodes in parallel
    final childResults = await Future.wait(
      node.children.map((subnode) async {
        final childPath = path.value.endsWith('/')
            ? '${path.value}${subnode.name}'
            : '${path.value}/${subnode.name}';
        try {
          final result = await widget.dbusClient
              .callMethod(
                destination: serviceName,
                path: DBusObjectPath(childPath),
                interface: 'org.freedesktop.DBus.Introspectable',
                name: 'Introspect',
                replySignature: DBusSignature('s'),
              )
              .timeout(timeout);

          final childNode =
              parseDBusIntrospectXml(result.returnValues.first.asString());
          return _scanNodeForConfigInterfaces(
            serviceName,
            DBusObjectPath(childPath),
            childNode,
          );
        } catch (e) {
          _logger.t('Failed to scan child path $childPath: $e');
          return <_ConfigInterfaceInfo>[];
        }
      }),
      eagerError: false,
    );

    matches.addAll(childResults.expand((x) => x));
    return matches;
  }

  @override
  Widget build(BuildContext context) {
    return BaseScaffold(
      title: 'Available Configs',
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
              ? Center(child: Text('Error: $_error'))
              : _foundConfigs.isEmpty
                  ? const Center(child: Text('No configs found.'))
                  : ListView.builder(
                      itemCount: _foundConfigs.length,
                      itemBuilder: (context, index) {
                        final info = _foundConfigs[index];
                        return ListTile(
                          title:
                              Text('${info.serviceName} - ${info.objectPath}'),
                          onTap: () {
                            // Instead of beaming, open a dialog
                            showDialog(
                              context: context,
                              barrierDismissible: false, // Force user to choose
                              builder: (_) => ConfigEditDialog(
                                dbusClient: widget.dbusClient,
                                serviceName: info.serviceName,
                                objectPath: info.objectPath,
                              ),
                            );
                          },
                        );
                      },
                    ),
    );
  }
}

class _ConfigInterfaceInfo {
  final String serviceName;
  final String objectPath;

  _ConfigInterfaceInfo(this.serviceName, this.objectPath);
}
