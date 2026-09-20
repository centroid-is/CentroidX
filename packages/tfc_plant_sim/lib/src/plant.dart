/// A fake plant: one OPC UA server per [ServerSpec], running until closed.
///
/// The servers are real — open62541, the same stack production talks to — so
/// what a client sees here is what a client sees on a panel: the same
/// encodings, the same type dictionary, the same monitored-item behaviour.
/// What is fake is the plant behind them.
///
/// **Teardown order is load-bearing.** Cancel the crank first, then
/// `shutdown()` inside a `try`, then `delete()`. A `runIterate` on a deleted
/// server does not throw, it SEGVs the VM — project memory from the
/// open62541_dart repo — and a SEGV in teardown destroys the result of
/// whatever was being measured.
library;

import 'dart:async';

import 'package:open62541/open62541.dart';

import 'free_port.dart';
import 'spec.dart';

/// How often each server's crank is turned. 10 ms, the figure the pipe's own
/// fixtures use.
const Duration kIteratePeriod = Duration(milliseconds: 10);

/// One write a client performed on a recording node, as the plant saw it.
///
/// The plant's own record of having been moved. Everything else in a relay
/// test is a report *about* an actuation — a write outcome, a read-back, a
/// notification — and every one of those crosses the link whose failure is
/// under test. This does not: it is taken inside the server, by the node that
/// received the write, before any answer is composed.
final class Actuation {
  Actuation({required this.node, required this.value, required this.at});

  /// The node's spec id, as a key mapping spells it.
  final String node;

  /// The value the node was moved to, decoded by open62541.
  final DynamicValue value;

  final DateTime at;

  @override
  String toString() => 'Actuation($node = ${value.value} at $at)';
}

/// One running server.
class RunningServer {
  RunningServer._(this.alias, this.port, this._server, this._nodes, this._seeds,
      this._recorded, this._actuations, this._actuationEvents);

  /// The timer moving each node, by spec id. A node that is taken out of the
  /// address space stops moving with it — without this, the next tick writes
  /// to a node that is gone and throws inside a `Timer` callback, which
  /// surfaces as an unhandled error in whatever happens to be running.
  final Map<String, Timer> _motions = {};

  final String alias;

  /// The port it actually bound, which is the interesting one when the spec
  /// asked for 0.
  final int port;

  final Server _server;

  /// The nodes it serves, by their spec id.
  final Map<String, NodeId> _nodes;

  /// What each node was created with, kept for its OPC UA type: a bare Dart
  /// number has no deducible type (`Unable to deduce type double for 18.0`),
  /// so a scenario writing 18 has to be given the type the node already has.
  final Map<String, DynamicValue> _seeds;

  /// The backing store of each recording node, by spec id.
  ///
  /// A recording node is a data source rather than a stored variable, so its
  /// value lives here and open62541 asks for it. A node absent from this map
  /// is an ordinary variable node and is written through the server.
  final Map<String, DynamicValue> _recorded;

  /// Every write a client has performed on a recording node, in order.
  final List<Actuation> _actuations;

  final StreamController<Actuation> _actuationEvents;

  String get endpoint => 'opc.tcp://127.0.0.1:$port';

  /// Every actuation this server has received, oldest first.
  ///
  /// **This is the count "a write is never retried" is a claim about.** A
  /// duplicated command shows up here as two entries carrying the same value,
  /// which is precisely the case a read-back cannot distinguish from one: the
  /// node holds the same number either way, and only the plant knows it was
  /// moved twice.
  List<Actuation> get actuations => List.unmodifiable(_actuations);

  /// Actuations on one node, oldest first.
  List<Actuation> actuationsOf(String id) =>
      _actuations.where((a) => a.node == id).toList(growable: false);

  /// How many times [id] has been moved by a client.
  int actuationCount(String id) =>
      _actuations.where((a) => a.node == id).length;

  /// Actuations as they arrive, for a case that wants to wait for one rather
  /// than poll for it.
  Stream<Actuation> get actuated => _actuationEvents.stream;

  /// Forgets what has been recorded so far.
  ///
  /// For a case that drives the plant into position and then wants to count
  /// only what the part under test did.
  void clearActuations() => _actuations.clear();

  /// Every node id this server serves, by spec id.
  Map<String, NodeId> get nodes => Map.unmodifiable(_nodes);

