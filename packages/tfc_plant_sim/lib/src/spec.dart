/// What a fake plant is made of, and how it is read off a YAML file.
///
/// The spec is deliberately small. It describes servers, the custom types
/// their nodes carry, the nodes themselves and how each one's value moves —
/// and nothing else. Anything a scenario needs beyond that (breaking a link,
/// deleting a node mid-run) is a lever on the running plant, not a field here.
///
/// Every parse failure names the path it failed at (`servers[1].nodes[3].id`).
/// A spec is written by hand and read by somebody debugging something else;
/// "type error" with no location is a second bug to find.
library;

import 'package:yaml/yaml.dart';

/// A spec that could not be read, with the path that failed.
class PlantSpecError implements Exception {
  PlantSpecError(this.path, this.message);

  /// Dotted path into the document, e.g. `servers[0].nodes[2].behaviour.kind`.
  final String path;
  final String message;

  @override
  String toString() => 'plant spec: $path: $message';
}

/// How a node's value moves while the plant runs.
enum Motion {
  /// Written once at start-up and never again.
  ///
  /// The shape a configured setpoint has: a monitored item reports it at
  /// establishment and the node never notifies again, which is what a
  /// freshness sweep with no keep-alive badges stale.
  once,

  /// Written on every tick with the same value.
  ///
  /// Not the same as [once] and the difference is the point: this one keeps
  /// arriving, so anything that treats silence as staleness stays quiet.
  constant,

  /// A sawtooth between [NodeSpec.min] and [NodeSpec.max].
  ramp,

  /// Steps through the values of its enum type, one per period.
  cycle,
}

/// A custom type the server publishes: an enum, or a struct of members.
class TypeSpec {
  TypeSpec.enumeration({required this.name, required this.values})
      : members = const [];

  TypeSpec.structure({required this.name, required this.members})
      : values = const {};

  final String name;

  /// Enum: value -> name. Empty for a struct.
  final Map<int, String> values;

  /// Struct: its members, in order. Empty for an enum.
  final List<MemberSpec> members;

  bool get isEnum => values.isNotEmpty;
}

/// One member of a struct type.
class MemberSpec {
  MemberSpec({required this.name, required this.type, this.value});

  final String name;

  /// `double`, `bool`, `int`, `string`, or the name of an enum [TypeSpec].
  final String type;

  /// The member's value at start-up. Null takes the type's zero.
  final Object? value;
}

/// One node on one server.
class NodeSpec {
  NodeSpec({
    required this.id,
    required this.namespace,
    required this.type,
    required this.motion,
    required this.period,
    this.value,
    this.min = 0,
    this.max = 100,
    this.records = false,
  });

  /// The string identifier, as a key mapping would spell it.
  final String id;

  final int namespace;

  /// `double`, `bool`, `int`, `string`, or the name of a [TypeSpec].
  final String type;

  final Motion motion;

  /// How often [motion] moves the value.
  final Duration period;

  /// The start-up value. Null takes the type's zero.
  final Object? value;

  final num min;
  final num max;

  /// Whether this node records the writes a client performs on it.
  ///
  /// Off by default, and opt-in rather than universal because it changes how
  /// the node is served: a recording node is a **data source**, so open62541
  /// asks a Dart callback for its value on every sampling interval instead of
  /// notifying subscribers the moment something writes the store. That is the
  /// right shape for an actuator and the wrong one for the motion shapes this
  /// package exists to serve, which is why [Motion.once] is still a plain
  /// variable node unless a spec says otherwise.
  ///
  /// What it buys is the only question a fake plant can answer and a fake
  /// `StateManApi` cannot: **how many times did the machine actually move.**
  /// "A write is never retried" is a claim about actuations, and an actuation
  /// is a thing that happens at the plant — so it is counted at the plant, by
  /// the node that received it, and not inferred from what the panel was told
  /// afterwards.
  final bool records;
}

/// One OPC UA server: an alias, a port and its nodes.
class ServerSpec {
  ServerSpec({
    required this.alias,
    required this.port,
    required this.nodes,
  });

  /// What a key mapping calls this server (`st101`). The bench prints its
  /// endpoint under this name, so a backend config can be written against it.
  final String alias;

  /// 0 asks the kernel for a free port, which is what a test wants and what a
  /// second bench on the same box needs.
  final int port;

  final List<NodeSpec> nodes;
}

/// A whole fake plant.
class PlantSpec {
  PlantSpec({required this.types, required this.servers});

  /// Custom types by name, shared by every server that uses one.
  final Map<String, TypeSpec> types;

  final List<ServerSpec> servers;

