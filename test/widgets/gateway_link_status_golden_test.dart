/// The six link states, drawn, in both station themes.
///
/// `GatewayLinkStatusRow` is what an operator who has just typed the gateway
/// address reads, and what it *says* is already pinned by
/// `test/widgets/gateway_link_status_row_test.dart` and
/// `test/core/gateway_copy_test.dart`. What no widget test can answer is
/// whether the six read as six — whether yellow-still-retrying is visibly not
/// red-stopped, whether the terminal notice reads as a full stop, whether any
/// of it is legible on the dark theme the night shift runs. These images are
/// where that gets checked, which is why every frame is shot twice.
///
/// **Both brightnesses, and the dark one is not decoration.** Neither Solarized
/// scheme sets `colorScheme.outline`, so a widget that borrowed it would draw a
/// border that is perfectly fine in the light image and invisible on base03
/// (project memory `solarized-outline-is-invisible`). This row deliberately
/// uses `onSurface` at alpha instead — the dark frames are the only thing that
/// can prove it stayed that way.
///
/// **The frames are built by the real mapper, not hand-written.** Each one
/// hands `describeGatewayLink` the inputs that actually produce it, so the
/// prose in the image is the prose the plant gets and a change to the mapper
/// moves the picture. The mapper is pure — no `DateTime.now()`, elapsed
/// arrives as a `Duration` the caller measured — so six frames are six
/// constants and nothing here churns between runs.
///
/// To update: derive the failing set first (never a blanket `--update-goldens`
/// over the directory — 128 PNGs live there and 126 belong to other features),
/// then
/// `flutter test test/widgets/gateway_link_status_golden_test.dart --update-goldens`.
@Tags(['golden'])
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/widgets/gateway_link_status_row.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart' show LinkState;

import '../helpers/themed_golden_host.dart';

/// Wide enough that the detail wraps the way it wraps on a station, tall enough
/// that the certificate frame — headline, four lines of detail, the SAN hint
/// and the raw toggle — is laid out and painted whole. Anything clipped
/// captures as a cut-off sentence, which is exactly the defect these images
/// exist to catch.
const Size _surface = Size(620, 440);

/// The address the rig actually runs, so the frames read like the plant.
final Uri _byAddress = Uri.parse('wss://10.50.10.11:9443');

/// The same gateway dialled by name — the only way to get a SAN hint.
final Uri _byName = Uri.parse('wss://plc-gw.svn:9443');

/// One frame: a name, the report, and whether `connecting` is a legitimate
/// answer for it.
///
/// [spinnerWouldBeALie] is the whole of criterion 2 written down per frame. On
/// every kind but `connecting` the panel has reached a conclusion, and an
/// indeterminate indicator is the shape of a promise that something is about to
/// happen — a promise this surface must not make. The assertion runs in the
/// same pump that records the image.
class _Frame {
  const _Frame(this.name, this.report, {this.spinnerWouldBeALie = true});

  final String name;
  final GatewayLinkReport report;
  final bool spinnerWouldBeALie;
}

