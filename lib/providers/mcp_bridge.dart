import 'dart:async';
import 'dart:io' as io;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_access/tfc_access.dart' show AccessDenied;
import 'package:tfc_mcp_server/tfc_mcp_server_data.dart'
    show
        AlarmReader,
        DriftDrawingIndex,
        DriftTechDocIndex,
        McpConfig,
        McpDatabase,
        NodeBrowser,
        StateReader,
        migrateMcpConfigToDeviceLocal,
        readMcpConfigFromPreferences;

import '../mcp/alarm_man_alarm_reader.dart';
import '../mcp/app_screen_capturer.dart';
import '../mcp/mcp_lifecycle_state.dart';
import '../mcp/mcp_bridge_notifier.dart';
// Behind a seam: the browser holds a live OPC UA session, which is
// `dart:ffi`. See `mcp/node_browser_seam.dart`.
import '../mcp/node_browser_seam.dart';
import '../mcp/state_man_state_reader.dart';
import '../pages/page_view.dart' show PlantPageView;
import 'alarm.dart';
import 'database.dart' show databaseProvider;
import 'page_manager.dart' show pageManagerProvider;
import 'plc.dart' show plcCodeIndexProvider;
import 'preferences.dart'
    show localPreferencesProvider, systemPreferencesProvider;
import 'proposal.dart' show describeProposalFeedback;
import 'proposal_state.dart'
    show
        PendingProposal,
        ProposalFeedback,
        proposalFeedbackProvider,
        proposalStateProvider;
import 'state_man.dart';

export '../mcp/mcp_bridge_notifier.dart'
    show McpBridgeNotifier, McpBridgeState, McpConnectionState, kMcpConfigKey;

/// Provides a singleton [McpBridgeNotifier] for managing the SSE MCP server.
///
/// Uses [ChangeNotifierProvider] so that [ref.watch] consumers rebuild
/// when the bridge state changes (e.g., server starts/stops).
final mcpBridgeProvider = ChangeNotifierProvider<McpBridgeNotifier>((ref) {
  final notifier = McpBridgeNotifier();
  ref.onDispose(() {
    notifier.dispose();
  });
  return notifier;
});

/// Assembles the environment variable map for the MCP server subprocess.
Map<String, String> getMcpServerEnv() {
  final env = io.Platform.environment;
  return {
    if (env['CENTROID_PGHOST'] != null)
      'CENTROID_PGHOST': env['CENTROID_PGHOST']!,
    if (env['CENTROID_PGPORT'] != null)
      'CENTROID_PGPORT': env['CENTROID_PGPORT']!,
    if (env['CENTROID_PGDATABASE'] != null)
      'CENTROID_PGDATABASE': env['CENTROID_PGDATABASE']!,
    if (env['CENTROID_PGUSER'] != null)
      'CENTROID_PGUSER': env['CENTROID_PGUSER']!,
    if (env['CENTROID_PGPASSWORD'] != null)
      'CENTROID_PGPASSWORD': env['CENTROID_PGPASSWORD']!,
  };
}

/// Mutable state for the MCP server lifecycle provider.
final _serverLifecycle = McpLifecycleState();

