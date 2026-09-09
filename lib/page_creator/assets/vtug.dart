/// Festo VTUG valve terminal — the coil model, the decode, and the operator
/// surface. The subscription lives with the asset in `festo.dart`.
///
/// On this plant the terminal is a **VTUG-14** manifold with a **CTEU-EC**
/// bus node bolted to its left end plate. The EtherCAT config in the PLC
/// repo calls the electronics `VAEM-L1-S-8-PT [16DO]`: eight valve
/// positions, two solenoid coils apiece, sixteen digital outputs. Three of
/// these are fitted — `ST303.A1` on Device 2, plus two more on Device 5.
///
/// What the PLC publishes today is two raw bytes:
///
/// ```
/// ST303_A1_C1_Output AT %Q* : BYTE;   // positions 1..4
/// ST303_A1_C2_Output AT %Q* : BYTE;   // positions 5..8
/// ```
///
/// Those are the PLC's own outputs — it writes them every scan, so the HMI
/// cannot drive a coil by writing into them and expect the value to survive
/// to the next cycle. Hand control therefore goes through a pair of words
/// the PLC reads and the HMI owns; see [VtugTerminal] for the struct this
/// asset expects and `festo.dart` for the key fields that address it.
library;

import 'package:flutter/material.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import '../../painter/festo/valve_symbol.dart';
import '../../painter/festo/vtug.dart' show CteuLed, CteuLedState;
import '../../theme.dart' show HmiStateColors;
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/side_pane.dart';
import 'io_pane.dart' show IoChannelEntry, IoChannelList;
import 'led.dart' show LEDPainter, LEDType;

/// Valve positions on the manifold this asset draws.
///
/// Fixed at eight because the electronics are: `VAEM-L1-S-8-PT` drives
/// sixteen coils and no more, and a ninth position on the same node has
/// nowhere to be wired. A wider manifold is a second cluster and a second
/// asset.
const int vtugPositionCount = 8;

/// Solenoid coils on a full manifold — two per position.
const int vtugCoilCount = vtugPositionCount * 2;

/// What is fitted at one valve position.
///
/// A position is not always a valve: unused positions on a VTUG carry a
/// blanking plate, which has no coil and therefore no LED. Drawing a lamp
/// there would invent a channel the hardware does not have.
///
/// The two valves actually ordered for this manifold are here by name. They
/// are not interchangeable in the way a coil count would suggest: a 5/3 and
/// a bistable 5/2 both have two coils and two lamps, and they do completely
/// different things when neither coil is energised. That difference is the
/// reason this is an enum of parts rather than a number of solenoids.
enum VtugValveKind {
  /// Blanking plate. No coil, no LED, nothing to command.
  blank(
    'Blank',
    'Blanking plate',
    0,
    'nothing — there is no valve here',
  ),

  /// `VUVG-B14-M52-AZT-F-1T1L` — 5/2 monostable. Five of these are fitted.
  ///
  /// One pilot solenoid. Coil 14 shifts the valve and a spring returns it,
  /// so de-energised is a real, known position and there is no second coil
  /// to push.
  valve52Mono(
    '5/2 single',
    'VUVG-B14-M52 — 5/2 monostable, spring return',
    1,
    'port 2 — the spring returns the valve',
  ),

  /// 5/2 bistable — two pilot solenoids, no spring.
  ///
  /// Not fitted on this manifold, and kept because it is the standard VTUG
  /// alternative to the 5/3 and the two are easy to confuse. Coil 14 shifts
  /// one way, coil 12 the other, and with neither energised the valve stays
  /// exactly where it was last driven.
  valve52Bistable(
    '5/2 double',
    '5/2 bistable — stays where it was last driven',
    2,
    'wherever it was last driven — a bistable valve has no rest position',
  ),

  /// `VUVG-B14-P53C-ZT-F-1T1L` — 5/3 closed centre. Three are fitted.
  ///
  /// Two pilot solenoids and a centring spring. Coil 14 gives port 4, coil
  /// 12 gives port 2, and with neither energised the valve springs to the
  /// middle with **both work ports blocked** — the cylinder is pneumatically
  /// locked where it stands. That middle is a third commandable position,
  /// not the absence of a command, which is why this valve gets a control a
  /// 5/2 does not.
  valve53Closed(
    '5/3 closed',
    'VUVG-B14-P53C — 5/3 closed centre, springs to mid',
    2,
    'the closed centre — both work ports blocked, cylinder locked',
  );

  const VtugValveKind(this.label, this.blurb, this.coilCount, this.restBlurb);

  /// Short name for the configure form's picker.
  final String label;

  /// The line beside it, where there is room to say what it means.
  final String blurb;

