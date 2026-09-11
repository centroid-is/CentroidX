/// The standing proof the access suite can fail: seven damage modes, each run on
/// both legs, each reddening a named set of checks and leaving a control green.
///
/// `broken_browse.dart`'s discipline, applied to access: a sabotage that failed
/// everything would prove nothing about any individual check, so every mode is
/// correct except one and the test asserts BOTH halves — the targeted checks go
/// red, and a neighbour stays green. Run on the in-memory leg and over the
/// channel, because a mode that reddens in memory and not over the channel is a
/// channel port swallowing something (mode (g) is the one deliberate exception,
/// and it is a finding, documented below).
@TestOn('vm')
@Tags(['contract'])
library;

import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_access_services.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';
import 'package:test/test.dart';

/// The two legs, each a fresh implementation from a damaged access store.
typedef Leg = ({String name, StateManApi Function(AccessDamage) make});

final _legs = <Leg>[
  (name: 'in-memory', make: (d) => FakeStateMan(access: BrokenAccessServices(d))),
  (
    name: 'channel',
    make: (d) => channelServedFake(access: BrokenAccessServices(d))
  ),
];

/// Runs the check named [name] against a fresh instance and returns whether it
/// FAILED (threw). Disposes the instance afterward.
Future<bool> _reddens(Leg leg, AccessDamage damage, String name) async {
  final api = leg.make(damage);
  final check = accessChecks[name] ??
      (throw ArgumentError('no such access check: "$name"'));
  try {
    await check(api);
    return false;
  } catch (_) {
    return true;
  } finally {
    await api.dispose();
  }
}

/// Asserts every check in [red] fails and every check in [green] passes, on both
/// legs — recording the per-leg outcome in the failure message.
void _mode(
  AccessDamage damage, {
  required List<String> red,
  required List<String> green,
}) {
  for (final leg in _legs) {
    for (final name in red) {
      test('[$damage/${leg.name}] reddens: $name', () async {
        expect(await _reddens(leg, damage, name), isTrue,
            reason: 'damage $damage did NOT redden "$name" on the ${leg.name} '
                'leg — the check it is meant to be caught by let it through, '
                'which is the vacuity this suite exists to forbid');
      });
    }
    for (final name in green) {
      test('[$damage/${leg.name}] leaves green: $name', () async {
        expect(await _reddens(leg, damage, name), isFalse,
            reason: 'damage $damage reddened "$name" on the ${leg.name} leg, '
                'which it should not touch — the sabotage is not surgical, so a '
                'red result no longer isolates the property it is aimed at');
      });
    }
  }
}

// The check names, quoted from accessChecks so a rename fails here loudly.
const _tplCreate =
    'creating a template refuses a configure session and permits a users one';
const _tplReads = 'the template reads are ungated and still answer';
const _roleCreate = 'creating a role refuses configure and permits users';
const _configWrite =
    'writing the backend config refuses configure and permits administer';
const _configRead =
    'reading the backend config refuses configure and permits administer';
const _configValidate = 'the backend config is validated before it is persisted';
const _relayLock = 'a relay-section edit is refused by name';
const _auditRecords =
    'the audit trail records every decision, allowed and refused';
const _auditReads = 'the audit reads are ungated';
const _pwNoEcho = 'setUserPassword never echoes the secret and still succeeds';
const _pwPaired = 'resetting a password refuses configure and permits users';

