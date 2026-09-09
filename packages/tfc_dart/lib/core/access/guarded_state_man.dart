/// The tag write guard: a [StateMan] that checks and records before it writes,
/// and forwards everything else untouched.
///
/// This is where `AccessDenied` starts being thrown and where every hand-made
/// tag write starts landing in the trail. Nothing constructs it here; plan
/// 03-06 wraps `stateManProvider` with it.
///
/// ## Why every member is written out
///
/// [StateMan] is a concrete class, not an abstract interface, so `implements
/// StateMan` means implementing its whole implicit interface — around twenty
/// public members, of which exactly one changes behaviour. The tests' fakes
/// reach for Dart's catch-all invocation hook to avoid that tedium and are
/// right to; **this file must not**, and `guarded_state_man_test.dart` greps
/// this file to prove it has not. A decorator built on that hook answers a
/// member nobody wired by throwing at runtime, on a plant, at whatever moment
/// somebody first calls it — and the member it would swallow is as likely to
/// be a write path as a getter. The test's `forwards every public member`
/// group instead derives the list from `state_man.dart` at test time, so a
/// member added there and not here fails the build rather than the plant.
///
/// ## Every tag write requires at least `operate`
///
/// Phase 3 shipped this guard recording everything and denying nothing —
/// `AccessPolicy` had no tag bindings, and an unbound key meant unrestricted.
/// The 2026-09-02 ruling replaced that: `groupForWireSurface('tag', …)` now
/// floors at `operate`, so a session without it is refused on every tag
/// write, bound or not, and templates only raise the requirement from there.
/// The anonymous session maps to the Operator role, which holds `operate`,
/// so a stock station behaves exactly as before.
library;

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc_access/tfc_access.dart';

import '../state_man.dart';
import 'dynamic_value_diff.dart';

/// A [StateMan] that records every write it lets through and refuses the ones
/// the session in force may not make.
class GuardedStateMan implements StateMan {
  /// [session] is a **callback, not a value**, and that is load-bearing. The
  /// guard outlives any one session — it is built once, when the provider is —
  /// and must see the session in force *at the moment of the write*. A
  /// captured [AccessSession] would keep granting whatever the operator held
  /// when the provider was built, long after the inactivity monitor dropped
  /// them back to anonymous. That is the elevation window this milestone
  /// exists to close.
  ///
  /// [surface] is one string with two uses: the policy lookup
  /// (`policy.groupForWireSurface(surface, key)`) and the `surface` column of
  /// every row this guard writes. One value, so the group that was checked and
  /// the surface that was recorded cannot disagree — and so `AccessPolicy`'s
  /// unmapped-surface branch sits on the production write path rather than in
  /// a wrapper nothing calls. A guard constructed with a surface the policy
  /// does not know fails closed on `administer`.
  ///
  /// [readBaseline] answers the value a key held before the write, so a
  /// whole-struct write can be reduced to the members that actually moved. It
  /// is optional: without it every write is one row marked as having no
  /// baseline, which is a readable trail rather than a wrong one.
  ///
  /// [onDenied] fires before the [AccessDenied] is thrown, so a screen can
  /// present a refusal as a locked affordance even at the call sites that do
  /// not catch the exception. Plan 03-07 owns the prompt; this owns firing
  /// the event.
  GuardedStateMan({
    required StateMan inner,
    required AccessPolicy policy,
    required AccessSession Function() session,
    required AuditSink audit,
    required String station,
    String surface = 'tag',
    Future<DynamicValue?> Function(String key)? readBaseline,
    void Function(AccessDenied denial)? onDenied,
    Logger? logger,
  })  : _inner = inner,
        _policy = policy,
        _session = session,
        _audit = audit,
        _station = station,
        _surface = surface,
        _readBaseline = readBaseline,
        _onDenied = onDenied,
        _logger = logger ?? Logger();

  final StateMan _inner;

