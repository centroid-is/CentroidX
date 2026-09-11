@TestOn('vm')

/// `KeyPolicy` stops being a policy and becomes an **adapter**.
///
/// PROJECT.md's constitution for this phase: *"one master access control
/// system, the websocket can build on top of that"*. The rule "a tag write
/// needs `operate`" is therefore not stated in this package. It is stated once,
/// in `AccessPolicy.groupForTag`'s operate floor, and `AccessPolicyKeyPolicy`
/// **asks**.
///
/// Four properties:
///
///  1. **`canWrite` is `session.can(groupForWireSurface('tag', key))`** — the
///     single statement of the tag rule reaching the wire, rather than a second
///     copy of it living in a role comparison.
///  2. **`canSee` still answers true for everything under the shipped
///     configuration, and is still a real seam.** Both halves: there is no
///     hiding data, and a policy given a hiding lookup hides. A seam that hid a
///     tag nobody configured would be policy invented by the plumbing; a
///     constant that could not hide would not be a seam.
///  3. **`canWritePreference` asks `groupForPref`** — the third member, closing
///     sweep §3.12 point 1. D-03, ruled 2026-09-07: `key_mappings` grades as
///     `configure` over the wire exactly as it does at a panel, and there is no
///     per-key exception.
///  4. **All three members are synchronous.** An `await` here opens the
///     `SubscriptionLimitExceeded` race `session_handlers.dart:255-264` names,
///     which surfaces as `-32011 handlerFailed` — "possibly transient:
///     retrying is legitimate" — so a panel would retry a limit it can never
///     get under.
///
/// Plus the double. `policy_test.dart:332`'s `_HidesTags` authorised writes to
/// keys it claimed to hide (17-CONTEXT D-12); [ScriptedPolicy] replaces it, and
/// the arms below prove its two answers really are independently observable —
/// which is the exact property the old one lacked.
library;

import 'dart:mirrors';

import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_server/src/policy/key_policy.dart';

import 'support/scripted_policy.dart';

/// An unbound tag: no access template names it, so `groupForTag` answers its
/// `operate` floor.
const _tag = 'ST101.CN01.MOT01.cmd';

