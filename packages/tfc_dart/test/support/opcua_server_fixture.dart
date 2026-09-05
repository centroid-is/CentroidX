/// A real in-process OPC UA server, on a port the kernel picked, with a seam
/// to break the wire in front of it.
///
/// Ported (trimmed) from `tfc_relay_local/test/support/opcua_server_fixture.dart`.
/// The original serves Phase 8's browse and collection work as well, so it
/// carries struct nodes, a folder hierarchy and method nodes; **no Phase 12
/// criterion needs any of those**, and a lever with no caller is a fixture
/// growing a surface nobody is judged by. What is left is the four things the
/// pipe's integration arms actually measure:
///
///  * a **plain variable node** ([valueKeys]) — an ordinary stored value, the
///    node kind nearly every real tag is. It cannot carry a chosen source
///    instant; see [setValue] and [setSourceTimestamp] for the measurement that
///    settled that;
///  * a **data-source node** ([writeKeys]) whose write callback counts
///    ([writeCount]) and records ([writeLog]) every write the *server* was
///    handed — counting at the far end of the wire is the only place that can
///    tell a re-issued write from a re-tried one, which is PIPE-12's no-retry
///    arm — and whose read callback serves an explicit `sourceTimestamp`
///    ([setSourceTimestamp]), which is how a sample is made *provably* older
///    than its own arrival by a chosen margin. PIPE-11's `sourceTime` arm is
///    that measurement, and it is the arm that has to be able to fail if the
///    translator ever stamps arrival instead;
///  * a **named refusal** ([setWriteRefusal]) — the write callback completes
///    with a `UaStatusException`, so the client sees that exact status code
///    (`Bad_NotWritable`) rather than the generic `Bad_InternalError` any other
///    error maps to. That is the difference between `WriteRejected` and
///    `WriteUnknown` in the three-state classifier, and the classifier parses
///    the *name* out of `UaStatusException.toString()`;
///  * [deleteNode] — the tag leaves the address space and a monitored item
///    reports `BadNodeIdUnknown`, which is a permanent (`errorConfig`) fault and
///    a different instruction to an operator than a comms fault.
///
/// **Teardown order is the fixture's whole content.** Cancel the iterate
/// driver, drop the proxy, `shutdown()` inside `try/catch` because a test may
/// have killed the server already, then `delete()`. Getting it wrong does not
/// fail a test — it SEGVs the VM, which is project memory from the
/// open62541_dart repo (state-after-delete). A SEGV in teardown destroys the
/// result of the arm that just ran, so this order is load-bearing for the
/// measurement, not just for hygiene.
///
/// Anything using this fixture binds a socket and must therefore carry
/// `@TestOn('vm')` (precedent: `test/core/acquisition_isolate_fatal_test.dart:9`).
library;

import 'dart:async';

import 'package:open62541/open62541.dart';

import '../proxy.dart';
import 'free_port.dart';

/// How often the iterate driver turns the server's crank.
///
/// 10 ms, the figure `test/subscription_inactivity_test.dart:47` already uses.
/// `runIterate` is a blocking FFI call, so this is also the granularity at
/// which the test isolate's event loop is interrupted — which is why this
/// package's `dart_test.yaml` pins `concurrency: 1`.
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
  // An array node: the binding models arrays as List<DynamicValue>
  // (`dynamic_value.dart:117`), so a bare Dart list must go through
  // `fromList` with an element type.
  if (value is List<double>) {
    return DynamicValue.fromList(value, typeId: NodeId.double, name: name);
  }
  return DynamicValue(
    value: value,
    name: name,
    typeId: value is int ? NodeId.int32 : null,
  );
}

/// An in-process OPC UA server with the levers Phase 12's plans need.
final class OpcUaServerFixture {
  OpcUaServerFixture._({
    required this.port,
    required this.valueKeys,
    required this.writeKeys,
    required this.logLevel,
    required Server server,
    required Timer driver,
    required this.proxy,
  })  : _server = server,
        _driver = driver;