  /// How many coils this position drives — and so how many LEDs the real
  /// slice wears.
  final int coilCount;

  /// Where the valve goes with no coil energised, in words the pane uses.
  ///
  /// The whole reason [valve52Bistable] and [valve53Closed] are separate
  /// kinds: same two coils, same two lamps, and this sentence differs.
  final String restBlurb;

  /// Whether de-energising every coil is a position worth offering as a
  /// command of its own.
  ///
  /// True for both two-coil valves, and it means different things on each —
  /// see [midLabel]. False on a monostable, where "no coil energised" is
  /// simply the port-2 end and already has a button.
  bool get hasMidPosition => coilCount == 2;

  /// What the pane calls the both-coils-off position.
  ///
  /// `Centre` on a 5/3, which springs to a defined middle. `Hold` on a
  /// bistable, which does not spring anywhere and simply stays put. Calling
  /// both of them 'Centre' would tell an operator a bistable valve has a
  /// mid position, which is the mistake this whole enum exists to prevent.
  String get midLabel => switch (this) {
        VtugValveKind.valve53Closed => 'Centre',
        _ => 'Hold',
      };
}

/// Which end of a valve a coil sits on, named the way Festo prints it.
///
/// The number is the port the coil pressurises: energising `14` puts
/// pressure on port 4, energising `12` puts it on port 2. That is what is
/// moulded into the valve beside each LED, so it is what the pane calls the
/// coil — an electrician reading the pane and an electrician looking at the
/// terminal should be reading the same two characters.
enum VtugCoil {
  /// Pilot 14 — the first coil, always fitted when there is a valve at all.
  p14('14'),

  /// Pilot 12 — the second coil, fitted only on a double-solenoid valve.
  p12('12');

  const VtugCoil(this.label);

  /// `14` / `12`, as printed on the valve.
  final String label;
}

/// Where coil [coil] of valve position [position] lands in the terminal's
/// 16-bit output image.
///
/// Positions are numbered from one, as the manifold is. Each takes two
/// consecutive bits, coil 14 on the even bit and coil 12 on the odd one, so
/// position 1 is bits 0–1, position 2 is bits 2–3, and so on. The low byte
/// is the PLC's `C1 Output` and the high byte its `C2 Output`, which is why
/// positions 1–4 live in the low byte and 5–8 in the high one.
///
/// This is the standard Festo I-Port layout for a valve cluster and it is
/// the one assumption in this file that hardware can disagree with. If a
/// commissioning check finds the coils transposed, the fix belongs here —
/// every lamp, every button and every test reads the map from this function
/// and none of them re-derive it.
int vtugBitIndex(int position, VtugCoil coil) {
  assert(position >= 1 && position <= vtugPositionCount);
  return (position - 1) * 2 + (coil == VtugCoil.p12 ? 1 : 0);
}

/// Hand control in effect at one valve position.
///
/// Named after the ports rather than after "open" and "closed". On a 5/2
/// those two words are a fair description of a cylinder's two ends; on a 5/3
/// closed centre they are actively wrong, because the position an operator
/// most wants — both coils off, both work ports blocked — is neither open
/// nor closed. `4` and `2` are also what is moulded into the valve, so the
/// pane and the hardware use one vocabulary.
///
/// [auto] is not an override at all — it is the absence of one, and the
/// position it leaves the valve in is whatever the PLC's own logic drives.
enum VtugForce {
  /// The PLC has the valve. Nothing is held.
  auto('Auto'),

  /// Held with coil 14 energised — pressure on port 4.
  port4('Port 4'),

  /// Both coils held de-energised.
  ///
  /// Only offered on a two-coil valve, and it means what that valve's
  /// spring does: the closed centre on a 5/3, the last position on a
  /// bistable. See [VtugValveKind.midLabel].
  mid('Centre'),

  /// Held with coil 12 energised on a two-coil valve, or with coil 14
  /// de-energised on a monostable so the spring takes it back.
  port2('Port 2');

  const VtugForce(this.label);

  /// The segment's caption. [mid] is overridden per valve kind — ask
  /// [VtugValveKind.midLabel] rather than reading this one for it.
  final String label;
}

/// One valve position as the terminal last reported it, plus whatever the
/// operator is currently holding it at.
@immutable
class VtugValve {
  const VtugValve({
    required this.position,
    required this.kind,
    required this.coil14,
    required this.coil12,
    required this.force,
    this.description,
  });

  /// 1..8, as the positions are numbered on the manifold.
  final int position;

  /// What is fitted here — and so how many of the coil fields mean anything.
  final VtugValveKind kind;

