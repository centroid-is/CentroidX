/// An in-memory `ua.ClientApi`, so the OPC UA adapter's **lifecycle** can be
/// judged without a server.
///
/// ## Why this exists when there is a real in-process server one file over
///
/// `opcua_link_test.dart` runs against a genuine open62541 `Server` and that
/// is the right subject for anything about the *wire*: what a Bad status
/// deserializes to, whether a monitored item is re-created after a reprogram,
/// what the binding does with a source timestamp. None of those can be faked
/// honestly.
///
/// The three lifetime hazards 08-REVIEW found are a different kind of
/// question, and the real server is the wrong instrument for all three:
///
///  * **WR-04** is *"`dispose()` landed while `connect()` was between two
///    awaits"*. Against a real server the window is microseconds wide and
///    cannot be aimed at; the failure it produces is a **SEGV**, which does
///    not fail a case, it kills the process running it. Here the window is a
///    lever ([connectDelay]).
///  * **WR-03** is *"the injected client was never deleted"*, and the symptom
///    is a worker isolate outliving the VM's last `await`. There is no isolate
///    census a case can read; there is a [deleteCount] here.
///  * **WR-05** is *"one deadline was spent five times"*, and what a case
///    needs there is a phase that is slower than its share. [connectDelay],
///    [subscriptionDelay] and [readDelay] supply that; the elapsed time is
///    then measured from outside, because `.timeout()` is applied by the
///    caller and a double cannot see what it was given.
///
/// So this double is deliberately not a second OPC UA implementation — it
/// answers nothing about the protocol, and every case that uses it is about
/// this package's own bookkeeping.
library;

import 'dart:async';

import 'package:open62541/open62541.dart' as ua;

/// A `ClientApi` that does what it is told and remembers what it was asked.
final class FakeUaClient implements ua.ClientApi {
  // ------------------------------------------------------------- the levers

  /// How long [connect] takes. The window a `dispose` has to land inside.
  Duration connectDelay = Duration.zero;

  /// How long [subscriptionCreate] takes. The *second* window, which is the
  /// one `_disposed` was never re-read before.
  Duration subscriptionDelay = Duration.zero;

  /// How long each [read] takes. Three of these happen inside one epoch
  /// reading, which is what made a single deadline into three.
  Duration readDelay = Duration.zero;

  /// Thrown by [connect] when set, to exercise the failure path.
  Object? connectFailure;

  /// Thrown by every [read] while set, to exercise the undecodable-type path.
  ///
  /// The pinned binding's decode failures arrive as **strings** ('Unsupported
  /// nodeId type: …', thrown at `common.dart:170`) — and under
  /// `useIsolate: true` every error is a string by construction, because the
  /// isolate marshals them as `e.toString()`. A case that wants the decode
  /// probe to see what the bench's Guid/ByteString/LocalizedText/Range keys
  /// produce sets this to that exact sentence. Unlike [connectFailure] it is
  /// NOT one-shot: an undecodable type fails every read, not the next one.
  Object? readFailure;

  // ----------------------------------------------------------- the evidence

  /// How many times [delete] was called. **The WR-03 observable**: one means
  /// the link released what it was handed, zero means a `ClientIsolate` would
  /// still be alive and keeping the VM up.
  int deleteCount = 0;

  /// Node reads, in order.
  final List<ua.NodeId> reads = <ua.NodeId>[];

  /// Writes, in order.
  final List<({ua.NodeId node, ua.DynamicValue value})> writes =
      <({ua.NodeId node, ua.DynamicValue value})>[];

  /// How many subscriptions this client was asked to create.
  int subscriptionCreates = 0;

  /// What [read] answers, by node string. Anything unmapped answers a null
  /// value, which is what a server that has nothing to say looks like.
  final Map<String, ua.DynamicValue> answers = <String, ua.DynamicValue>{};

  final StreamController<ua.ClientState> _states =
      StreamController<ua.ClientState>.broadcast();

  bool _deleted = false;

  /// Whether [delete] has been called at least once.
  bool get deleted => _deleted;

