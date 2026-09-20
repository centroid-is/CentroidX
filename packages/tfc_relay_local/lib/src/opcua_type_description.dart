/// A binding sample's **type**, as the relay describes one — the OPC UA link's
/// half of `type_descriptor.dart`.
///
/// **This is a port of `describeUaType` and `PipeWorkerEndpoint.typeIdentityOf`
/// in `packages/tfc_dart/lib/core/pipe_worker_endpoint.dart`, line for line,
/// and it should not exist.** Both are `@visibleForTesting` there — the pipe
/// worker's own internals — so the one describer the backend uses cannot be
/// imported into a `lib/` file in this package without suppressing a lint that
/// `tfc_dart` put there on purpose. The honest fix is to promote them beside
/// [translateOpcUaSample] in `tfc_dart/core/opcua_value_translation.dart`,
/// which was moved down into `tfc_dart` for exactly this reason ("the single
/// source of truth for the quality table and the converter"), and then delete
/// this file. Until somebody with that file in scope does so, this copy is kept
/// deliberately identical in behaviour: the same recursion, the same locale
/// normalisation, the same identity rule. A change to one is a change to both,
/// and the two disagreeing is the divergence the v1.0 post-mortem (§11) names.
///
/// **IMPORT-PREFIX HAZARD (R-6)**, as in the source: two classes are called
/// `DynamicValue` and two `LocalizedText`. The binding is `ua.` here and the
/// relay is bare, the opposite of `tfc_dart`'s convention and the same as the
/// rest of this package.
library;

import 'package:open62541/open62541.dart' as ua;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The relay's description of an `open62541` value's **type**: its node id,
/// enum table, display name and description, recursively through struct
/// members and array elements. Pure; the sample's value is read only for its
/// shape.
///
/// `LocalizedText.locale` is empty rather than null on the open62541 side,
/// and the relay spells "no locale" as null; the crossing normalises it so a
/// panel does not render an empty locale tag.
TypeDescriptor describeOpcUaType(ua.DynamicValue sample) {
  final raw = sample.value;
  final enumFields = sample.enumFields;
  return TypeDescriptor(
    ua: sample.typeId?.toString(),
    enumFields: enumFields == null
        ? null
        : <int, EnumField>{
            for (final entry in enumFields.entries)
              entry.key: EnumField(
                value: entry.value.value,
                name: entry.value.name,
                displayName: _relayText(entry.value.displayName),
                description: _relayText(entry.value.description),
              ),
          },
    displayName: _relayText(sample.displayName),
    description: _relayText(sample.description),
    members: raw is Map
        ? <String, TypeDescriptor>{
            for (final entry in raw.entries)
              if (entry.value is ua.DynamicValue)
                '${entry.key}': describeOpcUaType(entry.value as ua.DynamicValue),
          }
        : const <String, TypeDescriptor>{},
    element: raw is List && raw.isNotEmpty && raw.first is ua.DynamicValue
        ? describeOpcUaType(raw.first as ua.DynamicValue)
        : null,
  );
}

/// What identifies [sample]'s type before anything has been read: its data
/// type node id when the sample carried one; for a struct that carried none,
/// its **shape** — the member names, sorted; null for a typeless scalar,
/// which is a builtin with nothing to describe.
String? opcUaTypeIdentityOf(ua.DynamicValue sample) {
  final nodeType = sample.typeId;
  if (nodeType != null) return nodeType.toString();
  final raw = sample.value;
  if (raw is! Map || raw.isEmpty) return null;
  final names = [for (final name in raw.keys) '$name']..sort();
  return 'shape:${names.join(',')}';
}

LocalizedText? _relayText(ua.LocalizedText? text) {
  if (text == null) return null;
  if (text.value.isEmpty) return null;
  return LocalizedText(text.value,
      locale: text.locale.isEmpty ? null : text.locale);
}
