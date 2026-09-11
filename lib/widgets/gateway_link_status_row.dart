/// The live gateway link, rendered — one report, in the report's own words.
///
/// Two surfaces show this fact: the row inside the Transport card, where an
/// operator who has just typed the address is standing, and the chip in the app
/// bar, where an operator who never opened settings is standing. **Both read one
/// `GatewayLinkReport` and neither composes a message of its own.** This widget
/// therefore watches nothing and computes no prose: it takes a report and draws
/// it, which is also what lets plan 15-07 drive eleven golden frames from
/// eleven constants instead of faking a supervisor eleven times.
///
/// ## Colour
///
/// Every colour here comes from `HmiStateColors.of(context)`, which is themed,
/// and a grep for a raw Material colour constant in this file must come back
/// empty — comments included, which is why the offending spelling does not
/// appear anywhere below. `test/core/gateway_copy_test.dart` runs that grep.
/// The neighbouring `lib/widgets/connection_status_chip.dart` is entirely raw
/// palette constants and is a known violation that predates the convention; it
/// is deliberately **not** in scope to fix, because it is three server-config
/// cards' worth of golden churn for no Phase 15 criterion.
///
/// The scheme's `outline` role is not read here, anywhere, on purpose: neither
/// Solarized scheme sets it, so an edge borrowed from it is invisible on the
/// dark theme the night shift runs (project memory
/// `solarized-outline-is-invisible`). The container edge is `onSurface` with
/// alpha instead. The scan in `test/core/gateway_copy_test.dart` is literal, so
/// the offending spelling appears nowhere in this file, comments included.
///
/// Four colours over six kinds, and the grouping is the design rather than an
/// economy:
///
///  * **green** — a live session.
///  * **blue** — a first attempt still in flight.
///  * **yellow** — no session, and the panel is still retrying. Both the
///    unreachable and the untrusted-certificate kinds live here. A certificate
///    can be replaced under a running panel, so spending fault red on it is how
///    the red that means *stopped* stops being read.
///  * **red** — the retry loop has stopped. Only fault red may be saturated in
///    this repo, and these two are the only conditions on this surface that
///    will not change on the next attempt.
///
/// What separates the two members inside each group is the [
/// GatewayLinkReport.headline] and [GatewayLinkReport.detail] the mapper
/// already wrote, plus — for the two terminal kinds — the stopped-retrying
/// notice below, which the four retrying kinds do not carry.
///
/// ## No spinner, ever, not even for `connecting`
///
/// Criterion 2 of this milestone is that the UI stops pretending. An
/// indeterminate indicator is the shape of a promise that something is about to
/// happen, and on a panel that has been dialling a dead address since the
/// morning shift that promise is a lie told once a frame. The `connecting`
/// frame says what is being dialled, in words, and the provider's patience
/// timer replaces it with what the panel actually knows.
///
/// ## `raw` is not on the card
///
/// [GatewayLinkReport.raw] is the one field carrying text this app did not
/// write — the client's `OS Error` tail, which is the only part of a remote
/// fault a support engineer can act on. It is kept whole and put behind a tap
/// rather than rendered inline: a panel stands where anybody can read it, and
/// an untrusted peer's message dominating an operator's card is the disclosure
/// half of the same threat the mapper already handles by never splicing that
/// text into [GatewayLinkReport.headline] or [GatewayLinkReport.detail].
library;

import 'package:flutter/material.dart';

import '../core/gateway_link_status.dart';
import '../theme.dart';

/// The row itself, so a widget test can assert presence and absence without
/// matching on prose that plan 15-01 owns.
const Key kGatewayLinkStatusRowKey = Key('gateway_link_status_row');

/// The coloured mark. Keyed the way `audit_trail_row.dart` keys its denial bar:
/// a test that looked the colour up by searching for a colour would pass on a
/// widget that painted it somewhere meaningless.
const Key kGatewayLinkStatusMarkKey = Key('gateway_link_status_mark');

/// The sentence that says the panel has stopped retrying. Present on exactly
/// the two terminal kinds.
const Key kGatewayLinkTerminalNoticeKey = Key('gateway_link_terminal_notice');

/// The subject-alternative-name sentence, on a certificate refused for a dial
/// by name and never on one dialled by address.
const Key kGatewayLinkSanHintKey = Key('gateway_link_san_hint');

