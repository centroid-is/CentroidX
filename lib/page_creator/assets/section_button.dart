import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:logger/logger.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';

import 'button.dart' show ButtonPainter, ButtonType;
import 'common.dart';
import '../../providers/state_man.dart';
import '../../theme.dart' show HmiStateColors;
import '../../widgets/hit_boundary.dart';
import '../../widgets/memo_stream_builder.dart';
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/side_pane.dart';
import '../../widgets/panes/standard_dialog.dart';
import '../../widgets/tag_access_guard.dart' show guardTagWrite, writeTag;

part 'section_button.g.dart';

// ---------------------------------------------------------------------------
// The PLC side
//
// `FB_Section` (SVNCoreComponents/Section/FB_Section.TcPOU) is the generic
// line controller behind every section of the plant — `section.beforeFreezers`,
// `section.afterFreezers`, `section.boxPackingFilm`, … Its `HMI` member is a
// structured OPC UA node (`ST_Section_HMI`) with everything this asset needs
// and nothing it does not:
//
//   p_cmd_Start        momentary — TOGGLES q_xEnabled, clears cleaning
//   p_cmd_StartClean   momentary — TOGGLES q_xCleanEnabled, clears auto
//   p_cmd_Stop         momentary — drops both
//   p_stat_xEnabled    the section is running in auto
//   p_stat_xCleanEnabled  the section is running in cleaning
//   p_stat_xPermissive external interlock; FALSE drops the outputs and
//                      makes both start commands no-ops
//
// The FB clears the command bits itself on the scan it processes them, so the
// HMI writes TRUE and never has to write FALSE back.
//
// The toggle semantics of the two start commands are the trap in this
// interface, and the reason [canStart] / [canClean] exist: sending
// `p_cmd_Start` to a section that is already running STOPS it. Nothing here
// ever offers a command that would do the opposite of what its label says —
// and with several sections behind one button that guard has to be applied
// per section, not to the group, or one press would start the stopped members
// and stop the running ones, leaving the line exactly as it was, inverted.
// ---------------------------------------------------------------------------

/// Struct member names on `ST_Section_HMI`.
const String kSectionCmdStart = 'p_cmd_Start';
const String kSectionCmdStartClean = 'p_cmd_StartClean';
const String kSectionCmdStop = 'p_cmd_Stop';
const String kSectionStatEnabled = 'p_stat_xEnabled';
const String kSectionStatCleanEnabled = 'p_stat_xCleanEnabled';
const String kSectionStatPermissive = 'p_stat_xPermissive';

/// What a section is doing, as an operator would say it.
enum SectionMode {
  /// `p_stat_xEnabled` — running in auto.
  running('Running'),

  /// `p_stat_xCleanEnabled` — running in cleaning.
  cleaning('Cleaning'),

  /// Idle, and it could be started.
  stopped('Stopped'),

  /// Idle and not allowed to start: `p_stat_xPermissive` is FALSE, so the PLC
  /// will ignore both start commands until the interlock returns.
  ///
  /// Not a fault. On this plant the only permissive that is ever FALSE is the
  /// mutual exclusion between the two box-packing sections — ST201/ST301 wire
  /// `boxPackingFilm.i_xPermissive := NOT boxPackingVacuum.q_xEnabled` and the
  /// mirror of it — so the usual meaning is "the other mode has the line".
  /// Hence yellow (waiting) rather than red: a section held off by its twin is
  /// working exactly as designed, and fault red would send an electrician
  /// after nothing.
  blocked("Can't start"),

  /// Nothing readable: no key configured, no value yet, a stream error, or a
  /// struct that does not carry the members a section has.
  ///
  /// Painted the way every unreadable thing in the app is painted — a grey
  /// face with an exclamation mark on it (see `conveyor.dart`, which greys a
  /// belt and stamps a `!` on it when it has no keys, no data, or an errored
  /// stream). Grey alone would be a lie: grey is `stopped`, and a section
  /// nobody can read is not a section anybody knows to be safe.
  unknown("Can't read");

  const SectionMode(this.label);

  /// What the pane calls this state.
  ///
  /// Plain words, not PLC words. An operator standing at the machine reads
  /// "Can't start", not "permissive not satisfied" — the term of art lives in
  /// the explanation behind [SectionPane]'s permit row, where it is defined
  /// rather than assumed.
  final String label;
}

/// The section's mode, given the three status bits of `ST_Section_HMI`.
///
/// Null means "not read yet" for any of the three, which is
/// [SectionMode.unknown] — a section whose state is unreadable must not be
/// painted as one that is safely stopped.
///
/// Running and cleaning outrank a lost go-ahead deliberately. The PLC drops
/// the outputs the same scan the permissive goes away, so the combination is
/// transient at worst; painting a moving line as idle for those scans is the
/// one wrong answer that could get somebody hurt. The lost go-ahead is never
/// hidden — the pane always carries it as its own row.
SectionMode resolveSectionMode({
  required bool? enabled,
  required bool? cleanEnabled,
  required bool? permissive,
}) {
  if (enabled == null || cleanEnabled == null || permissive == null) {
    return SectionMode.unknown;
  }
  if (enabled) return SectionMode.running;
  if (cleanEnabled) return SectionMode.cleaning;
  return permissive ? SectionMode.stopped : SectionMode.blocked;
}

/// Colour a section in [mode] is painted, from the theme's equipment palette.
///
/// Green run / blue clean / grey stopped / yellow waiting is the house
/// vocabulary — see `HmiStateColors`. Never `Colors.*`. Unreadable is grey
/// too and is told apart by its glyph, not its colour.
Color sectionModeColor(BuildContext context, SectionMode mode) {
  final states = HmiStateColors.of(context);
  switch (mode) {
    case SectionMode.running:
      return states.green;
    case SectionMode.cleaning:
      return states.blue;
    case SectionMode.stopped:
      return states.grey;
    case SectionMode.blocked:
      return states.yellow;
    case SectionMode.unknown:
      // Grey, like every other unreadable face in the app. What separates it
      // from a stopped section is the exclamation mark the painter puts on it
      // in place of the power glyph, not the colour.
      return states.grey;
  }
}

/// How "live" a mode is, used to pick the two colours of a split face.
///
/// Only the extremes are shown when a group disagrees, so this ordering is
/// what decides them: the busiest state present takes the top-left half and
/// the quietest takes the bottom-right. Running outranks cleaning because a
/// line in auto is the one carrying product; unknown sits at the bottom
/// because a section that cannot be read is the least safe thing to assume
/// anything about.
int sectionActivityRank(SectionMode mode) {
  switch (mode) {
    case SectionMode.running:
      return 3;
    case SectionMode.cleaning:
      return 2;
    case SectionMode.blocked:
      return 1;
    case SectionMode.stopped:
      return 0;
    case SectionMode.unknown:
      return -1;
  }
}

/// The state of every section behind one button, reduced to what the face has
/// to paint and the pane has to say.
@immutable
class SectionGroup {
  /// One entry per configured section, in configuration order.
  final List<SectionMode> modes;

  const SectionGroup(this.modes);

  /// True when the sections are not all in the same mode.
  ///
  /// This is the whole reason a group button needs more than one colour: an
  /// operator who sees a solid green button and walks away has been told the
  /// line is running, and with three sections behind that button it may be
  /// one of them that is.
  bool get mixed => modes.toSet().length > 1;

  /// The single mode when they all agree. Meaningless while [mixed]; the face
  /// and the chip use [busiest] and [quietest] there instead.
  SectionMode get agreed =>
      modes.isEmpty ? SectionMode.unknown : modes.first;

  /// Liveliest mode present — the top-left half of a split face.
  SectionMode get busiest => modes.isEmpty
      ? SectionMode.unknown
      : modes.reduce(
          (a, b) => sectionActivityRank(a) >= sectionActivityRank(b) ? a : b);

  /// Quietest mode present — the bottom-right half of a split face.
  SectionMode get quietest => modes.isEmpty
      ? SectionMode.unknown
      : modes.reduce(
          (a, b) => sectionActivityRank(a) <= sectionActivityRank(b) ? a : b);

  /// Any section the HMI cannot read. The face wears a `!` whenever this is
  /// true, even when the readable members agree — a button speaking for three
  /// sections that can only see two must say so.
  bool get anyUnreadable => modes.contains(SectionMode.unknown);

  /// How many sections are in [mode].
  int count(SectionMode mode) => modes.where((m) => m == mode).length;

  /// How many are moving, in either mode.
  int get movingCount =>
      count(SectionMode.running) + count(SectionMode.cleaning);

  /// The word the pane puts on the State tile.
  String get label => mixed ? 'Mixed' : agreed.label;
}

/// The header chip for a group.
///
/// The named [PaneStatus] constructors carry running, stopped and unknown, so
/// those keep the exact chip an operator sees on a conveyor or a lift.
///
/// The others have no house equivalent and take the theme's own colours,
/// which is also what the face and the buttons use, so the whole pane says one
/// thing at a time: cleaning is blue, a section waiting on its go-ahead is
/// yellow, and a group that disagrees with itself takes the busiest colour it
/// contains. None of them may borrow `PaneStatus.running` (green says "yes,
/// now") or `PaneStatus.fault` (red says something is wrong).
PaneStatus sectionGroupStatus(BuildContext context, SectionGroup group) {
  if (group.mixed) {
    return PaneStatus(
      label: 'Mixed',
      color: sectionModeColor(context, group.busiest),
      icon: Icons.contrast,
    );
  }
  switch (group.agreed) {
    case SectionMode.running:
      return const PaneStatus.running();
    case SectionMode.cleaning:
      return PaneStatus(
        label: 'Cleaning',
        color: HmiStateColors.of(context).blue,
        icon: Icons.water_drop,
      );
    case SectionMode.stopped:
      return const PaneStatus.stopped();
    case SectionMode.blocked:
      return PaneStatus(
        label: "Can't start",
        color: HmiStateColors.of(context).yellow,
        icon: Icons.lock_outline,
      );
    case SectionMode.unknown:
      return const PaneStatus.unknown("Can't read");
  }
}

/// Whether `p_cmd_Start` does what a `Run` button says it does.
///
/// It is a toggle in the PLC, so offering it to a section that is already
/// running would stop the line — the opposite of the label. It is also a
/// no-op without the go-ahead, and meaningless while the state is unknown.
bool canStart(SectionMode mode) =>
    mode == SectionMode.stopped || mode == SectionMode.cleaning;

/// Whether `p_cmd_StartClean` does what a `Clean` button says it does.
/// Same toggle reasoning as [canStart].
bool canClean(SectionMode mode) =>
    mode == SectionMode.stopped || mode == SectionMode.running;

/// Whether `p_cmd_Stop` is worth offering. It is not a toggle and it is not
/// gated by the go-ahead, so it is available whenever the state is known —
/// including from `Stopped`, where an operator pressing it wants the
/// reassurance more than the state change.
bool canStop(SectionMode mode) => mode != SectionMode.unknown;

/// The guard for one `p_cmd_*` member, so the fan-out can ask per section.
bool canSend(String field, SectionMode mode) {
  switch (field) {
    case kSectionCmdStart:
      return canStart(mode);
    case kSectionCmdStartClean:
      return canClean(mode);
    case kSectionCmdStop:
      return canStop(mode);
  }
  return false;
}