void main() {
  group('canWrite asks the master policy about tags', () {
    test('an unbound tag write takes operate, and the adapter does not say so',
        () {
      const policy = AccessPolicy();
      const adapter = AccessPolicyKeyPolicy(policy: policy);

      final operating = stationHolding(const {AccessGroup.operate});
      final nothing = stationHolding(const <AccessGroup>{});

      expect(adapter.canWrite(_tag, operating), isTrue);
      expect(adapter.canWrite(_tag, nothing), isFalse,
          reason: 'the two halves of one claim: a station holding operate '
              'writes and a station holding nothing does not. Without the '
              'second, an adapter returning true for everybody passes');

      expect(adapter.canWrite(_tag, operating),
          operating.session.can(policy.groupForWireSurface('tag', _tag)),
          reason: 'the equality, not just the answer. This is the rule "a tag '
              'write needs operate" being asked for rather than restated: it '
              'is stated once, in AccessPolicy.groupForTag\'s operate floor, '
              'and PROJECT.md says it must exist once');
      expect(adapter.canWrite(_tag, nothing),
          nothing.session.can(policy.groupForWireSurface('tag', _tag)));
    });

    test('a binding that raises the requirement raises what the wire takes',
        () {
      // The falsifiable half of the delegation claim. The arm above compares
      // the adapter against the policy, which a hard-coded `operate` compare
      // would also satisfy — `groupForTag`'s floor *is* operate. This one moves
      // the policy's answer and requires the adapter to move with it.
      final policy = AccessPolicy(
          tagBindings: (key, member) =>
              key == _tag ? AccessGroup.administer : null);
      final adapter = AccessPolicyKeyPolicy(policy: policy);

      final operating = stationHolding(const {AccessGroup.operate});
      final administering = stationHolding(const {AccessGroup.administer});

      expect(adapter.canWrite(_tag, operating), isFalse,
          reason: 'the template raised this key to administer, and a station '
              'holding only operate no longer writes it. An adapter that '
              'compared against a role enum could not see this at all');
      expect(adapter.canWrite(_tag, administering), isTrue);
      expect(adapter.canWrite('ST101.CN02.MOT01.cmd', operating), isTrue,
          reason: 'the anti-vacuity half: an unbound key beside it still takes '
              'the operate floor, so the refusal above is the binding and not '
              'a policy that refuses everything');
    });
  });

  group('canSee is still a seam, and still hides nothing that was shipped', () {
    test('everything is visible under the shipped configuration', () {
      const adapter = AccessPolicyKeyPolicy();
      final display = stationHolding(const <AccessGroup>{});

      for (final key in const [
        _tag,
        'ST201.CN14.SEN02.state',
        'pipe.egress_kbps',
      ]) {
        expect(adapter.canSee(key, display), isTrue,
            reason: 'there is no hiding data in this phase either, and a seam '
                'that hid a tag nobody configured would be policy invented by '
                'the plumbing. Note the station holds no groups at all: '
                'read permissions are deferred (spec §11), so canSee is a '
                'visibility question and not a permission question');
      }
    });

    test('the visibility member is genuinely consulted', () {
      // The other half. A `canSee` hard-coded to `=> true` passes the arm
      // above, and the seam this whole file exists for would be gone with
      // nothing failing.
      final adapter = AccessPolicyKeyPolicy(
          visibility: (key, identity) => key != _tag);
      final panel = stationHolding(const {AccessGroup.operate});

      expect(adapter.canSee(_tag, panel), isFalse);
      expect(adapter.canSee('ST201.CN14.SEN02.state', panel), isTrue,
          reason: 'a lookup that hid everything would pass the assertion '
              'above and serve an empty plant');
    });
  });

  group('canWritePreference asks groupForPref — sweep §3.12 point 1', () {
    const policy = AccessPolicy();
    const adapter = AccessPolicyKeyPolicy(policy: policy);

    /// Four cases, one per rule kind plus the default.
    const cases = <String, AccessGroup>{
      'key_mappings': AccessGroup.configure,
      'theme_mode': AccessGroup.operate,
      'collector_config': AccessGroup.administer,
      'a_key_no_rule_matches': AccessGroup.administer,
    };

    for (final entry in cases.entries) {
      test('${entry.key} takes ${entry.value.name}', () {
        final holder = stationHolding({entry.value});
        final empty = stationHolding(const <AccessGroup>{});

        expect(adapter.canWritePreference(entry.key, holder), isTrue);
        expect(adapter.canWritePreference(entry.key, empty), isFalse,
            reason: 'the live control: a station holding nothing is refused, '
                'so the assertion above is the group being held and not an '
                'adapter that says yes');
        expect(adapter.canWritePreference(entry.key, holder),
            holder.session.can(policy.groupForPref(entry.key)),
            reason: 'the app\'s kPrefAccessRules wins everywhere and there is '
                'no per-key exception (D-03, ruled 2026-09-07). The adapter '
                'asks the same table GuardedPreferences asks');
      });
    }

    test('key_mappings takes configure and not the tag floor', () {
      // The §3.12 point-1 closure, stated as the thing that used to be false.
      // Before this phase every preferences frame asked one question —
      // `role == operate` — for every key alike, so a station the gateway
      // called `operate` could re-point the plant's tag map over the pipe
      // while an operator standing at a panel could not. D-03 accepted the
      // deployment cost of closing that: engineering panels are provisioned
      // with a configure-holding role.
      final operateOnly = stationHolding(const {AccessGroup.operate});

      expect(adapter.canWritePreference('key_mappings', operateOnly), isFalse,
          reason: 'this is the behaviour change on the wire that D-03 accepted '
              'by name, and keeping this one key at operate was declined '
              'precisely because it would reintroduce the §3.12 divergence in '
              'the place it bites most often');
      expect(adapter.canWritePreference('theme_mode', operateOnly), isTrue,
          reason: 'the anti-vacuity half: the same station still writes what a '
              'panel writes about itself, so the refusal above is the key\'s '
              'grading and not a station that can write nothing');
      expect(adapter.canWrite('key_mappings', operateOnly), isTrue,
          reason: 'and the two members really do answer differently for the '
              'same string: as a *tag* it takes the operate floor, as a '
              '*preference* it takes configure. A canWritePreference that '
              'delegated to canWrite would answer true here');
    });
  });

  group('the interface itself', () {
    test('all three members are synchronous', () {
      final members = reflectClass(KeyPolicy)
          .declarations
          .values
          .whereType<MethodMirror>()
          .where((member) => !member.isConstructor && !member.isPrivate)
          .toList();

      expect(
          members.map((m) => MirrorSystem.getName(m.simpleName)).toSet(),
          {'canSee', 'canWrite', 'canWritePreference'},
          reason: 'three members, and exactly three. The doc\'s rejection of a '
              'hypothetical canHold stands: that one would have no policy data '
              'behind it. This one has thirty-four rules in kPrefAccessRules, '
              'which the app has been enforcing since Phase 3');

      for (final member in members) {
        final name = MirrorSystem.getName(member.simpleName);
        final returns = MirrorSystem.getName(member.returnType.simpleName);
        expect(returns, 'bool',
            reason: '$name returns $returns. An asynchronous policy is the '
                'await between the atCapacity check and the put in '
                'session_handlers.dart:255-264 — the comment there names this '
                'seam as the obvious thing to open the race. A subscription '
                'that got past a full ceiling is refused as -32011 '
                'handlerFailed, whose documented meaning is "retrying is '
                'legitimate", so a panel would retry a limit it can never get '
                'under. The role set is cached in memory on the same reload '
                'that refreshes the token set; there is nothing here to await');
      }
    });

    test('no member can carry a refusal reason', () {
      // Claim 2 of the interface's doc, asserted structurally. `canSee == false`
      // must mean the key is **absent**, never "forbidden": a gateway that
      // answers forbidden for a tag a station may not see has told that station
      // the tag exists, and a thousand such questions enumerate the plant's
      // address space to a peer that may not read a byte of it.
      //
      // At this level the property is a type property: every member answers a
      // bare bool, so there is no channel through which a reason could travel.
      // The decorator half — that a hidden key takes the nonexistent-tag path
      // through `keys` and the refusal carries no `forbidden` — needs
      // PolicyStateMan, which is 17-07's file and does not compile until it
      // lands. This arm is what is falsifiable here.
      final members = reflectClass(KeyPolicy)
          .declarations
          .values
          .whereType<MethodMirror>()
          .where((member) => !member.isConstructor && !member.isPrivate);

      expect(members, isNotEmpty,
          reason: 'the anti-vacuity half: a mirror that read no members would '
              'satisfy every claim below about what the members are not');
      for (final member in members) {
        expect(MirrorSystem.getName(member.returnType.simpleName), 'bool',
            reason: 'a member returning a reason type — a String?, a sealed '
                'verdict — is a member through which "you may not see this" '
                'can reach the wire');
      }
    });

    test('the policy lives in the server package', () {
      // Read as the library's uri rather than its name: every library in this
      // package is declared `library;`, so simpleName is empty for all of them
      // and a name-based assertion would pass against anything.
      final home = (reflectClass(KeyPolicy).owner! as LibraryMirror).uri;
      expect('$home', startsWith('package:tfc_relay_server/'),
          reason: 'the access-control question is not one a connected client '
              'may ask. api_surface_test.dart:213-226 calls the 49-member set '
              '"the access-control policy", so a policy *query* on it would be '
              'the thing it guards asking itself for permission');
    });
  });

  group('the replacement double can lie in two directions', () {
    test('a double that sees everything and writes nothing', () {
      final policy = ScriptedPolicy.readOnly();
      final panel = stationHolding(const {AccessGroup.operate});

      expect(policy.canSee(_tag, panel), isTrue);
      expect(policy.canWrite(_tag, panel), isFalse);
      expect(policy.canWritePreference('theme_mode', panel), isFalse);
    });

    test('a double that sees nothing and writes everything', () {
      // The configuration `_HidesTags` could not express. Its canWrite was
      // `identity.role == Role.operate` and ignored `hidden` entirely, so
      // every write-refusal arm driven by it was satisfied by canSee making
      // the key absent — it proved nothing about canWrite being consulted at
      // all (17-CONTEXT D-12).
      final policy = ScriptedPolicy.invisibleButWritable();
      final panel = stationHolding(const {AccessGroup.operate});

      expect(policy.canSee(_tag, panel), isFalse);
      expect(policy.canWrite(_tag, panel), isTrue,
          reason: 'this is the whole point: under this double a write that '
              'comes back refused can only have been refused by the existence '
              'check, and under readOnly() it can only have been refused by '
              'the write gate. That is what makes a write-refusal arm '
              'falsifiable');
    });

    test('the two answers are observably independent for one key and one '
        'station', () {
      final panel = stationHolding(const {AccessGroup.operate});

      final seesNotWrites = ScriptedPolicy.readOnly();
      final writesNotSees = ScriptedPolicy.invisibleButWritable();

      expect(
          [
            seesNotWrites.canSee(_tag, panel),
            seesNotWrites.canWrite(_tag, panel),
            writesNotSees.canSee(_tag, panel),
            writesNotSees.canWrite(_tag, panel),
          ],
          [true, false, false, true],
          reason: 'all four corners, for one key and one identity. A double '
              'whose canWrite is derived from its canSee cannot produce this '
              'table, and that derivation is exactly the defect the old one '
              'had');
    });

    test('hiding does not silently decide writes', () {
      final policy = ScriptedPolicy.hiding({_tag});
      final panel = stationHolding(const {AccessGroup.operate});

      expect(policy.canSee(_tag, panel), isFalse);
      expect(policy.canWrite(_tag, panel), isTrue,
          reason: '`hiding` hides and does nothing else. `_HidesTags` was '
              'named for this and did two jobs, one of them invisibly');
    });
  });
}
