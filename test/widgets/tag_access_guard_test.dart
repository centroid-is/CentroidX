/// Tap-time elevation: the refusal that happens before a write is composed.
///
/// The claim this file exists to check is end-to-end and cannot be assembled
/// out of unit assertions: an operator taps a control on a locked member, the
/// prompt appears, **and the PLC never hears about it**. So every test here
/// pumps a real `BaseScaffold` — which is where `AccessDeniedPrompt` is
/// mounted — over a real `ProviderContainer`, and asserts on a fake
/// `StateMan`'s `writes` list rather than on a mock's call log.
///
/// The three things that must all be true at once, and each has its own test:
///
///  * the prompt is on screen,
///  * `inner.write` was never reached,
///  * `tester.takeException()` is null — nothing was thrown on the operator's
///    path, which is the difference between this and plan 03-07's safety net.
library;

import 'dart:async';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/access_denied_prompt.dart';
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc/widgets/tag_access_guard.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/state_man.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// The conveyor key the whole phase is argued around: one struct carrying a
/// jog command anybody may issue and a drive frequency only `device` may set.
const String _key = 'ST101.CN01';
const String _lockedMember = 'p_cfg_ManualFreq';
const String _openMember = 'p_cmd_JogFwd';

/// A key nothing is bound to, so it exercises the short-circuit rather than
/// the decision.
const String _unboundKey = 'ST201.MX02';

const String _templateName = 'conveyor';

/// A resolver already carrying the snapshot, so the tests never depend on the
/// loader, the store or a database.
TagBindingResolver _loadedResolver() => TagBindingResolver()
  ..setSnapshot(
    keyToTemplate: const {_key: _templateName},
    templates: {
      _templateName: AccessTemplate(
        name: _templateName,
        rules: const {_lockedMember: AccessGroup.device},
      ),
    },
  );

AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

AccessSession _device() => AccessSession.anonymous(
    const {AccessGroup.operate, AccessGroup.device});

/// A session that answers one fixed value without standing up the real
/// controller chain (database, preferences, audit sink, inactivity monitor).
class _FixedSession extends AccessSessionController {
  _FixedSession(this._session);

  final AccessSession _session;

  @override
  Future<AccessSession> build() async => _session;

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.ok;

  @override
  Future<void> signOut() async {}

  @override
  void poke() {}
}

/// A repository that answers nothing. Nothing here asks it anything; it exists
/// so `accessRepositoryProvider` never reaches `databaseProvider` and the
/// station keychain.
class _StubRepository extends Fake implements AccessRepository {}

/// Every row this container writes, in order.
class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// The sink that cannot write. A refusal must survive it unchanged — same
/// rule, same words, as 03-04 and 03-10.
class _ThrowingSink implements AuditSink {
  @override
  Future<void> record(AuditRecord entry) async =>
      throw StateError('the trail is down');
}

/// A `StateMan` that records writes and resolves keys the way the real one
/// does: unchanged unless they name a variable.
class _FakeStateMan implements StateMan {
  _FakeStateMan({this.subs = const {}, this.writeThrows});

  final Map<String, String> subs;

  /// What `write` throws instead of recording, when a test needs to prove the
  /// exception reaches the caller.
  final Object? writeThrows;

  final List<String> writes = [];

  @override
  String resolveKey(String key) {
    var resolved = key;
    for (final entry in subs.entries) {
      resolved = resolved.replaceAll('\$${entry.key}', entry.value);
    }
    return resolved;
  }