// ---------------------------------------------------------------------------
// Mutually exclusive sections
//
// Two sections on this plant are not peers, they are alternatives. ST201 and
// ST301 wire their two box-packing modes as mutual exclusion in MAIN:
//
//   section.boxPackingFilm  (i_xPermissive := NOT section.boxPackingVacuum.q_xEnabled);
//   section.boxPackingVacuum(i_xPermissive := NOT section.boxPackingFilm.q_xEnabled);
//
// so exactly one of them can be in auto at a time, by construction. A button
// driving both was therefore PERMANENTLY split, and a split that is always
// there stops meaning "something is wrong" — it means "everything is normal",
// which destroys the signal for every other button too.
//
// The HMI cannot infer this. The exclusion lives in ladder it never sees, and
// `p_stat_xPermissive` reports only the result — an idle section with no
// go-ahead looks identical whether its twin has the line or an upstream
// interlock has failed. So it is declared in config, on the section itself:
// [SectionRef.exclusiveGroup].
//
// Two facts about that ladder shape the code below, and both come from
// `FB_Section` itself rather than from a guess:
//
//   * The permissive keys off `q_xEnabled` ONLY, so cleaning is NOT exclusive.
//     Both modes may clean at once, and a section held off while its twin is
//     merely cleaning is NOT explained by the exclusion.
//   * Two members in auto at once is impossible while the interlock holds, so
//     seeing it means the interlock is not doing its job. The pane says so;
//     the face cannot, because two sections in the same mode is agreement and
//     there is no seam to draw.
// ---------------------------------------------------------------------------

/// A declared set of sections that cannot run at the same time as each other.
///
/// [name] is the operator's word for the choice ("Line 2 packing"): it is the
/// tag typed into the editor, and it titles the choice in the pane. [members]
/// are indices into the button's usable sections.
@immutable
class ExclusiveSet {
  final String name;
  final List<int> members;

  const ExclusiveSet({required this.name, required this.members});

  @override
  bool operator ==(Object other) =>
      other is ExclusiveSet &&
      other.name == name &&
      _sameInts(other.members, members);

  @override
  int get hashCode => Object.hash(name, Object.hashAll(members));

  @override
  String toString() => 'ExclusiveSet($name, $members)';
}