  /// Coil 14 as the terminal reports it. Null when nothing has been
  /// received; an unpublished coil and a de-energised one are different
  /// things and the lamp shows the difference.
  final bool? coil14;

  /// Coil 12, same contract. Always null on a single-solenoid valve and on a
  /// blank — there is no second coil to report.
  final bool? coil12;

  /// What the operator is holding this valve at, if anything.
  final VtugForce force;

  /// What the plant calls this valve. Null when nobody has said.
  final String? description;

  /// True when a coil at this position is energised.
  bool get energised => (coil14 ?? false) || (coil12 ?? false);

  /// True when nothing has been received about this position.
  bool get isUnknown =>
      kind != VtugValveKind.blank && coil14 == null && coil12 == null;

  /// The coil state for [coil], or null when this valve has no such coil.
  bool? coilState(VtugCoil coil) => switch (coil) {
        VtugCoil.p14 => kind == VtugValveKind.blank ? null : coil14,
        VtugCoil.p12 => kind.coilCount == 2 ? coil12 : null,
      };

  /// Whether pushing [coil] does anything on this valve.
  bool hasCoil(VtugCoil coil) => switch (coil) {
        VtugCoil.p14 => kind.coilCount >= 1,
        VtugCoil.p12 => kind.coilCount == 2,
      };

  /// Whether this valve has a both-coils-off position worth commanding —
  /// see [VtugValveKind.hasMidPosition].
  bool get hasMid => kind.hasMidPosition;

  /// The force settings this valve can actually be put into, in the order
  /// the positions sit on its symbol: port 4, the middle, port 2.
  List<VtugForce> get availableForces => [
        VtugForce.auto,
        VtugForce.port4,
        if (hasMid) VtugForce.mid,
        VtugForce.port2,
      ];

  /// Which box of this valve's schematic the spool is in, or null when the
  /// terminal has not said.
  ///
  /// Read off the coils rather than off [force], because the schematic is a
  /// picture of the valve and not of who is driving it: a valve the PLC has
  /// energised is in exactly the same position as one an operator is
  /// holding there, and the symbol should show that position either way.
  ValveSymbolPosition get symbolPosition {
    final on14 = coil14;
    if (on14 == null) return null;
    if (on14) return 0;
    if (kind.coilCount == 2) {
      final on12 = coil12;
      if (on12 == null) return null;
      if (on12) return kind.hasMidPosition ? 2 : 1;
      // Neither coil energised on a two-coil valve. A 5/3 has sprung to its
      // centre; a bistable is wherever it was last driven, and this page
      // has no way to know where that is — so it claims no box rather than
      // guessing one.
      return kind == VtugValveKind.valve53Closed ? 1 : null;
    }
    // Monostable, de-energised: the spring has it, and that is a position
    // this page does know.
    return 1;
  }
}

/// The schematic [kind] draws as, or null for a position with no valve.
ValveSymbolKind? vtugSymbolKind(VtugValveKind kind) => switch (kind) {
      VtugValveKind.blank => null,
      VtugValveKind.valve52Mono => ValveSymbolKind.fiveTwoMono,
      VtugValveKind.valve52Bistable => ValveSymbolKind.fiveTwoBistable,
      VtugValveKind.valve53Closed => ValveSymbolKind.fiveThreeClosed,
    };

/// A whole terminal, decoded — eight positions and the two words behind them.
///
/// ## The struct this reads
///
/// The PLC side is four words in one `OPC.UA.DA` struct, generated beside
/// the `ST_EL9222_5500` this repo already talks to and in the same
/// `p_stat_` / `p_cmd_` idiom:
///
/// ```
/// TYPE ST_VTUG_16 :
/// STRUCT
///     p_stat_Coils  : WORD;   // what the sixteen coils are actually doing
///     p_stat_Forced : WORD;   // which coils the PLC has handed to the HMI
///     p_cmd_Force   : WORD;   // HMI: take these coils
///     p_cmd_Value   : WORD;   // HMI: and drive them here
/// END_STRUCT
/// END_TYPE
/// ```
///
/// Words rather than sixty-four BOOLs because the wire already is a word —
/// the terminal's output image is two bytes — and because a bit set in
/// `p_cmd_Force` has to reach the PLC in the same write as the value it
/// applies to. Two separate members written one after the other would leave
/// a scan in which a coil is taken but not yet told what to do.
///
/// `p_cmd_Force` and `p_cmd_Value` are the HMI's own: the PLC reads them and
/// never writes them, so this asset can set one bit without reading the word
/// back first and without racing the scan. `p_stat_*` are the PLC's, and are
/// read-only here. That split is the whole reason hand control on this
/// terminal works where it does not on the Beckhoff panes, whose only
/// writable surface is an output the PLC drives every cycle.
@immutable
class VtugTerminal {
  const VtugTerminal({required this.valves});

