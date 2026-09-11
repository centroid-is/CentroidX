/// The access surface is exhaustive over `StateManApi`, and both kit
/// implementations now *answer* it rather than refuse it.
///
/// 17-03 added `accessTemplates`, `accessAdmin`, `audit` and `backendConfig` to
/// `StateManApi`; 17-03b left this package's two implementations —
/// `FakeStateMan` and `ChannelStateMan` — **refusing** those four by name,
/// until a contract case existed to judge them. Plan 17-05 wrote that contract
/// (`access_contract.dart`, judged in `access_contract_meta_test.dart` and swept
/// on both legs by `harness_parity_test.dart`) and gave both implementations a
/// real access surface: `FakeStateMan` holds [FakeAccessServices], and
/// `ChannelStateMan` forwards the four families over the harness channel.
///
/// So the refusal arms that lived here are gone — a refusal a contract now
/// answers would be a false claim. What remains is the property those arms were
/// standing in for while the contract was being written: that the interface
/// declares **exactly** the four access getters this package knows how to judge,
/// and no unjudged fifth. A sub-API getter added with nothing behind it would
/// slip past `dart analyze` (it compiles) and reach a driver as a silent answer;
/// this arm names the newcomer instead.
@TestOn('vm')
@Tags(['contract'])
library;

import 'dart:mirrors';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';
import 'package:test/test.dart';

/// The four access getters the contract has a home for.
const accessFamilies = <String>[
  'accessTemplates',
  'accessAdmin',
  'audit',
  'backendConfig',
];

/// Every public member `StateManApi` declares, inherited members included.
Set<String> declaredMemberNames(Type type) {
  final seen = <String>{};
  final visited = <ClassMirror>{};

  void walk(ClassMirror mirror) {
    if (!visited.add(mirror)) return;
    for (final member in mirror.declarations.values.whereType<MethodMirror>()) {
      if (member.isConstructor || member.isPrivate) continue;
      final name = MirrorSystem.getName(member.simpleName);
      seen.add(name.endsWith('=') ? name.substring(0, name.length - 1) : name);
    }
    mirror.superinterfaces.forEach(walk);
    final parent = mirror.superclass;
    if (parent != null && parent.reflectedType != Object) walk(parent);
  }

  walk(reflectClass(type));
  return seen;
}

void main() {
  group('the access surface is exhaustive over StateManApi', () {
    test('the interface declares exactly these four access getters', () {
      final declared = declaredMemberNames(StateManApi);

      for (final member in accessFamilies) {
        expect(declared, contains(member),
            reason: '"$member" is judged by the access contract but StateManApi '
                'no longer declares it; a stale entry makes the contract judge '
                'a member the interface has dropped');
      }

      // The other side: a fifth access-shaped getter arriving unjudged. Spelled
      // as the full member set minus the ones this package has a home for, so a
      // failure names the newcomer rather than reporting a count.
      const judgedElsewhere = <String>{
        'listen', 'subscribe', 'read', 'readFresh', 'readMany', 'keys',
        'write', 'writeStatus', 'holdToRun', 'browse', 'timeseries',
        'historyViews', 'preferences', 'dispose',
      };
      expect(declared.difference({...judgedElsewhere, ...accessFamilies}),
          isEmpty,
          reason: 'StateManApi grew a member this contract has never seen. If '
              'it is a sub-API getter with nothing behind it, it owes the '
              'access contract a family to judge it — and this file an entry');
    });

    test('the access contract judges every declared access family', () {
      // The contract and this roster must not drift: every family named here is
      // exercised by at least one access check.
      final judged = accessChecks.keys.join(' | ').toLowerCase();
      for (final family in accessFamilies) {
        final surface = switch (family) {
          'accessTemplates' => 'template',
          'accessAdmin' => 'role',
          'audit' => 'audit',
          'backendConfig' => 'config',
          _ => family,
        };
        expect(judged, contains(surface),
            reason: 'no access check mentions the $family surface ("$surface"), '
                'so that family is declared but unjudged');
      }
    });
  });
}
