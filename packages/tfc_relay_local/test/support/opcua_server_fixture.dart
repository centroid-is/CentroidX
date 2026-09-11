/// A real in-process OPC UA server, a real client, and a seam to break the
/// wire between them.
///
/// The precedent is `packages/tfc_dart/test/subscription_inactivity_test.dart`,
/// which has been standing an in-process `Server` up in CI on ubuntu and macOS
/// on every push and which nobody had noticed: `Server(port: …)`,
/// `server.start()`, `addVariableNode`, a `Timer.periodic(10 ms,
/// server.runIterate)` driver, a real `Client`, and a byte-level TCP proxy in
/// between. This fixture is that arrangement with three changes — the port is
/// not a literal ([withFreePort]), the proxy is Phase 2's [FaultProxy] rather
/// than the buffer-only one, and the levers each carry the plan that earned
/// them.
///
/// **Teardown order is the fixture's whole content.** Cancel the iterate
/// driver, `shutdown()` inside `try/catch` because a test may have killed the
/// server already, then `delete()`. Getting it wrong does not fail a test — it
/// SEGVs the VM, which is project memory from the open62541_dart repo
/// (state-after-delete). The existing fixture's order (`:51-57`) is copied
/// exactly and this comment is why.
library;

import 'dart:async';

import 'package:open62541/open62541.dart';
import 'package:tfc_stateman_contract/faults.dart';

import 'free_port.dart';

/// How often the iterate driver turns the server's crank.
///
/// 10 ms, the existing fixture's figure. `runIterate` is a blocking FFI call,
/// so this is also the granularity at which the test isolate's event loop is
/// interrupted — which is why `dart_test.yaml` in this package pins
/// `concurrency: 1`.
const Duration serverIteratePeriod = Duration(milliseconds: 10);

/// The namespace the fixture's own nodes live in. Namespace 0 is the server's,
/// and writing into it is how a test accidentally edits `ServerStatus`.
const int fixtureNamespace = 1;

/// The node id one gateway key maps to.
///
/// A string node id spelled with the key itself, so a failure message names
/// the tag the operator would have typed rather than a number.
NodeId fixtureNodeId(String key) => NodeId.fromString(fixtureNamespace, key);

/// A binding value with an explicit OPC UA type.
///
/// **An `int` has no deducible OPC UA type and the binding says so by
/// throwing** (`opcua_serializer.dart:334`): Int16/Int32/Int64/UInt* are all
/// candidates and guessing one silently would produce a node whose data type
/// disagrees with every later write. `subscription_inactivity_test.dart:43-44`
/// passes `typeId: NodeId.int32` for the same reason; this is that, in one
/// place, so no lever can forget it.
DynamicValue fixtureValue(Object? value, {String? name}) {
  // Already shaped, by a caller that needs a type this function cannot derive
  // — an Int32 array, say, where `List<double>` below is the only list shape
  // with a rule. Passed through untouched; wrapping it would make a node whose
  // value is a DynamicValue holding a DynamicValue.
  if (value is DynamicValue) return value;
  // An array node: the binding models arrays as List<DynamicValue>
  // (`dynamic_value.dart:117`), so a bare Dart list must go through
  // `fromList` with an element type — the F7 group's node is a list of
  // doubles.
  if (value is List<double>) {
    return DynamicValue.fromList(value, typeId: NodeId.double, name: name);
  }
  return DynamicValue(
    value: value,
    name: name,
    typeId: value is int ? NodeId.int32 : null,
  );
}

/// An in-process OPC UA server with the levers this phase's plans need.
///
/// Two kinds of node, because the binding gives them different powers and the
/// difference is load-bearing:
///
///  * **Plain variable nodes** ([valueKeys]) hold a stored `UA_DataValue`. The
///    server stamps `sourceTimestamp` when the value is written and that stamp
///    is what every later monitored-item sample reports — which is the only
///    way to produce a source instant that is measurably *older than its own
///    arrival* without touching the pinned binding. 08-07's headline arm needs
///    exactly that.
///  * **Data-source nodes** ([writeKeys]) are backed by a read callback and an
///    optional write callback (`server.dart:443`). They can count writes — the
///    behavioural no-retry arm counts at the server, not at the adapter — and
///    they can fail a read on demand, which is how a *live* node produces a Bad
///    status. Their source timestamp is stamped per sample, so they are the
///    wrong node for the offset arm and the right one for everything else.
final class OpcUaServerFixture {
  OpcUaServerFixture._({
    required this.port,
    required this.valueKeys,
    required this.writeKeys,
    required this.typedWriteKeys,
    required this.structKeys,
    required this.treePaths,
    required this.methodPaths,
    required this.logLevel,
    required Server server,
    required Timer driver,
    required this.proxy,
  })  : _server = server,
        _driver = driver;

