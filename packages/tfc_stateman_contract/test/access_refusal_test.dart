/// The kit's two `StateManApi` implementations refuse the four access
/// families, by name, and can still answer everything else.
///
/// Plan 17-03 added `accessTemplates`, `accessAdmin`, `audit` and
/// `backendConfig` to `StateManApi`. Neither implementation in this package has
/// anything behind them: `ChannelStateMan` forwards over a channel that carries
/// no access method, and `FakeStateMan` has no in-memory access store. So both
/// refuse, and this file is what makes the refusal a property rather than a
/// placeholder.
///
/// ## Why a refusal and not an empty implementation
///
/// `channel_state_man.dart`'s own library doc already made this argument once,
/// about the four data services: *"They were stubs that threw until plan 02-08,
/// deliberately — a getter returning an empty implementation would have let
/// `runDataServicesContract` run against a channel carrying nothing and report
/// a colour."* The four access families are in exactly that state now, and the
/// same sentence governs them. An `AuditApi` that answered "no entries" would
/// be a claim about a trail this object has never read.
///
/// ## The anti-vacuity half
///
/// A refusal arm passes vacuously if the member was never reachable at all, so
/// every refusal group below is paired with a **live control**: a neighbouring
/// member on the same object that still answers. If the control ever fails, the
/// refusals below prove nothing, because an object that refuses everything
/// would pass them.
///
/// ## The exhaustiveness half
///
/// The four names are written as a literal *and* checked against what
/// `StateManApi` declares, by mirrors — `api_surface_test.dart`'s idiom. A
/// fifth sub-API getter added to the interface with nothing behind it fails
/// here rather than reaching a driver as a silent answer.
library;

import 'dart:mirrors';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/src/channel/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:test/test.dart';

/// The four getters this file judges, and nothing else.
///
/// A literal rather than a derivation, so that adding a fifth is a decision
/// somebody makes here with this file's rule in front of them. The mirror arm
/// at the bottom turns the literal into a gate.
const accessFamilies = <String>[
  'accessTemplates',
  'accessAdmin',
  'audit',
  'backendConfig',
];

/// Reaches one access family on [api] without knowing which class it is.
///
/// Written as a switch over the literal rather than through mirrors: a mirror
/// invocation would report `NoSuchMethodError` for a member that was never
/// declared, which is indistinguishable here from the refusal being tested.
Object? reachFamily(StateManApi api, String member) => switch (member) {
      'accessTemplates' => api.accessTemplates,
      'accessAdmin' => api.accessAdmin,
      'audit' => api.audit,
      'backendConfig' => api.backendConfig,
      _ => throw ArgumentError('unknown access family "$member"'),
    };

/// Every public member `StateManApi` declares, inherited members included.
///
/// Trimmed from `api_surface_test.dart`'s `_walkSurface`.
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

/// Asserts [api] refuses all four families, naming [className] and the member.
void expectRefusesEveryFamily(StateManApi Function() api, String className) {
  for (final member in accessFamilies) {
    test('$member refuses, naming itself', () {
      expect(
        () => reachFamily(api(), member),
        throwsA(isA<UnsupportedError>().having(
            (e) => e.message.toString(),
            'message',
            contains('$className.$member'))),
        reason: 'an unwired member must say which member it is and on which '
            'class; "unsupported" on its own is not something anybody can act '
            'on',
      );
    });
  }

  test('no refusal hides behind "TODO" or "not implemented"', () {
    for (final member in accessFamilies) {
      Object? caught;
      try {
        reachFamily(api(), member);
      } catch (e) {
        caught = e;
      }
      final message = (caught as UnsupportedError).message.toString();
      expect(message.toLowerCase(), isNot(contains('todo')),
          reason: '$member: a refusal naming a plan instead of the missing '
              'thing tells a reader nothing to change');
      expect(message.toLowerCase(), isNot(contains('not implemented')),
          reason: '$member: the member IS implemented; what is absent is the '
              'store behind it');
    }
  });

  test('no family answers with an empty value instead of refusing', () {
    // The failure this whole file exists to prevent, stated directly. A getter
    // that answered *anything* — an empty template list, a null-object audit
    // reader — would be a claim made by an object that has never asked
    // anything. `expect` on a returned value rather than on a throw, so this
    // arm fails with "returned X" rather than with a type error.
    for (final member in accessFamilies) {
      Object? returned;
      var threw = false;
      try {
        returned = reachFamily(api(), member);
      } catch (_) {
        threw = true;
      }
      expect(threw, isTrue,
          reason: '$className.$member answered with $returned instead of '
              'refusing. A stub that says "no templates" is an answer, and an '
              'answer from an object with no store behind it is a lie the '
              'caller cannot tell from the truth');
    }
  });
}

void main() {
  group('ChannelStateMan', () {
    late ChannelServedFake fixture;

    setUp(() {
      fixture = serveFakeOverChannel();
      addTearDown(fixture.api.dispose);
    });

    expectRefusesEveryFamily(() => fixture.api, 'ChannelStateMan');

    test('LIVE CONTROL: the data services still forward over the channel',
        () async {
      // Without this, every refusal above is satisfied by a channel that
      // carries nothing at all — which is a broken fixture passing as a
      // deliberate refusal.
      await expectLater(fixture.api.preferences.getKeys(), completes);
      expect(fixture.api.browse, isA<BrowseApi>());
      expect(fixture.api.timeseries, isA<TimeseriesApi>());
      expect(fixture.api.historyViews, isA<HistoryViewApi>());
    });
  });

  group('FakeStateMan', () {
    late FakeStateMan fake;

    setUp(() {
      fake = FakeStateMan();
      addTearDown(fake.dispose);
    });

    expectRefusesEveryFamily(() => fake, 'FakeStateMan');

    test('LIVE CONTROL: the four data services are real in-memory stores', () {
      // The fake's whole argument is that it is not a mock. If these four ever
      // start throwing, the refusals above stop distinguishing "no access
      // store" from "no store of any kind".
      expect(fake.browse, isA<BrowseApi>());
      expect(fake.timeseries, isA<TimeseriesApi>());
      expect(fake.historyViews, isA<HistoryViewApi>());
      expect(fake.preferences, isA<PreferencesApi>());
    });

    test('LIVE CONTROL: the plant lever still drives a value through', () async {
      fake.setValue('AREA01.DEV01.SUB01', 7);
      expect(fake.read('AREA01.DEV01.SUB01')?.value, 7);
    });
  });

  group('the roster of access families is exhaustive over StateManApi', () {
    test('the interface declares exactly these four access getters', () {
      final declared = declaredMemberNames(StateManApi);

      for (final member in accessFamilies) {
        expect(declared, contains(member),
            reason: '"$member" is judged here but StateManApi no longer '
                'declares it; a stale entry makes every arm above vacuous');
      }

      // The other side: a fifth access-shaped getter arriving unjudged. Spelled
      // as the full member set minus the ones this package has a home for,
      // rather than as a count, so the failure names the newcomer.
      const judgedElsewhere = <String>{
        'listen', 'subscribe', 'read', 'readFresh', 'readMany', 'keys',
        'write', 'writeStatus', 'holdToRun', 'browse', 'timeseries',
        'historyViews', 'preferences', 'dispose',
      };
      expect(declared.difference({...judgedElsewhere, ...accessFamilies}),
          isEmpty,
          reason: 'StateManApi grew a member this file has never seen. If it '
              'is a sub-API getter with nothing behind it, it owes the two '
              'implementations in this package a refusal — and this file an '
              'entry');
    });
  });
}
