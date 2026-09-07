/// The app bar's gateway-link affordance: one pill, gateway mode only, and the
/// whole report behind a tap.
///
/// Surface (b) of the two this phase builds. A panel booted into gateway mode
/// with a bad address otherwise shows grey values and `--- °C` on the home page
/// with nothing anywhere saying why, and an operator standing there has no
/// reason to walk to Server Config. That is the rig's own observation, with the
/// difference that on the rig somebody knew why.
///
/// **A full-width banner was considered and rejected.** The app bar already
/// carries the navigation-alarm banner, and a second banner competing for the
/// same row is how the real alarm stops being read. This is a pill, it is
/// absent on every direct station, and it costs those stations nothing.
///
/// ## Colour
///
/// Every colour here comes from `HmiStateColors.of(context)`, which is themed,
/// and a grep for a raw Material colour constant in this file must come back
/// empty — comments included, which is why the offending spelling appears
/// nowhere below. `lib/widgets/connection_status_chip.dart` supplied the pill's
/// **geometry** and none of its colours: that file is entirely raw palette
/// constants, a known violation that predates the convention, and it is
/// deliberately not in scope to fix.
///
/// The scheme's edge role is not read here either, on purpose: neither
/// Solarized scheme sets one, so a border borrowed from it is invisible on the
/// dark theme the night shift runs (project memory
/// `solarized-outline-is-invisible`). The pill's edge is its own state colour
/// at alpha instead, which is the same answer and is legible in both schemes.
///
/// The four-colours-over-six-kinds grouping is **the same one the status row in
/// `lib/widgets/gateway_link_status_row.dart` spends**, deliberately, so the
/// chip and the card cannot disagree about what yellow means. That row is *not*
/// imported and its class name appears nowhere in this file, so a grep for it
/// stays a useful question: the two surfaces share the *report*, not a widget,
/// and a shared widget would put the two plans that built them in the same wave
/// with a file dependency between them.
///
/// ## Why a dialog and not a tooltip
///
/// The message is two sentences, and a tooltip on a touch panel is
/// unreachable — there is no hover on a 15-inch resistive screen bolted to a
/// wall. Tapping the pill opens an `AlertDialog` rendering the report's
/// `headline`, `detail` and, when there is one, its `sanHint`. It does **not**
/// render `GatewayLinkReport.raw`: that is the one field carrying text this app
/// did not write, and the card in Server Config is where a support engineer
/// stands when they want it.
///
/// ## No spinner, ever
///
/// While the device-local transport row is still being read the chip renders
/// nothing at all rather than an indeterminate indicator. The app bar rebuilds
/// on every navigation and a spinner in the furniture would flicker on each
/// one — `access_status_action.dart:44-66` states the same rule for the same
/// bar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/gateway_link_status.dart';
import '../providers/gateway_link.dart';
import '../theme.dart';

/// The width budget for the chip, **gap included**.
///
/// `base_scaffold.dart` adds this term to `appBarRightMargin` whenever the chip
/// is shown, exactly the way `kAccessStatusActionGap` is already counted into
/// the left margin. A chip wider than its budget would push the clock and the
/// navigation-alarm banner off-centre, so a long label ellipsises inside this
/// rather than growing it. Overturning the number means changing one constant;
/// overturning the *arithmetic* means an alarm nobody can read.
const double kGatewayChipWidth = 160;

/// The gap between the chip and the Centroid logo to its right.
///
/// Kept **inside** this widget so an absent chip contributes exactly zero
/// width. A `SizedBox` beside it in `base_scaffold.dart` would survive the chip
/// disappearing and every direct-mode app bar in the plant would silently gain
/// these pixels, moving four existing goldens with it — the defect
/// `access_lock_badge.dart:96-106` documents.
const double kGatewayChipGap = 8;

/// The pill. Absent — not merely empty — on a direct station.
const Key kGatewayLinkChipKey = Key('gateway_link_chip');

/// The coloured container, keyed the way `gateway_link_status_row.dart` keys
/// its mark: a test that looked the colour up by searching the tree for a
/// colour would pass on a widget that painted it somewhere meaningless.
const Key kGatewayLinkChipMarkKey = Key('gateway_link_chip_mark');

