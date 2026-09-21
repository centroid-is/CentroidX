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
/// ## The five that were untriaged, and what each turned out to be
///
/// This lane was committed mid-flight with five cases that had never passed
/// and had not been diagnosed. They were deliberately not marked `knownRed`,
/// because `knownRed` asserts "this is a defect in the product" and nobody
/// had established that. All five were run down on 2026-09-20. **One was a
/// product defect, three were fixture faults, and one was never a failure at
/// all.** All five are green; the lane has a CI job because of it.
///
///  * **server config — an edit landing in the backend's stateman file.**
///    Never a defect. It fails only under the WRONG Flutter SDK: homebrew's
///    3.41.9 instead of the pinned 3.44.9, where `build/unit_test_assets`
///    holds an `ink_sparkle.frag` the older engine reports as *"Unsupported
///    runtime stages format version. Expected 1, got 2"* — so every case that
///    taps a Material surface dies, and this is the first case in the lane
///    that taps one. Check `flutter --version` before reading a failure here.
///
///  * **audit trail — rendering a row written a moment ago.** A fixture
///    fault, and a subtle one. Inside `testWidgets` the ambient `clock.now()`
///    is FROZEN at the instant the case body starts, while the backend stamps
///    `audit_entry.at` from real time; `AuditTrailPage` bounds its seven-day
///    window at `clock.now()`, so the row the case writes lands after the
///    window closes and the page correctly renders "0 entries". Measured, not
///    guessed: the panel's own store answered 0 rows for the page's query and
///    5 for the same query without the window. Fixed with `withClock`, and
///    the case carries the reasoning. **The relay-mode half of it is real** —
///    see the note there.
///
///  * **page editor — opening with its canvas and save control.** A PRODUCT
///    defect, fixed in `lib/pages/page_editor.dart`: `initState` did
///    `ref.read(pageManagerProvider.future).then((m) => setState(...))` with
///    no `mounted` check, so an editor disposed before its pages load — the
///    access gate swapping the subtree, or an operator leaving the route —
///    asserts in debug and dereferences a null element in release.
///
///  * **page editor — `configItems.items(page)` served and refused.** A
///    fixture fault: the row it asserts on was seeded inside a `knownRed`
///    case, which runs only under `CENTROIDX_E2E_PAGES_KNOWN_RED=1`. A green
///    case depending on a skipped one's side effect, failing against an empty
///    list in a way that reads exactly like the gateway refusing to serve
///    pages. The seed now belongs to the group's `setUpAll`.
///
///  * **knowledge base — opening for an engineer.** A fixture fault: it
///    anchored on `find.text('Knowledge Base')`, which is the ExpansionTile
///    title `TechDocLibrarySection` renders only when `embedded: true`, and
///    this page mounts it with `embedded: false`. Nor does the app bar carry
///    it — **`BaseScaffold.title` is a required parameter that is never
///    rendered anywhere**, which is worth knowing before anchoring any case
///    in this lane on a page title.
///
/// ## Two `knownRed` cases were green
///
/// The `knownRed` set had never been run either — `knownRed` only runs under
/// `CENTROIDX_E2E_PAGES_KNOWN_RED=1`. Running it on 2026-09-20 found **two of
/// the fifteen already correct**, and both are now ordinary cases in
/// `wire_invariants.dart`:
///
///  * the history-view read floor, which this branch fixed while the case sat
///    gated and nobody noticed it had gone green;
///  * `browse.fetchDetail` against a forged node kind — fixed too, but the
///    case demanded the **wrong remedy**: it expected the hidden node to be
///    refused, where the fix answers it the way a node that does not exist is
///    answered. A refusal confirms the node is there, which is the one thing
///    hiding must not do. Rewritten against the shipped design, with a
///    visible key beside it as the control.
///
/// A `knownRed` that has quietly gone green is a case protecting nothing, so
/// the CI job runs the gated set too — see `e2e-pages-test`.
///
/// Everything else in here has run: 42 cases pass and 9 are `knownRed`
/// against defects listed in their own descriptions. It was 38 and 13 until
/// the gateway learned to write a `config_item` row — the report editor's two
/// cases, the preferences JSON editor and the alarm editor were one gap, and
/// they went green together.
///
/// ## Running it
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