void main() {
  group('(a) checksAfterWriting — the pre-effect property', () {
    // The refusal still happens (it does refuse); the store-untouched half is
    // what breaks. The fused paired checks go red on their writes-empty half.
    _mode(AccessDamage.checksAfterWriting,
        red: [_tplCreate, _configWrite],
        green: [_tplReads, _auditRecords]);

    // The asymmetry stated directly, since the fused checks cannot show it: a
    // refusal STILL throws AccessDenied, and the store grew anyway.
    for (final leg in _legs) {
      test('[a/${leg.name}] the refusal is still an AccessDenied, and the store '
          'was touched anyway', () async {
        final api = leg.make(AccessDamage.checksAfterWriting);
        addTearDown(api.dispose);
        final h = api as StateManAccessHarness;
        h.actAs(AccessSession(groups: {AccessGroup.configure}));
        final before = h.accessStoreWrites.length;
        Object? refusal;
        try {
          await api.accessTemplates.create(AccessTemplate(
              name: 'x', rules: const {kWholeKeyMember: AccessGroup.setpoints}));
        } catch (e) {
          refusal = e;
        }
        expect(refusal, isA<AccessDenied>(),
            reason: 'mode (a) must STILL refuse — the plain refusal is what a '
                'naive test sees, and it stays green; got $refusal');
        expect(h.accessStoreWrites.length, greaterThan(before),
            reason: 'mode (a) is the store being touched before the refusal; if '
                'it were not, the writes-empty half would have nothing to catch');
      });
    }
  });

  group('(b) refusesEverything — the blank page', () {
    // Every permitted twin goes red. The template-reads and audit-records
    // checks are COLLATERAL red — both do a gated create in their setup, which
    // (b) refuses. The audit READS check needs no gated setup, so it is the
    // honest control. Collateral recorded in the SUMMARY.
    _mode(AccessDamage.refusesEverything,
        red: [_tplCreate, _roleCreate, _configRead],
        green: [_auditReads]);
  });

  group('(c) ignoresSession — the gate never consulted', () {
    // Every refusal arm goes red (nothing is refused). Reads-ungated stays
    // green. The audit-records check is COLLATERAL red (its refused seed is now
    // allowed, so no refusal row is recorded) — recorded in the SUMMARY.
    _mode(AccessDamage.ignoresSession,
        red: [_tplCreate, _roleCreate, _configRead],
        green: [_tplReads]);
  });

  group('(d) auditWritesNothing — the trail stops', () {
    _mode(AccessDamage.auditWritesNothing,
        red: [_auditRecords],
        green: [_tplCreate, _configWrite]);
  });

  group('(e) acceptsRelaySectionEdit — D-10 second hazard reopened', () {
    _mode(AccessDamage.acceptsRelaySectionEdit,
        red: [_relayLock],
        green: [_configWrite, _configValidate]);
  });

  group('(f) writesWithoutValidating — D-10 first hazard reopened', () {
    _mode(AccessDamage.writesWithoutValidating,
        red: [_configValidate],
        green: [_relayLock, _configWrite]);
  });

  group('(g) leaksPassword — the secret in the refusal message', () {
    // In memory the leak reaches the check: the refusal's toString carries the
    // password. Over the channel it does NOT — the served side maps the
    // AccessDenied to a wire error and the client RE-RAISES a clean AccessDenied
    // (D-09), so the client-side no-echo check sees a sanitised message. That is
    // a FINDING, not a swallowed defect in another mode: the no-echo property is
    // a client-side assertion, and 17-07's real forbidden messages must not echo
    // secrets because the contract cannot catch that over the wire. The paired
    // password check stays green on both legs — the refusal is still an
    // AccessDenied and the store is untouched.
    test('[g/in-memory] reddens the no-echo check', () async {
      expect(
          await _reddens(_legs[0], AccessDamage.leaksPassword, _pwNoEcho), isTrue,
          reason: 'the in-memory leg did not catch a password echoed in a '
              'refusal message');
    });
    test('[g/channel] the no-echo check does NOT redden — the re-raise sanitises '
        '(finding)', () async {
      expect(
          await _reddens(_legs[1], AccessDamage.leaksPassword, _pwNoEcho),
          isFalse,
          reason: 'if the channel leg reddened here, the re-raise would be '
              'leaking the wire message into the client exception — which would '
              'be a different, worse bug than the one under test');
    });
    for (final leg in _legs) {
      test('[g/${leg.name}] the paired password check stays green', () async {
        expect(await _reddens(leg, AccessDamage.leaksPassword, _pwPaired),
            isFalse,
            reason: 'mode (g) reddened the paired refusal check on the '
                '${leg.name} leg; it should only touch the no-echo assertion');
      });
    }
  });
}
