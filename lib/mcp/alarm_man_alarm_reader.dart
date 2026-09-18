import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_mcp_server/tfc_mcp_server_data.dart' show AlarmReader;

/// [AlarmReader] implementation backed by the Flutter app's [AlarmMan].
///
/// Converts [AlarmConfig] objects from [AlarmMan.config.alarms] to
/// `Map<String, dynamic>` format expected by the MCP server's alarm tools.
///
/// Each map contains: uid, key, title, description, rules (serialized
/// via [AlarmRule.toJson]), group and bindToGroup.
///
/// There is deliberately no constructor taking an [AlarmMan]. Holding one --
/// or, worse, holding its `config.alarms` list -- is the bug this class was
/// shipped with: every accepted alarm edit follows its mutation with
/// `invalidate(alarmManProvider)`, which builds a *new* [AlarmMan] around a
/// *new* list read back from preferences. A reader that captured either at
/// construction is pinned to an orphan from that moment on, and answers every
/// MCP alarm read from it until the app is restarted. Confirmed in the field:
/// after 91 alarms were regrouped and persisted, `get_alarm_tree` still
/// reported 6 alarms under "Line 1" where the saved config had 31. Pass a
/// source that resolves the provider instead, so an invalidate is picked up
/// on the next read.
class AlarmManAlarmReader implements AlarmReader {
  /// Creates a reader over a source consulted afresh on every read.
  ///
  /// [source] returns the alarm list of whichever [AlarmMan] is current, or
  /// `null` when there is no current one to read -- the window while
  /// `alarmManProvider` is rebuilding after an invalidate, or after its
  /// container is gone. `null` means "nothing new to say", not "no alarms":
  /// the reader keeps answering from the last list it saw rather than
  /// reporting an empty plant mid-rebuild. An operator who deletes their last
  /// alarm still gets an empty answer, because that is an empty list from a
  /// live [AlarmMan], not a null.
  AlarmManAlarmReader.live(this._source);

  /// Creates an [AlarmManAlarmReader] directly from a list of [AlarmConfig].
  ///
  /// Used for testing without needing a full AlarmMan instance. Note that the
  /// list is captured -- this constructor is for fixtures that do not change
  /// identity, never for production wiring.
  AlarmManAlarmReader.fromConfigs(List<AlarmConfig> configs)
      : _source = (() => configs);

  final List<AlarmConfig>? Function() _source;

  /// The most recent list [_source] produced, kept so a rebuild window
  /// degrades to "slightly behind" instead of "no alarms configured".
  List<AlarmConfig> _lastSeen = const <AlarmConfig>[];

  @override
  List<Map<String, dynamic>> get alarmConfigs {
    final configs = _source() ?? _lastSeen;
    _lastSeen = configs;
    return configs.map((alarm) {
      return <String, dynamic>{
        'uid': alarm.uid,
        'key': alarm.key,
        'title': alarm.title,
        'description': alarm.description,
        'rules': alarm.rules.map((r) => r.toJson()).toList(),
        // Where the alarm sits in the alarm tree. The copilot needs this to
        // answer "what is under Line 3" and to place a new alarm sensibly.
        'group': List<String>.from(alarm.group),
        'bindToGroup': alarm.bindToGroup,
      };
    }).toList();
  }
}