bool _sameInts(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The exclusive sets [refs] declares, in the order their first member is
/// configured.
///
/// A tag on its own is not a set: one section has no alternative, so it is a
/// plain peer and everything below leaves it alone. Tags are matched on their
/// trimmed text, so a stray space typed into the editor does not silently
/// split a pair into two singletons.
List<ExclusiveSet> exclusiveSetsOf(List<SectionRef> refs) {
  final order = <String>[];
  final byTag = <String, List<int>>{};
  for (var i = 0; i < refs.length; i++) {
    final tag = refs[i].exclusiveGroup?.trim() ?? '';
    if (tag.isEmpty) continue;
    if (!byTag.containsKey(tag)) order.add(tag);
    byTag.putIfAbsent(tag, () => <int>[]).add(i);
  }
  return [
    for (final tag in order)
      if (byTag[tag]!.length > 1)
        ExclusiveSet(name: tag, members: List.unmodifiable(byTag[tag]!)),
  ];
}

/// The one mode an exclusive set is in, or null when it has to be shown member
/// by member after all.
///
/// Returning a mode is what stops a working interlock reading as disagreement.
/// Returning null is the escape hatch: a member nobody can read leaves the
/// set's state unknown, and a set that collapsed to the readable member's
/// colour would be claiming to know it. Those members then flow through
/// individually and the face splits, exactly as it did before exclusivity
/// existed.
///
/// Otherwise: the mode that has the line, or `Stopped` when none has. A member
/// held off while nothing in the set is running is NOT explained by the
/// exclusion (the permissive keys off `q_xEnabled`, and nothing here has it),
/// so that stays yellow — an unexplained hold is news.
///
/// Two members in auto at once cannot happen while the ladder holds, and if it
/// is ever seen this still answers `Running`, because they ARE both running.
/// There is no seam to draw for two sections in the same mode, so the place
/// that reports a failed interlock is the pane, not the face.
SectionMode? reduceExclusiveSet(List<SectionMode> members) {
  if (members.length < 2) return null;
  if (members.contains(SectionMode.unknown)) return null;

  final active = [
    for (final m in members)
      if (m == SectionMode.running || m == SectionMode.cleaning) m,
  ];
  if (active.isNotEmpty) {
    // Running outranks cleaning: a set with one mode in auto and the other
    // washing down is carrying product, and that is what the face must say.
    return active.reduce(
        (a, b) => sectionActivityRank(a) >= sectionActivityRank(b) ? a : b);
  }
  return members.contains(SectionMode.blocked)
      ? SectionMode.blocked
      : SectionMode.stopped;
}

/// The modes the face compares, with every well-behaved exclusive set counted
/// as the one thing it is.
///
/// Peers are passed straight through, so a button driving only peers gets back
/// exactly what it gave — the non-exclusive case cannot change. Each set is
/// emitted at the position of its first member so the result is stable, and a
/// set that does not reduce contributes all of its members and therefore still
/// splits the face.
List<SectionMode> resolveFaceModes(
  List<SectionMode> modes,
  List<ExclusiveSet> sets,
) {
  if (sets.isEmpty) return modes;
  final setOf = <int, ExclusiveSet>{};
  for (final s in sets) {
    for (final i in s.members) {
      setOf[i] = s;
    }
  }
  final out = <SectionMode>[];
  final done = <ExclusiveSet>{};
  for (var i = 0; i < modes.length; i++) {
    final set = setOf[i];
    if (set == null) {
      out.add(modes[i]);
      continue;
    }
    if (!done.add(set)) continue;
    final members = [
      for (final m in set.members)
        if (m < modes.length) modes[m],
    ];
    final reduced = reduceExclusiveSet(members);
    if (reduced != null) {
      out.add(reduced);
    } else {
      out.addAll(members);
    }
  }
  return out;
}

/// Whether the section at [index] is held off by an alternative that has the
/// line — the ordinary, working case of the interlock.
///
/// Only auto counts, because auto is the only thing the ladder negates. A
/// section held while its twin is merely cleaning is held by something else,
/// and the pane must go on reporting that as an anomaly.
bool heldByAlternative(
  int index,
  List<SectionMode> modes,
  List<ExclusiveSet> sets,
) {
  if (index >= modes.length || modes[index] != SectionMode.blocked) {
    return false;
  }
  for (final set in sets) {
    if (!set.members.contains(index)) continue;
    for (final other in set.members) {
      if (other == index || other >= modes.length) continue;
      if (modes[other] == SectionMode.running) return true;
    }
  }
  return false;
}

/// Whether the section at [index] is one alternative of a declared set.
bool inExclusiveSet(int index, List<ExclusiveSet> sets) =>
    sets.any((s) => s.members.contains(index));

/// Whether the group's `Run all` has anything to write.
///
/// It never starts an alternative: two `p_cmd_Start`s landing in one PLC scan
/// both pass `AND i_xPermissive` (computed from the previous scan), so both
/// modes latch on, and the scan after that each one's permissive reads FALSE
/// and `FB_Section` drops BOTH. A group button that stopped the line it was
/// pressed to start is worse than one that leaves the choice to the chooser.
/// With no sets declared this is exactly `modes.any(canStart)`, which is what
/// the pane asked before.
bool groupStartable(List<SectionMode> modes, List<ExclusiveSet> sets) {
  for (var i = 0; i < modes.length; i++) {
    if (!canStart(modes[i])) continue;
    if (inExclusiveSet(i, sets)) continue;
    return true;
  }
  return false;
}

/// A mode switch, as the sequence of `p_cmd_*` writes it is made of.
///
/// There is no PLC command for "select this mode" — `ST_Section_HMI` offers
/// `p_cmd_Start`, `p_cmd_Stop` and `p_cmd_StartClean`, and nothing else — so a
/// switch is composed: stop whatever has the line, wait for the PLC to hand
/// the go-ahead over, then start the chosen one. [stop] may be empty, which is
/// the case where nothing has the line and this is a plain start.
@immutable
class SectionSwitchPlan {
  /// Members that have to give the line up first, by ref index.
  final List<int> stop;

  /// The member to start once they have, by ref index.
  final int start;

  const SectionSwitchPlan({required this.stop, required this.start});

  /// True when this is a genuine hand-over rather than a plain start — the
  /// case that stops running machinery and therefore has to be confirmed.
  bool get isHandover => stop.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is SectionSwitchPlan &&
      other.start == start &&
      _sameInts(other.stop, stop);

  @override
  int get hashCode => Object.hash(start, Object.hashAll(stop));

  @override
  String toString() => 'SectionSwitchPlan(stop: $stop, start: $start)';
}

/// How to put [target] in charge of its exclusive [set], or null when there is
/// no honest way to.
///
/// Null every time the HMI would be guessing:
///
///   * [target] already has the line — there is nothing to do, and
///     `p_cmd_Start` is a TOGGLE, so "doing it anyway" would stop it.
///   * any member of the set is unreadable — a switch that stops a section
///     nobody can see the state of is a switch made blind.
///   * [target] is held off and no member of the set is running — the
///     exclusion is not what holds it, so stopping its alternatives would
///     stop the line and still not let it start.
SectionSwitchPlan? planModeSwitch({
  required List<SectionMode> modes,
  required ExclusiveSet set,
  required int target,
}) {
  if (!set.members.contains(target)) return null;
  for (final i in set.members) {
    if (i >= modes.length || modes[i] == SectionMode.unknown) return null;
  }
  final targetMode = modes[target];
  if (targetMode == SectionMode.running || targetMode == SectionMode.cleaning) {
    return null;
  }
  if (targetMode == SectionMode.blocked &&
      !set.members.any((i) => i != target && modes[i] == SectionMode.running)) {
    // Held by something outside the set. Stopping the alternatives would cost
    // the line and buy nothing.
    return null;
  }
  return SectionSwitchPlan(
    stop: [
      for (final i in set.members)
        if (i != target &&
            (modes[i] == SectionMode.running ||
                modes[i] == SectionMode.cleaning))
          i,
    ],
    start: target,
  );
}

/// How far a mode switch got.
///
/// Every value except [done] leaves the line stopped rather than half
/// switched, because stopped is the state this asset is allowed to reach
/// without being sure — and the pane says which one happened rather than
/// falling silent, since a hand-over that quietly did half its job is
/// indistinguishable from machinery that refused to start.
enum SectionSwitchOutcome {
  /// The chosen mode was started.
  done,

  /// Nothing was written: the plan did not survive a second look, or the
  /// hand-over is not enabled on this button.
  notOffered,

  /// The alternatives were stopped, and the PLC did not hand the go-ahead
  /// over before the wait ran out, so nothing was started.
  notHandedOver,

  /// A write did not reach the PLC. Whatever had the line may still have it.
  writeFailed,
}

/// How long the HMI waits for the PLC to hand the go-ahead over mid-switch.
///
/// The interlock is combinational — `i_xPermissive` is recomputed from the
/// other section's `q_xEnabled` in the same MAIN, so it flips the scan after
/// the stop lands. Seconds of margin covers the OPC UA round trip and a
/// station under load; anything longer and an operator watching a stopped line
/// has already reached for the buttons themselves.
const Duration kSectionSwitchTimeout = Duration(seconds: 3);

// ---------------------------------------------------------------------------
// Asset config
// ---------------------------------------------------------------------------

/// One `FB_Section` instance behind a button.
@JsonSerializable(explicitToJson: true)
class SectionRef {
  /// The `HMI` member of an `FB_Section` instance — one structured node
  /// carrying all three commands and all three status bits.
  String key;

  /// What this member is called in the pane's section list, e.g. `ST101`.
  /// Falls back to the tail of [key].
  String? label;

  /// What holds this section back, in the operator's words.
  ///
  /// Per section because the answer is: `boxPackingFilm` is held by
  /// `boxPackingVacuum` and vice versa, while the freezer sections are wired
  /// to have the go-ahead permanently so losing it means something upstream
  /// broke. Text inside a generic asset cannot know which of those it is, and
  /// a confident wrong instruction on a machine pane is worse than none.
  String? holdReason;

  /// Names a set of sections that are ALTERNATIVES rather than peers: only one
  /// of them can run at a time, and the PLC is what enforces it.
  ///
  /// Declared rather than derived, because the HMI has no way to derive it.
  /// The exclusion is a line of ST in `MAIN` (`i_xPermissive := NOT other.
  /// q_xEnabled`) that never reaches the wire; all the HMI can read is
  /// `p_stat_xPermissive`, which says a section may not start and not why.
  ///
  /// A tag on the section rather than a list of sets on the button, for two
  /// reasons an editor cares about: it is one field on the row already being
  /// edited, and deleting or reordering a section cannot leave a set pointing
  /// at one that is gone. Sections sharing a tag are alternatives; a blank tag
  /// is a plain peer, which is every section saved before this field existed.
  ///
  /// The text is the operator's name for the choice — it heads the choice in
  /// the pane — so use a distinct one per line: `Line 2 packing`, not
  /// `packing` on all four of ST201's and ST301's modes, which would declare
  /// that starting film on line 2 holds off film on line 3.
  String? exclusiveGroup;

  SectionRef({
    required this.key,
    this.label,
    this.holdReason,
    this.exclusiveGroup,
  });

  /// The name to show for this member.
  String get displayLabel {
    final l = label?.trim();
    if (l != null && l.isNotEmpty) return l;
    final k = key.trim();
    if (k.isEmpty) return 'Section';
    final parts = k.split(RegExp(r'[./]')).where((p) => p.isNotEmpty);
    return parts.isEmpty ? k : parts.last;
  }

  factory SectionRef.fromJson(Map<String, dynamic> json) =>
      _$SectionRefFromJson(json);
  Map<String, dynamic> toJson() => _$SectionRefToJson(this);
}

/// A power button for one or more sections of the plant.
///
/// The face is the IEC 5009 power symbol on a disc in the section's state
/// colour, so a wall of sections reads as a row of coloured lamps from across
/// the hall. Tapping opens the pane that starts, cleans and stops them — the
/// button itself never writes, because a section is a whole line of machinery
/// and starting one on a stray touch of a touchscreen is not acceptable.
///
/// More than one section may sit behind one button: `beforeFreezers` exists
/// separately on ST101, ST201 and ST301 and is one line to the operator who
/// has to start it. When those disagree the face splits along a diagonal
/// rather than picking a single colour — a solid green button meaning "one of
/// the three is running" is the kind of thing somebody walks away from.
@JsonSerializable(explicitToJson: true)
class SectionButtonConfig extends BaseAsset {
  @override
  String get displayName => 'Section Button';
  @override
  String get category => 'Interactive Controls';

  @override
  List<String> get searchKeywords =>
      const ['section', 'power', 'line', 'start', 'stop', 'clean', 'auto'];

  /// The sections this button drives, in the order the pane lists them.
  @JsonKey(defaultValue: <SectionRef>[])
  List<SectionRef> sections;

  /// Legacy home of the button's name, read from pages saved before it moved
  /// to the asset's own [text].
  ///
  /// It titled the pane and nothing else, which left the name on the mimic —
  /// the one an operator actually reads — with no field in the form at all.
  /// Read on load, migrated into [text] by [fromJson], and never written
  /// back, so a page saved once is rid of it.
  @JsonKey(includeToJson: false)
  String? label;

  /// Whether the name is drawn beside the button on the page.
  ///
  /// The name is two things at once — the caption on the mimic and the title
  /// of the pane the button opens — so clearing it to get a bare face would
  /// also leave the pane titled "Section". This is the switch that separates
  /// them: off, the mimic shows only the button and the name lives on in the
  /// pane. True by default, and absent from pages saved before it existed, so
  /// every button that has a caption today keeps it.
  @JsonKey(name: 'show_name', defaultValue: true)
  bool showName = true;

  /// Whether the pane may hand the line from one alternative to the other in
  /// one press — stop the mode that has it, wait for the PLC to hand the
  /// go-ahead over, then start the chosen one.
  ///
  /// **Off by default, and deliberately.** It is the one control on this asset
  /// that starts machinery, and it is composed of two commands rather than
  /// asked of one, so it is opt-in per button: a page saved before it existed,
  /// or by anyone who has not thought about it, gets the choice presented and
  /// the hand-over withheld. With it off the chooser still offers a plain
  /// start of an alternative that is already free — that is not a hand-over,
  /// it is the `Run` this pane always had.
  @JsonKey(name: 'allow_mode_switch', defaultValue: false)
  bool allowModeSwitch = false;

  SectionButtonConfig({
    List<SectionRef>? sections,
    this.label,
    this.showName = true,
    this.allowModeSwitch = false,
  }) : sections = sections ?? <SectionRef>[];

  SectionButtonConfig.preview() : sections = <SectionRef>[] {
    size = const RelativeSize(width: 0.05, height: 0.05);
    text = 'Section';
    textPos = TextPos.below;
  }

  /// What the operator calls this button ("Before freezers") — the label on
  /// the mimic and the title of the pane, which are one name and were never
  /// worth two fields. Falls back to the first section's own name so a button
  /// nobody has named still says which line it drives.
  @JsonKey(includeFromJson: false, includeToJson: false)
  String get name {
    final t = text?.trim();
    if (t != null && t.isNotEmpty) return t;
    final l = label?.trim();
    if (l != null && l.isNotEmpty) return l;
    for (final s in sections) {
      if (s.key.trim().isNotEmpty) return s.displayLabel;
    }
    return 'Section';
  }

  /// Keys live inside [sections], which the base class's JSON introspection
  /// cannot see — without this override the asset reports using no keys at
  /// all, and anything asking which keys a page depends on (unused-key
  /// cleanup, for one) would be told they are free to delete.
  /// The page paints the caption only when [showName] is on. The pane's
  /// title comes from [name] either way — hiding the caption does not
  /// un-name the button.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  bool get showLabel => showName;

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<String> get allKeys => [
        for (final s in sections)
          if (s.key.trim().isNotEmpty) s.key.trim(),
      ];

  factory SectionButtonConfig.fromJson(Map<String, dynamic> json) {
    final config = _$SectionButtonConfigFromJson(json);
    // Migration, not a fallback: a page saved before the name moved to [text]
    // has it in `label`, and leaving it there would mean the button on the
    // mimic silently lost its caption the day the form gained the field.
    final text = config.text?.trim();
    final legacy = config.label?.trim();
    if ((text == null || text.isEmpty) && legacy != null && legacy.isNotEmpty) {
      config.text = legacy;
      config.textPos ??= TextPos.below;
    }
    return config;
  }
  @override
  Map<String, dynamic> toJson() => _$SectionButtonConfigToJson(this);

  @override
  Widget build(BuildContext context) => SectionButton(config: this);

  @override
  Widget configure(BuildContext context) =>
      _SectionButtonConfigEditor(config: this);
}

class _SectionButtonConfigEditor extends StatefulWidget {
  final SectionButtonConfig config;
  const _SectionButtonConfigEditor({required this.config});

  @override
  State<_SectionButtonConfigEditor> createState() =>
      _SectionButtonConfigEditorState();
}

class _SectionButtonConfigEditorState
    extends State<_SectionButtonConfigEditor> {
  @override
  Widget build(BuildContext context) {
    final sections = widget.config.sections;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            key: const Key('section-name'),
            initialValue: widget.config.text,
            decoration: const InputDecoration(
              labelText: 'Button name',
              helperText: 'Titles the pane, and labels the button on the page '
                  'unless that is switched off below, e.g. Before freezers',
            ),
            onChanged: (v) => setState(() {
              widget.config.text = v;
              // A name typed into a button that has never had one would
              // otherwise be stored and not drawn: `page_view` paints nothing
              // without a position. `below` is where the editor puts every
              // other newly-labelled asset.
              widget.config.textPos ??= TextPos.below;
            }),
          ),
          SwitchListTile(
            key: const Key('section-name-visible'),
            contentPadding: EdgeInsets.zero,
            value: widget.config.showName,
            title: const Text('Show the name on the page'),
            subtitle: const Text(
              'Off leaves a bare button on the mimic. The pane it opens is '
              'still titled with the name.',
            ),
            onChanged: (v) => setState(() => widget.config.showName = v),
          ),
          // No position to choose when there is nothing to place.
          if (widget.config.showName) ...[
            const SizedBox(height: 16),
            DropdownButton<TextPos>(
              key: const Key('section-name-position'),
              value: widget.config.textPos ?? TextPos.below,
              isExpanded: true,
              onChanged: (value) =>
                  setState(() => widget.config.textPos = value!),
              items: TextPos.values
                  .map((e) => DropdownMenuItem<TextPos>(
                        value: e,
                        child: Text('Name ${e.name}'),
                      ))
                  .toList(),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Text('Sections', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                key: const Key('section-add'),
                onPressed: () =>
                    setState(() => sections.add(SectionRef(key: ''))),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add section'),
              ),
            ],
          ),
          if (sections.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No sections yet. Add one per FB_Section instance this button '
                'should drive — the same line on ST101, ST201 and ST301 can '
                'share one button.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          for (var i = 0; i < sections.length; i++)
            _SectionRefEditor(
              key: ObjectKey(sections[i]),
              entry: sections[i],
              index: i,
              onRemove: () => setState(() => sections.removeAt(i)),
              onChanged: () => setState(() {}),
            ),
          // Only once a set actually exists. A switch offering to hand a line
          // over on a button that drives nothing but peers is a question with
          // no subject, and this one starts machinery — it should appear the
          // moment it means something and not before.
          if (exclusiveSetsOf(sections).isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Choices: ${exclusiveSetsOf(sections).map((s) => s.name).join(', ')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            SwitchListTile(
              key: const Key('section-allow-mode-switch'),
              contentPadding: EdgeInsets.zero,
              value: widget.config.allowModeSwitch,
              title: const Text('Allow switching between alternatives'),
              subtitle: const Text(
                'Lets one press stop the mode that has the line and start the '
                'other, after a confirmation naming both. Off, the operator '
                'stops one and starts the other themselves.',
              ),
              onChanged: (v) =>
                  setState(() => widget.config.allowModeSwitch = v),
            ),
          ],
          const SizedBox(height: 16),
          SizeField(
            initialValue: widget.config.size,
            onChanged: (size) => setState(() => widget.config.size = size),
          ),
          const SizedBox(height: 16),
          CoordinatesField(
            initialValue: widget.config.coordinates,
            onChanged: (v) => setState(() => widget.config.coordinates = v),
          ),
        ],
      ),
    );
  }
}

