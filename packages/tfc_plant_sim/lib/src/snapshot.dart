/// Turning a plant's key mappings into a plant spec.
///
/// The input is the `key_mapping` rows a station holds, exported as JSON. The
/// output is a spec this package can serve: one server per `server_alias`,
/// one node per mapped tag, in the namespace the mapping names.
///
/// **This reads rows; it does not dial a station.** The export is a `psql`
/// one-liner run by somebody who already has access (see the package README),
/// which keeps plant credentials out of this tool and keeps a dev box from
/// opening connections to a live station database. What comes back is
/// customer data — see `destination.dart` for where it may be written.
///
/// What a mapping cannot say is what a tag's VALUE looks like: the rows carry
/// node ids, not types or ranges. Every derived node is therefore a scalar
/// that holds still, and the shapes that catch bugs — an enum inside a
/// struct, a node that reports once — have to be written by hand. A derived
/// spec gives the bench the plant's *size and layout*; the invented fixture
/// gives it the *behaviour*.
library;

import 'dart:convert';

/// One exported row: what the export query selects.
typedef KeyMappingRow = ({String key, String payload});

/// The spec text derived from [rows], ready to write.
///
/// Returns YAML rather than a [PlantSpec] because the point is a file
/// somebody can read, edit and keep: they will want to give a tag a range, or
/// make one of them move.
String specFromKeyMappings(Iterable<KeyMappingRow> rows, {String? note}) {
  final servers = <String, List<({String id, int namespace})>>{};
  var skipped = 0;
  for (final row in rows) {
    final Object? decoded;
    try {
      decoded = jsonDecode(row.payload);
    } on FormatException {
      skipped++;
      continue;
    }
    if (decoded is! Map) {
      skipped++;
      continue;
    }
    final node = decoded['opcua_node'];
    if (node is! Map) {
      // Modbus and weigher mappings: not an address space, nothing to serve.
      skipped++;
      continue;
    }
    final alias = node['server_alias'];
    final identifier = node['identifier'];
    final namespace = node['namespace'];
    if (alias is! String || identifier is! String || namespace is! int) {
      skipped++;
      continue;
    }
    (servers[alias] ??= []).add((id: identifier, namespace: namespace));
  }

  final out = StringBuffer()
    ..writeln('# Derived from a plant\'s key mappings'
        '${note == null ? '' : ' — $note'}.')
    ..writeln('#')
    ..writeln('# CUSTOMER DATA. This file does not belong in the CentroidX')
    ..writeln('# repository, in any form, scrubbed or sampled.')
    ..writeln('#')
    ..writeln('# Every node here holds still: a key mapping says where a tag')
    ..writeln('# is, not what it does. Give the interesting ones a motion by')
    ..writeln('# hand — see the package README.')
    ..writeln('#')
    ..writeln('# ${servers.length} server(s), '
        '${servers.values.fold<int>(0, (n, l) => n + l.length)} node(s), '
        '$skipped row(s) skipped (no OPC UA node).')
    ..writeln()
    ..writeln('servers:');
  final aliases = servers.keys.toList()..sort();
  for (final alias in aliases) {
    final nodes = servers[alias]!..sort((a, b) => a.id.compareTo(b.id));
    out
      ..writeln('  - alias: $alias')
      ..writeln('    nodes:');
    for (final node in nodes) {
      out.writeln('      - {id: "${node.id}", namespace: ${node.namespace}, '
          'type: double, motion: constant}');
    }
  }
  return out.toString();
}
