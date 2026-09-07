/// The app-bar chip: present in gateway mode, absent in direct mode, tappable,
/// and free when it is absent.
///
/// Surface (b) of the two the phase's CONTEXT names. Surface (a) — the row in
/// the Transport card — is `test/widgets/gateway_link_status_row_test.dart`.
/// Both read one `GatewayLinkReport`; neither composes a message of its own,
/// and neither imports the other's widget.
///
/// **There is no golden here, and there must not be one.** The chip's images
/// are plan 15-07's, which owns the themed pairs. This file is the *behaviour*,
/// and behaviour has to be able to fail on Linux too — so it carries neither
/// the golden tag annotation nor a macOS-only skip, and a grep for either
/// spelling in this file must come back empty. The two are different jobs: a
/// pixel arm tells you the chip moved, a behaviour arm tells you the chip lied.
///
/// The report is injected as a constant through `gatewayLinkProvider
/// .overrideWith`. No sockets, no supervisor, no clock: plan 15-04 already
/// measures the provider against three real listeners, and repeating that here
/// would buy a slower suite and no new fact.
library;

import 'dart:async';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/theme.dart' show HmiStateColors, solarized;
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc/widgets/gateway_link_chip.dart';

import '../helpers/test_helpers.dart' show pumpAndLoad, settle;
import 'alarm_fixture.dart';

/// Sentinels rather than the mapper's real prose: this file must fail when the
/// chip stops rendering *the report it was handed*, not when plan 15-01 rewords
/// a sentence. `gateway_link_status_test.dart` owns the wording.
const _headline = 'SENTINEL-HEADLINE the gateway at wss://gw.example:9444';
const _detail = 'SENTINEL-DETAIL walk to the cabinet, not to the switch.';
const _sanHint = 'SENTINEL-SANHINT the certificate must name gw.example.';

final _url = Uri.parse('wss://gw.example:9444');

GatewayLinkReport _report(GatewayLinkKind kind, {bool terminal = false}) =>
    GatewayLinkReport(
      kind: kind,
      headline: _headline,
      detail: _detail,
      url: _url,
      terminal: terminal,
      sanHint: _sanHint,
    );

void _registerMenu() {
  final registry = RouteRegistry();
  registry.menuItems.clear();
  registry
      .addMenuItem(const MenuItem(label: 'Home', path: '/', icon: Icons.home));
}

/// The scaffold behind a router, at the window size a plant station runs.
///
/// The shape is `base_scaffold_appbar_golden_test.dart:56-85`'s `_shell`, minus
/// the `RepaintBoundary` it only needs for a golden. [link] is what
/// `gatewayLinkProvider` publishes: a report for a gateway station, `null` for a
/// direct one, and nothing at all while the device-local row is still being
/// read.
Widget _shell({
  required Stream<GatewayLinkReport?> link,
  AlarmFixture? alarms,
}) {
  final (light, _) = solarized();
  final delegate = BeamerDelegate(
    locationBuilder: RoutesLocationBuilder(routes: {
      '/': (context, state, data) => const BeamPage(
            key: ValueKey('/'),
            title: 'Home',
            child: BaseScaffold(title: 'Home', body: Text('home-body')),
          ),
    }).call,
  );

  return ProviderScope(
    overrides: [
      alarmManProvider.overrideWith((ref) async => alarms ?? AlarmFixture()),
      gatewayLinkProvider.overrideWith((ref) => link),
    ],
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        theme: light,
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required Stream<GatewayLinkReport?> link,
}) async {
  tester.view.physicalSize = const Size(1600, 160);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // Never the pump-until-quiet helper: a chip that regressed into rendering an
  // indeterminate indicator would hang it forever, and a hang names nothing.
  // `settle` pumps a fixed number of frames and lets the assertion talk. The
  // offending spelling appears nowhere in this file so that a grep for it
  // stays a useful question.
  await pumpAndLoad(tester, _shell(link: link));
}

/// A gateway station publishing [kind].
Stream<GatewayLinkReport?> _gateway(GatewayLinkKind kind,
        {bool terminal = false}) =>
    Stream<GatewayLinkReport?>.value(_report(kind, terminal: terminal));

/// A direct station: the provider resolves, to nothing.
Stream<GatewayLinkReport?> _direct() => Stream<GatewayLinkReport?>.value(null);