List<_Frame> _frames() => <_Frame>[
      _Frame(
        'connected',
        describeGatewayLink(
          state: LinkState.ready,
          url: _byAddress,
          elapsed: const Duration(seconds: 4),
        ),
      ),
      _Frame(
        'connecting',
        describeGatewayLink(
          // No reason of any kind, and genuinely young: the one arm of the
          // mapper that is allowed to say "connecting".
          state: LinkState.connecting,
          url: _byAddress,
          elapsed: const Duration(seconds: 3),
        ),
        spinnerWouldBeALie: false,
      ),
      _Frame(
        'unreachable',
        describeGatewayLink(
          state: LinkState.down,
          url: _byAddress,
          // Deliberately INSIDE the patience window while carrying a reason.
          // A reason that already exists is proof the panel has been here
          // before, so it wins over the clock (`gateway_link_status.dart`
          // step 3 before step 4). Staged this way the frame is also the
          // rendered half of the F-6 short-circuit: delete it and this image
          // becomes a blue "Connecting to …".
          elapsed: const Duration(seconds: 2),
          lastDownReason: '${GatewayLinkReasons.didNotAnswer}: '
              'SocketException: Connection refused (OS Error: Connection '
              'refused, errno = 61), address = 10.50.10.11, port = 9443',
        ),
      ),
      _Frame(
        'untrusted_ip',
        describeGatewayLink(
          state: LinkState.down,
          url: _byAddress,
          elapsed: const Duration(seconds: 6),
          lastDownReason: GatewayLinkReasons.certificateNotTrusted,
        ),
      ),
      _Frame(
        'untrusted_host',
        describeGatewayLink(
          state: LinkState.down,
          url: _byName,
          elapsed: const Duration(seconds: 6),
          lastDownReason: GatewayLinkReasons.certificateNotTrusted,
        ),
      ),
      _Frame(
        'credential',
        describeGatewayLink(
          state: LinkState.down,
          url: _byAddress,
          elapsed: const Duration(seconds: 9),
          // `stopReason`, not `lastDownReason` — the retry loop has stopped,
          // which is what makes this frame terminal and what it has to read
          // differently from the four above.
          stopReason: GatewayLinkReasons.credentialRefused,
        ),
      ),
    ];

void main() {
  setUpAll(loadThemedGoldenFonts);

  group('gateway link status goldens',
      // Belt and braces: `dart_test.yaml` already skips the `golden` tag on
      // linux and windows via `on_os`, and this says so again at the group so
      // a file read on its own is not misleading.
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    Future<void> shoot(
      WidgetTester tester,
      _Frame frame, {
      required bool dark,
    }) async {
      await tester.binding.setSurfaceSize(_surface);
      // 1:1 pixels — these images are for reading in a PR, not for pixel
      // archaeology.
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(themedGoldenHost(
        SizedBox(
          width: 560,
          // `IntrinsicHeight`, and it is load-bearing rather than tidiness.
          // The row's inner `Column` is `MainAxisSize.max`, so it fills any
          // *bounded* height it is handed. On the real card it sits in an
          // `ExpansionTile`'s children, where the height is unbounded and it
          // therefore hugs its content. Framed in a plain `Center` it stretched
          // to the full 440 px surface and every frame recorded a mostly-empty
          // box — a picture of the harness rather than of the plant, and one
          // that hides how much vertical space each state actually costs.
          child: IntrinsicHeight(
            child: GatewayLinkStatusRow(report: frame.report),
          ),
        ),
        dark: dark,
      ));
      // Explicit pumps, via the same loop `test_helpers.dart`'s `settle` uses.
      // The settle-until-quiet helper is deliberately not spelled anywhere in
      // this file: it does not return while an indeterminate animation is in
      // the tree, and the whole point of the `unreachable` frame is that it
      // must not be able to hang here.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Anti-vacuity, and it is not ceremony: `findsNothing` below is
      // satisfied by an empty screen, so a harness that rendered nothing at
      // all would pass the property and then record a blank image. Assert the
      // row is actually there first, in the same pump.
      expect(find.byKey(kGatewayLinkStatusRowKey), findsOneWidget,
          reason: 'the no-spinner property below is only meaningful if the '
              'row was rendered at all');

      if (frame.spinnerWouldBeALie) {
        expect(
          find.byType(CircularProgressIndicator),
          findsNothing,
          reason: 'kind ${frame.report.kind.name} is a conclusion, not an '
              'attempt: past the patience window the UI must stop pretending '
              'something is about to happen. A golden proves what a frame '
              'looks like; it does not prove a widget is absent, so both live '
              'in this one pump.',
        );
      }

      final suffix = dark ? '_dark' : '';
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/gateway_link_${frame.name}$suffix.png'),
      );
    }

    for (final frame in _frames()) {
      // Both brightnesses for every frame. See the library doc: a light-only
      // golden cannot see an edge that vanished on base03.
      for (final dark in [false, true]) {
        testWidgets('${frame.name}${dark ? ', dark' : ', light'}',
            (tester) async {
          await shoot(tester, frame, dark: dark);
        });
      }
    }
  });
}