class _SectionRefEditor extends StatelessWidget {
  final SectionRef entry;
  final int index;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  const _SectionRefEditor({
    super.key,
    required this.entry,
    required this.index,
    required this.onRemove,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text('Section ${index + 1}',
                    style: Theme.of(context).textTheme.labelLarge),
                const Spacer(),
                IconButton(
                  tooltip: 'Remove',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
              ],
            ),
            KeyField(
              label: 'Section HMI key',
              initialValue: entry.key,
              onChanged: (v) {
                entry.key = v;
                onChanged();
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: entry.label,
              decoration: const InputDecoration(
                labelText: 'Shown as',
                helperText: 'Name in the pane list, e.g. ST101',
              ),
              onChanged: (v) => entry.label = v,
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: entry.holdReason,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                labelText: "Why it can't start",
                alignLabelWithHint: true,
                helperMaxLines: 3,
                helperText: 'Shown behind "Allowed to start". Name what holds '
                    'this section, in operator words — e.g. "The vacuum mode '
                    'has the line. Stop it and this one is free."',
              ),
              onChanged: (v) => entry.holdReason = v,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: Key('section-$index-exclusive'),
              initialValue: entry.exclusiveGroup,
              decoration: const InputDecoration(
                labelText: 'Alternative to (choice name)',
                helperMaxLines: 4,
                helperText: 'Leave blank for a normal section. Give the same '
                    'name to sections that CANNOT run at the same time as '
                    'each other — the PLC allows only one — and the pane '
                    'shows them as one choice under this name. One name per '
                    'line, e.g. "Line 2 packing".',
              ),
              onChanged: (v) {
                entry.exclusiveGroup = v;
                onChanged();
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The button on the mimic
// ---------------------------------------------------------------------------

class SectionButton extends ConsumerStatefulWidget {
  final SectionButtonConfig config;
  const SectionButton({super.key, required this.config});

  @override
  ConsumerState<SectionButton> createState() => _SectionButtonState();
}

class _SectionButtonState extends ConsumerState<SectionButton> {
  static final _log = Logger();

  /// Whether the face is held down, so it wears the same shrink-and-tighten
  /// as every other button on a mimic. Local: this button writes nothing, so
  /// there is no PLC state to reflect here.
  bool _isPressed = false;

  void _setPressed(bool value) {
    if (_isPressed == value) return;
    setState(() => _isPressed = value);
  }

  /// Cache so the combined stream is not rebuilt — and every section
  /// re-subscribed — on each frame.
  List<Stream<DynamicValue>>? _sources;
  Stream<List<DynamicValue?>>? _combined;

  /// The configured sections that actually name a node.
  List<SectionRef> get _refs => [
        for (final s in widget.config.sections)
          if (s.key.trim().isNotEmpty) s,
      ];

  String get _paneId => 'section:${identityHashCode(widget.config)}';

  String get _title => widget.config.name;

  /// One shared stream per key, combined into a single list that fires as soon
  /// as any member updates.
  ///
  /// Each source is seeded with `null` so the combined stream produces before
  /// every section has reported — a group with one slow PLC must still show
  /// the others rather than sitting blank until the last one arrives.
  Stream<List<DynamicValue?>> _combinedFor(List<Stream<DynamicValue>> sources) {
    final cached = _combined;
    final previous = _sources;
    if (cached != null &&
        previous != null &&
        previous.length == sources.length) {
      var same = true;
      for (var i = 0; i < sources.length; i++) {
        if (!identical(previous[i], sources[i])) {
          same = false;
          break;
        }
      }
      if (same) return cached;
    }
    _sources = sources;
    if (sources.isEmpty) {
      return _combined = Stream.value(const <DynamicValue?>[]);
    }
    // Shared with a one-event replay, not a plain combineLatest: the face
    // and the open pane both listen, and a combined stream is
    // single-subscription — the second listener threw
    // "Stream has already been listened to" and the pane never rendered.
    // The replay is what lets the pane come up already showing the sections
    // instead of blank until the next PLC update.
    return _combined = Rx.combineLatestList<DynamicValue?>(
      sources.map((s) => s.cast<DynamicValue?>().startWith(null)),
    ).shareReplay(maxSize: 1);
  }

  /// Reads one section's mode out of its latest struct value.
  static SectionMode _modeOf(DynamicValue? value) {
    if (value == null) return SectionMode.unknown;
    return resolveSectionMode(
      enabled: _boolOrNull(value, kSectionStatEnabled),
      cleanEnabled: _boolOrNull(value, kSectionStatCleanEnabled),
      permissive: _boolOrNull(value, kSectionStatPermissive),
    );
  }

  /// Fans [field] out to every section that can accept it.
  ///
  /// The per-section guard is the point. `p_cmd_Start` toggles, so a blind
  /// broadcast to a half-running group would start the stopped members and
  /// stop the running ones — one press leaving the line exactly as it was,
  /// inverted. Sections that cannot take the command are skipped silently;
  /// the button was only offered because at least one could.
  ///
  /// `p_cmd_Start` is additionally never fanned out to a member of an
  /// exclusive set — see [groupStartable]. Two starts arriving in one PLC
  /// scan both pass `AND i_xPermissive`, which is computed from the previous
  /// scan, so both modes latch on; the scan after that each one's permissive
  /// reads FALSE and `FB_Section` drops BOTH. `Run all` would stop the line it
  /// was pressed to start. Which alternative the operator wanted is not
  /// something a group button can know, so it leaves them to the chooser.
  Future<void> _send(
    List<SectionRef> refs,
    List<DynamicValue?> values,
    String field,
  ) async {
    final sets = exclusiveSetsOf(refs);
    final stateMan = await ref.read(stateManProvider.future);
    for (var i = 0; i < refs.length; i++) {
      final current = i < values.length ? values[i] : null;
      if (current == null) continue;
      if (!canSend(field, _modeOf(current))) continue;
      if (field == kSectionCmdStart && inExclusiveSet(i, sets)) continue;
      // Copy-on-write of the whole struct with the one command bit set — the
      // same shape every structured-node write in this repo uses. The FB
      // clears the bit itself, so there is no release write to pair with this.
      final next = DynamicValue.from(current);
      next[field] = true;
      try {
        // `field` is the member: a section struct carries the status bits an
        // operator has to keep reading, so a template locking `p_cmd_Start`
        // must not lock the reading of `p_stat_xEnabled` beside it.
        //
        // Per section, and deliberately: the sections in a group can be bound
        // to different templates, so one refused member does not make the
        // press a no-op for the others. That matches the mode guard directly
        // above it, which is also per section.
        await writeTag(ref, stateMan, refs[i].key.trim(), next, member: field);
      } catch (e, st) {
        // A command that silently fails to reach the PLC is indistinguishable
        // from a section that refused to start.
        _log.e('section ${refs[i].key}: writing $field failed',
            error: e, stackTrace: st);
      }
    }
  }

  /// Sends [field] to one member only.
  ///
  /// Same guard as the fan-out, asked of that one section: a `Run` on a row
  /// whose section is already running would stop it, so the button is dead
  /// there and this is the belt-and-braces behind it.
  Future<void> _sendOne(
    List<SectionRef> refs,
    List<DynamicValue?> values,
    int index,
    String field,
  ) async {
    if (index < 0 || index >= refs.length) return;
    final current = index < values.length ? values[index] : null;
    if (current == null) return;
    if (!canSend(field, _modeOf(current))) return;
    final stateMan = await ref.read(stateManProvider.future);
    final next = DynamicValue.from(current);
    next[field] = true;
    try {
      // The member again, same argument as the fan-out.
      await writeTag(ref, stateMan, refs[index].key.trim(), next,
          member: field);
    } catch (e, st) {
      _log.e('section ${refs[index].key}: writing $field failed',
          error: e, stackTrace: st);
    }
  }

  /// Waits for the PLC to say the line has changed hands: everything in
  /// [SectionSwitchPlan.stop] idle, and [target] `Stopped` — which is idle AND
  /// permitted, exactly the condition `p_cmd_Start` needs to be obeyed.
  ///
  /// Returns the values it saw, or null if [kSectionSwitchTimeout] passes
  /// first.
  ///
  /// Hand-rolled rather than `stream.firstWhere(...).timeout(...)`, which
  /// deadlocks here: `firstWhere` completes its future inside
  /// `subscription.cancel().whenComplete(...)`, and cancelling a subscription
  /// to a ref-counted shared stream does not complete under `fake_async` —
  /// the wait then always ran to the timeout and the switch never sent its
  /// start. Same trap as awaiting a cancel anywhere else in this repo: the
  /// completer is finished FIRST and the cancel is never awaited.
  Future<List<DynamicValue?>?> _awaitHandover(
    Stream<List<DynamicValue?>> stream,
    SectionSwitchPlan plan,
    int target,
  ) async {
    bool handedOver(List<DynamicValue?> vs) {
      for (final i in plan.stop) {
        final m = i < vs.length ? _modeOf(vs[i]) : SectionMode.unknown;
        if (m != SectionMode.stopped && m != SectionMode.blocked) return false;
      }
      final t = target < vs.length ? _modeOf(vs[target]) : null;
      return t == SectionMode.stopped;
    }

    final done = Completer<List<DynamicValue?>?>();
    final sub = stream.listen(
      (vs) {
        if (!done.isCompleted && handedOver(vs)) done.complete(vs);
      },
      onError: (_) {
        if (!done.isCompleted) done.complete(null);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(null);
      },
    );
    final timer = Timer(kSectionSwitchTimeout, () {
      if (!done.isCompleted) done.complete(null);
    });
    try {
      return await done.future;
    } finally {
      timer.cancel();
      // Fire-and-forget, but with a handler: `unawaited` attaches none, and a
      // cancel that throws on a torn-down shared stream would surface as an
      // unhandled async error in a test or the log rather than here.
      unawaited(sub.cancel().catchError((Object _) {}));
    }
  }

  /// Hands the line from whatever holds it to [target], composed out of the
  /// only three commands `ST_Section_HMI` has.
  ///
  /// Stop the alternatives, WAIT for the PLC to confirm it has handed the
  /// go-ahead over, then start the chosen one. The wait is the whole point:
  /// `FB_Section` gates both start commands behind `AND i_xPermissive`, so a
  /// start fired before the interlock releases is not refused, not reported
  /// and not queued — it is simply gone, and the operator is left looking at a
  /// line that stopped and did not restart, with no idea a command was even
  /// sent. Sending it late is the difference between a switch and a stop.
  ///
  /// Every failure stops short rather than pressing on, so the worst outcome
  /// is a stopped line — which is the state this asset may reach without
  /// being sure of anything.
  Future<SectionSwitchOutcome> _switchMode(
    List<SectionRef> refs,
    List<DynamicValue?> values,
    int target,
  ) async {
    final sets = exclusiveSetsOf(refs);
    ExclusiveSet? set;
    for (final s in sets) {
      if (s.members.contains(target)) set = s;
    }
    if (set == null) return SectionSwitchOutcome.notOffered;

    final modes = [for (final v in values) _modeOf(v)];
    final plan = planModeSwitch(modes: modes, set: set, target: target);
    if (plan == null) return SectionSwitchOutcome.notOffered;
    // A hand-over starts machinery after stopping other machinery, so it is
    // opt-in on the asset. A plain start — nothing to stop — is the `Run` this
    // pane always had and is not gated by it.
    if (plan.isHandover && !widget.config.allowModeSwitch) {
      return SectionSwitchOutcome.notOffered;
    }

    final stateMan = await ref.read(stateManProvider.future);

    // Ask for the whole plan before any of it is written. Each leg is gated
    // again at its own write below, but a hand-over that stopped the
    // alternatives and was only then refused on the start would leave the
    // line stopped with nothing running -- worse than refusing outright.
    // Stopping at the first refusal keeps that to one denial row rather than
    // one per section, and `guardTagWrite` has already told the operator, so
    // `notOffered` returns quietly rather than stacking a second dialog on
    // top of the prompt.
    for (final i in plan.stop) {
      if (!await guardTagWrite(ref, refs[i].key.trim(),
          member: kSectionCmdStop, stateMan: stateMan)) {
        return SectionSwitchOutcome.notOffered;
      }
    }
    if (!await guardTagWrite(ref, refs[target].key.trim(),
        member: kSectionCmdStart, stateMan: stateMan)) {
      return SectionSwitchOutcome.notOffered;
    }

    Future<bool> write(int index, String field) async {
      final current = index < values.length ? values[index] : null;
      if (current == null) return false;
      final next = DynamicValue.from(current);
      next[field] = true;
      try {
        return await writeTag(ref, stateMan, refs[index].key.trim(), next,
            member: field);
      } catch (e, st) {
        _log.e('section ${refs[index].key}: writing $field failed',
            error: e, stackTrace: st);
        return false;
      }
    }

    for (final i in plan.stop) {
      if (!await write(i, kSectionCmdStop)) {
        return SectionSwitchOutcome.writeFailed;
      }
    }

    var latest = values;
    if (plan.isHandover) {
      final stream = _combined;
      if (stream == null) return SectionSwitchOutcome.notHandedOver;
      final handed = await _awaitHandover(stream, plan, target);
      if (handed == null) return SectionSwitchOutcome.notHandedOver;
      latest = handed;
    }

    // Re-ask the guard against what the PLC says NOW, not against the snapshot
    // this switch was planned from. `p_cmd_Start` toggles, and a section that
    // came up in the meantime — a physical button, another station — must not
    // be stopped by a command labelled Start.
    final current = target < latest.length ? latest[target] : null;
    if (current == null) return SectionSwitchOutcome.notHandedOver;
    if (!canSend(kSectionCmdStart, _modeOf(current))) {
      return SectionSwitchOutcome.notHandedOver;
    }
    final next = DynamicValue.from(current);
    next[kSectionCmdStart] = true;
    try {
      if (!await writeTag(ref, stateMan, refs[target].key.trim(), next,
          member: kSectionCmdStart)) {
        return SectionSwitchOutcome.writeFailed;
      }
    } catch (e, st) {
      _log.e('section ${refs[target].key}: writing $kSectionCmdStart failed',
          error: e, stackTrace: st);
      return SectionSwitchOutcome.writeFailed;
    }
    return SectionSwitchOutcome.done;
  }

  void _showPane(BuildContext context) {
    final refs = _refs;
    if (refs.isEmpty) return;
    final stream = _combined;
    if (stream == null) return;
    showSidePane(
      context: context,
      id: _paneId,
      // One subscription for the life of the pane, memoised on the stream
      // itself so a rebuild does not re-subscribe every section.
      builder: (_) => MemoStreamBuilder<List<DynamicValue?>>(
        keys: [stream],
        stream: stream,
        builder: (paneContext, snapshot) {
          final values = snapshot.hasData && !snapshot.hasError
              ? snapshot.data!
              : List<DynamicValue?>.filled(refs.length, null);
          final modes = [for (final v in values) _modeOf(v)];
          return SectionPane(
            title: _title,
            refs: refs,
            values: values,
            modes: modes,
            exclusiveSets: exclusiveSetsOf(refs),
            allowModeSwitch: widget.config.allowModeSwitch,
            onCommand: (field) => _send(refs, values, field),
            onSectionCommand: (i, field) => _sendOne(refs, values, i, field),
            onModeSwitch: (target) => _switchMode(refs, values, target),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    // The pane's body reads this State's counter fields and its command
    // callback, and a docked pane outlives the route that opened it.
    closeSidePane(id: _paneId, immediate: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final refs = _refs;
    if (refs.isEmpty) {
      return _face(context, const SectionGroup([SectionMode.unknown]),
          interactive: false);
    }
    // Watched here rather than inside the builder below: that builder belongs
    // to the StreamBuilder's element, so a `ref.watch` inside it is not a
    // watch this widget holds — the dependency would lapse and the shared
    // stream could be disposed underneath it.
    final sources = [
      for (final r in refs) ref.watch(keyStreamProvider(r.key.trim()))
    ];
    return StreamBuilder<List<DynamicValue?>>(
      stream: _combinedFor(sources),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.hasError) {
          return _face(
            context,
            SectionGroup(
                List.filled(refs.length, SectionMode.unknown, growable: false)),
            interactive: true,
          );
        }
        final modes = [for (final v in snapshot.data!) _modeOf(v)];
        // Every well-behaved exclusive set counts as the one thing it is
        // before the face asks whether its sections agree. Without this a
        // button driving film and vacuum is split for as long as either mode
        // runs — which is always — and a seam that is always there stops
        // meaning "look at this" for every other button too.
        return _face(
          context,
          SectionGroup(resolveFaceModes(modes, exclusiveSetsOf(refs))),
          interactive: true,
        );
      },
    );
  }

  Widget _face(BuildContext context, SectionGroup group,
      {required bool interactive}) {
    final theme = Theme.of(context);
    final states = HmiStateColors.of(context);

    // The box this is laid out in, not the one the config asks for.
    //
    // `AssetStack` sizes an asset off the CANVAS it is drawing on, while
    // `RelativeSize.toSize(MediaQuery…)` sizes it off the whole SCREEN — and
    // the canvas is the screen less the app bar, the nav rail and whatever a
    // docked side pane is covering. The painter is handed the real box either
    // way (`paint` gets the size it was laid out at), so the disc was always
    // drawn in the middle of the button; only the published hit shape was
    // derived from the config's size, which put its centre and its radius
    // somewhere the disc is not. On a canvas shorter than the screen that is
    // exactly what the plant view drew: a ring low and wide of the button
    // whose pane was open. Same arrangement as `conveyor_gate.dart` — take
    // the constraints, fall back to the config only when nothing bounds us
    // (an asset built outside a stack, e.g. the editor's palette preview).
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.hasBoundedWidth && constraints.hasBoundedHeight
            ? Size(constraints.maxWidth, constraints.maxHeight)
            : widget.config.size.toSize(MediaQuery.of(context).size);

        final pressed = interactive && _isPressed;

        final painter = PowerButtonPainter(
          disc: sectionModeColor(context, group.busiest),
          splitWith:
              group.mixed ? sectionModeColor(context, group.quietest) : null,
          glyph: states.onState,
          border: theme.colorScheme.outlineVariant,
          unreadable: group.anyUnreadable,
          isPressed: pressed,
        );

        // The face is a disc in a square box. Without a hit shape the corners
        // of that box would swallow taps meant for whatever is drawn behind
        // them — and the plant view would outline a square around a round
        // button while its pane is open.
        Widget face = AssetHitShape(
          shape: () => PowerButtonPainter.hitShape(size),
          child: CustomPaint(size: size, painter: painter),
        );

        if (interactive) {
          // The press feedback is the painter's, not an `InkWell`'s. A
          // `Material` splash is drawn behind its child, and this child is an
          // opaque disc — the ripple `button.dart` sets up is invisible there
          // too. What an operator actually sees is `ButtonPainter` shrinking
          // the face and tightening its shadow, which is driven from here.
          face = GestureDetector(
            onTapDown: (_) => _setPressed(true),
            onTapUp: (_) => _setPressed(false),
            onTapCancel: () => _setPressed(false),
            onTap: () => _showPane(context),
            child: face,
          );
        }
        return Semantics(
          button: interactive,
          label: '$_title — ${group.label}',
          child: face,
        );
      },
    );
  }
}

/// Reads one BOOL member off a structured value, or null when it is absent.
///
/// A section key pointed at the wrong node, or a PLC built before a member
/// existed, gives a struct without it. That is "unknown", not "false" — the
/// difference between a button that says it cannot read the section and one
/// that says the section is safely stopped.
bool? _boolOrNull(DynamicValue value, String field) {
  if (!value.contains(field)) return null;
  final member = value[field];
  return member.isNull ? null : member.asBool;
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

/// The IEC 5009 power symbol on a filled disc.
///
/// Deliberately the whole of the button's language: shape says "this is the
/// thing that starts and stops the line", colour says what it is doing now.
class PowerButtonPainter extends CustomPainter {
  /// Disc fill — the section's state colour, or the busiest of them when a
  /// group is split.
  final Color disc;

  /// Second colour for a group whose sections disagree, filling the lower
  /// right of a diagonal split. Null paints a plain single-colour disc, which
  /// is every button driving one section and every group that agrees.
  ///
  /// The split runs corner to corner rather than straight across: a vertical
  /// or horizontal seam reads as two buttons pushed together, or as a
  /// rendering artefact, while a slash reads as one face carrying two states.
  /// The dividing line is stroked in [border] so it is unmistakably meant.
  final Color? splitWith;

  /// The ring-and-bar glyph, drawn on top of the face.
  final Color glyph;

  /// Hairline around the disc, so a grey button still has an edge against a
  /// pale mimic background. Also draws the split.
  final Color border;

  /// Draw an exclamation mark instead of the power glyph.
  ///
  /// The disc is grey either way, because a section nobody can read and a
  /// section standing idle are both "not running" — what separates them is
  /// this mark, exactly as a belt in `conveyor.dart` goes grey and wears a
  /// `!` when it has no keys, no data, or an errored stream.
  final bool unreadable;

  /// Held down. Passed straight to [ButtonPainter], which shrinks the face and
  /// tightens its shadow; the glyph is scaled with it so the whole button
  /// moves as one thing rather than a disc sliding under a fixed symbol.
  final bool isPressed;

  const PowerButtonPainter({
    required this.disc,
    required this.glyph,
    required this.border,
    this.splitWith,
    this.unreadable = false,
    this.isPressed = false,
  });

  /// How much [ButtonPainter] shrinks a pressed face.
  static const double _pressedScale = 0.95;

  /// Radius of the disc at rest, which is the radius [ButtonPainter] fills a
  /// circular face to.
  static double radiusFor(Size size) =>
      math.max(0, math.min(size.width, size.height) / 2);

  /// The tappable shape: the disc, not the box it is laid out in.
  static Path hitShape(Size size) => Path()
    ..addOval(Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: radiusFor(size),
    ));

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = radiusFor(size) * (isPressed ? _pressedScale : 1.0);
    if (r <= 0) return;

    // The face is not drawn here. Shadow, fill, pressed shrink and hairline
    // are exactly what every other button on a mimic has, and they come from
    // the one painter that already draws them — a second flat disc of our own
    // was the same button with the depth missing.
    ButtonPainter(
      color: disc,
      isPressed: isPressed,
      buttonType: ButtonType.circle,
      borderColor: border,
    ).paint(canvas, size);

    final second = splitWith;
    if (second != null) {
      // A "/" corner to corner: bottom-left to top-right. The half below and
      // right of it takes the quieter colour, so the busier state is the one
      // the eye lands on first.
      final a = Offset(center.dx - r, center.dy + r);
      final b = Offset(center.dx + r, center.dy - r);
      canvas.save();
      canvas.clipPath(
          Path()..addOval(Rect.fromCircle(center: center, radius: r)));
      canvas.drawPath(
        Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy)
          ..lineTo(b.dx, a.dy)
          ..close(),
        Paint()..color = second,
      );
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = border
          ..strokeWidth = math.max(1, r * 0.07),
      );
      canvas.restore();

      // The quieter half was laid over the hairline `ButtonPainter` had
      // already drawn, so put it back. Same width and colour, so a split
      // button's edge is indistinguishable from a plain one's.
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    if (unreadable) {
      _paintExclamation(canvas, center, r);
      return;
    }

    // Glyph: a ring with a gap at the top and a bar down through the gap.
    final ringRadius = r * 0.46;
    final stroke = Paint()
      ..color = glyph
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, r * 0.13)
      ..strokeCap = StrokeCap.round;

    const gapHalfAngle = 0.66; // ~38°, wide enough for the bar to pass through
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: ringRadius),
      -math.pi / 2 + gapHalfAngle,
      2 * math.pi - 2 * gapHalfAngle,
      false,
      stroke,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - ringRadius * 1.22),
      Offset(center.dx, center.dy + ringRadius * 0.08),
      stroke,
    );
  }

  /// The `!` an unreadable section wears in place of its power glyph.
  ///
  /// Drawn rather than laid out as text so it does not depend on a font being
  /// loaded — the same reason the rest of this painter is strokes. A bar with
  /// a rounded cap over a round dot, on the disc's own centre line.
  void _paintExclamation(Canvas canvas, Offset center, double r) {
    final stroke = Paint()
      ..color = glyph
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, r * 0.16)
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
      Offset(center.dx, center.dy - r * 0.44),
      Offset(center.dx, center.dy + r * 0.12),
      stroke,
    );
    canvas.drawCircle(
      Offset(center.dx, center.dy + r * 0.42),
      math.max(0.8, r * 0.09),
      Paint()..color = glyph,
    );
  }

  @override
  bool shouldRepaint(PowerButtonPainter old) =>
      old.disc != disc ||
      old.splitWith != splitWith ||
      old.glyph != glyph ||
      old.border != border ||
      old.unreadable != unreadable ||
      old.isPressed != isPressed;
}