  /// The object beneath this guard, **if** it is a [T] — and null otherwise.
  ///
  /// A read-only escape hatch for facts about the transport, and **never a
  /// write path.** Every write, every read and every subscribe still goes
  /// through this class's own members; a caller that reaches through here to
  /// get at [StateMan.write] has removed the access check and the audit row
  /// that are the only two things this class adds. That is the fence, and it
  /// is a doc rather than a compiler rule for the same reason
  /// [readBaseline]'s and [baselineTimeout]'s scope limits are.
  ///
  /// **Why it has to exist.** `implements StateMan` is what makes this
  /// decorator invisible to its callers, and it is also what makes the object
  /// underneath unreachable: [_inner] is private and each of the ~20 forwarded
  /// members hands back the inner's *answer*, never the inner. That is right
  /// for everything on the interface and impossible for the handful of facts
  /// that are not on it at all. The one caller is
  /// `lib/providers/gateway_link.dart` in the Flutter app, which needs
  /// `RemoteStateMan.linkState` — not a `StateMan` member, and never will be,
  /// because a local station has no link to have a state.
  ///
  /// **Narrow on purpose.** A plain getter handing back [_inner] typed as the
  /// interface was the obvious alternative and is rejected in writing — and
  /// the offending spelling is deliberately absent from this file, comments
  /// included, so a grep for it stays a useful question. It would hand out an
  /// unguarded write
  /// path to every caller, not just the one that wanted a link state. Here the
  /// caller must name the type it wants and is told null when the inner object
  /// is something else — which is also how a gateway-only surface learns it is
  /// running on a direct-mode station.
  ///
  /// No cast: [_inner] is a private final field, so `is T` promotes it. An
  /// explicit `as T` beside the test analyses as an unnecessary cast and would
  /// add a warning to a package that has exactly two and keeps them counted.
  T? innerAs<T extends StateMan>() => _inner is T ? _inner : null;

  final AccessPolicy _policy;
  final AccessSession Function() _session;
  final AuditSink _audit;
  final String _station;
  final String _surface;
  final Future<DynamicValue?> Function(String key)? _readBaseline;
  final void Function(AccessDenied denial)? _onDenied;

  /// The guard's own diagnostic logger, used for the audit-sink failures it
  /// swallows. Distinct from [logger], which forwards the inner `StateMan`'s
  /// so that a caller typed as `StateMan` sees exactly what it saw before.
  final Logger _logger;

  /// How long the guard will wait for the baseline read before treating the
  /// write as having none.
  ///
  /// The baseline exists to make the trail *readable* - one row per member
  /// instead of one blob. Making a jog wait on a PLC round trip that is not
  /// answering would trade a usability feature for an outage, so the wait is
  /// short and its expiry is not an error: it is "no baseline", the same
  /// answer as not supplying a reader at all.
  ///
  /// This timeout is on the **write** path only. Spec section 10 and the
  /// repo's own history say not to put a `.timeout` on anything that runs
  /// during dispose, and nothing here does.
  static const Duration baselineTimeout = Duration(milliseconds: 250);

  /// The `who` recorded when nobody is signed in.
  static const String _anonymousWho = 'anonymous';

  // -------------------------------------------------------------------------
  // The one member that behaves differently
  // -------------------------------------------------------------------------