  /// The port the OPC UA server itself is listening on.
  final int port;

  /// Keys served by plain variable nodes.
  final List<String> valueKeys;

  /// Keys served by data-source nodes: writable, countable, failable.
  final List<String> writeKeys;

  /// Keys served by data-source nodes whose **DataType attribute is set**.
  ///
  /// [writeKeys] leaves the attribute at open62541's permissive default, which
  /// is `BaseDataType` — a node that accepts an Int32 where the plant has a
  /// REAL and never says a word. That is the wrong instrument for judging the
  /// write path's typing: a plant tag has exactly one type, the server enforces
  /// it, and a gateway that guesses gets `Bad_TypeMismatch` or, worse, a
  /// silently converted number. Each entry is key → the seed value, whose
  /// [DynamicValue.typeId] becomes the node's declared DataType.
  final Map<String, DynamicValue> typedWriteKeys;

  /// **8b-03.** Keys served as **structured values** with a server-registered
  /// custom type: key → member name → initial scalar value.
  ///
  /// The collection e2e leg needs a struct crossing the whole chain —
  /// `sample_members` picks columns out of it — and a flat scalar node
  /// cannot demonstrate that in either direction. The recipe is the
  /// binding's own three calls, verbatim from its `Basic struct read and
  /// write` integration test: `addCustomType` registers the schema,
  /// `addDataTypeNode` publishes it where a client can learn it, and
  /// `addVariableNode(typeId:)` serves the encoded value. Member types are
  /// derived from the initial values ([fixtureValue]'s rule, per member),
  /// and only scalars are accepted — a nested struct member would need its
  /// own registered type, and no plan has asked for one.
  final Map<String, Map<String, Object>> structKeys;

  /// **08-11.** Dotted paths that get a real *hierarchy*, not a flat node.
  ///
  /// [valueKeys] and [writeKeys] put every node directly under ObjectsFolder,
  /// which is all 08-07 needed: a subscription does not care what a node's
  /// parent is. Browse does, and it is the whole subject —
  /// `browse_contract.dart:69-75` exists because *"a source that ignores its
  /// argument and returns the same list for every parent satisfies every check
  /// that only ever expands one folder"*, and a flat address space cannot
  /// demonstrate the difference in either direction. So each path here becomes
  /// an object node per intermediate segment and a plain variable node at the
  /// leaf, with `ST101.CN01` and `ST101.CN04` as two genuinely different
  /// parents.
  ///
  /// The node id of every segment is the dotted prefix itself, which is what
  /// lets `OpcUaAddressSpace` read a gateway key straight off a NodeId instead
  /// of maintaining a second mapping.
  final List<String> treePaths;

  /// **08-11.** Dotted paths that become method nodes.
  ///
  /// The one node kind that must NOT be expandable, and therefore the one the
  /// type mapping can be judged on: a folder that fails to expand hides tags,
  /// and a method that offers to expand invites a click that can only ever
  /// produce an empty level.
  final List<String> methodPaths;

  /// The server's log level, kept so [restart] can rebuild an identical one.
  final LogLevel logLevel;

  /// The fault seam, or null when the fixture was built without one.
  ///
  /// Present, the client connects through it and every one of Phase 2's eight
  /// modes is available against `opc.tcp` unchanged: the injection is at the
  /// TCP level and a server at `MessageSecurityMode.NONE` has no TLS record
  /// layer to swallow a mid-frame cut.
  final FaultProxy? proxy;

  Server _server;
  Timer _driver;
  bool _disposed = false;

  /// The last value written to each plain node, so [restart] can restore them.
  final Map<String, DynamicValue> _plainValues = <String, DynamicValue>{};

  /// The current value of each data-source node.
  final Map<String, DynamicValue> _sourceValues = <String, DynamicValue>{};

  /// Data-source keys whose read callback is currently made to throw.
  final Set<String> _failingReads = <String>{};

  /// How many writes each data-source node has been handed **by the server**.
  ///
  /// This is the counter the behavioural no-retry arm reads. It counts at the
  /// far end of the wire, which is the only place that can tell a re-issued
  /// write from a re-tried one.
  final Map<String, int> _writeCounts = <String, int>{};