/// The device-local row has not been read yet, so the provider has not resolved
/// at all. Deliberately never closed — a closed empty stream resolves to a
/// value, which is a different state.
Stream<GatewayLinkReport?> _unresolved(WidgetTester _) {
  final controller = StreamController<GatewayLinkReport?>();
  addTearDown(controller.close);
  return controller.stream;
}

/// The `right:` the app bar's centre region was actually laid out with.
///
/// Read off the rendered `Positioned`, never re-derived: an arm that computed
/// `280 + kGatewayChipWidth` itself would agree with the widget about whatever
/// the widget did, including forgetting the term entirely.
double _centreRightMargin(WidgetTester tester) {
  final fills = tester
      .widgetList<Positioned>(find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(Positioned),
      ))
      .where((p) =>
          p.left != null &&
          p.right != null &&
          p.top != null &&
          p.bottom != null)
      .toList();
  expect(fills, hasLength(1),
      reason: 'the app bar has exactly one Positioned.fill — the centre region '
          'holding the navigation-alarm banner. If this count moved, the '
          'margin arm below is measuring the wrong box.');
  return fills.single.right!;
}

/// The RIGHT cluster's `Row`, the one the chip joins immediately left of the
/// Centroid logo.
Finder _rightCluster() =>
    find.ancestor(of: find.byType(SvgPicture), matching: find.byType(Row)).first;