  /// Checks, records, then writes.
  ///
  /// ## The order, and why the row comes first
  ///
  /// The rows are written **before** [StateMan.write] is awaited. A write that
  /// then fails at the PLC therefore leaves an `allowed: true` row with no
  /// corresponding change in the plant. That is deliberate: the row records
  /// that the action was *authorized*, and losing the evidence of an
  /// authorized attempt because the network blinked is the worse failure.
  /// Spec §2's own reasoning is that an absent audit row is the one defect
  /// nobody ever notices.
  ///
  /// On the deny path the rows come before the throw for the same reason,
  /// sharpened: the row is the only evidence the guard fired, and it must
  /// exist even if nobody catches the exception. [onDenied] fires before the
  /// throw too, so the operator sees a lock even at the call sites where the
  /// exception escapes.
  ///
  /// ## The key
  ///
  /// The **resolved** key is what gets looked up and what gets audited,
  /// because that is the key that was written. The **raw** key is what gets
  /// delegated: the guard sits outside `StateMan.write`, which resolves,
  /// rejects disabled servers and does its own read-modify-write for indexed
  /// keys. None of that moves in here.
  @override
  Future<void> write(String key, DynamicValue value) async {
    final String resolvedKey;
    try {
      resolvedKey = _inner.resolveKey(key);
    } on Object {
      // `resolveKey` throws when a substitution variable has no value. That is
      // the inner `StateMan`'s exception to raise, not the guard's to
      // reinterpret, and there is nothing to audit: no key was written. Hand
      // the call straight on so the caller sees exactly the failure it saw
      // before this decorator existed.
      return _inner.write(key, value);
    }

    final session = _session();

    // The diff comes **before** the decision, and that ordering is the whole
    // of plan 04-04. One conveyor key carries `p_cmd_JogFwd` and
    // `p_cfg_ManualFreq` through a single whole-struct write (spec §7b), so a
    // question asked about the key can only ever have one answer for both. The
    // question asked about the members that moved can have two.
    final changes = diffDynamicValue(await _baselineOrNull(resolvedKey), value);

    // Through `groupForWireSurface`, never `groupForTag`. The wire-surface
    // lookup is what puts the unmapped-surface branch on a real write path;
    // calling the typed method here would quietly delete that branch's only
    // caller.
    //
    // ## The fallback, and the hole in it
    //
    // A change with a null member is a value with nothing to compare against:
    // a bare scalar write, an opaque or array value, or a baseline read that
    // answered null, threw, or missed [baselineTimeout]. The guard then does
    // not know which members moved, so it falls back to the key-level
    // question - the template's whole-key row, or null.
    //
    // That degrades to the least gated answer the template can give — since
    // the 2026-09-02 ruling that is the operate floor, never "unrestricted".
    // The strict reading - require every group the template names anywhere -
    // would refuse an anonymous jog because a PLC read was slow, which takes
    // a working control off the floor for a reason the operator cannot see
    // or fix. Tap-time elevation (plan 04-06) resolves from the template
    // synchronously and needs no baseline at all, so this guard is the
    // backstop rather than the operator's path.
    //
    // The cost, stated plainly: **a setpoint write lands checked only against
    // the key-level answer — the operate floor, absent a whole-key row — when
    // the baseline read fails.** This is the one way member gating can be
    // bypassed. Both halves are pinned in
    // `guarded_state_man_member_test.dart`, group `the no-baseline fallback -
    // the one way member gating is bypassed`: the restricted member write is
    // permitted without a baseline, and the same case *is* gated when the
    // template carries a whole-key row - so the fallback is the key-level
    // answer, not the absence of one.
    final memberGroups = <AccessGroup>[
      if (changes.isEmpty || changes.any((c) => c.member == null))
        _policy.groupForWireSurface(_surface, resolvedKey)
      else
        for (final c in changes)
          _policy.groupForWireSurface(_surface, resolvedKey, member: c.member),
    ];

    // Since the 2026-09-02 ruling the policy never answers null on this
    // surface: every tag write requires at least `operate`, and bindings only
    // raise that. The old fail-open reading — unbound key means unrestricted
    // — let any account press any plain control regardless of its role,
    // which surfaced on hq-skjar as a user stripped of `operate` toggling
    // lights. The anonymous session maps to the Operator role, which holds
    // `operate`, so the floor locks nothing on a stock station.
    final required = memberGroups;
    final missing =
        required.where((group) => !session.can(group)).toList(growable: false);

    // On a refusal the prompt must name **one** permission, not a list, so the
    // strictest missing group is the one reported. On an allow it is the
    // strictest group the action actually required. Strictness is
    // `AccessGroup`'s declaration index - the enum is declared in increasing
    // privilege and is the single ranking; a second table here would be a
    // second thing to keep in step.
    final strictestMissing = _strictest(missing);
    final strictestRequired = _strictest(required);

    // One id per write, so every member row of one action correlates and two
    // actions never collide.
    final actionId = newActionId();
    final at = DateTime.now();
    final who = session.user?.username ?? _anonymousWho;

    if (strictestMissing != null) {
      await _recordAll(auditRecordsForChanges(
        // No suppression on this path, ever. See [_denialChanges].
        changes: _denialChanges(changes, value),
        at: at,
        who: who,
        station: _station,
        roleName: session.roleName,
        surface: _surface,
        itemKey: resolvedKey,
        // One string for the whole row set, because that is
        // `auditRecordsForChanges`' shape: 03-02 owns it and 03-05's
        // `GuardedPreferences` shares it, so threading a per-change group
        // through from here would ripple into a guard this phase has no
        // reason to touch. The rows therefore carry the strictest group the
        // action required, and the `member` column plus the bound template
        // answer the finer question of what each individual member needed.
        // A stated limitation, not a claim of completeness - if a Phase 5
        // filter needs per-member groups, the change belongs in
        // `dynamic_value_diff.dart`.
        groupRequired: strictestMissing.name,
        allowed: false,
        actionId: actionId,
      ));

      final denial = AccessDenied(resolvedKey, strictestMissing);
      try {
        _onDenied?.call(denial);
      } on Object catch (error, stack) {
        // A listener's bug must not change what the caller sees. The refusal
        // is the guard's answer; a broken prompt is a cosmetic failure beside
        // it.
        _logger.e('onDenied listener threw for "$resolvedKey"',
            error: error, stackTrace: stack);
      }
      throw denial;
    }

    await _recordAll(auditRecordsForChanges(
      // Empty here means the write changed nothing, and spec §2's no-op
      // suppression is exactly that: no rows. The **write itself still goes
      // through** - a re-issued command after a comms blip is a real action
      // with a real effect at the PLC, and a guard that silently swallowed it
      // would be changing plant behaviour to tidy a log.
      changes: changes,
      at: at,
      who: who,
      station: _station,
      roleName: session.roleName,
      surface: _surface,
      itemKey: resolvedKey,
      // An unbound key - and a write that moved only members no rule
      // mentions - carries an empty `groupRequired`, matching the auth rows'
      // convention for "not gated on a group". Otherwise the strictest group
      // the action required, for the reason spelled out on the deny path.
      groupRequired: strictestRequired?.name ?? '',
      allowed: true,
      actionId: actionId,
    ));

    return _inner.write(key, value);
  }