  /// Position 1 first. Always [vtugPositionCount] long.
  final List<VtugValve> valves;

  /// A terminal with nothing received — every fitted position unknown.
  factory VtugTerminal.unknown(List<VtugValveKind> kinds) => VtugTerminal(
        valves: [
          for (var i = 0; i < vtugPositionCount; i++)
            VtugValve(
              position: i + 1,
              kind: i < kinds.length ? kinds[i] : VtugValveKind.blank,
              coil14: null,
              coil12: null,
              force: VtugForce.auto,
            ),
        ],
      );

  /// Decodes one subscribed `ST_VTUG_16` against the manifold's [kinds].
  ///
  /// [descriptions] names the positions, position 1 first; short of eight is
  /// fine and leaves the rest unnamed.
  factory VtugTerminal.read(
    DynamicValue? struct, {
    required List<VtugValveKind> kinds,
    List<String> descriptions = const [],
  }) {
    int? word(String member) {
      if (struct == null || !struct.contains(member)) return null;
      return struct[member].asInt;
    }

    final coils = word('p_stat_Coils');
    final forceMask = word('p_cmd_Force') ?? 0;
    final forceValue = word('p_cmd_Value') ?? 0;

    bool? bitOf(int? word, int index) =>
        word == null ? null : (word & (1 << index)) != 0;

    String? descriptionAt(int index) {
      if (index >= descriptions.length) return null;
      final text = descriptions[index].trim();
      return text.isEmpty ? null : text;
    }

    return VtugTerminal(
      valves: [
        for (var i = 0; i < vtugPositionCount; i++)
          () {
            final position = i + 1;
            final kind = i < kinds.length ? kinds[i] : VtugValveKind.blank;
            final bit14 = vtugBitIndex(position, VtugCoil.p14);
            final bit12 = vtugBitIndex(position, VtugCoil.p12);
            return VtugValve(
              position: position,
              kind: kind,
              coil14:
                  kind == VtugValveKind.blank ? null : bitOf(coils, bit14),
              coil12:
                  kind.coilCount == 2 ? bitOf(coils, bit12) : null,
              force: vtugForceOf(
                kind: kind,
                position: position,
                forceMask: forceMask,
                forceValue: forceValue,
              ),
              description: descriptionAt(i),
            );
          }(),
      ],
    );
  }

  /// Coils energised across the whole terminal.
  int get energisedCount =>
      valves.where((v) => v.energised).length;

  /// Positions the operator is currently holding.
  int get forcedCount =>
      valves.where((v) => v.force != VtugForce.auto).length;

  /// Positions that carry a valve at all.
  int get fittedCount =>
      valves.where((v) => v.kind != VtugValveKind.blank).length;

  /// True when nothing has been received about any fitted position — the
  /// terminal is not publishing, or there is no key.
  bool get isUnknown =>
      valves.where((v) => v.kind != VtugValveKind.blank).every((v) => v.isUnknown);
}

/// Reads the force state of one position out of the two command words.
///
/// A single-solenoid valve has one coil, so port 2 is that coil held OFF
/// rather than a second coil held on. Held-off is still a hold: the mask bit
/// is set, so the PLC has handed the coil over and is not driving it.
///
/// On a two-coil valve, both coils held with neither driven is
/// [VtugForce.mid] — the closed centre on a 5/3, the last position on a
/// bistable. That is a command somebody gave, not an absence of one, and
/// reading it back as [VtugForce.auto] would show the PLC in charge of a
/// valve it has been taken off.
VtugForce vtugForceOf({
  required VtugValveKind kind,
  required int position,
  required int forceMask,
  required int forceValue,
}) {
  if (kind == VtugValveKind.blank) return VtugForce.auto;

  bool bit(int word, int index) => (word & (1 << index)) != 0;
  final bit14 = vtugBitIndex(position, VtugCoil.p14);
  final bit12 = vtugBitIndex(position, VtugCoil.p12);

  final held14 = bit(forceMask, bit14);
  final held12 = kind.coilCount == 2 && bit(forceMask, bit12);
  if (!held14 && !held12) return VtugForce.auto;

  if (kind.coilCount == 2) {
    if (held12 && bit(forceValue, bit12)) return VtugForce.port2;
    if (held14 && bit(forceValue, bit14)) return VtugForce.port4;
    return VtugForce.mid;
  }

  return bit(forceValue, bit14) ? VtugForce.port4 : VtugForce.port2;
}