  /// Everything each data-source node was written, in order.
  final Map<String, List<DynamicValue>> _writeLog =
      <String, List<DynamicValue>>{};

  /// The endpoint a client should dial.
  ///
  /// Through the proxy when there is one — which is the point of having it:
  /// nothing else in the fixture changes, so a fault leg and a clean leg
  /// exercise the same adapter over the same code path.
  String get endpoint => proxy == null
      ? 'opc.tcp://127.0.0.1:$port'
      : 'opc.tcp://127.0.0.1:${proxy!.port}';

  /// Stands the server up, with an optional fault proxy in front of it.
  static Future<OpcUaServerFixture> start({
    Iterable<String> valueKeys = const <String>[],
    Iterable<String> writeKeys = const <String>[],
    Map<String, DynamicValue> typedWriteKeys = const <String, DynamicValue>{},
    Map<String, Map<String, Object>> structKeys =
        const <String, Map<String, Object>>{},
    Iterable<String> treePaths = const <String>[],
    Iterable<String> methodPaths = const <String>[],
    // Initial values for plain value nodes, applied **before** the node is
    // created so its OPC UA data type is minted from the seed. A node
    // created scalar (the default seed is `0`) coerces a later array write to
    // a scalar — an array node must be born one. Keys here must also appear
    // in [valueKeys].
    Map<String, Object?> seedValues = const <String, Object?>{},
    bool viaFaultProxy = false,
    LogLevel logLevel = LogLevel.UA_LOGLEVEL_ERROR,
  }) async {
    final values = valueKeys.toList();
    final writes = writeKeys.toList();
    final tree = treePaths.toList();
    final methods = methodPaths.toList();

    final built = await withFreePort<({Server server, int port})>((port) async {
      final server = Server(port: port, logLevel: logLevel);
      server.start();
      return (server: server, port: port);
    });

    final fixture = OpcUaServerFixture._(
      port: built.port,
      valueKeys: values,
      writeKeys: writes,
      typedWriteKeys: typedWriteKeys,
      structKeys: structKeys,
      treePaths: tree,
      methodPaths: methods,
      logLevel: logLevel,
      server: built.server,
      // Armed immediately: the nodes below are added while the crank is
      // already turning, exactly as the existing fixture does it.
      driver: Timer.periodic(
          serverIteratePeriod, (_) => _crank(() => built.server)),
      proxy: viaFaultProxy ? FaultProxy(targetPort: built.port) : null,
    );
    // Before `_addNodes`, so the seed is the value the node is created with
    // and therefore what mints its data type.
    for (final entry in seedValues.entries) {
      fixture._plainValues[entry.key] = fixtureValue(entry.value, name: entry.key);
    }
    fixture._addNodes();
    await fixture.proxy?.start();
    return fixture;
  }

  /// One turn of the crank, guarded.
  ///
  /// A `runIterate` on a server a test has already shut down is not a test
  /// failure worth reporting and it must not become an unhandled zone error;
  /// the teardown cancels this timer first precisely so it normally cannot
  /// happen, and this guard is what makes "normally" not matter.
  static void _crank(Server Function() server) {
    try {
      server().runIterate();
    } catch (_) {
      // Deliberately swallowed. See above.
    }
  }

  void _addNodes() {
    _addTree();
    for (final entry in structKeys.entries) {
      final key = entry.key;
      // The type id is minted from the key, so a failure names the tag.
      final typeId = fixtureNodeId('$key.__Type');
      final value = DynamicValue(name: key, typeId: typeId);
      for (final member in entry.value.entries) {
        value[member.key] = _structMember(member.value);
      }
      _server.addCustomType(typeId, value);
      _server.addDataTypeNode(typeId, '$key.__Type');
      _server.addVariableNode(fixtureNodeId(key), value, typeId: typeId);
    }
    for (final key in valueKeys) {
      final seed = _plainValues[key] ?? fixtureValue(0, name: key);
      _server.addVariableNode(fixtureNodeId(key), seed);
      _plainValues[key] = seed;
    }
    for (final key in writeKeys) {
      _addDataSourceNode(key, fixtureValue(0, name: key));
    }
    for (final entry in typedWriteKeys.entries) {
      // The seed's own typeId is the node's declared DataType — that is the
      // whole difference between this loop and the one above.
      _addDataSourceNode(entry.key, entry.value,
          typeId: entry.value.typeId);
    }
  }

