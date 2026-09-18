import 'package:flutter/material.dart';
import 'package:dbus/dbus.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'base_scaffold.dart';
import '../dbus/generated/operations.dart';
import '../theme.dart' show kAppFontFamily;

class OperationModeAppBarLeftWidgetProvider
    extends GlobalAppBarLeftWidgetProvider {
  late final IsCentroidOperationMode _operationMode;

  OperationModeAppBarLeftWidgetProvider(DBusClient client) {
    _operationMode = IsCentroidOperationMode(
        client,
        'is.centroid.operations.def',
        DBusObjectPath('/is/centroid/OperationMode'));
  }

  Future<void> toggleRunning() async {
    try {
      final currentMode = await _operationMode.getMode();
      if (currentMode == 'stopped') {
        await _operationMode.callSetMode('running');
      } else {
        await _operationMode.callSetMode('stopped');
      }
    } catch (e) {
      debugPrint('Failed to toggle operation mode: $e');
    }
  }

  @override
  Widget buildAppBarLeftWidgets(BuildContext context) {
    return FutureBuilder<String>(
      future: _operationMode.getMode(),
      builder: (context, snapshot) {
        return StreamBuilder<IsCentroidOperationModeUpdate>(
          stream: _operationMode.update, // Use directly from _operationMode
          initialData: snapshot.hasData
              ? IsCentroidOperationModeUpdate(DBusSignal(
                  sender: _operationMode.name,
                  path: _operationMode.path,
                  interface: 'is.centroid.OperationMode',
                  name: 'Update',
                  values: [DBusString(snapshot.data!), DBusString('')],
                ))
              : null,
          builder: (context, streamSnapshot) {
            final mode =
                streamSnapshot.data?.new_mode ?? snapshot.data ?? 'unknown';

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: FaIcon(mode == 'stopped'
                      ? FontAwesomeIcons.play
                      : FontAwesomeIcons.stop),
                  tooltip: mode == 'stopped' ? 'Start' : 'Stop',
                  onPressed: () {
                    toggleRunning();
                  },
                ),
                IconButton(
                  icon: const FaIcon(FontAwesomeIcons.droplet),
                  tooltip: 'Cleaning',
                  onPressed: mode == 'stopped'
                      ? () async {
                          try {
                            await _operationMode.callSetMode('cleaning');
                          } catch (e) {
                            debugPrint('Failed to set cleaning mode: $e');
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content:
                                      Text('Failed to start cleaning: $e')),
                            );
                          }
                        }
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Center(
                    child: Text(
                      mode.toUpperCase(),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontFamily: kAppFontFamily,
                            fontSize: 16.0,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.1,
                            height: 1.5,
                          ),
                      overflow: TextOverflow.ellipsis,
                      softWrap: true,
                      maxLines: 1,
                      locale: const Locale('en', 'US'),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