/// One-time (per run) migration of the MCP config out of the shared
/// database-backed preferences into device-local preferences.
///
/// The MCP config is per-station: whether this device runs the MCP server
/// must not be decided by another HMI writing to the same database.
final mcpConfigMigrationProvider = FutureProvider<void>((ref) async {
  final local = ref.watch(localPreferencesProvider);
  try {
    // Watch, don't read: when the database comes up after an offline
    // start, preferencesProvider is recreated and re-syncs Postgres rows
    // into the device store — the migration must re-run at that moment
    // to delete the stale mcp.config row before the next sync. It is
    // idempotent, so re-running on every reconnect is safe.
    // systemPreferencesProvider watches preferencesProvider, so this keeps
    // that property rather than trading it for the escape.
    //
    // The timeout keeps the device-local MCP config independent of
    // database health: if preferencesProvider stalls (e.g. a half-open
    // connection), the config loads anyway and the migration re-runs
    // when the provider eventually emits.
    //
    // The **system** view of the shared store, not the ordinary one. This
    // runs at boot with nobody signed in and calls `shared.remove(...)` once
    // for `mcp.config` and once for each legacy key, all of which need
    // `administer` under the `mcp.` prefix rule. Through the checked path
    // every one of those is refused, the `catch` below swallows it, and the
    // stale shared row this migration exists to delete survives forever —
    // behind a log line that reads like a database outage. `systemWrites`
    // skips the denial, not the audit: each removal still lands in the trail
    // marked `origin: 'system'`.
    //
    // `local` stays `localPreferencesProvider` and stays unguarded. Widening
    // that store into the guard to make the two sides symmetric would put an
    // audit row on every `poke()` — one per pointer-down, per plan 01-07's
    // note — which is a conversation about throttling the persist, not a
    // change to make in passing.
    final shared = await ref
        .watch(systemPreferencesProvider.future)
        .timeout(const Duration(seconds: 15));
    await migrateMcpConfigToDeviceLocal(shared: shared, local: local);
  } on AccessDenied catch (e) {
    // Not an outage. Reaching here means the migration was routed back
    // through the checked path, and no session at boot can satisfy
    // `administer` — so the stale shared row will never be deleted and the
    // device config will be overwritten by it on the next sync. That is a
    // defect in this app's access policy wiring, and it is deliberately not
    // phrased like the sentence below.
    io.stderr.writeln(
        'MCP config migration REFUSED: writing "${e.itemKey}" needs the '
        '${e.required.name} group, and nobody is signed in at boot. '
        'This is a defect in the access policy wiring, not a database '
        'outage: the migration must take systemPreferencesProvider. The '
        'stale shared mcp.config row has NOT been removed.');
  } catch (e) {
    // Shared preferences unavailable — the local store is authoritative
    // anyway; migration re-runs when preferencesProvider recovers.
    io.stderr.writeln('MCP config migration skipped: $e');
  }
});

/// Provider for the consolidated MCP config (single JSON blob).
///
/// Stored in device-local preferences only — never in the database.
final mcpConfigProvider = FutureProvider<McpConfig>((ref) async {
  await ref.watch(mcpConfigMigrationProvider.future);
  final local = ref.watch(localPreferencesProvider);
  return await readMcpConfigFromPreferences(local);
});

/// Provider for the MCP server enabled preference.
final mcpEnabledProvider = FutureProvider<bool>((ref) async {
  final config = await ref.watch(mcpConfigProvider.future);
  return config.serverEnabled;
});

/// Provider for the in-app chat bubble preference.
final mcpChatEnabledProvider = FutureProvider<bool>((ref) async {
  final config = await ref.watch(mcpConfigProvider.future);
  return config.chatEnabled;
});

/// Provider for the MCP server port preference.
final mcpPortProvider = FutureProvider<int>((ref) async {
  final config = await ref.watch(mcpConfigProvider.future);
  return config.port;
});

/// No-op reader for when StateMan is unavailable (no OPC-UA connection).
class _EmptyStateReader implements StateReader {
  @override
  Map<String, dynamic> get currentValues => {};
  @override
  dynamic getValue(String key) => null;
  @override
  List<String> get keys => [];
}

/// No-op reader for when AlarmMan is unavailable.
class _EmptyAlarmReader implements AlarmReader {
  @override
  List<Map<String, dynamic>> get alarmConfigs => [];
}