  /// The port the OPC UA server itself is listening on.
  ///
  /// Kernel-allocated via [withFreePort]. There is no port literal anywhere in
  /// this file and there must never be one: a fixed port collides with the
  /// other copy of this suite running in a parallel worktree, and it collides
  /// deterministically rather than occasionally (project memory).
  final int port;

  /// Keys served by plain variable nodes: the server owns the source timestamp.
  final List<String> valueKeys;

  /// Keys served by data-source nodes: writable, countable, refusable.
  final List<String> writeKeys;

  /// The server's log level.
  final LogLevel logLevel;

  /// The fault seam, or null when the fixture was built without one.
  ///
  /// This is `tfc_dart`'s own `test/proxy.dart` `TcpProxy` — no new dev
  /// dependency. Set `proxy!.bufferServerToClient = true` to blackhole the
  /// upstream (server→client traffic held, client→server still forwarded, so
  /// the server-side subscription stays alive and the stall is a *silence*
  /// rather than a disconnect — which is the fault mode the isolation arm
  /// exists to measure).
  final TcpProxy? proxy;

  final Server _server;
  final Timer _driver;
  bool _disposed = false;

  /// The last value written to each plain node.
  final Map<String, DynamicValue> _plainValues = <String, DynamicValue>{};

  /// The current value of each data-source node.
  final Map<String, DynamicValue> _sourceValues = <String, DynamicValue>{};

  /// How many writes each data-source node has been handed **by the server**.
  final Map<String, int> _writeCounts = <String, int>{};

  /// Everything each data-source node was handed, in order.
  final Map<String, List<DynamicValue>> _writeLog =
      <String, List<DynamicValue>>{};

  /// Data-source keys whose writes are currently refused, and with what code.
  final Map<String, int> _writeRefusals = <String, int>{};

  /// The source instant each data-source node serves, when one was chosen.
  ///
  /// Absent (the default) means open62541 stamps the read — see
  /// [setSourceTimestamp].
  final Map<String, DateTime> _sourceStamps = <String, DateTime>{};

  /// The endpoint a client should dial.
  ///
  /// Through the proxy when there is one — which is the point of having it:
  /// nothing else in the fixture changes, so a fault leg and a clean leg
  /// exercise the same code path.
  String get endpoint => proxy == null
      ? 'opc.tcp://127.0.0.1:$port'
      : 'opc.tcp://127.0.0.1:${proxy!.port}';

  /// Stands the server up, with an optional fault proxy in front of it.
  static Future<OpcUaServerFixture> start({
    Iterable<String> valueKeys = const <String>[],
    Iterable<String> writeKeys = const <String>[],
    // Initial values for plain value nodes, applied **before** the node is
    // created so its OPC UA data type is minted from the seed. A node created
    // scalar (the default seed is `0`, hence Int32) coerces every later write
    // to that type — a double node must be born one. Keys here must also
    // appear in [valueKeys].
    Map<String, Object?> seedValues = const <String, Object?>{},
    bool viaProxy = false,
    LogLevel logLevel = LogLevel.UA_LOGLEVEL_ERROR,
  }) async {
    final values = valueKeys.toList();
    final writes = writeKeys.toList();

    final built = await withFreePort<({Server server, int port})>((port) async {
      final server = Server(port: port, logLevel: logLevel);
      server.start();
      return (server: server, port: port);
    });

    final fixture = OpcUaServerFixture._(
      port: built.port,
      valueKeys: values,
      writeKeys: writes,
      logLevel: logLevel,
      server: built.server,
      // Armed immediately: the nodes below are added while the crank is
      // already turning, exactly as the existing fixture does it.
      driver: Timer.periodic(
          serverIteratePeriod, (_) => _crank(() => built.server)),
      proxy: viaProxy ? TcpProxy(targetPort: built.port) : null,
    );
    // Before `_addNodes`, so the seed is the value the node is created with
    // and therefore what mints its data type.
    for (final entry in seedValues.entries) {
      fixture._plainValues[entry.key] =
          fixtureValue(entry.value, name: entry.key);
    }
    fixture._addNodes();
    await fixture.proxy?.start();
    return fixture;
  }