/// The command words that put [position] into [force], applied over the
/// words currently in effect.
///
/// Returns the pair to write. Both words go in one write of the struct's
/// command members — see [VtugTerminal] for why they cannot be split.
///
/// A [force] the valve cannot reach is a no-op rather than an approximation:
/// asking a monostable for [VtugForce.mid] leaves the words alone, because
/// the nearest thing that valve has is port 2 and quietly substituting it
/// would move a cylinder nobody asked to move.
({int mask, int value}) vtugApplyForce({
  required int forceMask,
  required int forceValue,
  required VtugValveKind kind,
  required int position,
  required VtugForce force,
}) {
  if (kind == VtugValveKind.blank) {
    return (mask: forceMask, value: forceValue);
  }
  if (force == VtugForce.mid && !kind.hasMidPosition) {
    return (mask: forceMask, value: forceValue);
  }

  final bit14 = vtugBitIndex(position, VtugCoil.p14);
  final bit12 = vtugBitIndex(position, VtugCoil.p12);
  final twoCoil = kind.coilCount == 2;

  int set(int word, int index, bool on) =>
      on ? word | (1 << index) : word & ~(1 << index);

  /// Applies [take] to the mask and [drive] to the value for both coils.
  ({int mask, int value}) both(bool take, bool drive14, bool drive12) {
    var mask = set(forceMask, bit14, take);
    var value = set(forceValue, bit14, drive14);
    if (twoCoil) {
      mask = set(mask, bit12, take);
      value = set(value, bit12, drive12);
    }
    return (mask: mask, value: value);
  }

  return switch (force) {
    // Handing a coil back with its value bit still set would bring it up
    // energised the moment anything set the mask bit again, so auto clears
    // both words, not just the mask.
    VtugForce.auto => both(false, false, false),
    VtugForce.port4 => both(true, true, false),
    VtugForce.port2 => both(true, !twoCoil ? false : false, true),
    // Both coils taken and neither driven. On a 5/3 the spring puts the
    // valve in its closed centre; on a bistable it stays where it was.
    VtugForce.mid => both(true, false, false),
  };
}

/// The command words that energise one coil for as long as it is held.
///
/// This is the pane's push button, and it is deliberately not a force: it
/// takes exactly the coil under the finger, drives it, and gives it back on
/// release. The other coil of a double solenoid is left alone, because
/// pushing 14 while the PLC is driving 12 is a thing an electrician does on
/// purpose at the terminal — the manual override buttons on the real valve
/// work one coil at a time and so does this.
({int mask, int value}) vtugApplyPush({
  required int forceMask,
  required int forceValue,
  required int position,
  required VtugCoil coil,
  required bool pressed,
}) {
  final bit = vtugBitIndex(position, coil);
  return (
    mask: pressed ? forceMask | (1 << bit) : forceMask & ~(1 << bit),
    value: pressed ? forceValue | (1 << bit) : forceValue & ~(1 << bit),
  );
}

/// Command words with every hold released.
///
/// Clearing the value word as well as the mask matters: a coil handed back
/// to the PLC with its value bit still set would come up energised the
/// instant anything set the mask bit again.
({int mask, int value}) vtugReleaseAll() => (mask: 0, value: 0);

/// The chip the terminal's pane header shows.
///
/// A held valve outranks a busy one. A terminal with three valves moving is
/// doing its job; a terminal with one valve held by hand is a terminal
/// somebody has to remember to give back, and that is the thing the header
/// exists to keep in front of them.
PaneStatus vtugPaneStatus(VtugTerminal terminal) {
  if (terminal.fittedCount == 0) return const PaneStatus.unknown('No valves');
  if (terminal.isUnknown) return const PaneStatus.unknown('No data');
  if (terminal.forcedCount > 0) {
    return PaneStatus.warning('${terminal.forcedCount} held');
  }
  final on = terminal.energisedCount;
  return on == 0
      ? const PaneStatus.stopped('All quiet')
      : PaneStatus.running('$on of ${terminal.fittedCount} on');
}

/// What the pane calls a valve position in its name gutter.
String vtugPositionLabel(int position) => 'V$position';

// ---------------------------------------------------------------------------
// Operator surface
// ---------------------------------------------------------------------------

/// One coil's lamp, drawn the way the terminal draws it.
///
/// The real VTUG puts a yellow LED beside each pilot solenoid and lights it
/// when that coil is energised — the same yellow this repo gives commanded
/// state everywhere else, which is a happy accident worth keeping. A coil
/// the terminal has said nothing about is grey, not off: on a manifold where
/// half the positions may be blanked, "no data" and "not energised" are
/// answers an electrician acts on differently.
///
/// Square, because these are outputs, and this repo draws outputs square in
/// every I/O pane it has.
class VtugCoilLamp extends StatelessWidget {
  const VtugCoilLamp({super.key, required this.state});