  /// The most privileged of [groups], or null when there are none.
  ///
  /// Ranked by `AccessGroup`'s declaration index, which is declared in
  /// increasing privilege. Deliberately not a second ranking table: two
  /// orderings of the same enum is a defect waiting for somebody to add a
  /// group to one of them.
  static AccessGroup? _strictest(Iterable<AccessGroup> groups) {
    AccessGroup? strictest;
    for (final group in groups) {
      if (strictest == null || group.index > strictest.index) strictest = group;
    }
    return strictest;
  }

  /// The change list a **refusal** records, which is never empty.
  ///
  /// Spec §2's no-op suppression was written about writes that changed nothing
  /// and therefore recorded nothing worth reading. A refusal is not that. Its
  /// row is the evidence the guard fired, it is what the phase requirement
  /// means by "including denials", and this class's own contract is that the
  /// evidence exists even if nobody catches the exception. Re-pressing Start
  /// on a machine that is already started, against a bound key, is a denial
  /// with nothing to diff - and deleting its only row would make the guard
  /// invisible in exactly the case an operator is most likely to repeat.
  ///
  /// An operator jabbing a locked Start button therefore produces a run of
  /// identical denial rows. That is a signal, not noise, and the Phase 5
  /// viewer is where it gets collapsed for reading.
  ///
  /// The synthesised row is a whole-value row: a null member, and the value
  /// that was attempted. [renderDynamicValue] rather than a second renderer,
  /// so the deny path and the diff cannot disagree about how a value looks or
  /// about the difference between null and the empty string.
  List<MemberChange> _denialChanges(
    List<MemberChange> changes,
    DynamicValue attempted,
  ) =>
      changes.isNotEmpty
          ? changes
          : [MemberChange(newValue: renderDynamicValue(attempted))];

  /// The value [key] held before this write, or null when there is no usable
  /// baseline.
  ///
  /// Null for three reasons that all mean the same thing to the diff: no
  /// reader was supplied, the read threw, or it did not answer within
  /// [baselineTimeout]. A failed baseline read costs the trail its member
  /// breakdown for one row. Letting it cost the operator their jog would be
  /// the guard causing the outage it exists to prevent.
  Future<DynamicValue?> _baselineOrNull(String key) async {
    final read = _readBaseline;
    if (read == null) return null;
    try {
      return await read(key).timeout(baselineTimeout);
    } on Object catch (error) {
      _logger.w('audit baseline unavailable for "$key": $error');
      return null;
    }
  }