void main() {
  setUp(_registerMenu);
  tearDown(() => RouteRegistry().menuItems.clear());

  testWidgets(
      'gateway mode: the chip is in the app bar and names the link state',
      (tester) async {
    await _pump(tester, link: _gateway(GatewayLinkKind.connected));

    expect(find.byKey(kGatewayLinkChipKey), findsOneWidget,
        reason: 'a panel booted into gateway mode says so on every page — the '
            'whole point of surface (b) is the operator who never walks to '
            'Server Config');
    expect(
      find.descendant(
        of: find.byKey(kGatewayLinkChipKey),
        matching: find.byType(Text),
      ),
      findsOneWidget,
      reason: 'one pill, one label',
    );
    final label = tester
        .widget<Text>(find.descendant(
          of: find.byKey(kGatewayLinkChipKey),
          matching: find.byType(Text),
        ))
        .data;
    expect(label, isNotNull);
    expect(label, isNotEmpty,
        reason: 'the label names the state; an empty pill is a smudge on the '
            'bar that tells an operator nothing');
  });

  testWidgets(
      'direct mode: no chip in the tree, and the slot it would fill is Size.zero',
      (tester) async {
    await _pump(tester, link: _direct());

    // The contract this widget honours, stated because "absent" and
    // "zero-width" are different promises and the margin arithmetic below
    // depends on which one is true: `GatewayLinkChip` is ALWAYS in the tree —
    // `base_scaffold.dart` places it unconditionally — and in direct mode it
    // renders `SizedBox.shrink()`, so it occupies exactly zero. What is absent
    // is the *pill*, keyed `kGatewayLinkChipKey`. Both halves are asserted, so
    // a future change from one contract to the other cannot pass silently.
    expect(find.byKey(kGatewayLinkChipKey), findsNothing,
        reason: 'a direct station\'s app bar carries no pill at all');
    expect(find.byType(GatewayLinkChip), findsOneWidget,
        reason: 'the widget itself is unconditional in base_scaffold.dart; it '
            'is its OUTPUT that is conditional');
    expect(tester.getSize(find.byType(GatewayLinkChip)), Size.zero,
        reason: 'zero width when absent — access_lock_badge.dart:96-106\'s '
            'rule, and what keeps every existing app-bar golden '
            'byte-identical');
  });

  testWidgets('direct mode: while the provider is still resolving, nothing — '
      'and never a spinner', (tester) async {
    await _pump(tester, link: _unresolved(tester));

    expect(find.byKey(kGatewayLinkChipKey), findsNothing);
    expect(tester.getSize(find.byType(GatewayLinkChip)), Size.zero);
    // access_status_action.dart:44-66: the app bar rebuilds on every
    // navigation, so a spinner there flickers on every one of them. Criterion 2
    // of this milestone is that the UI stops pretending; an indeterminate
    // indicator in the furniture is pretending once a frame.
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'render nothing rather than a spinner');
  });

  testWidgets('refused: the chip takes the fault colour and reads differently '
      'from a connected one', (tester) async {
    await _pump(tester, link: _gateway(GatewayLinkKind.connected));
    final connectedLabel = tester
        .widget<Text>(find.descendant(
          of: find.byKey(kGatewayLinkChipKey),
          matching: find.byType(Text),
        ))
        .data;

    await _pump(tester,
        link: _gateway(GatewayLinkKind.credentialRefused, terminal: true));

    // Found by Key, never by searching for a colour: an arm that hunted the
    // tree for a red box would pass on a widget that painted red somewhere
    // meaningless.
    final mark = tester.widget<Container>(find.byKey(kGatewayLinkChipMarkKey));
    final decoration = mark.decoration;
    expect(decoration, isA<BoxDecoration>());
    final border = (decoration! as BoxDecoration).border;
    expect(border, isA<Border>());

    final context = tester.element(find.byKey(kGatewayLinkChipMarkKey));
    final fault = HmiStateColors.of(context).red;
    expect((border! as Border).top.color.value, fault.withAlpha(120).value,
        reason: 'the retry loop has stopped, and only a fault may be saturated '
            'in this repo — the same red plan 15-05\'s row spends on the two '
            'terminal kinds, so the two surfaces cannot disagree');

    final refusedLabel = tester
        .widget<Text>(find.descendant(
          of: find.byKey(kGatewayLinkChipKey),
          matching: find.byType(Text),
        ))
        .data;
    expect(refusedLabel, isNot(connectedLabel),
        reason: 'a terminal state must not read like a healthy one from across '
            'the hall; colour alone is not a message');
  });

  testWidgets('dialog: tapping the chip shows the report in a dialog, not in a '
      'tooltip', (tester) async {
    await _pump(tester, link: _gateway(GatewayLinkKind.untrustedCertificate));

    // A tooltip on a touch panel is unreachable — there is no hover. CONTEXT
    // § "Claude's Discretion" prefers a dialog for exactly that reason, and
    // this arm is the only automated check that can tell the two apart.
    expect(
      find.descendant(
        of: find.byType(GatewayLinkChip),
        matching: find.byType(Tooltip),
      ),
      findsNothing,
      reason: 'nothing in this chip may hide its message behind a hover',
    );

    expect(find.text(_headline), findsNothing,
        reason: 'the pill is one short label; the report is behind the tap');

    await tester.tap(find.byKey(kGatewayLinkChipKey));
    await settle(tester);

    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'the same report, in a dialog an operator can actually open');
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(_headline),
      ),
      findsOneWidget,
      reason: 'verbatim: the chip adds chrome and not one word',
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(_detail),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(_sanHint),
      ),
      findsOneWidget,
      reason: 'rig FIND-B: the SAN sentence is the one that stops an operator '
          'walking to the wrong end of the wire',
    );
  });

  testWidgets('margin: the centre region reserves the chip\'s width, and only '
      'when the chip is there', (tester) async {
    await _pump(tester, link: _direct());
    final withoutChip = _centreRightMargin(tester);

    await _pump(tester, link: _gateway(GatewayLinkKind.connected));
    final withChip = _centreRightMargin(tester);

    expect(withoutChip, 280.0,
        reason: 'a direct station\'s app bar is byte-identical to what it is '
            'today: ~210 px of logo, 16 of padding, 48 of theme toggle and a '
            'buffer');
    expect(withChip, 280.0 + kGatewayChipWidth,
        reason: 'the chip\'s width is counted into the right margin so the '
            'navigation-alarm banner keeps its clear space. Read off the '
            'rendered Positioned, not re-derived — see _centreRightMargin');
  });

  testWidgets('in direct mode the right cluster is the logo and the theme '
      'toggle and nothing else', (tester) async {
    await _pump(tester, link: _direct());

    final clusterWidth = tester.getSize(_rightCluster()).width;
    final logoWidth = tester
        .getSize(find
            .ancestor(
                of: find.byType(SvgPicture), matching: find.byType(Padding))
            .first)
        .width;
    final toggleWidth = tester
        .getSize(find.widgetWithIcon(IconButton, Icons.brightness_6))
        .width;

    // The gap belongs INSIDE GatewayLinkChip, never beside it in the caller —
    // access_lock_badge.dart:96-106. A `SizedBox` sibling would survive the
    // chip disappearing and every direct-mode app bar in the plant would
    // silently gain those pixels, moving four existing goldens with it.
    expect(clusterWidth, closeTo(logoWidth + toggleWidth, 0.01),
        reason: 'an absent chip contributes exactly zero width — no pill, no '
            'gap, no padding, nothing');
  });
}