  /// One turn of the crank, guarded.
  ///
  /// A `runIterate` on a server a test has already shut down is not a test
  /// failure worth reporting and it must not become an unhandled zone error;
  /// [dispose] cancels this timer first precisely so it normally cannot happen,
  /// and this guard is what makes "normally" not matter.
  static void _crank(Server Function() server) {
    try {
      server().runIterate();
    } catch (_) {
      // Deliberately swallowed. See above.
    }
  }

  void _addNodes() {
    for (final key in valueKeys) {
      final seed = _plainValues[key] ?? fixtureValue(0, name: key);
      _server.addVariableNode(fixtureNodeId(key), seed);
      _plainValues[key] = seed;
    }
    for (final key in writeKeys) {
      _writeCounts.putIfAbsent(key, () => 0);
      _writeLog.putIfAbsent(key, () => <DynamicValue>[]);
      _sourceValues.putIfAbsent(key, () => fixtureValue(0, name: key));
      _server.addDataSourceVariableNode(
        fixtureNodeId(key),
        browseName: key,
        // onReadValue, not onRead: it is the only overload that can carry a
        // chosen sourceTimestamp (`server.dart:592-594` sets it on the outgoing
        // DataValue when one is supplied). See [setSourceTimestamp].
        onReadValue: () => DataSourceValue(
          value: _sourceValues[key]!,
          sourceTimestamp: _sourceStamps[key],
        ),
        onWrite: (value) async {
          // Counted and logged BEFORE the refusal check, deliberately. The
          // counter answers "how many writes did the server receive", and a
          // write that was refused was still received — that is precisely the
          // number the no-retry arm needs, because the failure it hunts is a
          // refused write being re-sent.
          _writeCounts[key] = (_writeCounts[key] ?? 0) + 1;
          _writeLog[key]!.add(value);
          final refusal = _writeRefusals[key];
          if (refusal != null) {
            // Completing this future with a UaStatusException is what makes
            // the client see this exact code (`server.dart:678-687`); any
            // other error becomes the generic Bad_InternalError, and the
            // write classifier reads the *name* out of the exception's
            // toString to tell a rejection from an unknown.
            throw UaStatusException(refusal);
          }
          // Only an accepted write moves the served value.
          _sourceValues[key] = value;
        },
      );
    }
  }

  // ------------------------------------------------------------- the levers
  //
  // Nothing may be added here without a caller — a lever no arm pulls is a
  // surface nobody is judged by.

  /// Publishes [value] for [key] — a plain node ([valueKeys]) or a data-source
  /// node ([writeKeys]).
  ///
  /// **This does not choose a source timestamp, and the source fixture's claim
  /// that it does is wrong against the pinned build — measured, 12-02.** The
  /// original comment (`tfc_relay_local/test/support/opcua_server_fixture.dart`
  /// `:384-398`) says the server stamps `sourceTimestamp` at write and every
  /// later sample reports that instant. It does not: `Server.write`
  /// (`server.dart:1673-1676`) calls `UA_Server_writeValue`, which writes the
  /// **Variant only** — no DataValue, no timestamp — and open62541 then stamps
  /// the source instant when the node is *read*. A write, a 600 ms wait and a
  /// first sample produced a stamp 142 ms before arrival, not 600+: the offset
  /// was the publish interval, i.e. the transport, not anything the test chose.
  ///
  /// That offset is exactly the one an arrival-stamping implementation would
  /// also produce, so a PIPE-11 arm built on it could not fail — which is why
  /// [setSourceTimestamp] exists and why the source-time arm must use it.
  void setValue(String key, Object? value) {
    final shaped = fixtureValue(value, name: key);
    if (_sourceValues.containsKey(key)) {
      _sourceValues[key] = shaped;
      return;
    }
    _plainValues[key] = shaped;
    _server.write(fixtureNodeId(key), shaped);
  }