  /// Null when the coil is unpublished or the position has no such coil.
  final bool? state;

  @override
  Widget build(BuildContext context) {
    final colors = HmiStateColors.of(context);
    return SizedBox(
      width: 22,
      height: 22,
      child: CustomPaint(
        painter: LEDPainter(
          color: switch (state) {
            null => null,
            true => colors.yellow,
            false => Colors.white,
          },
          ledType: LEDType.square,
        ),
      ),
    );
  }
}

/// A push button that energises its coil for exactly as long as it is held.
///
/// Momentary because the manual override on the valve itself is momentary:
/// an electrician who presses the little button on a VTUG expects the valve
/// to go back when they let go, and a control on a screen that behaved
/// otherwise would be the one surprise in the room.
///
/// [onPressedChanged] is called with true on the way down and false on the
/// way up — including when the pointer leaves the button still held, and
/// when the widget is disposed mid-press. A coil left energised because a
/// pane closed under a finger is the failure this exists to prevent.
class VtugPushButton extends StatefulWidget {
  const VtugPushButton({
    super.key,
    required this.label,
    required this.onPressedChanged,
    this.enabled = true,
  });

  /// `14` or `12`, as printed on the valve.
  final String label;

  final ValueChanged<bool>? onPressedChanged;

  final bool enabled;

  @override
  State<VtugPushButton> createState() => _VtugPushButtonState();
}

class _VtugPushButtonState extends State<VtugPushButton> {
  bool _down = false;