  /// Writes [value] to [id] as the plant would.
  ///
  /// The lever a scenario drives: raise a level, trip a drive, stop a line.
  void set(String id, Object? value) {
    final node = _nodes[id];
    if (node == null) {
      throw ArgumentError.value(id, 'id', 'no such node on "$alias"');
    }
    // A recording node is moved by writing its backing store, NOT by writing
    // the node: a write through the server would arrive at the same callback a
    // client's write does, and the plant moving itself would be indexed as an
    // actuation somebody performed. The log has to mean "a client did this" or
    // it cannot be counted against a client's commands.
    if (_recorded.containsKey(id)) {
      _recorded[id] = _value(id, value);
      return;
    }
    _server.write(node, _value(id, value));
  }

  /// Takes [id] out of the address space.
  ///
  /// What a key mapping pointing at a node the PLC does not have looks like
  /// from the client: `BadNodeIdUnknown`, permanently, rather than a gap.
  void remove(String id) {
    final node = _nodes.remove(id);
    if (node == null) {
      throw ArgumentError.value(id, 'id', 'no such node on "$alias"');
    }
    _motions.remove(id)?.cancel();
    _server.deleteNode(node);
  }

  DynamicValue _value(String id, Object? value) => value is DynamicValue
      ? value
      : DynamicValue(value: value, typeId: _seeds[id]?.typeId);
}

/// The whole plant.
class FakePlant {
  FakePlant._(this.servers, this._cranks, this._motions);

  /// The running servers, by alias.
  final Map<String, RunningServer> servers;

  final List<Timer> _cranks;
  final List<Timer> _motions;

  /// `alias -> opc.tcp://…`, which is what a backend config is written from.
  Map<String, String> get endpoints =>
      {for (final s in servers.values) s.alias: s.endpoint};

  /// Stands the plant up and starts it moving.
  static Future<FakePlant> start(PlantSpec spec) async {
    final servers = <String, RunningServer>{};
    final cranks = <Timer>[];
    final motions = <Timer>[];
    for (final serverSpec in spec.servers) {
      // The port is settled before the server is built: open62541's `Server`
      // binds at construction and does not say which port it got, so 0 has to
      // be resolved here.
      final port =
          serverSpec.port == 0 ? await freePort() : serverSpec.port;
      final server = Server(port: port);
      _ensureNamespaces(server, [
        _typeNamespace,
        for (final node in serverSpec.nodes) node.namespace,
      ].reduce((a, b) => a > b ? a : b));
      final nodes = <String, NodeId>{};
      final seeds = <String, DynamicValue>{};
      final typeIds = _publishTypes(server, spec.types);
      // Built here rather than on the RunningServer because the write callback
      // has to close over them, and the callback is installed while the node is
      // added — which is before there is a RunningServer to hang them off.
      final recorded = <String, DynamicValue>{};
      final actuations = <Actuation>[];
      final actuationEvents = StreamController<Actuation>.broadcast();

      for (final node in serverSpec.nodes) {
        final id = NodeId.fromString(node.namespace, node.id);
        final seed = _seed(node, spec.types, typeIds);
        seeds[node.id] = seed;
        final declared = spec.types[node.type] == null
            ? null
            : NodeId.fromString(_typeNamespace, node.type);
        if (node.records) {
          recorded[node.id] = seed;
          server.addDataSourceVariableNode(
            id,
            browseName: node.id,
            typeId: declared ?? seed.typeId,
            onRead: () => recorded[node.id]!,
            onWrite: (value) async {
              recorded[node.id] = value;
              final actuation = Actuation(
                  node: node.id, value: value, at: DateTime.now());
              actuations.add(actuation);
              // The plant does not stop being a plant because nobody is
              // listening to its diary. A broadcast controller with no
              // subscriber discards, which is what is wanted — but the write
              // must still be recorded above, and must still succeed.
              if (!actuationEvents.isClosed) actuationEvents.add(actuation);
            },
          );
        } else {
          server.addVariableNode(id, seed, typeId: declared ?? seed.typeId);
        }
        nodes[node.id] = id;
      }
      server.start();
      final running = RunningServer._(serverSpec.alias, port, server, nodes,
          seeds, recorded, actuations, actuationEvents);
      servers[serverSpec.alias] = running;
      cranks.add(Timer.periodic(kIteratePeriod, (_) => _crank(server)));
      for (final node in serverSpec.nodes) {
        final motion = _motionFor(running, node, spec.types, typeIds);
        if (motion != null) {
          running._motions[node.id] = motion;
          motions.add(motion);
        }
      }
    }
    return FakePlant._(servers, cranks, motions);
  }