  /// Serves [at] as [key]'s `sourceTimestamp`, or hands the stamp back to the
  /// server.
  ///
  /// Data-source keys only — a plain node has no read callback, and (see
  /// [setValue]) the plain-node path cannot carry a chosen instant at all.
  ///
  /// This is the lever PIPE-11's source-time arm needs, and the reason is that
  /// **the arm has to be able to fail**. Pass
  /// `DateTime.now().subtract(const Duration(seconds: 30))` and the sample's
  /// source instant is thirty seconds older than its arrival *by construction*
  /// — a margin no transport delay explains and no arrival-stamping translator
  /// can reproduce. Assert against that margin and the test distinguishes a
  /// preserved source time from a re-stamped one; assert against the few
  /// hundred milliseconds a plain node happens to show and it does not.
  ///
  /// Passing `null` clears it, and open62541 goes back to stamping the read.
  void setSourceTimestamp(String key, DateTime? at) {
    if (!_sourceValues.containsKey(key)) {
      throw ArgumentError.value(key, 'key',
          'setSourceTimestamp works on a data-source node; pass it in '
              'writeKeys');
    }
    if (at == null) {
      _sourceStamps.remove(key);
    } else {
      _sourceStamps[key] = at;
    }
  }

  /// Makes writes to [key] fail with a **named** status code, or stop failing.
  ///
  /// Pass a code (`UA_STATUSCODE_BADNOTWRITABLE`,
  /// `UA_STATUSCODE_BADUSERACCESSDENIED`) to refuse; pass `null` to accept
  /// again. Data-source keys only — a plain node has no callback to refuse
  /// with.
  ///
  /// The point of the *name* is that the three-state classifier's textual
  /// branch matches `Bad_NotWritable` against its refusal table and answers
  /// `WriteRejected`. An unnamed failure (any other thrown object) arrives as
  /// `Bad_InternalError`, is not in the table, and is therefore classified
  /// `WriteUnknown` — the safe half. This fixture must be able to produce both
  /// or neither half can be shown to be reached.
  void setWriteRefusal(String key, int? statusCode) {
    if (!_sourceValues.containsKey(key)) {
      throw ArgumentError.value(key, 'key',
          'setWriteRefusal works on a data-source node; pass it in writeKeys');
    }
    if (statusCode == null) {
      _writeRefusals.remove(key);
    } else {
      _writeRefusals[key] = statusCode;
    }
  }

  /// The tag leaves the address space.
  ///
  /// A monitored item on a deleted node reports `BadNodeIdUnknown`, which the
  /// translator maps to `Quality.errorConfig` — waiting will not bring it back,
  /// and that is a different thing to tell an operator than a comms fault.
  void deleteNode(String key) {
    _server.deleteNode(fixtureNodeId(key));
    _plainValues.remove(key);
    _sourceValues.remove(key);
    _writeRefusals.remove(key);
    _sourceStamps.remove(key);
  }

  /// How many writes the *server* has been handed for [key], refusals included.
  int writeCount(String key) => _writeCounts[key] ?? 0;

  /// Everything the server was handed for [key], in order, refusals included.
  List<DynamicValue> writeLog(String key) =>
      List<DynamicValue>.unmodifiable(_writeLog[key] ?? const <DynamicValue>[]);

  /// Tears the fixture down in the one order that does not crash the VM.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // 1. The driver first. A `runIterate` racing a `shutdown()` is the SEGV.
    _driver.cancel();
    // 2. The proxy next, so nothing is still trying to reach the server.
    await proxy?.shutdown();
    // 3. shutdown() inside try/catch: a test may have killed the server
    //    already (`subscription_inactivity_test.dart:51-57` does exactly this,
    //    and says the same thing).
    try {
      _server.shutdown();
    } catch (_) {
      // Already shut down.
    }
    // 4. delete() last, and only after shutdown. The binding refuses the other
    //    order (`server.dart:1333-1336`) and the native side does not.
    _server.delete();
  }
}
