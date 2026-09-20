@Timeout(Duration(minutes: 30))
library;

/// Every ADVANCED page of the HMI, opened over the real relay WebSocket
/// against the real backend, a real plant and a real Postgres.
///
/// ## Why these pages, and why here
///
/// `lib/access_routes.dart`'s `kRaisedRoutes` lists the eleven routes raised
/// above `operate`. They are where a panel edits the plant — accounts, key
/// mappings, alarm rules, the backend's own configuration — and where a
/// wrong answer costs the most. Every one of them has widget tests over fakes;
/// none of them had ever been rendered against the graph `centroidx-backend`
/// actually serves. This lane is that: `support/backend_bench.dart` assembles
/// `composeBackendRelay` the way `bin/main.dart` does, `support/panel.dart`
/// boots the app's own providers in gateway mode against it, and each page
/// file under `pages/` drives the page the way a finger would.
///
/// ## What every page proves
///
/// 1. It opens over the relay and renders REAL data — a value that came from
///    the plant or a row that came from Postgres, asserted by content. A
///    section-shaped hole is a known failure mode here (memory
///    `fake-prefs-hides-missing-ui`), so nothing below asserts on the absence
///    of an exception.
/// 2. Its access gate holds SERVER-SIDE. docs/relay-wire-api.md §10: the
///    client is not a security boundary. Each page's wire methods are sent by
///    `support/wire_probe.dart` from a session that verified as `op`
///    (`operate` alone) and from a session that never signed in, and the
///    GATEWAY's refusal is asserted by error code. Hiding the button is
///    asserted too, as the usability affordance it is — never instead.
/// 3. An edit round-trips: made through the widget, read back from the
///    backend's own database or file, then re-read through the page.
///
/// Where a page has no wire behind it — the configuration history, the report
/// editor and the knowledge base read `databaseProvider`, which is null on a
/// gateway panel, and the IP settings page reads NetworkManager over D-Bus —
/// its file says so and proves what is left: that the page tells the operator
/// the truth about what it cannot show, and that the client gate reads the
/// session the GATEWAY resolved.
///
/// ## Known-red cases
///
/// Cases marked `KNOWN RED` in their descriptions assert the CORRECT behaviour
/// for a defect that was found and not yet fixed. They are meant to fail
/// today and to turn green when the fix lands; nothing here works around
/// them. The list is in the final report and repeated at each case.
///
/// ## Running it
///
/// ## UNFINISHED — five cases fail and nobody has diagnosed them
///
/// This lane is committed mid-flight. The agent writing it reached the last
/// two page suites and stopped before it could run the lane once end to end,
/// so five cases have never passed and have not been triaged:
///
///  * server config — an edit in the widget landing in the backend's stateman
///    file on disk and being audited
///  * audit trail — rendering rows from the backend's `audit_entry`
///  * page editor — opening with its canvas and save control
///  * page editor — `configItems.items(page)` served to an engineer and
///    refused to a session holding nothing
///  * knowledge base — opening for an engineer
///
/// **They are not marked `knownRed`, deliberately.** `knownRed` asserts "this
/// is a defect in the product", and nobody has established that. Each is
/// equally likely to be an unfinished fixture — the suites they sit in were
/// the last written. Marking them would be claiming a finding that has not
/// been made.
///
/// So the lane is gated and has **no CI job**: a lane whose failures nobody
/// has read is not evidence, and wiring it into CI would either go red for
/// reasons no one can explain or be quietly given a tolerance that hides the
/// rest. Add the job in the change that makes these five green or converts
/// them, with a reason, into `knownRed`.
///
/// Everything else in here has run: 28 cases pass and 15 are `knownRed`
/// against defects listed in their own descriptions.
///
/// Gated on `CENTROIDX_E2E_PAGES=1`, because `flutter test test/` in the
/// `flutter-test` job runs everything under `test/` on three operating
/// systems and this lane needs Docker, binds sockets, spawns an isolate with
/// an FFI OPC UA client and takes minutes. Without the switch every case is
/// reported as skipped, with this reason, so a green run is never mistaken
/// for a run that happened. With it:
///
///     CENTROIDX_E2E_PAGES=1 flutter test test/e2e_pages --concurrency=1
///
/// `--concurrency=1` is not decoration: the bench binds one Postgres, one
/// OPC UA port and one relay port per file, and the sibling lane under
/// `test/e2e_assets` binds its own. Two files loading at once race for ports
/// and for the machine's idea of a millisecond. The lane is one file for
/// the same reason — one backend for all eleven pages, the way one backend
/// serves a plant's panels — with the pages split into `pages/*.dart` so a
/// page whose case turns out to need more than a test can be separated.
///
/// The `TIMESCALEDB_EXTERNAL=1` / `CENTROIDX_TEST_PG*` variables select a
/// natively provisioned Postgres instead of the Compose stack, exactly as the
/// `tfc-dart-test` job's macOS and Windows legs do.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'pages/access_admin.dart';
import 'pages/alarm_editor.dart';
import 'pages/audit_trail.dart';
import 'pages/config_history.dart';
import 'pages/ip_settings.dart';
import 'pages/key_repository.dart';
import 'pages/knowledge_base.dart';
import 'pages/page_editor.dart';
import 'pages/preferences.dart';
import 'pages/report_editor.dart';
import 'pages/server_config.dart';
import 'pages/wire_invariants.dart';
import 'support/backend_bench.dart';

const String kEnableVariable = 'CENTROIDX_E2E_PAGES';

void main() {
  final enabled = Platform.environment[kEnableVariable] == '1';
  final skip = enabled
      ? null
      : 'set $kEnableVariable=1 — this lane needs Docker (or '
          'TIMESCALEDB_EXTERNAL=1), binds sockets and spawns an OPC UA '
          'acquisition isolate; it runs in its own CI job';

  // Registered before any `setUpAll`, so the binding exists when the
  // first one runs. `testWidgets` initialises it at registration.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('over the real relay,', () {
    late BackendBench bench;
    BackendBench current() => bench;

    // Inside the skipped group, so a run without the switch never stands a
    // backend up for cases it is not going to run.
    setUpAll(() async {
      // The widget binding's HTTP mock answers 400 to every request, and
      // `WebSocket.connect` — the panel's dial and the probe's — goes
      // through `HttpClient`. Real sockets need the real client.
      HttpOverrides.global = null;
      bench = await BackendBench.standUp();
    });

    tearDownAll(() async {
      await bench.tearDown();
    });

    serverConfigCases(current);
    accessAdminCases(current);
    auditTrailCases(current);
    preferencesCases(current);
    alarmEditorCases(current);
    keyRepositoryCases(current);
    pageEditorCases(current);
    configHistoryCases(current);
    reportEditorCases(current);
    ipSettingsCases(current);
    knowledgeBaseCases(current);
    wireInvariantCases(current);
  }, skip: skip);
}