/// The dialog the tap opens.
const Key kGatewayLinkChipDialogKey = Key('gateway_link_chip_dialog');

/// What the gateway link is doing, in the app bar — or nothing.
class GatewayLinkChip extends ConsumerWidget {
  const GatewayLinkChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Null is direct mode and must render as *absence*, not as an empty pill;
    // an unresolved value is the device-local row still being read, and says
    // nothing yet rather than guessing. Both collapse to the same answer here,
    // and the answer is zero width.
    final report = ref.watch(gatewayLinkProvider).valueOrNull;
    if (report == null) return const SizedBox.shrink();

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kGatewayChipWidth),
      child: Padding(
        // The gap, inside. See kGatewayChipGap.
        padding: const EdgeInsets.only(right: kGatewayChipGap),
        child: _Pill(report: report),
      ),
    );
  }
}

/// The pill itself, and the tap that opens the report.
class _Pill extends StatelessWidget {
  const _Pill({required this.report});

  final GatewayLinkReport report;

  /// The state colour for [GatewayLinkReport.kind].
  ///
  /// Total over the enum with no `default`, so a seventh kind is a compile
  /// error here rather than a pill drawn in whatever colour the last branch
  /// happened to leave behind. The grouping is `gateway_link_status_row.dart`'s,
  /// to the member.
  Color _colour(BuildContext context) {
    final state = HmiStateColors.of(context);
    return switch (report.kind) {
      GatewayLinkKind.connected => state.green,
      GatewayLinkKind.connecting => state.blue,
      GatewayLinkKind.unreachable => state.yellow,
      GatewayLinkKind.untrustedCertificate => state.yellow,
      GatewayLinkKind.credentialRefused => state.red,
      GatewayLinkKind.versionRefused => state.red,
    };
  }

  /// Two or three words, at 11 px, read from a metre away.
  ///
  /// Short on purpose: the pill is a *pointer* to the report, not the report.
  /// The two terminal kinds are worded so that they cannot be mistaken for the
  /// four that are still retrying — "refused" is a decision somebody has to
  /// act on, "no gateway" is a condition that may clear on its own.
  String _label() => switch (report.kind) {
        GatewayLinkKind.connected => 'Gateway live',
        GatewayLinkKind.connecting => 'Gateway dialling',
        GatewayLinkKind.unreachable => 'No gateway',
        GatewayLinkKind.untrustedCertificate => 'Cert refused',
        GatewayLinkKind.credentialRefused => 'Token refused',
        GatewayLinkKind.versionRefused => 'Version refused',
      };

  @override
  Widget build(BuildContext context) {
    final colour = _colour(context);

    return InkWell(
      key: kGatewayLinkChipKey,
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showReport(context, report),
      child: Container(
        key: kGatewayLinkChipMarkKey,
        // Geometry from connection_status_chip.dart:114-126, and nothing else
        // from it.
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: colour.withAlpha(30),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colour.withAlpha(120)),
        ),
        child: Text(
          _label(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: colour,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// The report, in a dialog.
///
/// `headline`, `detail` and `sanHint` verbatim: this file adds chrome and not
/// one word, so the chip and the Transport card say exactly the same thing.
/// `raw` is deliberately absent — see the library doc.
void _showReport(BuildContext context, GatewayLinkReport report) {
  showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        key: kGatewayLinkChipDialogKey,
        title: Text(report.headline),
        // Scrollable, because the shortest panel this ships to is 800 px tall
        // in landscape and a certificate refusal dialled by name carries three
        // paragraphs. An overflowing dialog hides the sentence that names the
        // end of the wire to walk to, which is the only reason the dialog
        // exists.
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(report.detail, style: theme.textTheme.bodyMedium),
              if (report.terminal) ...[
                const SizedBox(height: 8),
                Text(
                  'The panel has stopped retrying. This will not clear on its '
                  'own.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: HmiStateColors.of(context).red,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (report.sanHint != null) ...[
                const SizedBox(height: 8),
                Text(report.sanHint!, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