  /// Reads a spec from YAML [source], naming [origin] in any failure.
  static PlantSpec parse(String source, {String origin = 'spec'}) {
    final doc = _asMap(loadYaml(source), origin);
    final types = <String, TypeSpec>{};
    final rawTypes = doc['types'];
    if (rawTypes != null) {
      final list = _asList(rawTypes, '$origin.types');
      for (var i = 0; i < list.length; i++) {
        final type = _type(list[i], '$origin.types[$i]');
        if (types.containsKey(type.name)) {
          throw PlantSpecError('$origin.types[$i].name',
              'two types are called "${type.name}"');
        }
        types[type.name] = type;
      }
      // **Every member names something that exists, and nothing names
      // itself.** Both are checked here, after the whole table is read,
      // because a member may legally name a type declared later in the file.
      //
      // The cycle check is not tidiness. A struct that contains itself makes
      // `_structValue` recurse until the stack goes, and a stack overflow
      // while building a fixture reads as a crash in whatever happened to be
      // running. Refusing it at the file is where it is cheapest to diagnose
      // — the same argument `GatewayConfig` makes for refusing two links that
      // share an alias.
      _checkTypeGraph(types, origin);
    }

    final rawServers = _asList(doc['servers'] ?? [], '$origin.servers');
    if (rawServers.isEmpty) {
      throw PlantSpecError('$origin.servers', 'a plant with no servers '
          'serves nothing; add one');
    }
    final servers = <ServerSpec>[];
    final seen = <String>{};
    for (var i = 0; i < rawServers.length; i++) {
      final server = _server(rawServers[i], '$origin.servers[$i]', types);
      if (!seen.add(server.alias)) {
        throw PlantSpecError('$origin.servers[$i].alias',
            'two servers are called "${server.alias}"; a key mapping names '
            'one server per alias');
      }
      servers.add(server);
    }
    return PlantSpec(types: types, servers: servers);
  }

  /// Refuses a member naming an unknown type, and any cycle among structs.
  ///
  /// Depth-first with a path, so the message can name the loop rather than
  /// just report that there is one: "DriveStatus -> Motor -> DriveStatus" is
  /// something a person can fix, "a cycle exists" is not.
  static void _checkTypeGraph(Map<String, TypeSpec> types, String origin) {
    final settled = <String>{};

    void walk(TypeSpec type, List<String> path) {
      if (settled.contains(type.name)) return;
      final loop = path.indexOf(type.name);
      if (loop >= 0) {
        throw PlantSpecError('$origin.types',
            'the struct "${type.name}" contains itself: '
            '${[...path.sublist(loop), type.name].join(' -> ')}. A value of '
            'that type has no size, so nothing can serve it');
      }
      for (final member in type.members) {
        if (_builtins.contains(member.type)) continue;
        final named = types[member.type];
        if (named == null) {
          throw PlantSpecError('$origin.types',
              'the member "${type.name}.${member.name}" is typed '
              '"${member.type}", which is neither a built-in '
              '(${_builtins.join(', ')}) nor a declared type');
        }
        if (named.isEnum) continue;
        walk(named, [...path, type.name]);
      }
      settled.add(type.name);
    }

    for (final type in types.values.where((t) => !t.isEnum)) {
      walk(type, const <String>[]);
    }
  }

  static TypeSpec _type(Object? raw, String path) {
    final map = _asMap(raw, path);
    final name = _string(map['name'], '$path.name');
    final kind = _string(map['kind'], '$path.kind');
    switch (kind) {
      case 'enum':
        final values = _asMap(map['values'], '$path.values');
        if (values.isEmpty) {
          throw PlantSpecError('$path.values', 'an enum with no values names '
              'no state, which is the thing a panel draws');
        }
        return TypeSpec.enumeration(name: name, values: {
          for (final entry in values.entries)
            _int(entry.key, '$path.values'): _string(
                entry.value, '$path.values[${entry.key}]'),
        });
      case 'struct':
        final members = _asList(map['members'], '$path.members');
        return TypeSpec.structure(
          name: name,
          members: [
            for (var i = 0; i < members.length; i++)
              _member(members[i], '$path.members[$i]'),
          ],
        );
      default:
        throw PlantSpecError('$path.kind',
            '"$kind" is not a type kind; use "enum" or "struct"');
    }
  }

  static MemberSpec _member(Object? raw, String path) {
    final map = _asMap(raw, path);
    return MemberSpec(
      name: _string(map['name'], '$path.name'),
      type: _string(map['type'], '$path.type'),
      value: _scalar(map['value']),
    );
  }