// ---------------------------------------------------------------------------
// The pane
// ---------------------------------------------------------------------------

/// The operator pane: what the sections are doing and the commands that
/// change it.
///
/// Split out from the asset so it can be pumped on its own in tests and
/// goldens, and so the layout is readable without the subscription plumbing
/// around it.
class SectionPane extends StatelessWidget {
  final String title;

  /// The configured sections, parallel to [values] and [modes].
  final List<SectionRef> refs;
  final List<DynamicValue?> values;
  final List<SectionMode> modes;

  /// Writes one `p_cmd_*` member, fanned out across every section that can
  /// take it.
  final Future<void> Function(String field) onCommand;

  /// Writes one `p_cmd_*` member to a single section, by index into [refs].
  ///
  /// The pane has no notion of a selected section — nothing here is "active".
  /// Every control names its own scope instead: the group buttons say `all`,
  /// and a member's buttons sit on that member's row. A pane that remembered
  /// a selection would have one `Stop` meaning either one section or the
  /// whole line depending on something an operator did a minute ago, which is
  /// how a line gets stopped by accident.
  final Future<void> Function(int index, String field)? onSectionCommand;

  /// Sets of sections that are alternatives rather than peers, as indices into
  /// [refs]. Empty for every button that drives plain peers, which is what
  /// keeps this pane identical to the one #387 shipped for those.
  final List<ExclusiveSet> exclusiveSets;

