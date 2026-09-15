/// Beckhoff EL9222-5500 — the 2-channel electronic overcurrent protection
/// terminal that feeds most of the 24 V loads on this plant (55 of them
/// across ST101/ST201/ST301).
///
/// The PLC publishes each terminal as an `ST_EL9222_5500`
/// (`SVNCoreComponents/ECT/ST_EL9222_5500.TcDUT`): sixteen read-only status
/// bits, eight per channel, mapped one-for-one off the terminal's `OCP Inputs
/// Channel n` PDO, plus four command bits on `OCP Outputs Channel n`.
///
/// No PLC POU sits between the struct and the terminal — nothing in the
/// project so much as reads `ST_EL9222_5500`, so `p_cmd_Reset` is wired
/// straight through to the terminal's `Control__Reset`. That input
/// acknowledges a trip on a RISING EDGE and nothing in the PLC ever clears
/// it again, so the HMI owns the whole pulse. See [kEl9222ResetPulse].
///
/// This library holds the decode and the operator surface. The subscription
/// and the writes live with the asset in `beckhoff.dart`: a pane is built
/// into the root overlay, and a widget that reads providers from there is not
/// on the page's tree (the lesson [EquipmentStatusDiodes] records).
library;

import 'package:flutter/material.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import '../../painter/beckhoff/io8.dart' show IOState;
import '../../theme.dart' show HmiStateColors;
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/side_pane.dart';
import 'led.dart' show LEDPainter, LEDType;

/// How long `p_cmd_Reset` is held high.
///
/// The terminal wants an edge, not a level, and no PLC code clears the bit —
/// so the HMI raises it and drops it again. Long enough to survive a slow
/// OPC UA round trip and the PLC scan behind it, short enough that an
/// operator watching the pane sees one press, not a latched switch.
const Duration kEl9222ResetPulse = Duration(milliseconds: 400);

/// The status bits one channel of an `ST_EL9222_5500` publishes, each with
/// the words an operator reads instead of the member name.
///
/// Channel 2 carries the same members with a `_2` suffix — see [member].
enum El9222Flag {
  /// `Status__Enabled` — the output is switched on and supplying its load.
  enabled('p_stat_Enabled', 'Supplying load'),

  /// `Status__Tripped` — the output was switched off after an overcurrent
  /// event. This is the bit that means "the breaker is out".
  tripped('p_stat_Tripped', 'Tripped'),

  /// `Status__Hardware Protection` — the hardware-level short-circuit
  /// protection engaged. Also means the output is dead, but for a harder
  /// reason than a slow overload.
  hardwareProtection('p_stat_Hardware_Protection', 'Short-circuit protection'),

  /// `Status__Current Level Warning` — prewarning: the load is drawing close
  /// to the configured trip limit but has not tripped.
  currentLevelWarning('p_stat_Current_Level_Warning', 'Near trip limit'),

  /// `Status__Cool Down Lock` — the channel is locked for its cool-down
  /// period after a trip. A reset is refused while this is set.
  coolDownLock('p_stat_Cool_Down_Lock', 'Cooling down'),

  /// `Status__Error` — a general channel diagnostic that is not a trip.
  error('p_stat_Error', 'Channel error'),

  /// `Status__State Reset` — the current level of the reset acknowledge
  /// signal. Diagnostic only: it says whether `p_cmd_Reset` is high now.
  stateReset('p_stat_State_Reset', 'Reset held'),

  /// `Status__State Switch` — the current on/off state of the channel
  /// switch, i.e. whether the output is commanded on at all.
  stateSwitch('p_stat_State_Switch', 'Switched on');

  const El9222Flag(this._member, this.label);

  final String _member;

  /// What the pane calls this bit. Operator words, never the member name.
  final String label;

  /// Struct member carrying this flag for [channel] (1 or 2).
  String member(int channel) => channel == 1 ? _member : '${_member}_2';
}

/// Command member carrying the reset edge for [channel] (1 or 2).
String el9222ResetMember(int channel) =>
    channel == 1 ? 'p_cmd_Reset' : 'p_cmd_Reset_2';

/// What one channel is doing, worst-first. The order is the severity order —
/// [el9222WorstOf] compares on `index`.
enum El9222ChannelState {
  /// The hardware short-circuit protection cut the output.
  shorted,

  /// The output was switched off by an overcurrent trip. The breaker is out.
  tripped,

  /// The channel reports a diagnostic that is not a trip.
  faulted,

  /// On, but drawing close to its trip limit.
  strained,

  /// On and supplying its load.
  live,

  /// Commanded off. Nothing is wrong.
  off,