  // -------------------------------------------------------------- the shape

  @override
  Future<void> awaitConnect() async {}

  @override
  Future<void> connect(String url) async {
    if (connectDelay > Duration.zero) {
      await Future<void>.delayed(connectDelay);
    }
    final failure = connectFailure;
    if (failure != null) {
      connectFailure = null;
      throw failure;
    }
  }

  @override
  Stream<ua.ClientState> get stateStream => _states.stream;

  @override
  Future<ua.DynamicValue> read(ua.NodeId nodeId) async {
    reads.add(nodeId);
    if (readDelay > Duration.zero) await Future<void>.delayed(readDelay);
    final failure = readFailure;
    if (failure != null) throw failure;
    return answers['$nodeId'] ?? ua.DynamicValue(value: null);
  }

  @override
  Future<ua.DataValue> readValue(ua.NodeId nodeId) async {
    // Same answers table as [read]; nothing in this package's tests consults
    // the DataValue envelope beyond the value itself.
    final value = await read(nodeId);
    return ua.DataValue(value: value, statusCode: 0);
  }

  @override
  Future<void> write(ua.NodeId nodeId, ua.DynamicValue value) async {
    writes.add((node: nodeId, value: value));
  }

  @override
  Future<Map<ua.NodeId, ua.DynamicValue>> readAttribute(
          Map<ua.NodeId, List<ua.AttributeId>> nodes) async =>
      <ua.NodeId, ua.DynamicValue>{};

  @override
  Future<int> subscriptionCreate({
    Duration requestedPublishingInterval = const Duration(milliseconds: 100),
    int requestedLifetimeCount = 10000,
    int requestedMaxKeepAliveCount = 10,
    int maxNotificationsPerPublish = 0,
    bool publishingEnabled = true,
    int priority = 0,
  }) async {
    if (subscriptionDelay > Duration.zero) {
      await Future<void>.delayed(subscriptionDelay);
    }
    subscriptionCreates++;
    return subscriptionCreates;
  }

  @override
  Stream<ua.DynamicValue> monitor(
    ua.NodeId nodeId,
    int subscriptionId, {
    ua.MonitoringMode monitoringMode =
        ua.MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
    bool deliverBadStatus = false,
  }) =>
      const Stream<ua.DynamicValue>.empty();

  @override
  Stream<Map<ua.NodeId, ua.DynamicValue>> monitoredItems(
    Map<ua.NodeId, List<ua.AttributeId>> nodes,
    int subscriptionId, {
    ua.MonitoringMode monitoringMode =
        ua.MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
    bool deliverBadStatus = false,
  }) =>
      const Stream<Map<ua.NodeId, ua.DynamicValue>>.empty();

  @override
  Future<List<ua.BrowseResultItem>> browse(
    ua.NodeId nodeId, {
    int direction = 0,
    ua.NodeId? referenceTypeId,
    bool includeSubtypes = true,
    int nodeClassMask = 0,
    ua.BrowseResultMask resultMask =
        ua.BrowseResultMask.UA_BROWSERESULTMASK_ALL,
  }) async =>
      <ua.BrowseResultItem>[];

  @override
  Stream<ua.BrowseTreeItem> browseTree(
    ua.NodeId root, {
    int maxDepth = 100,
    ua.NodeId? referenceTypeId,
    bool includeSubtypes = true,
    Set<ua.NodeClass> recurseInto = const <ua.NodeClass>{
      ua.NodeClass.UA_NODECLASS_OBJECT,
      ua.NodeClass.UA_NODECLASS_VIEW,
    },
  }) =>
      const Stream<ua.BrowseTreeItem>.empty();

  @override
  Future<List<ua.DynamicValue>> call(ua.NodeId objectId, ua.NodeId methodId,
          Iterable<ua.DynamicValue> args) async =>
      <ua.DynamicValue>[];

  @override
  Future<void> delete() async {
    deleteCount++;
    _deleted = true;
    if (!_states.isClosed) await _states.close();
  }
}