  /// Whether the choice may hand the line over in one press. See
  /// [SectionButtonConfig.allowModeSwitch].
  final bool allowModeSwitch;

  /// Puts one alternative in charge of its set, by index into [refs].
  ///
  /// The pane asks the confirmation and reports the outcome; the sequencing —
  /// stop, wait for the PLC, start — belongs to whoever owns the live values.
  final Future<SectionSwitchOutcome> Function(int target)? onModeSwitch;

  const SectionPane({
    super.key,
    required this.title,
    required this.refs,
    required this.modes,
    required this.onCommand,
    this.onSectionCommand,
    this.values = const [],
    this.exclusiveSets = const [],
    this.allowModeSwitch = false,
    this.onModeSwitch,
  });

  static String _runningOrNot(bool? value) =>
      value == null ? '—' : (value ? 'Running' : 'Stopped');

  bool? _bit(int i, String field) {
    if (i >= values.length) return null;
    final v = values[i];
    return v == null ? null : _boolOrNull(v, field);
  }

  SectionMode _modeAt(int i) =>
      i < modes.length ? modes[i] : SectionMode.unknown;

  /// What the Sections list draws, one entry per thing on the line.
  ///
  /// A plain section is one entry ([set] null). An exclusive set is ALSO one
  /// entry: the pair is one machine with a mode selector — the PLC allows
  /// exactly one of them `q_xEnabled` and drops the other the scan its
  /// permissive clears — so drawing it as two rows plus a separate choice
  /// block said the same two names four times and pushed the group commands
  /// below the fold.
  ///
  /// A set sits where its first member was configured, so a page that does
  /// not use exclusivity gets back exactly `0..refs.length` and this list is
  /// the one #387 drew.
  List<({int index, ExclusiveSet? set})> _listEntries() {
    final setOf = <int, ExclusiveSet>{};
    for (final s in exclusiveSets) {
      for (final i in s.members) {
        setOf[i] = s;
      }
    }
    final out = <({int index, ExclusiveSet? set})>[];
    final done = <ExclusiveSet>{};
    for (var i = 0; i < refs.length; i++) {
      final set = setOf[i];
      if (set == null) {
        out.add((index: i, set: null));
        continue;
      }
      if (!done.add(set)) continue;
      out.add((index: i, set: set));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final states = HmiStateColors.of(context);
    // Two views of the same sections. [raw] counts them — "2 of 7 running" is
    // a count of sections and stays one. [group] is what the pane SAYS they
    // are, and there every working exclusive set counts as the one thing it
    // is, so the header chip and the State tile agree with the face on the
    // page rather than saying `Mixed` at a plant that is behaving.
    final raw = SectionGroup(modes);
    final group = SectionGroup(resolveFaceModes(modes, exclusiveSets));
    final single = refs.length == 1;

    // A section held off by the alternative that has the line is the interlock
    // working, not an anomaly, and counting it here is what turned "Allowed to
    // start" into a permanent `No for 2 of 7` — a row that is always red is a
    // row nobody reads. Where it IS the answer is the choice below, which
    // shows which mode has the line.
    final held = [
      for (var i = 0; i < refs.length; i++)
        if (_modeAt(i) == SectionMode.blocked &&
            !heldByAlternative(i, modes, exclusiveSets))
          i,
    ];
    final unreadable = raw.count(SectionMode.unknown);
    final allowed = refs.isEmpty || unreadable == refs.length
        ? '—'
        : held.isEmpty
            ? 'Yes'
            : held.length == refs.length
                ? 'No'
                : 'No for ${held.length} of ${refs.length}';

    final runnable = groupStartable(modes, exclusiveSets);
    // `Run all` never writes to a member of an exclusive set, so on a button
    // where every section IS one it can never fire — in any state, forever.
    // Drawing it anyway gave the pane a permanently dead control, and (once
    // the reduced view agreed on Running) a permanently dead control wearing
    // the filled green of a live one. It is not drawn at all instead.
    final canEverRunAll = [
      for (var i = 0; i < refs.length; i++)
        if (!inExclusiveSet(i, exclusiveSets)) i,
    ].isNotEmpty;
    final cleanable = modes.any(canClean);
    final stoppable = modes.any(canStop);

    return SidePane(
      title: title,
      subtitle: single ? 'Section' : '${refs.length} sections',
      icon: Icons.power_settings_new,
      status: sectionGroupStatus(context, group),
      // Stop is the one command that must never be a scroll away, and the one
      // the PLC accepts unconditionally. Run and Clean live in the body, where
      // each can show whether it is the mode the sections are already in.
      actions: [
        PaneAction.destructive(
          // `Stop all` the moment there is more than one section, because a
          // member's own Stop sits a few rows above it. A button whose scope
          // has to be inferred from which part of the pane it is in is a
          // button that eventually stops the wrong thing.
          label: single ? 'Stop' : 'Stop all',
          icon: Icons.stop_circle_outlined,
          buttonKey: const Key('section-stop'),
          onPressed: stoppable ? () => onCommand(kSectionCmdStop) : null,
        ),
      ],
      child: PaneBody(
        sections: [
          PaneBodySection.status(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // No "for how long" tile beside it. `ST_Section_HMI` carries
                // three status bits and no transition timestamp, so the only
                // clock available was the HMI's own: it started when this
                // widget was built and went back to zero the moment the
                // operator navigated away and came back. A counter that
                // restarts on navigation is worse than no counter, because it
                // reads as the section having just changed mode. If the PLC
                // ever publishes the transition time, that is the number that
                // belongs here.
                PaneTileRow(
                  children: [
                    PaneMetricTile(
                      label: 'State',
                      value: group.label,
                      valueColor: sectionModeColor(context, group.busiest),
                      icon: Icons.bolt,
                      // Wider than the 108 px default: at 108 the longest
                      // state word was cut short.
                      width: 170,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // A single section shows its two mode bits directly; a group
                // shows a count, because four sections' worth of Yes/No rows is
                // exactly the "more information than a normal screen" the pane
                // rules exist to prevent. The Sections list below carries the
                // per-member detail.
                if (single) ...[
                  PaneDetailRow(
                    label: 'Auto mode',
                    value: _runningOrNot(_bit(0, kSectionStatEnabled)),
                  ),
                  PaneDetailRow(
                    label: 'Cleaning mode',
                    value: _runningOrNot(_bit(0, kSectionStatCleanEnabled)),
                  ),
                ] else
                  PaneDetailRow(
                    label: 'Running',
                    // Counted over the sections themselves, not over the
                    // reduced view: this row answers "how many are moving",
                    // and an exclusive set with one mode running has one
                    // section moving, not one unit in some state.
                    value: '${raw.movingCount} of ${refs.length}',
                    valueColor: raw.movingCount == 0
                        ? null
                        : sectionModeColor(context, group.busiest),
                  ),
                // The one term of art on this pane, and the one an operator is
                // most likely to be stuck on: a section that will not start and
                // gives no reason. So it is an explain row rather than a detail
                // row, and it opens itself when it is the answer to "why is
                // nothing happening" — the same treatment `conveyor.dart` gives
                // a live drive fault.
                PaneExplainRow(
                  label: 'Allowed to start',
                  value: allowed,
                  valueColor: held.isEmpty ? null : states.yellow,
                  initiallyExpanded: held.isNotEmpty,
                  explanationBuilder: (context) => _PermitExplainer(
                    reasons: [
                      for (final i in held)
                        (
                          label: single ? null : refs[i].displayLabel,
                          reason: refs[i].holdReason,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // A second `status` section, not `details`: what each member is
          // doing is the reason the operator opened the pane, and the house
          // order is Status → Manual. Tagged `details` it rendered below the
          // Run/Clean buttons, which reads as an appendix to the commands
          // rather than the thing you check before pressing them.
          if (!single)
            PaneBodySection.status(
              title: 'Sections',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in _listEntries().indexed) ...[
                    // A hairline between members: without it three name /
                    // state / three-button blocks run together into one wall
                    // and the eye cannot tell which buttons belong to which
                    // section — the one thing this list exists to make
                    // obvious.
                    if (entry.$1 > 0) const Divider(height: 1),
                    if (entry.$2.set case final set?)
                      _ExclusiveSetRow(
                        setIndex: exclusiveSets.indexOf(set),
                        set: set,
                        refs: refs,
                        modes: modes,
                        allowModeSwitch: allowModeSwitch,
                        onModeSwitch: onModeSwitch,
                        onSectionCommand: onSectionCommand,
                      )
                    else
                      _SectionRow(
                        index: entry.$2.index,
                        name: refs[entry.$2.index].displayLabel,
                        mode: _modeAt(entry.$2.index),
                        onCommand: onSectionCommand,
                      ),
                  ],
                ],
              ),
            ),
          PaneBodySection.manual(
            title: single ? 'Mode' : 'All sections',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (canEverRunAll) ...[
                      Expanded(
                        child: _ModeChoice(
                          buttonKey: const Key('section-run'),
                          label: single ? 'Run' : 'Run all',
                          icon: Icons.play_arrow,
                          color: states.green,
                          active: !group.mixed &&
                              group.agreed == SectionMode.running,
                          onPressed: runnable
                              ? () => onCommand(kSectionCmdStart)
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: _ModeChoice(
                        buttonKey: const Key('section-clean'),
                        label: single ? 'Clean' : 'Clean all',
                        icon: Icons.water_drop_outlined,
                        color: states.blue,
                        active: !group.mixed &&
                            group.agreed == SectionMode.cleaning,
                        onPressed: cleanable
                            ? () => onCommand(kSectionCmdStartClean)
                            : null,
                      ),
                    ),
                  ],
                ),
                // Said only when it is the answer to a question the operator
                // has just asked: something in a choice could have started,
                // and `Run all` deliberately did not start it.
                if (canEverRunAll &&
                    exclusiveSets.any((s) =>
                        s.members.any((i) => canStart(_modeAt(i))))) ...[
                  const SizedBox(height: 10),
                  _Note(
                    icon: Icons.rule,
                    color: states.grey,
                    text: 'Run all leaves '
                        '${_joinNames(exclusiveSets.map((s) => s.name))} '
                        'alone — only one of each can run, and starting both '
                        'at once would stop the line. Choose a mode above.',
                  ),
                ],
                if (!runnable && !cleanable && held.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  // No cross-reference to the row above: it opens itself in
                  // this state, so the explanation is already on screen.
                  _Note(
                    icon: Icons.lock_outline,
                    color: states.yellow,
                    text: single
                        ? 'Run and Clean will do nothing until this section is '
                            'allowed to start.'
                        : 'Run and Clean will do nothing until one of these '
                            'sections is allowed to start.',
                  ),
                ] else if (!runnable && !cleanable) ...[
                  const SizedBox(height: 10),
                  _Note(
                    icon: Icons.help_outline,
                    color: states.grey,
                    text: 'Nothing is coming back from '
                        '${single ? 'this section' : 'these sections'}, so no '
                        'command is offered — sending one blind could start '
                        'machinery nobody can see the state of.',
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

/// `a`, `a and b`, `a, b and c` — a list an operator reads as a sentence.
String _joinNames(Iterable<String> names) {
  final list = names.toList();
  if (list.isEmpty) return '';
  if (list.length == 1) return list.single;
  return '${list.sublist(0, list.length - 1).join(', ')} and ${list.last}';
}

/// The words that tell a set's members apart, with the run of leading words
/// they all share dropped.
///
/// "Line 2 film" and "Line 2 vacuum" become "Film" and "Vacuum". Inside one
/// entry the shared half is already overhead — it is in the heading — and the
/// four buttons on the row have about eighty pixels each on a pane, which is
/// not enough for the full name: both members ellipsised to "Line …" and the
/// operator could no longer tell which button was which. The full names are
/// what the screen reader and the confirmation dialog still say.
///
/// Falls back to the labels untouched whenever the trim would be a guess:
/// nothing shared, or a member that is nothing BUT the shared part.
List<String> shortMemberNames(List<String> labels) {
  if (labels.length < 2) return labels;
  final words = [for (final l in labels) l.trim().split(RegExp(r'\s+'))];
  var shared = 0;
  while (words.every((w) => w.length > shared + 1) &&
      words.every((w) => w[shared].toLowerCase() == words[0][shared].toLowerCase())) {
    shared++;
  }
  if (shared == 0) return labels;
  final short = [
    for (final w in words)
      () {
        final rest = w.sublist(shared).join(' ');
        return rest.isEmpty
            ? w.join(' ')
            : rest[0].toUpperCase() + rest.substring(1);
      }(),
  ];
  // A label that trimmed down to a stub is worse than a long one: "Line 2"
  // beside "Line 2 vacuum" would leave a button reading "2". Keep the full
  // names rather than ship a word nobody can act on.
  if (short.any((n) => n.length < 3)) return labels;
  return short;
}

/// One exclusive set, drawn as one entry in the Sections list.
///
/// The pair is one machine with a mode selector, and the PLC is what makes it
/// one: `FB_Section` allows exactly one member `q_xEnabled`, and drops the
/// other's outputs the scan its `i_xPermissive` clears. Two rows plus a
/// separate choice block said each machine's name twice and each set's name
/// twice, and pushed the group commands below the fold on the seven-section
/// button this asset was built for.
///
/// So: one heading, one state, and the members as the mode buttons. `Clean`
/// and `Stop` sit beside them and act on the whole set — neither is part of
/// the exclusion (`p_cmd_Stop` is not gated at all, and cleaning never sets
/// `q_xEnabled`, so both members may wash down at once).
///
/// The mode with the line is filled and inert: `p_cmd_Start` is a toggle, so
/// a live button there would stop the line it is reporting. The alternatives
/// are live only when picking one would actually do something.
///
/// When [reduceExclusiveSet] cannot say what the set is — a member nobody can
/// read — this falls back to the individual rows, which is the same rule the
/// face uses to decide whether to draw a seam. A set that collapsed to the
/// half it can read would be claiming a state it cannot see.
class _ExclusiveSetRow extends StatelessWidget {
  final int setIndex;
  final ExclusiveSet set;
  final List<SectionRef> refs;
  final List<SectionMode> modes;
  final bool allowModeSwitch;
  final Future<SectionSwitchOutcome> Function(int target)? onModeSwitch;
  final Future<void> Function(int index, String field)? onSectionCommand;

  const _ExclusiveSetRow({
    required this.setIndex,
    required this.set,
    required this.refs,
    required this.modes,
    required this.allowModeSwitch,
    required this.onModeSwitch,
    required this.onSectionCommand,
  });

  SectionMode _modeAt(int i) =>
      i < modes.length ? modes[i] : SectionMode.unknown;

  String _nameOf(int i) => i < refs.length ? refs[i].displayLabel : 'Section';

  /// The button labels, trimmed to what tells the members apart. Keyed by ref
  /// index so the row and the semantics can pick them out.
  Map<int, String> get _shortNames {
    final short =
        shortMemberNames([for (final i in set.members) _nameOf(i)]);
    return {
      for (var n = 0; n < set.members.length; n++) set.members[n]: short[n],
    };
  }

  String get _heading => '${set.name} — one at a time';

  /// The member that currently has the line, or null.
  int? get _active {
    for (final i in set.members) {
      final m = _modeAt(i);
      if (m == SectionMode.running || m == SectionMode.cleaning) return i;
    }
    return null;
  }

  Future<void> _pick(BuildContext context, int target) async {
    final send = onModeSwitch;
    if (send == null) return;
    final plan = planModeSwitch(modes: modes, set: set, target: target);
    if (plan == null) return;

    if (plan.isHandover) {
      // Explicit, and impossible to reach by a mis-tap: the press opens a
      // question naming both machines, and the answer that starts something
      // is a second, separate press on a button that is not focused.
      final ok = await showConfirmDialog(
        context: context,
        title: 'Switch to ${_nameOf(target)}?',
        message:
            '${_joinNames(plan.stop.map(_nameOf))} will be stopped first. '
            '${_nameOf(target)} starts as soon as the PLC hands the '
            'go-ahead over — only one of these can run at a time.\n\n'
            'If it does not, nothing is started and the line stays stopped.',
        confirmLabel: 'Switch',
        destructive: true,
        icon: Icons.swap_horiz,
      );
      if (!ok) return;
    }

    final outcome = await send(target);
    if (!context.mounted) return;
    switch (outcome) {
      case SectionSwitchOutcome.done:
      case SectionSwitchOutcome.notOffered:
        return;
      case SectionSwitchOutcome.notHandedOver:
        // The one outcome that must not pass quietly: the line is stopped and
        // the mode the operator asked for is not running. A message that faded
        // would leave them reading a stopped line as a machine that refused.
        await showStandardDialog<void>(
          context: context,
          title: '${_nameOf(target)} did not start',
          icon: Icons.warning_amber,
          builder: (_) => Text(
            '${_joinNames(plan.stop.map(_nameOf))} stopped, but the PLC did '
            'not release ${_nameOf(target)} within '
            '${kSectionSwitchTimeout.inSeconds} seconds, so no start was '
            'sent.\n\nNothing in ${set.name} is running. Check what else is '
            'holding ${_nameOf(target)}, then start it from here.',
          ),
          actionsBuilder: (ctx) => [
            PaneAction.primary(
              label: 'Close',
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        );
      case SectionSwitchOutcome.writeFailed:
        await showStandardDialog<void>(
          context: context,
          title: 'The command did not reach the PLC',
          icon: Icons.link_off,
          builder: (_) => Text(
            'Nothing in ${set.name} was changed that this screen can vouch '
            'for. Check the connection, then read the states above before '
            'trying again.',
          ),
          actionsBuilder: (ctx) => [
            PaneAction.primary(
              label: 'Close',
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        );
    }
  }

  /// Fans one command across the set, guarded per member exactly as the
  /// group's own buttons are.
  VoidCallback? _setCommand(String field) {
    final send = onSectionCommand;
    if (send == null) return null;
    final targets = [
      for (final i in set.members)
        if (canSend(field, _modeAt(i))) i,
    ];
    if (targets.isEmpty) return null;
    return () {
      for (final i in targets) {
        send(i, field);
      }
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final states = HmiStateColors.of(context);
    final reduced =
        reduceExclusiveSet([for (final i in set.members) _modeAt(i)]);

    // Nobody can read one of them. Fall back to the rows, and say why there
    // is no choice — switching would stop a section whose state is unknown.
    if (reduced == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Text(
              _heading,
              style: theme.textTheme.labelMedium?.copyWith(color: states.grey),
            ),
          ),
          for (final i in set.members)
            _SectionRow(
              index: i,
              name: _nameOf(i),
              mode: _modeAt(i),
              // No mode may be picked here, so no `Run` either: it would be
              // the unguarded half of a decision this pane has just refused
              // to offer.
              showRun: false,
              onCommand: onSectionCommand,
            ),
          const SizedBox(height: 6),
          _Note(
            icon: Icons.help_outline,
            color: states.grey,
            text: 'One of these is not reading, so no choice is offered — '
                'switching would stop a section nobody can see the state of.',
          ),
        ],
      );
    }

    final active = _active;
    // Whether a hand-over is possible but switched off, and whether anything
    // could be picked at all — the two reasons a mode button is dead, and
    // both of them have to be sayable or the button is dead for no visible
    // reason.
    var handoverWithheld = false;
    var anyPickable = false;
    final shortNames = _shortNames;
    final modeButtons = <Widget>[];
    for (final i in set.members) {
      final mode = _modeAt(i);
      final isActive = i == active;
      final plan =
          isActive ? null : planModeSwitch(modes: modes, set: set, target: i);
      final blocked = plan != null && plan.isHandover && !allowModeSwitch;
      if (blocked) handoverWithheld = true;
      if (plan != null && !blocked) anyPickable = true;
      modeButtons.add(Expanded(
        child: _MemberButton(
          buttonKey: Key('section-choice-$setIndex-$i'),
          // Short on the button, full in the semantics: the row has no space
          // for "Line 2 vacuum" four times over, and a screen reader has no
          // heading above it to borrow the rest from.
          label: shortNames[i] ?? _nameOf(i),
          semantic: isActive
              ? '${_nameOf(i)}, has the line'
              : 'Switch ${set.name} to ${_nameOf(i)}',
          icon: mode == SectionMode.cleaning
              ? Icons.water_drop_outlined
              : Icons.play_arrow,
          // Filled, the tint is the state it is IN (green auto, blue washing
          // down). Outlined, it is a button that starts something, so it
          // wears green like every other `Run` in the pane — tinting it with
          // the member's own mode painted a live "Film" the grey of a stopped
          // section, which on a compact outlined button is indistinguishable
          // from disabled.
          tint: isActive ? sectionModeColor(context, mode) : states.green,
          // The mode with the line is filled, so which one it is survives the
          // collapse from two rows to one. It is also inert — `p_cmd_Start`
          // toggles, and a live button here would stop what it is reporting.
          filled: isActive,
          onPressed:
              (isActive || plan == null || blocked || onModeSwitch == null)
                  ? null
                  : () => _pick(context, i),
        ),
      ));
    }

    // Both modes in auto at once cannot happen while the ladder holds
    // (`i_xPermissive := NOT other.q_xEnabled`), so seeing it means the
    // interlock is not doing its job. The face cannot say it — two sections in
    // the same mode is agreement, and there is no seam to draw — so this is
    // where it gets said.
    final violated =
        set.members.where((i) => _modeAt(i) == SectionMode.running).length > 1;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _heading,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                reduced.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: sectionModeColor(context, reduced),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final b in modeButtons) ...[
                b,
                const SizedBox(width: 6),
              ],
              Expanded(
                child: _MemberButton(
                  buttonKey: Key('section-set-$setIndex-clean'),
                  label: 'Clean',
                  semantic: 'Clean ${set.name}',
                  icon: Icons.water_drop_outlined,
                  tint: states.blue,
                  onPressed: _setCommand(kSectionCmdStartClean),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _MemberButton(
                  buttonKey: Key('section-set-$setIndex-stop'),
                  label: 'Stop',
                  semantic: 'Stop ${set.name}',
                  icon: Icons.stop_circle_outlined,
                  tint: theme.colorScheme.error,
                  onPressed: _setCommand(kSectionCmdStop),
                ),
              ),
            ],
          ),
          // At most one line, and only when something is dead or wrong. The
          // note that used to explain the hand-over in the ordinary case was
          // the only one that appeared when nothing was the matter, which is
          // exactly the noise this asset is trying not to make.
          if (violated) ...[
            const SizedBox(height: 8),
            _Note(
              icon: Icons.warning_amber,
              color: theme.colorScheme.error,
              text: 'Both of these are running. Only one is supposed to be '
                  'able to — the interlock in the PLC is not holding. '
                  'Report it.',
            ),
          ] else if (handoverWithheld && active != null) ...[
            const SizedBox(height: 8),
            _Note(
              icon: Icons.lock_outline,
              color: states.yellow,
              text: '${_nameOf(active)} has the line. Stop it, then the other '
                  'mode can be started.',
            ),
          ] else if (active != null && !anyPickable) ...[
            const SizedBox(height: 8),
            // The exclusion is not what holds the alternative: the permissive
            // keys off `q_xEnabled` only, so a member held while this one
            // merely CLEANS is held by something else entirely.
            _Note(
              icon: Icons.lock_outline,
              color: states.yellow,
              text: '${_nameOf(active)} has the line, but the other mode is '
                  'not free to take it either — something outside this choice '
                  'is holding it.',
            ),
          ],
        ],
      ),
    );
  }
}

/// One member of a group, with its own three commands on its own row.
///
/// The alternative was a picker that switched the whole pane between sections,
/// and it was rejected: it makes the footer `Stop` mean either one section or
/// the whole line depending on a selection made a minute ago, and the two
/// states of the pane look nearly the same. Here nothing is selected and
/// nothing is remembered — the group buttons say `all`, these buttons sit on
/// the row of the section they command, and both are on screen together.
///
/// The buttons carry words, not only glyphs. These panes are read on wet
/// touchscreens in a fish plant, where there is no hover and therefore no
/// tooltip, and an operator recovering one stalled station should not have to
/// infer that a droplet means cleaning.
///
/// Each button is guarded exactly as the group's is, per section: `p_cmd_Start`
/// toggles, so `Run` on a section already running would stop it and is dead
/// there instead.
class _SectionRow extends StatelessWidget {
  final int index;
  final String name;
  final SectionMode mode;
  final Future<void> Function(int index, String field)? onCommand;

  /// Off for one alternative of an exclusive set, whose mode is picked in the
  /// choice instead. Two ways to start the same section, one guarded and one
  /// not, is how an operator learns that a button sometimes does nothing.
  /// Clean and Stop stay: neither is part of the choice, and cleaning is not
  /// exclusive in the PLC at all.
  final bool showRun;

  const _SectionRow({
    required this.index,
    required this.name,
    required this.mode,
    required this.onCommand,
    this.showRun = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = sectionModeColor(context, mode);
    final send = onCommand;

    VoidCallback? action(String field) =>
        (send == null || !canSend(field, mode)) ? null : () => send(index, field);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                mode.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (showRun) ...[
                Expanded(
                  child: _MemberButton(
                    buttonKey: Key('section-$index-run'),
                    label: 'Run',
                    semantic: 'Run $name',
                    icon: Icons.play_arrow,
                    tint: HmiStateColors.of(context).green,
                    onPressed: action(kSectionCmdStart),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: _MemberButton(
                  buttonKey: Key('section-$index-clean'),
                  label: 'Clean',
                  semantic: 'Clean $name',
                  icon: Icons.water_drop_outlined,
                  tint: HmiStateColors.of(context).blue,
                  onPressed: action(kSectionCmdStartClean),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _MemberButton(
                  buttonKey: Key('section-$index-stop'),
                  label: 'Stop',
                  semantic: 'Stop $name',
                  icon: Icons.stop_circle_outlined,
                  tint: Theme.of(context).colorScheme.error,
                  onPressed: action(kSectionCmdStop),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One command on a member's row: compact, labelled, and named after the
/// section it commands so automation and a screen reader get the scope the
/// layout gives an eye.
class _MemberButton extends StatelessWidget {
  final Key buttonKey;
  final String label;
  final String semantic;
  final IconData icon;

  /// The same colour the group's button for this command wears, so `Run` means
  /// green and `Clean` means blue wherever it appears in the pane.
  final Color tint;
  final VoidCallback? onPressed;

  /// Paints the button in [tint] rather than outlining it — the mode of an
  /// exclusive set that has the line. Kept on the same compact metrics as the
  /// outlined ones so it sits in a row beside them without changing its
  /// height, and it keeps the colour while disabled: a filled button that
  /// faded to the theme's disabled grey would hide the very thing it is
  /// there to say.
  final bool filled;

  const _MemberButton({
    required this.buttonKey,
    required this.label,
    required this.semantic,
    required this.icon,
    required this.tint,
    required this.onPressed,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    if (filled) {
      return FilledButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(
          label,
          semanticsLabel: semantic,
          overflow: TextOverflow.ellipsis,
        ),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          visualDensity: VisualDensity.compact,
          textStyle: Theme.of(context).textTheme.labelMedium,
          backgroundColor: tint,
          foregroundColor: HmiStateColors.of(context).onState,
          disabledBackgroundColor: tint,
          disabledForegroundColor: HmiStateColors.of(context).onState,
        ),
      );
    }
    return OutlinedButton.icon(
      key: buttonKey,
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      // `semanticsLabel` rather than a wrapping `Semantics`: the button
      // builds its own semantics node from this child, so an outer wrapper
      // is shadowed and the row's three buttons all announce themselves as
      // bare "Run"/"Clean"/"Stop" with no idea which section they belong to.
      label: Text(
        label,
        semanticsLabel: semantic,
        overflow: TextOverflow.ellipsis,
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        visualDensity: VisualDensity.compact,
        textStyle: Theme.of(context).textTheme.labelMedium,
        // Left to the theme when disabled, so a dead button reads as dead
        // rather than as a quieter shade of its own colour.
        foregroundColor: onPressed == null ? null : tint,
      ),
    );
  }
}

/// What "allowed to start" means, in the words of somebody who has to act on
/// it rather than wire it.
///
/// One sentence is generic and always shown: it is true of every section and
/// it is the fact an operator needs first — pressing the buttons will not
/// help. Everything beyond that is per-section and comes from the asset's
/// [SectionRef.holdReason], because what actually holds a section is a
/// property of that section's wiring, not of this widget. An asset that
/// guessed would eventually guess wrong, and a confident wrong instruction on
/// a machine pane is worse than no instruction.
class _PermitExplainer extends StatelessWidget {
  /// The held sections and their configured reasons. [label] is null when
  /// there is only one section, where naming it adds nothing.
  final List<({String? label, String? reason})> reasons;

  const _PermitExplainer({this.reasons = const []});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final written = [
      for (final r in reasons)
        if ((r.reason?.trim() ?? '').isNotEmpty)
          (label: r.label, reason: r.reason!.trim()),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'The rest of the plant has to give a section a go-ahead before it '
          'will run. Until it does, Run and Clean are ignored.',
          style: style,
        ),
        for (final r in written) ...[
          const SizedBox(height: 8),
          Text(
            r.label == null ? r.reason : '${r.label}: ${r.reason}',
            style: style,
          ),
        ],
      ],
    );
  }
}

/// One of the two modes the sections can be put into.
///
/// Filled while it is the mode they are all in, outlined otherwise, and
/// disabled when no section could act on it (see [canStart]) — so a running
/// group shows a filled, inert `Run` rather than a live button that would stop
/// the line.
class _ModeChoice extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool active;
  final VoidCallback? onPressed;
  final Key buttonKey;

  const _ModeChoice({
    required this.label,
    required this.icon,
    required this.color,
    required this.active,
    required this.onPressed,
    required this.buttonKey,
  });

  @override
  Widget build(BuildContext context) {
    final onState = HmiStateColors.of(context).onState;
    final style = ButtonStyle(
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(vertical: 14),
      ),
    );
    if (active) {
      return FilledButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: style.copyWith(
          // A disabled FilledButton fades to the theme's disabled grey, which
          // would hide the very thing this button is saying — that this is the
          // mode the sections are in. Keep the state colour on both.
          backgroundColor: WidgetStatePropertyAll(color),
          foregroundColor: WidgetStatePropertyAll(onState),
        ),
      );
    }
    return OutlinedButton.icon(
      key: buttonKey,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: style.copyWith(
        foregroundColor:
            onPressed == null ? null : WidgetStatePropertyAll(color),
      ),
    );
  }
}

/// A one-line explanation under the mode buttons.
class _Note extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _Note({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}