  void _set(bool down) {
    if (_down == down) return;
    _down = down;
    widget.onPressedChanged?.call(down);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // Not `_set` — that would call setState on a disposed State. The coil
    // still has to be released, and this is the last chance to do it.
    if (_down) {
      _down = false;
      widget.onPressedChanged?.call(false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = HmiStateColors.of(context);
    final live = widget.enabled && widget.onPressedChanged != null;

    return Semantics(
      button: true,
      enabled: live,
      label: 'Push coil ${widget.label}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: live ? (_) => _set(true) : null,
        onTapUp: live ? (_) => _set(false) : null,
        onTapCancel: live ? () => _set(false) : null,
        child: Container(
          width: 34,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            // Both the fill and the border are derived from the theme's own
            // body colour rather than taken from `colorScheme.outline` and
            // `surfaceContainerHighest`. Neither Solarized scheme sets
            // `outline`, so it falls back to a Material default that is all
            // but invisible against base03 — a button whose edge disappears
            // on every dark station while the light golden looks fine.
            color: _down
                ? colors.yellow
                : theme.colorScheme.onSurface.withValues(alpha: 0.08),
            border: Border.all(
              color: theme.colorScheme.onSurface
                  .withValues(alpha: live ? 0.35 : 0.15),
            ),
          ),
          child: Text(
            widget.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: _down
                  ? colors.onState
                  : live
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// The terminal's pane body.
///
/// A plain [StatelessWidget] fed values and callbacks — the subscription
/// belongs to the asset, which outlives the overlay this is built into.
///
/// Two sections, in the house order. **Valves** answers what the terminal is
/// doing, one row per position with the coil lamps in the order they sit on
/// the slice. **Force** is the hand control, and it is a separate section
/// rather than two more columns on the status rows because the status list
/// is what an operator reads and the force list is what they act on — the
/// pane is 380 px wide and putting both on one line left no room for the
/// description that says which valve it is.
class VtugPaneBody extends StatelessWidget {
  const VtugPaneBody({
    super.key,
    required this.terminal,
    this.link = CteuLink.dark,
    this.onForce,
    this.onPush,
  });

  final VtugTerminal terminal;

  /// What is known about the bus node in front of these valves. Rendered as
  /// the pane's last section — the valves are what an operator opened this
  /// for, and the node is what they read when the valves say nothing.
  final CteuLink link;

  /// Latches a position. Null disables the whole force section — no command
  /// keys configured, so there is nothing to write to.
  final void Function(VtugValve valve, VtugForce force)? onForce;

  /// Momentary push, called true on press and false on release.
  final void Function(VtugValve valve, VtugCoil coil, bool pressed)? onPush;

  bool get _canCommand => onForce != null || onPush != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fitted =
        terminal.valves.where((v) => v.kind != VtugValveKind.blank).toList();

    return PaneBody(
      sections: [
        PaneBodySection.status(
          title: 'Valves',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              IoChannelList(
                channels: [
                  for (final valve in terminal.valves)
                    IoChannelEntry(
                      name: vtugPositionLabel(valve.position),
                      description: valve.kind == VtugValveKind.blank
                          ? 'Blanking plate'
                          : valve.description,
                      lamps: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          VtugCoilLamp(state: valve.coilState(VtugCoil.p14)),
                          const SizedBox(width: 6),
                          VtugCoilLamp(state: valve.coilState(VtugCoil.p12)),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Two lamps a position, in the order the LEDs sit on the '
                'slice: coil 14 on the left, coil 12 on the right. A lit '
                'lamp is a coil the terminal reports as energised. A grey '
                'pair is a position with no valve in it, or one the '
                'terminal has said nothing about yet.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        if (fitted.isNotEmpty)
          PaneBodySection.manual(
            title: 'Force',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_canCommand) ...[
                  Text(
                    'No command keys are configured for this terminal, so '
                    'nothing here can be driven by hand. The PLC has every '
                    'valve.',
                    style: theme.textTheme.bodySmall,
                  ),
                ] else ...[
                  for (final valve in fitted)
                    _VtugForceRow(
                      valve: valve,
                      onForce: onForce,
                      onPush: onPush,
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Open drives the valve to port 4 and holds it there; '
                    'Close drives it to port 2, or on a single-solenoid '
                    'valve lets the spring take it back. Both hold until '
                    'they are put back to Auto. The 14 and 12 buttons are '
                    'momentary — the coil is energised only while the '
                    'button is held, the same as the manual override on the '
                    'valve itself.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        PaneBodySection.details(
          title: 'Bus node',
          child: CteuPaneSection(link: link),
        ),
      ],
    );
  }
}

/// One position's row in the force section: identity, the latch, the pushes.
class _VtugForceRow extends StatelessWidget {
  const _VtugForceRow({
    required this.valve,
    required this.onForce,
    required this.onPush,
  });

  final VtugValve valve;
  final void Function(VtugValve valve, VtugForce force)? onForce;
  final void Function(VtugValve valve, VtugCoil coil, bool pressed)? onPush;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final symbolKind = vtugSymbolKind(valve.kind);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 34,
                child: Text(
                  vtugPositionLabel(valve.position),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  valve.description ?? valve.kind.blurb,
                  style: theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // The schematic and the momentary overrides share a line: the
          // symbol says where the spool is and the two buttons are the
          // manual override on the valve itself, which is the pairing an
          // electrician already has in their hands.
          Padding(
            padding: const EdgeInsets.only(left: 34),
            child: Row(
              children: [
                if (symbolKind != null)
                  ValveSymbol(
                    kind: symbolKind,
                    active: valve.symbolPosition,
                  ),
                const Spacer(),
                for (final coil in VtugCoil.values)
                  if (valve.hasCoil(coil))
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: VtugPushButton(
                        label: coil.label,
                        onPressedChanged: onPush == null
                            ? null
                            : (pressed) => onPush!(valve, coil, pressed),
                      ),
                    ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 34),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<VtugForce>(
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: WidgetStatePropertyAll(
                        theme.textTheme.labelSmall,
                      ),
                      // Material's default outline for a segmented button
                      // comes from `colorScheme.outline`, which neither
                      // Solarized scheme sets — on a dark station the three
                      // segments lost their border and their dividers, and
                      // the control read as three words floating in the
                      // pane. Derived from the body colour instead, the way
                      // the push buttons beside it are.
                      side: WidgetStatePropertyAll(
                        BorderSide(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                    // Built from the valve, not from the enum: a monostable
                    // has no middle to offer, and a segment that does
                    // nothing when pressed is worse than an absent one.
                    segments: [
                      for (final force in valve.availableForces)
                        ButtonSegment(
                          value: force,
                          label: Text(
                            force == VtugForce.mid
                                ? valve.kind.midLabel
                                : force.label,
                          ),
                        ),
                    ],
                    selected: {valve.force},
                    onSelectionChanged: onForce == null
                        ? null
                        : (selection) =>
                            onForce!(valve, selection.first),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the valve terminal's pane.
///
/// [stream] carries the decoded terminal; the asset owns the subscription
/// behind it. [onReleaseAll] is the footer action and is null when there is
/// nothing to write to, which renders the button disabled rather than
/// hiding it — a pane that shows the command exists and says it is
/// unavailable is more use than one that pretends it never existed.
void showVtugPane({
  required BuildContext context,
  required String id,
  required String title,
  required String subtitle,
  required Stream<VtugTerminal> stream,
  required VtugTerminal initial,
  void Function(VtugValve valve, VtugForce force)? onForce,
  void Function(VtugValve valve, VtugCoil coil, bool pressed)? onPush,
  VoidCallback? onReleaseAll,
}) {
  showSidePane(
    context: context,
    id: id,
    builder: (paneContext) => StreamBuilder<VtugTerminal>(
      stream: stream,
      initialData: initial,
      builder: (context, snap) {
        final terminal =
            (snap.hasData && !snap.hasError) ? snap.data! : initial;

        return SidePane(
          title: title,
          subtitle: subtitle,
          icon: Icons.tune,
          status: vtugPaneStatus(terminal),
          actions: [
            PaneAction.destructive(
              label: 'Release all',
              icon: Icons.lock_open,
              buttonKey: const Key('vtug-release-all'),
              // Disabled when nothing is held: the button would write zeros
              // over zeros, and an operator who pressed it and saw nothing
              // change would rightly wonder what it did.
              onPressed:
                  terminal.forcedCount > 0 ? onReleaseAll : null,
            ),
          ],
          child: VtugPaneBody(
            terminal: terminal,
            // The pane has no separate window on the node: data arriving is
            // the whole of what this page knows about it, and it is the same
            // fact the header's chip is built from.
            link: terminal.isUnknown ? CteuLink.dark : CteuLink.live,
            onForce: onForce,
            onPush: onPush,
          ),
        );
      },
    ),
  );
}

// ---------------------------------------------------------------------------
// The bus node
// ---------------------------------------------------------------------------

/// What is known about the CTEU-EC bolted to the terminal.
///
/// Nothing on this plant publishes the node. Its LEDs are not in any GVL,
/// the EtherCAT slave state is not exported, and no PLC variable names it —
/// so the honest number of lamps this asset can light from live data is
/// zero, and the honest thing to draw is what we do know: whether the
/// terminal's own process data is arriving through it.
///
/// That is a real diagnostic and it is the one an operator wants. Data
/// arriving means the node is in OPERATIONAL, the I-Port link to the valve
/// cluster is up, and the incoming EtherCAT port has link — `Run`, `X1` and
/// `L/A1` green, and this says so. Data not arriving means the node is
/// somewhere between INIT and a pulled cable, and this does *not* guess
/// which: the lamps go to [CteuLedState.unknown] rather than picking a
/// fault the node never reported.
///
/// The lamps this cannot know — `X2` and `L/A2`, the second I-Port device
/// and the outgoing bus port — stay unknown in both cases.
enum CteuLink {
  /// Process data is arriving from the valve cluster behind this node.
  live,

  /// It is not. Why is not known from here.
  dark;

  /// The node's lamps, in the order they are silkscreened down the face.
  ///
  /// Six, in one column: `PS`, `X1`, `X2`, `Run`, `L/A2`, `L/A1`. Taken
  /// from a photograph of the node itself, and worth stating because the
  /// installation instructions do not draw the face — reading them alone
  /// gives you a seventh lamp, `ERROR`, in a second column, and the
  /// hardware has neither. An HMI that draws a diagnostic lamp the
  /// electrician cannot find on the housing is worse than one that draws
  /// none.
  List<CteuLed> get leds {
    final known = this == CteuLink.live;
    CteuLedState green() => known ? CteuLedState.green : CteuLedState.unknown;
    return [
      CteuLed('PS', green()),
      CteuLed('X1', green()),
      const CteuLed('X2', CteuLedState.unknown),
      CteuLed('Run', green()),
      const CteuLed('L/A2', CteuLedState.unknown),
      CteuLed('L/A1', green()),
    ];
  }
}

/// The pane's account of the bus node.
///
/// A details section rather than a second pane: the node has no state of its
/// own to open, and a pane whose whole content is "we cannot see this" is a
/// pane that teaches an operator to stop opening panes.
class CteuPaneSection extends StatelessWidget {
  const CteuPaneSection({super.key, required this.link});

  final CteuLink link;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        PaneDetailRow(
          label: 'Process data',
          value: link == CteuLink.live ? 'Arriving' : 'Not arriving',
        ),
        const SizedBox(height: 6),
        Text(
          link == CteuLink.live
              ? 'The valve cluster is publishing, so the node is in '
                  'OPERATIONAL with the I-Port link up and the incoming '
                  'EtherCAT port connected. PS, X1, Run and L/A1 are drawn '
                  'green on that basis. The node itself publishes nothing '
                  'to this page — X2 and L/A2 are the housing\'s to read, '
                  'not ours.'
              : 'Nothing is arriving from the valve cluster. The node could '
                  'be in INIT, the I-Port link could be down, or the '
                  'EtherCAT cable could be out — the node publishes nothing '
                  'to this page, so its lamps are drawn unknown rather than '
                  'guessing which. Read them on the housing.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