  /// Appends [rows], swallowing and logging a sink that throws.
  ///
  /// `DriftAuditSink.record` already swallows its own failures, so this is
  /// belt-and-braces there. But [AuditSink] is an interface whose non-throwing
  /// contract lives in a doc comment and nothing enforces it, and the
  /// consequences of trusting it differ by path. On the permitted path an
  /// escaping sink exception would fail a write the session was allowed to
  /// make. On the deny path it would replace [AccessDenied] with something no
  /// caller catches, skip the denial callback, and leave the operator with no
  /// prompt and no explanation for a control that did nothing. Neither is
  /// acceptable, and the same rule is written into plans 03-05 and 03-10 in
  /// the same words.
  ///
  /// The price is that a lost row is only a log line, so the line names the
  /// record it lost.
  Future<void> _recordAll(List<AuditRecord> rows) async {
    for (final row in rows) {
      try {
        await _audit.record(row);
      } on Object catch (error, stack) {
        _logger.e(
          'AUDIT ROW LOST: action ${row.actionId}, ${row.who} on '
          '${row.surface}:${row.itemKey}, allowed: ${row.allowed}',
          error: error,
          stackTrace: stack,
        );
      }
    }
  }

  // -------------------------------------------------------------------------
  // Everything else forwards, unchanged
  // -------------------------------------------------------------------------
  //
  // Reads are neither gated nor audited. Spec §11 defers read permissions
  // deliberately, and §6's decorator wraps writes only.

  @override
  Logger get logger => _inner.logger;

  @override
  StateManConfig get config => _inner.config;

  @override
  KeyMappings get keyMappings => _inner.keyMappings;

  @override
  set keyMappings(KeyMappings value) => _inner.keyMappings = value;

  /// Live OPC UA sessions, when this guard happens to wrap a real one.
  ///
  /// Not a [StateMan] member and deliberately not an override: a panel in
  /// gateway mode holds no session and a browser cannot hold one at all. The
  /// browse and diagnostic widgets that ask for this must already cope with an
  /// empty list, because that is what gateway mode has always handed them.
  List<ClientWrapper> get clients {
    final inner = _inner;
    return inner is OpcUaStateMan ? inner.clients : const [];
  }

  @override
  List<DeviceClient> get deviceClients => _inner.deviceClients;

  @override
  String get alias => _inner.alias;

  @override
  set alias(String value) => _inner.alias = value;

  @override
  bool isKeyDisabled(String key) => _inner.isKeyDisabled(key);

  @override
  void setSubstitution(String key, String value) =>
      _inner.setSubstitution(key, value);

  @override
  Stream<Map<String, String>> get substitutionsChanged =>
      _inner.substitutionsChanged;

  @override
  Map<String, String> get substitutions => _inner.substitutions;

  @override
  String? getSubstitution(String key) => _inner.getSubstitution(key);

  @override
  String resolveKey(String key) => _inner.resolveKey(key);

  @override
  Future<DynamicValue> read(String key) => _inner.read(key);

  @override
  Future<Map<String, DynamicValue>> readMany(List<String> keys) =>
      _inner.readMany(keys);

  @override
  Future<Stream<DynamicValue>> subscribe(String key) => _inner.subscribe(key);

  @override
  KeyMappingsUpdateResult updateKeyMappings(KeyMappings newKeyMappings) =>
      _inner.updateKeyMappings(newKeyMappings);

  @override
  List<String> get keys => _inner.keys;

  @override
  List<({String alias, bool isModbus})> get connMetaAliases =>
      _inner.connMetaAliases;

  @override
  Stream<Map<String, DynamicValue>> subscribeConnMeta(String alias) =>
      _inner.subscribeConnMeta(alias);

  @override
  Future<void> close() => _inner.close();

  /// Forwarded, and carrying the same [visibleForTesting] contract the inner
  /// member does — a caller of the guard is warned exactly as a caller of
  /// `StateMan` is.
  ///
  /// The ignore is unavoidable and is **not** the kind the plan bans: nothing
  /// here suppresses a missing implementation. `addSubscription` is public, so
  /// `implements StateMan` requires it, and forwarding a `@visibleForTesting`
  /// member from production code is flagged whatever the forwarder is
  /// annotated with. The alternatives are worse: omitting the member does not
  /// compile, and the catch-all hook is the failure mode this whole file
  /// exists to avoid.
  @override
  @visibleForTesting
  void addSubscription({
    required String key,
    required Stream<DynamicValue> subscription,
    required DynamicValue? firstValue,
  }) =>
      // ignore: invalid_use_of_visible_for_testing_member
      _inner.addSubscription(
        key: key,
        subscription: subscription,
        firstValue: firstValue,
      );
}