  /// Stops every server. Safe to call twice.
  Future<void> close() async {
    for (final timer in [..._motions, ..._cranks]) {
      timer.cancel();
    }
    _motions.clear();
    _cranks.clear();
    for (final running in servers.values) {
      try {
        running._server.shutdown();
      } on Object {
        // A server a scenario already killed. Not a failure worth reporting,
        // and the delete below still has to happen.
      }
      running._server.delete();
      // After the server is gone: a listener cannot be handed an actuation
      // that arrives during shutdown if the server can no longer receive one,
      // and closing first would make a late write throw inside the callback.
      unawaited(running._actuationEvents.close());
    }
    servers.clear();
  }

  /// Registers namespaces until [upTo] exists.
  ///
  /// A server starts with 0 (the OPC UA namespace) and 1 (its own), and a
  /// node id in any other namespace is refused — `BadNodeIdInvalid`, from
  /// `addDataTypeNode` of all places, which reads like a broken type and is
  /// really a missing namespace. The plant publishes in 4 because that is
  /// what the PLCs here publish in and what a key mapping spells.
  static void _ensureNamespaces(Server server, int upTo) {
    var index = 1;
    while (index < upTo) {
      index = server.addNamespace('urn:tfc-plant-sim:$index');
    }
  }

  /// One turn of one server's crank, guarded for the reason the library doc
  /// gives.
  static void _crank(Server server) {
    try {
      server.runIterate();
    } on Object {
      // Deliberately swallowed.
    }
  }

  /// Publishes every declared type, enums first: a struct member that names
  /// an enum needs that enum's `UA_DataType` to exist before the struct is
  /// registered, or `addCustomType` cannot resolve the member.
  ///
  /// **An enum is published by adding a node, not by `addCustomType`.** That
  /// call takes structs only (`server.dart:1333`); an enum type is minted as
  /// a side effect of `addVariableNode` when the value carries
  /// [DynamicValue.enumFields], under the id `EnumType_<name>`. So each enum
  /// gets a node of its own, named for the type. It is also the only place
  /// the fixtures this package replaces could not reach: their struct members
  /// are scalars, and the shape that draws a conveyor violet is an enum
  /// INSIDE a struct.
  static Map<String, NodeId> _publishTypes(
      Server server, Map<String, TypeSpec> types) {
    final ids = <String, NodeId>{};
    for (final type in types.values.where((t) => t.isEnum)) {
      final declared = NodeId.fromString(_typeNamespace, type.name);
      server.addVariableNode(
          NodeId.fromString(_typeNamespace, '__type.${type.name}'),
          _enumValue(type, type.values.keys.first),
          typeId: declared);
      // What `_addEnumType` mints, which is what a member has to point at.
      ids[type.name] =
          NodeId.fromString(_typeNamespace, 'EnumType_${type.name}');
    }
    for (final type in types.values.where((t) => !t.isEnum)) {
      final typeId = NodeId.fromString(_typeNamespace, type.name);
      // The registered TYPE declares the enum member as the enum, which is
      // what puts the field names in the dictionary a client reads.
      final value = _structValue(type, types, ids, forWire: false)
        ..typeId = typeId;
      server.addCustomType(typeId, value);
      server.addDataTypeNode(typeId, type.name);
      ids[type.name] = typeId;
    }
    return ids;
  }

  /// The namespace custom types and tags are published in. 4 is what the
  /// PLCs in this plant use, and a key mapping spells `ns=4;s=…`.
  static const int _typeNamespace = 4;

  /// One enum value, carrying every field name so a client can read a state
  /// rather than an integer.
  ///
  /// The value stays Int32 — an enum is Int32-equivalent on the wire, and the
  /// serializer only knows how to write payload types. What names it is the
  /// DataType the node declares, which `addVariableNode` mints from these
  /// fields.
  static DynamicValue _enumValue(TypeSpec type, int value) =>
      DynamicValue(value: value, typeId: NodeId.int32)
        ..name = type.name
        ..enumFields = {
          for (final entry in type.values.entries)
            entry.key: EnumField(entry.key, entry.value,
                LocalizedText(entry.value, 'en'),
                LocalizedText(entry.value, 'en')),
        };

