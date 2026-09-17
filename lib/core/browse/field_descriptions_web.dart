import 'package:tfc_dart/core/state_man_types.dart';

import 'field_descriptions_types.dart';

/// No OPC UA session exists in a browser, so no browse can happen.
///
/// Returning an empty map rather than throwing is the point: the caller
/// renders the struct with the member names the value already carries, which
/// is the same pane a station shows before the browse comes back.
Future<Map<String, FieldDescription>> fetchFieldDescriptions(
  StateMan stateMan,
  String configKey,
) async =>
    const {};