  @override
  Future<void> write(String key, DynamicValue value) async {
    if (writeThrows != null) throw writeThrows!;
    writes.add(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_FakeStateMan: ${invocation.memberName} not in test scope',
      );
}

DynamicValue _value(double v) =>
    DynamicValue(value: v, typeId: NodeId.double);

/// The whole-struct write one conveyor key carries — the shape the member
/// gating in 04-04 exists for.
DynamicValue _struct(Map<String, Object?> members) {
  final v = DynamicValue();
  members.forEach((key, value) => v[key] = DynamicValue(value: value));
  return v;
}

/// The overrides every host shares: a loaded resolver, a fixed session, a
/// recording sink, and no path at all to Postgres.
List<Override> _overrides({
  required TagBindingResolver resolver,
  required AccessSession session,
  required AuditSink sink,
  StateMan? stateMan,
}) =>
    [
      tagBindingResolverProvider.overrideWith((ref) => resolver),
      // The loader is what `tagAccessProvider` watches for its rebuild. It must
      // answer without a database; the snapshot is already in the resolver.
      accessTemplatesProvider
          .overrideWith((ref) async => const <AccessTemplate>[]),
      accessSessionProvider.overrideWith(() => _FixedSession(session)),
      accessRepositoryProvider.overrideWith((ref) async => _StubRepository()),
      auditSinkProvider.overrideWith((ref) async => sink),
      stationNameProvider.overrideWithValue('test-station'),
      if (stateMan != null)
        stateManProvider.overrideWith((ref) async => stateMan),
    ];

/// The top-level menu `BaseScaffold` renders its navigation bar from.
void _registerAppMenu() {
  final registry = RouteRegistry();
  registry.menuItems.clear();
  registry
      .addMenuItem(const MenuItem(label: 'Home', path: '/', icon: Icons.home));
  // Two, not one: `NavigationBar` asserts `destinations.length >= 2`.
  registry.addMenuItem(const MenuItem(
      label: 'Alarm View', path: '/alarm-view', icon: Icons.alarm));
}

/// A one-route Beamer shell around a real `BaseScaffold`, which is where
/// `AccessDeniedPrompt` is mounted (`base_scaffold.dart:404`).
Widget _shell({required Widget body, required List<Override> overrides}) {
  final delegate = BeamerDelegate(
    locationBuilder: RoutesLocationBuilder(routes: {
      '/': (context, state, data) => BeamPage(
            key: const ValueKey('/'),
            title: 'Home',
            child: BaseScaffold(title: 'Home', body: body),
          ),
    }).call,
  );

  return ProviderScope(
    overrides: overrides,
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

/// A bare `MaterialApp` host, for the claims that are about a widget's own
/// size or answer rather than about the prompt. No Beamer, so a test may pump
/// it twice with different overrides — which is how "the lock comes off when
/// the session changes" is asserted without a second file.
Widget _plainHost({required Widget body, required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(home: Scaffold(body: Center(child: body))),
  );
}

/// The control under test: a button that asks before it writes.
///
/// Deliberately as thin as the asset call sites plans 04-10 and 04-11 convert
/// — one `writeTag` and nothing else — so a test failure here is a failure of
/// the helper rather than of the harness.
class _WriteButton extends ConsumerWidget {
  const _WriteButton({
    required this.stateMan,
    required this.tagKey,
    this.member,
    this.onResult,
  });

  final StateMan stateMan;
  final String tagKey;
  final String? member;
  final void Function(bool wrote)? onResult;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ElevatedButton(
      onPressed: () async {
        final wrote = await writeTag(
          ref,
          stateMan,
          tagKey,
          _value(42),
          member: member,
        );
        onResult?.call(wrote);
      },
      child: const Text('Write'),
    );
  }
}

/// The same control, but asking `guardTagWrite` and composing nothing.
class _GuardButton extends ConsumerWidget {
  const _GuardButton({
    required this.tagKey,
    this.member,
    this.onResult,
  });

  final String tagKey;
  final String? member;
  final void Function(bool allowed)? onResult;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ElevatedButton(
      onPressed: () async {
        final allowed = await guardTagWrite(ref, tagKey, member: member);
        onResult?.call(allowed);
      },
      child: const Text('Ask'),
    );
  }
}

void main() {
  setUp(_registerAppMenu);

  group('guardTagWrite refuses at the tap', () {
    testWidgets(
        'a locked member prompts, writes nothing, and throws nothing on the '
        'operator path', (tester) async {
      final inner = _FakeStateMan();
      final sink = _RecordingSink();

      await tester.pumpWidget(_shell(
        body: Center(
          child: _WriteButton(
            stateMan: inner,
            tagKey: _key,
            member: _lockedMember,
          ),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: sink,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(find.text(kAccessDeniedGroupNote(AccessGroup.device)),
          findsOneWidget);
      expect(inner.writes, isEmpty,
          reason: 'the decision happens before the write is issued');
      // The whole difference from plan 03-07: no `AccessDenied` was raised on
      // the path the operator's tap took.
      expect(tester.takeException(), isNull);
    });

    testWidgets('records exactly one row: allowed false, member set, newValue '
        'null', (tester) async {
      final inner = _FakeStateMan();
      final sink = _RecordingSink();

      await tester.pumpWidget(_shell(
        body: Center(
          child: _WriteButton(
            stateMan: inner,
            tagKey: _key,
            member: _lockedMember,
          ),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: sink,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();

      expect(sink.rows, hasLength(1),
          reason: 'moving the refusal earlier must not empty the trail');
      final row = sink.rows.single;
      expect(row.allowed, isFalse);
      expect(row.surface, AccessSurface.tag.wireName);
      expect(row.itemKey, _key);
      expect(row.member, _lockedMember);
      expect(row.groupRequired, AccessGroup.device.name);
      expect(row.origin, 'operator');
      expect(row.actionId, isNotEmpty);
      // The null that distinguishes a tap-time refusal from a guard refusal:
      // no value was ever composed, so there is nothing to record.
      expect(row.newValue, isNull);
      expect(row.oldValue, isNull);
    });

    testWidgets('a member no rule mentions writes normally and records nothing',
        (tester) async {
      final inner = _FakeStateMan();
      final sink = _RecordingSink();

      await tester.pumpWidget(_shell(
        body: Center(
          child: _WriteButton(
            stateMan: inner,
            tagKey: _key,
            member: _openMember,
          ),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: sink,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();

      expect(inner.writes, [_key]);
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing);
      expect(sink.rows, isEmpty,
          reason: 'this helper records refusals only; the guard records the '
              'permitted write');
    });

    testWidgets('an unbound key refuses a session without operate — the '
        '2026-09-02 floor', (tester) async {
      // The hq-skjar report that forced the ruling: a user whose role held
      // only `device`-less groups could toggle the bathroom lights, because
      // an unbound key was unrestricted. The floor is `operate`, everywhere.
      final inner = _FakeStateMan();
      final sink = _RecordingSink();

      await tester.pumpWidget(_shell(
        body: Center(
          child: _WriteButton(stateMan: inner, tagKey: _unboundKey),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: AccessSession.anonymous(const {AccessGroup.device}),
          sink: sink,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();

      expect(inner.writes, isEmpty,
          reason: 'no operate, no write — bound or not');
      expect(sink.rows.single.allowed, isFalse);
      expect(sink.rows.single.groupRequired, 'operate');
      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
    });

    testWidgets('an unbound key still writes for a session holding operate',
        (tester) async {
      final inner = _FakeStateMan();
      final sink = _RecordingSink();

      await tester.pumpWidget(_shell(
        body: Center(
          child: _WriteButton(stateMan: inner, tagKey: _unboundKey),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: sink,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();

      expect(inner.writes, [_unboundKey]);
      expect(sink.rows, isEmpty);
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing);
    });

    testWidgets('a session holding the group is not refused', (tester) async {
      final inner = _FakeStateMan();
      final sink = _RecordingSink();

      await tester.pumpWidget(_shell(
        body: Center(
          child: _WriteButton(
            stateMan: inner,
            tagKey: _key,
            member: _lockedMember,
          ),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _device(),
          sink: sink,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();

      expect(inner.writes, [_key]);
      expect(sink.rows, isEmpty);
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing);
    });

    testWidgets('a throwing audit sink still refuses and still prompts',
        (tester) async {
      final inner = _FakeStateMan();
      final results = <bool>[];

      await tester.pumpWidget(_shell(
        body: Center(
          child: _GuardButton(
            tagKey: _key,
            member: _lockedMember,
            onResult: results.add,
          ),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: _ThrowingSink(),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();

      expect(results, [false]);
      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(inner.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unresolvable key returns true and does not prompt',
        (tester) async {
      // No substitution for `$line`, so `resolveKey` hands the key back with
      // the variable still in it. Resolution failure is `StateMan`'s to raise.
      final inner = _FakeStateMan();
      final results = <bool>[];

      await tester.pumpWidget(_shell(
        body: Center(
          child: _GuardButton(
            tagKey: r'ST101.$line.p_cfg_ManualFreq',
            member: _lockedMember,
            onResult: results.add,
          ),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: _RecordingSink(),
          stateMan: inner,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();

      expect(results, [true]);
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing);
    });

    testWidgets('a substituted key is decided on the resolved name',
        (tester) async {
      // `$station` resolves to `ST101.CN01`, which is bound. The refusal must
      // name the resolved key, exactly as the guard's row would.
      final inner = _FakeStateMan(subs: const {'station': _key});
      final sink = _RecordingSink();

      await tester.pumpWidget(_shell(
        body: Center(
          child: _WriteButton(
            stateMan: inner,
            tagKey: r'$station',
            member: _lockedMember,
          ),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: sink,
          stateMan: inner,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();

      expect(inner.writes, isEmpty);
      expect(sink.rows.single.itemKey, _key);
      expect(find.text(kAccessDeniedItemNote(_key)), findsOneWidget);
    });
  });

  group('writeTag', () {
    testWidgets('returns false and reaches no write on a locked member',
        (tester) async {
      final inner = _FakeStateMan();
      final results = <bool>[];

      await tester.pumpWidget(_shell(
        body: Center(
          child: _WriteButton(
            stateMan: inner,
            tagKey: _key,
            member: _lockedMember,
            onResult: results.add,
          ),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: _RecordingSink(),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();

      expect(results, [false]);
      expect(inner.writes, isEmpty);
      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
    });

    testWidgets('returns true and reaches inner.write exactly once on an open '
        'member', (tester) async {
      final inner = _FakeStateMan();
      final results = <bool>[];

      await tester.pumpWidget(_shell(
        body: Center(
          child: _WriteButton(
            stateMan: inner,
            tagKey: _key,
            member: _openMember,
            onResult: results.add,
          ),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: _RecordingSink(),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();

      expect(results, [true]);
      expect(inner.writes, hasLength(1));
    });

    testWidgets('lets an exception from sm.write propagate unchanged',
        (tester) async {
      final failure = StateError('the PLC is not answering');
      final inner = _FakeStateMan(writeThrows: failure);

      await tester.pumpWidget(_shell(
        body: Center(
          child: _WriteButton(
            stateMan: inner,
            tagKey: _key,
            member: _openMember,
          ),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: _RecordingSink(),
        ),
      ));
      await tester.pumpAndSettle();

      // A zone, not `takeException`: the throw escapes an `onPressed` future
      // as an asynchronous error, which the framework never sees.
      Object? escaped;
      await runZonedGuarded(() async {
        await tester.tap(find.text('Write'));
        await tester.pumpAndSettle();
      }, (error, stack) => escaped = error);

      expect(escaped, same(failure),
          reason: 'a comms failure is the caller\'s, exactly as before');
    });
  });

  group('signing in gives back the affordance, not the action (T-04-34)', () {
    testWidgets('the refused write is not held anywhere, so the button needs a '
        'fresh press', (tester) async {
      final inner = _FakeStateMan();

      await tester.pumpWidget(_shell(
        body: Center(
          child: _WriteButton(
            stateMan: inner,
            tagKey: _key,
            member: _lockedMember,
          ),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: _RecordingSink(),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();
      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);

      // "Sign in" dismisses the prompt and opens the form. Nothing here is
      // remembered to retry — `kAccessDeniedNoReplayNote` is what says so to
      // the operator, and this is what says so to the next person to edit it.
      await tester.tap(find.byKey(kAccessDeniedSignInKey));
      await tester.pumpAndSettle();

      expect(inner.writes, isEmpty,
          reason: 'signing in must never replay the refused action');
    });
  });

  group('the guard underneath is unchanged (T-04-32)', () {
    testWidgets('a write that skips the helper is still refused at the guard',
        (tester) async {
      // Tap-time elevation is a **second** gate, not a replacement. A call
      // site that has not been converted — or an MCP tool, or a bug — still
      // meets `GuardedStateMan`.
      final inner = _FakeStateMan();
      final resolver = _loadedResolver();
      final guarded = GuardedStateMan(
        inner: inner,
        policy: AccessPolicy(tagBindings: resolver.groupFor),
        session: _anonymous,
        audit: const NullAuditSink(),
        station: 'test-station',
        // With a baseline the guard asks per changed member, which is the
        // question this template answers. Without one it falls back to the
        // key-level row — a documented hole (04-04), not this test's subject.
        readBaseline: (key) async => _struct(const {'p_cfg_ManualFreq': 42.5}),
      );

      await expectLater(
        guarded.write(_key, _struct(const {'p_cfg_ManualFreq': 55.0})),
        throwsA(isA<AccessDenied>()),
      );
      expect(inner.writes, isEmpty);
    });
  });

  group('TagLockBadge', () {
    testWidgets('measures Size.zero for an unbound key', (tester) async {
      await tester.pumpWidget(_plainHost(
        body: const TagLockBadge(tagKey: _unboundKey),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: _RecordingSink(),
        ),
      ));
      await tester.pumpAndSettle();

      // `findsNothing` on the icon is not enough: an invisible widget that
      // still took 8 px of gap would pass it. The `access_lock_badge_test`
      // idiom.
      expect(tester.getSize(find.byType(TagLockBadge)), Size.zero);
    });

    testWidgets('measures Size.zero for a member no rule mentions',
        (tester) async {
      await tester.pumpWidget(_plainHost(
        body: const TagLockBadge(tagKey: _key, member: _openMember),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: _RecordingSink(),
        ),
      ));
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(TagLockBadge)), Size.zero);
    });

    testWidgets('renders a lock on a locked member', (tester) async {
      await tester.pumpWidget(_plainHost(
        body: const TagLockBadge(tagKey: _key, member: _lockedMember),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: _RecordingSink(),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(tester.getSize(find.byType(TagLockBadge)).width, greaterThan(0));
    });

    testWidgets('renders nothing once the session holds the group',
        (tester) async {
      await tester.pumpWidget(_plainHost(
        body: const TagLockBadge(tagKey: _key, member: _lockedMember),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _device(),
          sink: _RecordingSink(),
        ),
      ));
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(TagLockBadge)), Size.zero);
    });

    testWidgets('takes no tap of its own', (tester) async {
      var taps = 0;

      await tester.pumpWidget(_plainHost(
        body: GestureDetector(
          onTap: () => taps++,
          child: const TagLockBadge(tagKey: _key, member: _lockedMember),
        ),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: _RecordingSink(),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.lock_outline));
      await tester.pumpAndSettle();

      expect(taps, 1,
          reason: 'the badge annotates; the control around it keeps its tap');
    });
  });

  group('tagWriteAllowed', () {
    testWidgets('answers the same question the badge renders', (tester) async {
      final answers = <String, bool>{};

      await tester.pumpWidget(_plainHost(
        body: Consumer(builder: (context, ref, _) {
          answers['unbound'] = tagWriteAllowed(ref, _unboundKey);
          answers['open'] = tagWriteAllowed(ref, _key, member: _openMember);
          answers['locked'] = tagWriteAllowed(ref, _key, member: _lockedMember);
          return const SizedBox.shrink();
        }),
        overrides: _overrides(
          resolver: _loadedResolver(),
          session: _anonymous(),
          sink: _RecordingSink(),
        ),
      ));
      await tester.pumpAndSettle();

      expect(answers, {'unbound': true, 'open': true, 'locked': false});
    });
  });
}