  /// Nothing published yet, or the struct carries no such member.
  unknown,
}

/// One channel of an EL9222 as the terminal last reported it.
///
/// Every flag is nullable and a missing member stays `null` rather than
/// collapsing to `false`: a bit the server never served is not the same
/// thing as a bit that is off, and painting it as a confident "off" is how
/// an operator ends up trusting a diode that means nothing.
@immutable
class El9222ChannelStatus {
  const El9222ChannelStatus({required this.channel, required this.flags});

  /// 1 or 2.
  final int channel;

  final Map<El9222Flag, bool?> flags;

  /// Reads [channel] out of a subscribed `ST_EL9222_5500`.
  ///
  /// A null [struct] — no key configured, nothing received yet — yields a
  /// status whose every flag is unknown.
  factory El9222ChannelStatus.read(DynamicValue? struct, int channel) {
    assert(channel == 1 || channel == 2);
    return El9222ChannelStatus(
      channel: channel,
      flags: {
        for (final flag in El9222Flag.values)
          flag: switch (struct) {
            null => null,
            final s => s.contains(flag.member(channel))
                ? s[flag.member(channel)].asBool
                : null,
          },
      },
    );
  }

  bool? operator [](El9222Flag flag) => flags[flag];

  bool _set(El9222Flag flag) => flags[flag] ?? false;

  /// True when the terminal itself cut the output — the operator's "the
  /// breaker is out". Distinct from [El9222Flag.stateSwitch] being off,
  /// which is somebody having asked for it off.
  bool get out =>
      _set(El9222Flag.tripped) || _set(El9222Flag.hardwareProtection);

  /// True while the terminal will refuse a reset. Pressing reset during the
  /// cool-down period does nothing, so the pane says so rather than letting
  /// an operator press a button that cannot work.
  bool get resetBlocked => _set(El9222Flag.coolDownLock);

  /// True when a reset would achieve something: the channel is out, or
  /// carrying an error to acknowledge.
  bool get resettable => out || _set(El9222Flag.error);

  /// True when nothing at all has been published for this channel.
  bool get isUnknown => flags.values.every((v) => v == null);

  El9222ChannelState get state {
    if (isUnknown) return El9222ChannelState.unknown;
    if (_set(El9222Flag.hardwareProtection)) return El9222ChannelState.shorted;
    if (_set(El9222Flag.tripped)) return El9222ChannelState.tripped;
    if (_set(El9222Flag.error)) return El9222ChannelState.faulted;
    if (_set(El9222Flag.enabled)) {
      return _set(El9222Flag.currentLevelWarning)
          ? El9222ChannelState.strained
          : El9222ChannelState.live;
    }
    return El9222ChannelState.off;
  }
}

/// The more serious of two channel states — the terminal's headline.
El9222ChannelState el9222WorstOf(
  El9222ChannelState a,
  El9222ChannelState b,
) =>
    a.index <= b.index ? a : b;

/// The chip a channel or a whole terminal shows.
PaneStatus el9222PaneStatus(El9222ChannelState state) => switch (state) {
      El9222ChannelState.shorted => const PaneStatus.fault('Short circuit'),
      El9222ChannelState.tripped => const PaneStatus.fault('Tripped'),
      El9222ChannelState.faulted => const PaneStatus.fault('Error'),
      El9222ChannelState.strained => const PaneStatus.warning('Near limit'),
      El9222ChannelState.live => const PaneStatus.running('On'),
      El9222ChannelState.off => const PaneStatus.stopped('Off'),
      El9222ChannelState.unknown => const PaneStatus.unknown('No data'),
    };

/// What the state means and what to do about it, shown under the headline
/// row when the operator taps it.
String el9222Explanation(El9222ChannelState state) => switch (state) {
      El9222ChannelState.shorted =>
        'The short-circuit protection cut this output. Something on the '
            'load side is shorted — find and clear it before resetting, or '
            'the channel will trip straight back out.',
      El9222ChannelState.tripped =>
        'This output drew more than its limit and the terminal switched it '
            'off. The load has no 24 V. Check what it feeds, then reset the '
            'channel to put it back on.',
      El9222ChannelState.faulted =>
        'The channel reports a diagnostic that is not an overcurrent trip. '
            'A reset acknowledges it.',
      El9222ChannelState.strained =>
        'The load is drawing close to this channel\'s trip limit. It is '
            'still supplied, but it will trip if the draw keeps climbing.',
      El9222ChannelState.live => 'The output is on and supplying its load.',
      El9222ChannelState.off =>
        'The output is switched off. It did not trip — the channel switch '
            'is off.',
      El9222ChannelState.unknown =>
        'Nothing has arrived for this channel. Either no key is configured '
            'for the terminal or the PLC link is down.',
    };

