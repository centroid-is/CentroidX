/// Which machine am I editing? (17-13, ACCESS-04)
///
/// One screen, two targets, and silently configuring the wrong one is the
/// failure mode the ROADMAP names before it names the feature. This banner is
/// the page's answer, rendered at the top where the operator's eye lands
/// first: in direct mode it names this station; in gateway mode it names the
/// backend the panel is dialling — the machine that will actually change when
/// Save is pressed.
///
/// ## Colour
///
/// The banner is informational, **not** a fault: only fault red may be
/// saturated in this repo, and "you are editing the backend" is a fact, not
/// an alarm. The gateway face wears `HmiStateColors.yellow` — the ratified
/// attention treatment the Transport card's unsaved save button already
/// wears, tinted over the surface with the ink split on brightness for the
/// same reason: both schemes' yellows are readable as ink on a dark card and
/// far too dim on a cream one. The direct face is quiet on purpose — editing
/// your own station is the unremarkable case, and a banner that shouts on
/// every screen in the plant is a banner nobody reads on the one screen where
/// it matters.
///
/// The border is `onSurface` with alpha, never the scheme's edge role:
/// neither Solarized scheme sets one, so an edge borrowed from it is
/// invisible on the dark theme the night shift runs (project memory
/// `solarized-outline-is-invisible`). The acceptance grep on this file is
/// literal and counts comments, which is why the offending spelling appears
/// nowhere here.
library;

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../theme.dart';

/// The banner itself, so tests find structure rather than prose.
const Key kConfigTargetBannerKey = Key('config_target_banner');

/// The width of the coloured mark — `GatewayLinkStatusRow`'s, deliberately:
/// one visual vocabulary for "a fact about this panel's far end".
const double kConfigTargetMarkWidth = 4;

/// The height of the coloured mark. Fixed, so the banner's geometry does not
/// move with the length of a hostname.
const double kConfigTargetMarkHeight = 28;

/// One row that names the machine about to be edited.
class ConfigTargetBanner extends StatelessWidget {
  /// Direct mode: the page edits this station's own configuration, and
  /// [name] is the station's name.
  const ConfigTargetBanner.station({super.key, required this.name})
      : isBackend = false;

  /// Gateway mode: the page edits the plant backend's configuration, and
  /// [name] is the endpoint this panel is dialling.
  const ConfigTargetBanner.backend({super.key, required this.name})
      : isBackend = true;

  /// Whether the target is the plant backend rather than this station.
  final bool isBackend;

  /// The machine, named. A banner that only says "a banner's worth of words"
  /// would pass a presence test while naming the wrong machine.
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final attention = HmiStateColors.of(context).yellow;

    // The gateway face: attention, not alarm. Ink split on brightness for the
    // reason the Transport card's save button splits it — the yellows are
    // mid-luminance, readable as ink on a dark surface and too dim on cream,
    // where onSurface carries the words and the tint carries the colour.
    final ink = isBackend && theme.brightness == Brightness.dark
        ? attention
        : theme.colorScheme.onSurface;
    final mark = isBackend
        ? attention
        : theme.colorScheme.onSurface.withValues(alpha: 0.35);
    final fill = isBackend ? attention.withValues(alpha: 0.12) : null;

    final text = isBackend
        ? 'Editing the plant backend at $name — not this station.'
        : 'Editing this station’s own configuration — $name.';

    return Container(
      key: kConfigTargetBannerKey,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: kConfigTargetMarkWidth,
            height: kConfigTargetMarkHeight,
            child: ColoredBox(color: mark),
          ),
          const SizedBox(width: 12),
          FaIcon(
            isBackend
                ? FontAwesomeIcons.towerBroadcast
                : FontAwesomeIcons.display,
            size: 16,
            color: ink,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: ink,
                fontWeight: isBackend ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
