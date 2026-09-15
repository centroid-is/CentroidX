/// `BackendStateMan` refuses by name, on every member, from day one.
///
/// The composer is written whole before any collaborator exists, and this file
/// is what makes that safe. Phase 13's honesty rule is that a member the
/// adapter cannot answer **throws**, naming itself and naming what is missing —
/// never an empty list, never a null, never a silently absent stream. The rig
/// already taught this once: a gateway that answers with silence is
/// indistinguishable, at the panel, from a gateway that is working.
///
/// So the roster below is the test. It walks every entry point on
/// `StateManApi` against a `BackendStateMan` composed with nothing, and asserts
/// each one refuses with its own name in the message. The roster is a **literal**
/// — and a `dart:mirrors` arm asserts the literal is exhaustive over the
/// interface, so a member added to `StateManApi` later fails here instead of
/// quietly joining the surface unjudged. That is `api_surface_test.dart`'s idiom
/// (`packages/tfc_stateman_contract/test/api_surface_test.dart:34,177`), and
/// mirrors are available because both packages are pure Dart under `dart test`.
///
/// On the arithmetic: `StateManApi` declares **18** members. Seventeen of them
/// refuse — nine calls plus the four data-service sub-interface getters plus
/// the four access families plan 17-03 added — and `dispose` does not, because
/// disposing something that was never composed is a no-op and contract cases
/// register it with `addTearDown`. The mirror arm below is the statement of
/// that count that cannot drift.
library;

import 'dart:mirrors';

import 'package:tfc_dart/core/relay/backend_state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
import 'package:test/test.dart';

/// One entry point, and the collaborator whose absence it must name.
typedef Refusal = ({
  String collaborator,
  Future<void> Function(BackendStateMan) invoke,
});

/// Every `StateManApi` member that must refuse when nothing is composed.
///
/// Written as a literal rather than derived, so that adding a member to the
/// interface is a decision somebody makes *here*, with this file's rule in
/// front of them, rather than an omission nobody notices. The exhaustiveness
/// arm below is what turns the literal into a gate.
final Map<String, Refusal> refusals = <String, Refusal>{
  'listen': (
    collaborator: 'BackendValueSource',
    invoke: (s) async => s.listen('AREA01.DEV01.SUB01'),
  ),
  'subscribe': (
    collaborator: 'BackendValueSource',
    invoke: (s) async => s.subscribe('AREA01.DEV01.SUB01'),
  ),
  'read': (
    collaborator: 'BackendValueSource',
    invoke: (s) async => s.read('AREA01.DEV01.SUB01'),
  ),
  'readFresh': (
    collaborator: 'BackendValueSource',
    invoke: (s) async => s.readFresh('AREA01.DEV01.SUB01'),
  ),
  'readMany': (
    collaborator: 'BackendValueSource',
    invoke: (s) async => s.readMany(const ['AREA01.DEV01.SUB01']),
  ),
  'keys': (
    collaborator: 'BackendValueSource',
    invoke: (s) async => s.keys,
  ),
  'write': (
    collaborator: 'BackendWriteSource',
    invoke: (s) async => s.write('AREA01.DEV01.SUB01', true),
  ),
  'writeStatus': (
    collaborator: 'BackendWriteSource',
    invoke: (s) async => s.writeStatus(const ['01JB000000000000000000000A']),
  ),
  'holdToRun': (
    collaborator: 'BackendWriteSource',
    invoke: (s) async => s.holdToRun('AREA01.DEV01.SUB01'),
  ),
  'browse': (
    collaborator: 'BrowseApi',
    invoke: (s) async => s.browse,
  ),
  'timeseries': (
    collaborator: 'TimeseriesApi',
    invoke: (s) async => s.timeseries,
  ),
  'historyViews': (
    collaborator: 'HistoryViewApi',
    invoke: (s) async => s.historyViews,
  ),
  'preferences': (
    collaborator: 'PreferencesApi',
    invoke: (s) async => s.preferences,
  ),
  // The four access families (17-03). They join the roster on exactly the
  // argument the nine above joined it on: this adapter was composed without an
  // access store, and an `AuditApi` that answered "no entries" would be a claim
  // about a trail it has never read. 17-06 gives them collaborators; until then
  // each is one more constructor argument that is null.
  'accessTemplates': (
    collaborator: 'AccessTemplateApi',
    invoke: (s) async => s.accessTemplates,
  ),
  'accessAdmin': (
    collaborator: 'AccessAdminApi',
    invoke: (s) async => s.accessAdmin,
  ),
  'audit': (
    collaborator: 'AuditApi',
    invoke: (s) async => s.audit,
  ),
  'backendConfig': (
    collaborator: 'BackendConfigApi',
    invoke: (s) async => s.backendConfig,
  ),
};