  /// A struct value: one entry per member.
  ///
  /// [forWire] decides how an enum member is typed, and both answers are
  /// needed. The registered `UA_DataType` (false) declares the member as the
  /// enum type, which is what carries the field names into the dictionary a
  /// client reads back. A value being serialized (true) types it Int32,
  /// because the serializer writes payload types and an enum is Int32 —
  /// the same bytes, the same layout, one of them named.
  static DynamicValue _structValue(TypeSpec type, Map<String, TypeSpec> types,
      Map<String, NodeId> typeIds, {required bool forWire}) {
    final value = DynamicValue(name: type.name);
    for (final member in type.members) {
      final memberType = types[member.type];
      if (memberType != null && memberType.isEnum) {
        final seed = member.value is int
            ? member.value! as int
            : memberType.values.keys.first;
        // `typeId` is the minted enum type, not the declared name: that is
        // what `addCustomType` resolves the member against.
        value[member.name] = _enumValue(memberType, seed)
          ..name = member.name
          ..typeId = forWire ? NodeId.int32 : typeIds[member.type];
      } else if (memberType != null) {
        // **A struct inside a struct.** Without this arm a struct-typed member
        // fell through to `_scalar`, which knows only the four built-ins, and
        // the member was served as whatever that made of a type name it had
        // never heard of. A PLC publishes nested structures routinely — a
        // drive carrying a motor carrying its own status — and every path this
        // package exists to exercise is deeper than one level: dotted member
        // paths in access templates, the wire's per-entry containment, and the
        // type dictionary's own recursion over members.
        //
        // `forWire` is carried down unchanged: the nested value is part of the
        // same encoding decision as its parent, and a member that disagreed
        // with its container about whether an enum is an Int32 would be a
        // struct the serializer cannot write.
        value[member.name] =
            _structValue(memberType, types, typeIds, forWire: forWire)
              ..name = member.name
              ..typeId = forWire ? null : typeIds[member.type];
      } else {
        value[member.name] = _scalar(member.type, member.value)
          ..name = member.name;
      }
    }
    return value;
  }

  static DynamicValue _seed(NodeSpec node, Map<String, TypeSpec> types,
      Map<String, NodeId> typeIds) {
    final type = types[node.type];
    if (type == null) {
      return _scalar(node.type, node.value)..name = node.id;
    }
    if (type.isEnum) {
      return _enumValue(
          type, node.value is int ? node.value! as int : type.values.keys.first)
        ..name = node.id;
    }
    return _structValue(type, types, typeIds, forWire: true)
      ..name = node.id
      ..typeId = typeIds[type.name];
  }

  /// A built-in value with its OPC UA type spelled out.
  ///
  /// Never deduced. An `int` has no deducible type — Int16/Int32/Int64 and
  /// the unsigned three are all candidates, and the binding throws rather
  /// than guess — and a struct member with no type at all is what
  /// `addCustomType` dereferences when it resolves its members.
  static DynamicValue _scalar(String type, Object? value) => switch (type) {
        'bool' => DynamicValue(
            value: value is bool ? value : false, typeId: NodeId.boolean),
        'int' => DynamicValue(
            value: value is int ? value : 0, typeId: NodeId.int32),
        'string' => DynamicValue(
            value: value is String ? value : '', typeId: NodeId.uastring),
        _ => DynamicValue(
            value: value is num ? value.toDouble() : 0.0,
            typeId: NodeId.double),
      };

  /// The timer that moves one node, or null for [Motion.once] — which is the
  /// whole of that motion: the seed is the value, and nothing writes again.
  static Timer? _motionFor(RunningServer server, NodeSpec node,
      Map<String, TypeSpec> types, Map<String, NodeId> typeIds) {
    switch (node.motion) {
      case Motion.once:
        return null;
      case Motion.constant:
        final seed = _seed(node, types, typeIds);
        return Timer.periodic(node.period, (_) => server.set(node.id, seed));
      case Motion.ramp:
        var current = node.min;
        final step = (node.max - node.min) / 20;
        return Timer.periodic(node.period, (_) {
          current += step;
          if (current > node.max) current = node.min;
          server.set(node.id, current.toDouble());
        });
      case Motion.cycle:
        final enumType = types[node.type]!.isEnum
            ? types[node.type]!
            : types[types[node.type]!
                .members
                .firstWhere((m) => types[m.type]?.isEnum ?? false)
                .type]!;
        final states = enumType.values.keys.toList();
        var index = 0;
        return Timer.periodic(node.period, (_) {
          index = (index + 1) % states.length;
          final next = _seed(node, types, typeIds);
          if (types[node.type]!.isEnum) {
            next.value = states[index];
          } else {
            final member = types[node.type]!
                .members
                .firstWhere((m) => types[m.type]?.isEnum ?? false);
            next[member.name].value = states[index];
          }
          server.set(node.id, next);
        });
    }
  }
}