/// The six lamps on the module face, in [IO6LedBlockPainter] order.
///
/// The face is a two-state indicator and nothing more — green means the
/// output is live, red means it is out. Prewarnings and cool-down locks stay
/// off it deliberately: red on a mimic is what sends an electrician across
/// the plant, and a load merely approaching its limit has not stopped
/// anything. The pane carries that nuance.
///
///     ┌──────────────┐
///     │      A       │  A = Ch1 supplying load        (green)
///     ├──────┬───────┤
///     │  B   │   C   │  B = Ch1 out    C = Ch1 error  (red)
///     ├──────┼───────┤
///     │  D   │   E   │  D = Ch2 out    E = Ch2 error  (red)
///     ├──────┴───────┤
///     │      F       │  F = Ch2 supplying load        (green)
///     └──────────────┘
List<IOState> el9222FaceLeds(
  El9222ChannelStatus ch1,
  El9222ChannelStatus ch2,
) {
  IOState supplying(El9222ChannelStatus ch) =>
      (ch[El9222Flag.enabled] ?? false) ? IOState.high : IOState.low;
  IOState alarm(bool set) => set ? IOState.error : IOState.low;

  return [
    supplying(ch1),
    alarm(ch1.out),
    alarm(ch1[El9222Flag.error] ?? false),
    alarm(ch2.out),
    alarm(ch2[El9222Flag.error] ?? false),
    supplying(ch2),
  ];
}

// ---------------------------------------------------------------------------
// Operator surface
// ---------------------------------------------------------------------------

/// The EL9222 pane body.
///
/// A plain [StatelessWidget] fed values — the subscription belongs to the
/// asset, which outlives the overlay this is built into.
class El9222PaneBody extends StatelessWidget {
  const El9222PaneBody({
    super.key,
    required this.channels,
    required this.descriptions,
    required this.onReset,
  });

  /// Channel 1 then channel 2.
  final List<El9222ChannelStatus> channels;

  /// What each channel feeds, when the page supplies a descriptions key.
  /// Short of two entries is fine — a channel without one just shows its
  /// number.
  final List<String> descriptions;

  /// Pulses `p_cmd_Reset` for the given channel. Completes when the pulse is
  /// over, so the button can show it running.
  final Future<void> Function(int channel) onReset;

  String? _descriptionFor(int channel) {
    final index = channel - 1;
    if (index >= descriptions.length) return null;
    final text = descriptions[index].trim();
    return text.isEmpty ? null : text;
  }