  /// One data-source node: writable, countable, failable.
  ///
  /// [typeId] null keeps open62541's permissive `BaseDataType` default (what
  /// [writeKeys] has always produced); non-null publishes the node's DataType
  /// attribute, which is what makes the server enforce a type on write.
  void _addDataSourceNode(String key, DynamicValue seed, {NodeId? typeId}) {
    _writeCounts.putIfAbsent(key, () => 0);
    _writeLog.putIfAbsent(key, () => <DynamicValue>[]);
    _sourceValues.putIfAbsent(key, () => seed);
    _server.addDataSourceVariableNode(
      fixtureNodeId(key),
      browseName: key,
      typeId: typeId,
      onRead: () {
        if (_failingReads.contains(key)) {
          // A throw out of the read callback becomes UA_STATUSCODE_
          // BADINTERNALERROR on the wire (`server.dart:318-320`), which is
          // exactly the 0x80020000 08-01's probe measured. That is a Bad
          // status on a node that still exists — the other half of the
          // quality table from a deleted node's BadNodeIdUnknown.
          throw StateError('fixture: read of $key is failing on purpose');
        }
        return _sourceValues[key]!;
      },
      onWrite: (value) async {
        _writeCounts[key] = (_writeCounts[key] ?? 0) + 1;
        _writeLog[key]!.add(value);
        _sourceValues[key] = value;
      },
    );
  }

  /// One struct member, with its OPC UA type derived from the initial value
  /// — [fixtureValue]'s explicit-type rule, applied per member, because a
  /// member whose data type the server guessed would disagree with every
  /// later sample.
  static DynamicValue _structMember(Object raw) => switch (raw) {
        bool value => DynamicValue(value: value, typeId: NodeId.boolean),
        int value => DynamicValue(value: value, typeId: NodeId.int32),
        double value => DynamicValue(value: value, typeId: NodeId.double),
        String value => DynamicValue(value: value, typeId: NodeId.uastring),
        _ => throw ArgumentError.value(raw, 'structKeys',
            'struct members are scalars; a nested struct needs its own '
                'registered type and no plan has asked for one'),
      };

  /// **08-11.** Builds the object chain for [treePaths] and [methodPaths].
  ///
  /// Segments are created once and in prefix order, so `ST101.CN01.MOT01` and
  /// `ST101.CN04.MOT01` share the `ST101` object and diverge below it — which
  /// is exactly the shape the two-folder arm needs and the shape a flat address
  /// space cannot produce.
  void _addTree() {
    final created = <String>{};
    void ensureFolder(String path) {
      if (!created.add(path)) return;
      final cut = path.lastIndexOf('.');
      final parent = cut < 0 ? null : path.substring(0, cut);
      if (parent != null) ensureFolder(parent);
      _server.addFolderNode(
        fixtureNodeId(path),
        path,
        parentNodeId: parent == null ? null : fixtureNodeId(parent),
      );
    }

    for (final path in treePaths) {
      final cut = path.lastIndexOf('.');
      if (cut < 0) {
        throw ArgumentError.value(path, 'treePaths',
            'a tree path needs at least one parent segment; a leaf directly '
            'under ObjectsFolder is what valueKeys already gives you');
      }
      ensureFolder(path.substring(0, cut));
      final seed = _plainValues[path] ?? fixtureValue(0, name: path);
      _server.addVariableNode(
        fixtureNodeId(path),
        seed,
        parentNodeId: fixtureNodeId(path.substring(0, cut)),
      );
      _plainValues[path] = seed;
    }
    for (final path in methodPaths) {
      final cut = path.lastIndexOf('.');
      if (cut < 0) {
        throw ArgumentError.value(
            path, 'methodPaths', 'a method path needs a parent segment');
      }
      ensureFolder(path.substring(0, cut));
      _server.addMethodNode(
        fixtureNodeId(path),
        browseName: path,
        // The gateway never calls it. What matters is that the node exists,
        // that it is reachable by a hierarchical reference, and that it comes
        // back as UA_NODECLASS_METHOD — the one kind that must not expand.
        callback: (_, __) async => const <DynamicValue>[],
        parentNodeId: fixtureNodeId(path.substring(0, cut)),
      );
    }
  }

  // ------------------------------------------------------------- the levers
  //
  // Each names the plan that earned it. Nothing may be added here without a
  // test in the same commit — a lever with no caller is a fixture growing a
  // surface nobody is judged by.