/// Starts the SSE server, using live data readers if available.
///
/// If StateMan or AlarmMan aren't ready (e.g., no OPC-UA connection),
/// the server starts anyway with empty readers. Config, drawings, PLC
/// code, and trend tools still work without live data.
Future<void> _startServer(McpBridgeNotifier bridge, int port,
    {required Ref ref}) async {
  StateReader stateReader;
  AlarmReader alarmReader;
  // Null unless StateMan is up: browsing needs a live PLC session.
  NodeBrowser? nodeBrowser;

  // Await live readers; fall back to empty no-ops only on actual error.
  try {
    final stateMan = await ref.read(stateManProvider.future);
    nodeBrowser = makeNodeBrowser(stateMan);
    final reader = StateManStateReader(stateMan);
    _serverLifecycle.activeStateReader = reader;
    // Subscribe in the background.  init() awaits one subscribe per key,
    // and StateMan._monitor waits on awaitConnect() with no timeout and
    // then retries forever, so a single unreachable node blocks the loop
    // permanently -- and even the happy path is one round trip per key.
    // The server must come up regardless; the cache fills in as the
    // subscriptions land, and getValue() returns null until then.
    unawaited(reader.init().catchError((Object e) {
      io.stderr.writeln('_startServer: state reader init failed: $e');
    }));
    stateReader = reader;
  } catch (e) {
    io.stderr
        .writeln('_startServer: StateMan unavailable, using empty reader: $e');
    stateReader = _EmptyStateReader();
  }

  try {
    // Awaited so an AlarmMan that cannot be built at all still falls back to
    // the empty reader below -- but the reader itself resolves the provider
    // on every read rather than closing over this instance. Accepting an
    // alarm edit invalidates alarmManProvider, and a reader holding the
    // AlarmMan from before would serve the pre-edit config for the rest of
    // the session.
    await ref.read(alarmManProvider.future);
    alarmReader = AlarmManAlarmReader.live(() => currentAlarmConfigs(ref));
  } catch (e) {
    io.stderr
        .writeln('_startServer: AlarmMan unavailable, using empty reader: $e');
    alarmReader = _EmptyAlarmReader();
  }

  final dbWrapper = await ref.read(databaseProvider.future);
  if (dbWrapper == null) {
    throw StateError('Database not connected');
  }
  final McpDatabase database = dbWrapper.db;

  final config = await ref.read(mcpConfigProvider.future);

  // What the operator is looking at, and what any configured page would look
  // like, as PNGs. Page keys are read live on every call so a page accepted
  // from a proposal is renderable without restarting the app.
  final screenCapturer = AppScreenCapturer(
    pageKeys: () =>
        ref.read(pageManagerProvider).valueOrNull?.pages.keys.toList() ??
        const <String>[],
    buildPage: (pageKey) => PlantPageView(pageName: pageKey),
  );

  await bridge.startSseServer(
    port,
    stateReader: stateReader,
    alarmReader: alarmReader,
    database: database,
    toggles: config.toggles,
    nodeBrowser: nodeBrowser,
    drawingIndex: DriftDrawingIndex(database),
    plcCodeIndex: ref.read(plcCodeIndexProvider),
    techDocIndex: DriftTechDocIndex(database),
    screenCapturer: screenCapturer,
  );
}

/// Relays the operator's decisions on proposals out to MCP clients.
///
/// [proposalFeedbackProvider] is a broadcast controller with two independent
/// consumers: the chat lifecycle turns each event into an operator-decision
/// note in the in-app conversation, and this relay pushes the same event onto
/// [McpBridgeNotifier.feedbackBus] where an external client picks it up with
/// `await_proposal_feedback`.
///
/// Deliberately NOT hung off `chatLifecycleProvider`. That provider only runs
/// when the in-app chat bubble is enabled, and the whole point of this path
/// is the case where it is not: an external client proposes over HTTP, the
/// operator accepts in the banner, and nothing about the in-app chat is
/// involved. Hanging the relay there would have made the feature work only
/// in the one configuration that does not need it.
///
/// The summary is rendered here, next to the proposals the banner actually
/// showed, with the same [describeProposalFeedback] the in-app AI is given:
/// the payload has to say WHAT was accepted, not just that something was.
final proposalFeedbackRelayProvider = Provider<void>((ref) {
  final bridge = ref.read(mcpBridgeProvider);
  final controller = ref.watch(proposalFeedbackProvider);

  final sub = controller.stream.listen((ProposalFeedback event) {
    try {
      bridge.feedbackBus.publish(
        action: event.action,
        summary: describeProposalFeedback(event.action, event.proposals),
        proposals: [
          for (final p in event.proposals)
            <String, dynamic>{
              'title': p.title,
              'type': p.proposalType,
              'op': p.action.name,
            },
        ],
      );
    } catch (e) {
      // A closed bus (bridge disposed mid-shutdown) must not take down the
      // stream that also feeds the in-app conversation.
      io.stderr.writeln('proposalFeedbackRelayProvider: publish failed: $e');
    }
  });
  ref.onDispose(sub.cancel);
});