  @override
  Widget build(BuildContext context) {
    return PaneBody(
      sections: [
        for (final channel in channels)
          PaneBodySection.status(
            title: 'Channel ${channel.channel}',
            child: _ChannelStatus(
              channel: channel,
              description: _descriptionFor(channel.channel),
            ),
          ),
        PaneBodySection.manual(
          title: 'Reset',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final channel in channels) ...[
                _ResetButton(
                  channel: channel,
                  description: _descriptionFor(channel.channel),
                  onReset: onReset,
                ),
                const SizedBox(height: 8),
              ],
              Text(
                'A reset puts the output back on. Clear what caused the trip '
                'first — a channel that trips straight back out is telling '
                'you the fault is still there.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One channel's block: the headline state with its explanation, then a
/// diode per diagnostic.
class _ChannelStatus extends StatelessWidget {
  const _ChannelStatus({required this.channel, this.description});

  final El9222ChannelStatus channel;
  final String? description;

  /// The bits worth a diode: the three that answer a question the headline
  /// row does not.
  ///
  /// [El9222Flag.tripped], [El9222Flag.hardwareProtection] and
  /// [El9222Flag.error] each ARE the headline when they are set, so a diode
  /// for them only restates the row above it — and every restated row pushes
  /// the reset button, which is what the operator opened this pane for,
  /// further below the fold. [El9222Flag.stateSwitch] and
  /// [El9222Flag.stateReset] are wiring: the second says whether the HMI's
  /// own command bit is high, which is not something anyone acts on.
  ///
  /// What is left is orthogonal to the headline:
  ///
  ///  * `Supplying load` — is there 24 V at the load right now, which is the
  ///    question an electrician actually arrives with;
  ///  * `Near trip limit` — the headline only says this while the channel is
  ///    otherwise healthy; on a channel that is already out it is the clue
  ///    that the load was creeping up before it went;
  ///  * `Cooling down` — the bit that decides whether a reset can work at
  ///    all, and the one the headline never carries.
  static const _diagnostics = [
    El9222Flag.enabled,
    El9222Flag.currentLevelWarning,
    El9222Flag.coolDownLock,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = HmiStateColors.of(context);
    final state = channel.state;
    final status = el9222PaneStatus(state);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (description != null) ...[
          Text(description!, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 6),
        ],
        PaneExplainRow(
          label: 'State',
          value: status.label,
          valueColor: status.color,
          // A channel that is out should be readable without a second tap.
          initiallyExpanded: channel.out,
          explanationBuilder: (context) => Text(
            el9222Explanation(state),
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final flag in _diagnostics)
          PaneDetailRow(
            // The diode is a fixed 22 px against a label that can wrap, so
            // centre it — the same call [EquipmentStatusDiodes] makes.
            crossAxisAlignment: CrossAxisAlignment.center,
            label: flag.label,
            child: SizedBox(
              width: 22,
              height: 22,
              child: CustomPaint(
                painter: LEDPainter(
                  color: switch (channel[flag]) {
                    null => null,
                    // None of the three is a fault in itself — supplying is
                    // good news, and the other two are the terminal warning
                    // or waiting. Red stays for what has actually stopped,
                    // which the headline row above already says.
                    true => flag == El9222Flag.enabled
                        ? colors.green
                        : colors.yellow,
                    false => Colors.white,
                  },
                  ledType: LEDType.circle,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The reset button for one channel — disabled, with the reason said out
/// loud, whenever pressing it could not work.
class _ResetButton extends StatefulWidget {
  const _ResetButton({
    required this.channel,
    required this.onReset,
    this.description,
  });

  final El9222ChannelStatus channel;
  final String? description;
  final Future<void> Function(int channel) onReset;

  @override
  State<_ResetButton> createState() => _ResetButtonState();
}

class _ResetButtonState extends State<_ResetButton> {
  bool _inFlight = false;

  Future<void> _press() async {
    setState(() => _inFlight = true);
    try {
      await widget.onReset(widget.channel.channel);
    } finally {
      if (mounted) setState(() => _inFlight = false);
    }
  }

  /// Why the button is dead, in words, or null when it is live.
  String? get _blockedReason {
    final channel = widget.channel;
    if (channel.isUnknown) return 'No data for this channel';
    if (channel.resetBlocked) {
      return 'Cooling down — the terminal refuses a reset until it clears';
    }
    if (!channel.resettable) return 'Nothing to reset';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = _blockedReason;
    final label = 'Reset channel ${widget.channel.channel}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PaneAction.destructive(
          label: _inFlight ? '$label…' : label,
          icon: Icons.restart_alt,
          buttonKey: ValueKey('el9222-reset-${widget.channel.channel}'),
          onPressed: (reason != null || _inFlight) ? null : _press,
        ).build(context),
        if (reason != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              reason,
              // Centred under the button it explains: left-aligned against a
              // centred button the caption reads as a stray line of body
              // text belonging to the section, not to the dead control.
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// Opens the EL9222 pane.
///
/// [stream] feeds the whole pane, so one subscription covers it and dies with
/// the pane. [statusOf] turns an emission into the two channel snapshots so
/// the asset keeps ownership of where the struct came from.
void showEl9222Pane({
  required BuildContext context,
  required String id,
  required String title,
  required Stream<({List<El9222ChannelStatus> channels, List<String> loads})>
      stream,
  required Future<void> Function(int channel) onReset,
}) {
  showSidePane(
    context: context,
    id: id,
    builder: (paneContext) => StreamBuilder<
        ({List<El9222ChannelStatus> channels, List<String> loads})>(
      stream: stream,
      builder: (context, snap) {
        final channels = (snap.hasData && !snap.hasError)
            ? snap.data!.channels
            : [
                El9222ChannelStatus.read(null, 1),
                El9222ChannelStatus.read(null, 2),
              ];
        final loads =
            (snap.hasData && !snap.hasError) ? snap.data!.loads : const <String>[];

        return SidePane(
          title: title,
          // Kept short on purpose: a pane is 380 px and the subtitle shares
          // its row with the status chip, so 'Beckhoff · 2× overcurrent
          // protection' came out as 'Beckhoff · 2× overcur…'. 'Breaker' is
          // also the word the operators use for these, and the two channel
          // sections below already say there are two.
          subtitle: 'Beckhoff · breaker',
          icon: Icons.electrical_services,
          status: el9222PaneStatus(
            channels.map((c) => c.state).reduce(el9222WorstOf),
          ),
          child: El9222PaneBody(
            channels: channels,
            descriptions: loads,
            onReset: onReset,
          ),
        );
      },
    ),
  );
}