/// The affordance behind which the client's own text sits.
const Key kGatewayLinkRawKey = Key('gateway_link_raw_toggle');

/// The width of the coloured mark, in logical pixels.
const double kGatewayLinkMarkWidth = 4;

/// The height of the coloured mark. Fixed rather than stretched: a bar sized to
/// its neighbour's text moves in every golden frame whose prose is a different
/// length, and eleven frames that all move is eleven frames nobody re-reads.
const double kGatewayLinkMarkHeight = 36;

/// One [GatewayLinkReport], drawn.
class GatewayLinkStatusRow extends StatelessWidget {
  const GatewayLinkStatusRow({super.key, required this.report});

  /// What to say. Written by `describeGatewayLink`; this widget adds chrome and
  /// not one word.
  final GatewayLinkReport report;

  /// The state colour for [GatewayLinkReport.kind].
  ///
  /// Total over the enum with no `default`, so the seventh kind somebody adds
  /// is a compile error here rather than a frame that renders in whatever
  /// colour the last branch happened to leave behind.
  Color _colour(BuildContext context) {
    final state = HmiStateColors.of(context);
    return switch (report.kind) {
      GatewayLinkKind.connected => state.green,
      GatewayLinkKind.connecting => state.blue,
      GatewayLinkKind.unreachable => state.yellow,
      GatewayLinkKind.untrustedCertificate => state.yellow,
      GatewayLinkKind.credentialRefused => state.red,
      GatewayLinkKind.versionRefused => state.red,
      // Red for the same reason as the two above and a stronger one: there is
      // no retry loop to have stopped, because none was started. Nothing on the
      // wire can clear it.
      GatewayLinkKind.notBuilt => state.red,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = _colour(context);
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
    );

    return Container(
      key: kGatewayLinkStatusRowKey,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          // Not the scheme's edge role: neither Solarized scheme sets one, so
          // a border borrowed from it is invisible on dark. See the library
          // doc.
          color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            key: kGatewayLinkStatusMarkKey,
            width: kGatewayLinkMarkWidth,
            height: kGatewayLinkMarkHeight,
            child: ColoredBox(color: colour),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  report.headline,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colour,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(report.detail, style: secondary),
                if (report.terminal) ...[
                  const SizedBox(height: 6),
                  Text(
                    key: kGatewayLinkTerminalNoticeKey,
                    'The panel has stopped retrying. This will not clear on '
                    'its own.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colour,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (report.sanHint != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    key: kGatewayLinkSanHintKey,
                    report.sanHint!,
                    style: secondary,
                  ),
                ],
                if (report.raw != null) ...[
                  const SizedBox(height: 6),
                  _RawDetails(
                    raw: report.raw!,
                    // Whose message it actually is. On every other kind the
                    // text came off the wire; on `notBuilt` nothing was
                    // dialled, so it is this station's own exception and a
                    // toggle offering "the gateway's own message" would be a
                    // false statement on the one frame whose whole point is
                    // that the fault is local. The four words are chosen so
                    // the existing label is character-for-character unchanged
                    // for the six kinds that had one.
                    whose: report.kind == GatewayLinkKind.notBuilt
                        ? 'this panel'
                        : 'the gateway',
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The client's own reason text, behind one tap.
///
/// Selectable when open, because the whole reason it is carried whole is that
/// somebody pastes the `OS Error` line into a ticket. Collapsed by default,
/// because an operator reading a panel across a room needs the two sentences
/// above it and not this.
class _RawDetails extends StatefulWidget {
  const _RawDetails({required this.raw, required this.whose});

  final String raw;

  /// Who wrote [raw] — `'the gateway'` on every kind that reached a socket,
  /// `'this panel'` on [GatewayLinkKind.notBuilt], where nothing was dialled.
  final String whose;

  @override
  State<_RawDetails> createState() => _RawDetailsState();
}

class _RawDetailsState extends State<_RawDetails> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: kGatewayLinkRawKey,
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _open ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                ),
                const SizedBox(width: 4),
                Text(
                  _open ? 'Hide ${widget.whose}\'s own message'
                      : 'Show ${widget.whose}\'s own message',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SelectableText(
              widget.raw,
              // No `fontFamily` override: the golden host applies
              // `roboto-mono` to the whole text theme, and a family named here
              // that the golden font loader never registered renders as Ahem
              // boxes rather than as a monospaced OS Error line.
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
              ),
            ),
          ),
      ],
    );
  }
}