  /// **08-07.** Publishes [value] for [key].
  ///
  /// On a plain node this writes the stored `UA_DataValue`, and the server
  /// stamps its `sourceTimestamp` **now** and keeps it. Every later sample
  /// reports that instant, so a write followed by a wait produces a value
  /// whose source time is provably older than its arrival.
  void setValue(String key, Object? value) {
    // A typed node keeps its declared type: re-seeding it through
    // [fixtureValue]'s int→Int32 rule would make the node serve a value whose
    // type disagrees with its own DataType attribute, and every read after
    // that would be measuring the fixture rather than the code.
    final declared = typedWriteKeys[key]?.typeId;
    final shaped = declared == null
        ? fixtureValue(value, name: key)
        : DynamicValue(value: value, typeId: declared, name: key);
    if (_sourceValues.containsKey(key)) {
      _sourceValues[key] = shaped;
      return;
    }
    _plainValues[key] = shaped;
    _server.write(fixtureNodeId(key), shaped);
  }

  /// **08-07.** Makes [key]'s reads fail (or stop failing) at the server.
  ///
  /// Data-source keys only — a plain node has no callback to fail. The Bad
  /// code the client sees is `BadInternalError`; for `BadNodeIdUnknown` use
  /// [deleteNode], because the two are different instructions to an operator
  /// and this fixture must be able to produce both.
  void setReadFails(String key, {bool failing = true}) {
    if (!_sourceValues.containsKey(key)) {
      throw ArgumentError.value(key, 'key',
          'setReadFails works on a data-source node; pass it in writeKeys');
    }
    if (failing) {
      _failingReads.add(key);
    } else {
      _failingReads.remove(key);
    }
  }

  /// **08-08.** The tag leaves the address space.
  ///
  /// A monitored item on a deleted node reports `BadNodeIdUnknown`, which the
  /// adapter maps to `Quality.errorConfig` — waiting will not bring it back,
  /// and that is a different thing to tell an operator than a comms fault.
  void deleteNode(String key) {
    _server.deleteNode(fixtureNodeId(key));
    _plainValues.remove(key);
    _sourceValues.remove(key);
  }

  /// **08-07.** How many writes the *server* has accepted for [key].
  int writeCount(String key) => _writeCounts[key] ?? 0;

  /// **08-07.** Everything the server was written for [key], in order.
  List<DynamicValue> writeLog(String key) =>
      List<DynamicValue>.unmodifiable(_writeLog[key] ?? const <DynamicValue>[]);

  /// **08-08.** Shuts the server down and brings a new one up on the same port.
  ///
  /// `Server_ServerStatus_StartTime` (ns=0, i=2257) genuinely moves, which is
  /// what makes the epoch arm a measurement rather than an assertion about a
  /// counter this fixture incremented. The port is held across the gap by
  /// nothing at all — there is a window in which it is free, which is the same
  /// race [freePort] documents and the same reason the caller retries.
  ///
  /// Write counts survive; node values are restored from what was last set, so
  /// a test that restarts does not also have to re-seed.
  Future<void> restart() async {
    _driver.cancel();
    try {
      _server.shutdown();
    } catch (_) {
      // Already down. See the teardown comment.
    }
    _server.delete();
    // The OS holds the listening socket briefly after a close; giving it a
    // turn of the event loop is not a fix for that and is not pretending to
    // be one — `Server.start()` throws if the port is still taken and the
    // caller's retry is what handles it.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final replacement = Server(port: port, logLevel: logLevel);
    replacement.start();
    _server = replacement;
    _driver =
        Timer.periodic(serverIteratePeriod, (_) => _crank(() => replacement));
    _addNodes();
  }

  /// Tears the fixture down in the one order that does not crash the VM.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // 1. The driver first. A `runIterate` racing a `shutdown()` is the SEGV.
    _driver.cancel();
    // 2. The proxy next, so nothing is still trying to reach the server.
    await proxy?.shutdown();
    // 3. shutdown() inside try/catch: a test may have killed the server
    //    already (`subscription_inactivity_test.dart:51-57` does exactly
    //    this, and says the same thing).
    try {
      _server.shutdown();
    } catch (_) {
      // Already shut down.
    }
    // 4. delete() last, and only after shutdown. The binding refuses the
    //    other order (`server.dart:1333-1336`) and the native side does not.
    _server.delete();
  }
}