/// The one member that must NOT refuse.
const notARefusal = 'dispose';

/// Every public member `StateManApi` declares, inherited members included.
///
/// Trimmed from `api_surface_test.dart:177`'s `_walkSurface`; it is short
/// enough to carry here and keeping it local means this file does not depend on
/// another package's test.
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
  group('a BackendStateMan composed with nothing', () {
    late BackendStateMan adapter;

    setUp(() => adapter = BackendStateMan());

    test('is a StateManApi', () {
      // The composer is the whole surface from day one. If this stops being
      // true, the later plans that hand it collaborators have nothing to hand
      // them to.
      expect(adapter, isA<relay.StateManApi>());
    });

    for (final entry in refusals.entries) {
      final member = entry.key;
      final refusal = entry.value;

      test('$member refuses, naming itself and its missing collaborator',
          () async {
        await expectLater(
          () => refusal.invoke(adapter),
          throwsA(isA<UnsupportedError>()
              .having((e) => e.message.toString(), 'message',
                  contains('BackendStateMan.$member'))
              .having((e) => e.message.toString(), 'names the collaborator',
                  contains(refusal.collaborator))),
          reason: 'every unwired member must say which member it is and what '
              'the composition is missing; an operator cannot act on "not '
              'implemented"',
        );
      });
    }

    test('no refusal message hides behind "TODO" or "not implemented"', () async {
      for (final entry in refusals.entries) {
        Object? caught;
        try {
          await entry.value.invoke(adapter);
        } catch (e) {
          caught = e;
        }
        final message = (caught as UnsupportedError).message.toString();
        expect(message.toLowerCase(), isNot(contains('todo')),
            reason: '${entry.key}: a refusal that names a plan instead of a '
                'missing collaborator tells the operator nothing to change');
        expect(message.toLowerCase(), isNot(contains('not implemented')),
            reason: '${entry.key}: the member IS implemented; what is absent '
                'is the thing behind it');
      }
    });

    test('read refuses rather than answering null', () {
      // `StateManApi.read` returns null for "not known yet", which is a value
      // state — an adapter with no value source at ALL that answered null would
      // be reporting a fact it has no way of knowing. This is the exact
      // silence-as-success failure the phase exists to prevent, and it is the
      // one refusal that is easiest to "simplify" away later.
      expect(() => adapter.read('AREA01.DEV01.SUB01'), throwsUnsupportedError);
    });

    test('dispose completes normally: disposing nothing is a no-op', () async {
      // The single exception to the rule above, and deliberately so: contract
      // cases register dispose with `addTearDown`, so a composition that
      // refused it would fail every test that used it as a fixture.
      await expectLater(adapter.dispose(), completes);
    });
  });

  group('the roster is exhaustive over StateManApi', () {
    test('every declared member is either judged or explicitly exempt', () {
      final declared = declaredMemberNames(relay.StateManApi);
      final covered = {...refusals.keys, notARefusal};

      expect(declared.difference(covered), isEmpty,
          reason: 'a member of StateManApi that this roster does not name is a '
              'member no test judges — which is how a member that answers with '
              'silence instead of a refusal gets onto the wire');
      expect(covered.difference(declared), isEmpty,
          reason: 'the roster names something StateManApi no longer declares; '
              'a stale entry makes the count above meaningless');
      expect(declared, hasLength(18),
          reason: 'seventeen members refuse and dispose does not; if this '
              'number moved, the interface grew and somebody owes the new '
              'member a decision. It moved from 14 to 18 when plan 17-03 added '
              'the four access families, and the four decisions are recorded '
              'in the roster above');
    });
  });
}