  static ServerSpec _server(
      Object? raw, String path, Map<String, TypeSpec> types) {
    final map = _asMap(raw, path);
    final nodes = _asList(map['nodes'] ?? [], '$path.nodes');
    return ServerSpec(
      alias: _string(map['alias'], '$path.alias'),
      port: map['port'] == null ? 0 : _int(map['port'], '$path.port'),
      nodes: [
        for (var i = 0; i < nodes.length; i++)
          _node(nodes[i], '$path.nodes[$i]', types),
      ],
    );
  }

  static NodeSpec _node(
      Object? raw, String path, Map<String, TypeSpec> types) {
    final map = _asMap(raw, path);
    final type = _string(map['type'] ?? 'double', '$path.type');
    if (!_builtins.contains(type) && !types.containsKey(type)) {
      throw PlantSpecError('$path.type',
          '"$type" is neither a built-in (${_builtins.join(', ')}) nor a '
          'declared type (${types.keys.join(', ')})');
    }
    final motion = _motion(map['motion'], '$path.motion');
    if (motion == Motion.cycle && (types[type]?.isEnum ?? false) == false) {
      final struct = types[type];
      final hasEnumMember = struct != null &&
          struct.members.any((m) => types[m.type]?.isEnum ?? false);
      if (!hasEnumMember) {
        throw PlantSpecError('$path.motion',
            '"cycle" steps through an enum\'s values, and "$type" has none');
      }
    }
    return NodeSpec(
      id: _string(map['id'], '$path.id'),
      namespace: map['namespace'] == null
          ? 4
          : _int(map['namespace'], '$path.namespace'),
      type: type,
      motion: motion,
      period: _duration(map['period'], '$path.period'),
      value: _scalar(map['value']),
      min: map['min'] == null ? 0 : _num(map['min'], '$path.min'),
      max: map['max'] == null ? 100 : _num(map['max'], '$path.max'),
      records: _bool(map['records'], '$path.records'),
    );
  }

  static const Set<String> _builtins = {'double', 'bool', 'int', 'string'};

  static Motion _motion(Object? raw, String path) {
    if (raw == null) return Motion.constant;
    final name = _string(raw, path);
    for (final motion in Motion.values) {
      if (motion.name == name) return motion;
    }
    throw PlantSpecError(path, '"$name" is not a motion; use '
        '${Motion.values.map((m) => m.name).join(', ')}');
  }

  /// `500ms`, `2s`, `1m`. Defaults to one second.
  static Duration _duration(Object? raw, String path) {
    if (raw == null) return const Duration(seconds: 1);
    final text = _string(raw, path);
    final match = RegExp(r'^(\d+)(ms|s|m)$').firstMatch(text);
    if (match == null) {
      throw PlantSpecError(path, '"$text" is not a duration; write 500ms, '
          '2s or 1m');
    }
    final n = int.parse(match.group(1)!);
    return switch (match.group(2)!) {
      'ms' => Duration(milliseconds: n),
      's' => Duration(seconds: n),
      _ => Duration(minutes: n),
    };
  }

  static Map<Object?, Object?> _asMap(Object? raw, String path) {
    if (raw is YamlMap) return raw.value;
    if (raw is Map) return raw;
    throw PlantSpecError(path, 'expected a mapping, found ${_kind(raw)}');
  }

  static List<Object?> _asList(Object? raw, String path) {
    if (raw is YamlList) return raw.toList();
    if (raw is List) return raw;
    throw PlantSpecError(path, 'expected a list, found ${_kind(raw)}');
  }

  static String _string(Object? raw, String path) {
    if (raw is String && raw.isNotEmpty) return raw;
    throw PlantSpecError(path, 'expected a name, found ${_kind(raw)}');
  }

  static bool _bool(Object? raw, String path) {
    if (raw == null) return false;
    if (raw is bool) return raw;
    throw PlantSpecError(path, 'expected true or false, found ${_kind(raw)}');
  }

  static int _int(Object? raw, String path) {
    if (raw is int) return raw;
    throw PlantSpecError(path, 'expected a whole number, found ${_kind(raw)}');
  }

  static num _num(Object? raw, String path) {
    if (raw is num) return raw;
    throw PlantSpecError(path, 'expected a number, found ${_kind(raw)}');
  }

  /// A start-up value, or null. Scalars only: a node's value is a value.
  static Object? _scalar(Object? raw) =>
      raw is num || raw is bool || raw is String ? raw : null;

  static String _kind(Object? raw) =>
      raw == null ? 'nothing' : '${raw.runtimeType}';
}