/// Stages the proposals a write tool produced, so the operator sees a banner.
///
/// A proposal is never stored anywhere: `create_alarm`, `propose_asset` and
/// the rest hand one to [McpBridgeNotifier.proposalStream] and return. If
/// nobody is listening on that stream the proposal is gone the instant it is
/// made, while the tool still reports success to the client -- which is
/// exactly what shipped builds did, because the only listener lived inside
/// `chatLifecycleProvider`.
///
/// Deliberately NOT hung off `chatLifecycleProvider`, for the same reason as
/// [proposalFeedbackRelayProvider] below it. That provider only runs when the
/// in-app chat bubble is enabled, and every deployment build is compiled with
/// `--dart-define=CENTROIDX_CHAT=false`; the case this path exists for is
/// precisely the one where an external client proposes over HTTP and no
/// in-app chat is involved. The inbound half and the outbound half of the
/// same conversation with the operator now hang off the same thing: the MCP
/// server's lifecycle.
///
/// When chat IS on -- development builds, where it defaults to on -- both
/// listeners stage the same proposal from the same broadcast stream. That is
/// harmless: [ProposalStateNotifier.addProposal] deduplicates on the proposal
/// JSON, and both paths carry the stream's string through unchanged.
final proposalIngestProvider = Provider<void>((ref) {
  final bridge = ref.read(mcpBridgeProvider);

  final sub = bridge.proposalStream.listen(
    (String proposalJson) {
      final proposal = PendingProposal.tryParse(proposalJson);
      if (proposal == null) {
        io.stderr.writeln(
            'proposalIngestProvider: not a proposal, dropped: $proposalJson');
        return;
      }
      try {
        ref.read(proposalStateProvider.notifier).addProposal(proposal);
      } catch (e) {
        io.stderr.writeln('proposalIngestProvider: staging failed: $e');
      }
    },
    onError: (Object e) {
      io.stderr.writeln('proposalIngestProvider: proposalStream error: $e');
    },
  );
  ref.onDispose(sub.cancel);
});

/// Manages the MCP SSE server lifecycle based on the enabled preference.
///
/// When [mcpEnabledProvider] is true, starts the SSE server on the configured
/// port with live StateMan/AlarmMan readers.
///
/// When it goes false, stops the server.
///
/// Also watches config preference changes for debounced server restart.
final mcpServerLifecycleProvider = Provider<void>((ref) {
  // Keep both directions of the proposal conversation alive for as long as
  // the server is. They are mounted here rather than in main.dart so they
  // cannot be forgotten: a proposal nobody stages never reaches the
  // operator's banner, and an MCP server whose clients never learn what the
  // operator decided is the other half of the same gap.
  ref.watch(proposalIngestProvider);
  ref.watch(proposalFeedbackRelayProvider);

  // Watch enabled state changes.
  // Ignore AsyncLoading transitions to avoid stop/restart cycles when
  // preferencesProvider is temporarily invalidated (e.g. database reconnect).
  ref.listen<AsyncValue<bool>>(mcpEnabledProvider, (prev, next) async {
    // Skip loading states — preserve whatever is currently running.
    if (next is AsyncLoading) return;

    final enabled = next.valueOrNull ?? false;
    final bridge = ref.read(mcpBridgeProvider);

    if (enabled && !bridge.isRunning) {
      try {
        final port = await ref.read(mcpPortProvider.future);
        await _startServer(bridge, port, ref: ref);
      } catch (e) {
        io.stderr.writeln('mcpServerLifecycleProvider: failed to start: $e');
        _serverLifecycle.disposeReader();
      }
    } else if (!enabled && bridge.isRunning) {
      _serverLifecycle.disposeReader();
      await bridge.stopSseServer();
    }
  });

  // Watch config changes (port/toggles) for debounced server restart.
  // The config lives in device-local preferences, so changes arrive
  // through mcpConfigProvider (invalidated on every save), not through
  // the database-backed preferences change stream.
  ref.listen<AsyncValue<McpConfig>>(mcpConfigProvider, (prev, next) {
    if (next is AsyncLoading) return;
    final config = next.valueOrNull;
    if (config == null) return;

    // AsyncLoading retains the previous value, so this compares the new
    // config against the one the server was last started with.
    if (prev?.valueOrNull == config) return;

    final bridge = ref.read(mcpBridgeProvider);
    if (!bridge.isRunning) return;
    // Enable/disable transitions are handled by the listener above.
    if (!config.serverEnabled) return;

    _serverLifecycle.cancelTimer();
    _serverLifecycle.reconnectTimer =
        Timer(const Duration(milliseconds: 800), () async {
      try {
        await bridge.stopSseServer();
        _serverLifecycle.disposeReader();

        final port = await ref.read(mcpPortProvider.future);
        await _startServer(bridge, port, ref: ref);
      } catch (e) {
        io.stderr.writeln('Toggle reconnect failed: $e');
      }
    });
  });

  ref.onDispose(() {
    _serverLifecycle.dispose();
  });
});
