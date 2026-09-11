/// A [KeyPolicy] whose three answers are **independently controllable**, and
/// the reason it exists.
///
/// It replaces `policy_test.dart:332`'s `_HidesTags`, which was
///
/// ```dart
/// bool canSee(String key, Identity identity) => !hidden.contains(key);
/// bool canWrite(String key, Identity identity) => identity.role == Role.operate;
/// ```
///
/// — a `canWrite` that ignores `hidden` entirely. Every write-refusal arm
/// driven by that double was satisfied by `canSee` making the key **absent**,
/// so none of them proved that `canWrite` was consulted at all. 17-CONTEXT
/// D-12 records it as one of the two vacuity defects this milestone has been
/// bitten by, and it is why every arm in this phase carries a live control.
///
/// Declared in `test/support/` rather than in the one file that needs it today
/// so 17-07 adopts *this* double instead of writing a second copy — two doubles
/// with the same name and different honesty is how the first one survived.
///
/// The three predicates default to "yes", so a case names only the answer it is
/// interested in and the rest stay out of the way.
library;

import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/policy/key_policy.dart';

/// One scripted answer: whether [identity] may do the thing to [key].
typedef PolicyAnswer = bool Function(String key, StationIdentity identity);

bool _yes(String key, StationIdentity identity) => true;

final class ScriptedPolicy implements KeyPolicy {
  const ScriptedPolicy({
    PolicyAnswer sees = _yes,
    PolicyAnswer writes = _yes,
    PolicyAnswer writesPreference = _yes,
  })  : _sees = sees,
        _writes = writes,
        _writesPreference = writesPreference;

  /// Sees everything, writes nothing. The half `_HidesTags` could express.
  factory ScriptedPolicy.readOnly() =>
      ScriptedPolicy(writes: _no, writesPreference: _no);

  /// Sees nothing, writes everything. **The half `_HidesTags` could not
  /// express**, and the one that makes a write-refusal arm falsifiable: under
  /// this double a refused write can only have been refused by the existence
  /// check, and a refused write under [ScriptedPolicy.readOnly] can only have
  /// been refused by the write gate.
  factory ScriptedPolicy.invisibleButWritable() => ScriptedPolicy(sees: _no);

  /// Hides exactly [hidden] and answers yes to everything else — `_HidesTags`'
  /// stated intent, with `canWrite` no longer secretly doing the same job.
  factory ScriptedPolicy.hiding(Set<String> hidden) =>
      ScriptedPolicy(sees: (key, _) => !hidden.contains(key));

  final PolicyAnswer _sees;
  final PolicyAnswer _writes;
  final PolicyAnswer _writesPreference;

  @override
  bool canSee(String key, StationIdentity identity) => _sees(key, identity);

  @override
  bool canWrite(String key, StationIdentity identity) => _writes(key, identity);

  @override
  bool canWritePreference(String key, StationIdentity identity) =>
      _writesPreference(key, identity);
}

bool _no(String key, StationIdentity identity) => false;

/// A station identity with a scripted group set, for cases whose subject is the
/// policy rather than the credential.
StationIdentity stationHolding(
  Set<AccessGroup> groups, {
  String station = 'ST101',
  String username = 'ST101-panel',
  String roleName = 'Line Panel',
}) {
  final user = AuthenticatedUser(
    username: username,
    roleName: roleName,
    stationAccount: true,
  );
  return StationIdentity(
    user: user,
    station: station,
    session: AccessSession(user: user, groups: groups),
  );
}
