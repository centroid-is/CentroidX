@TestOn('vm')
@Tags(['contract'])

/// The method table of the wire, written down.
///
/// This test exists to break the build on purpose. Every name below is a thing
/// a connected client may ask the gateway to do, so the set of names *is* the
/// access-control policy: capability is defined by surface. Adding a method to
/// `StateManApi` without editing this file fails; editing this file is the
/// deliberate act that says "yes, the wire may now do this too".
///
/// The expected sets are hand-written literals, never derived from the classes
/// they check. A set computed from the type would agree with any change and
/// assert nothing — the point is that a human reads a diff of these lines.
///
/// Two properties are enforced here:
///
///  * **Closure.** The five interfaces expose exactly these members. This is
///    where `query(String sql)` dies: a generic statement-taking method is a
///    name nobody wrote down, so it fails the set comparison before it can
///    ship, and no amount of gateway-side validation has to be trusted.
///  * **No secret retrieval.** No member of any of the five types declares a
///    parameter named `secret`. The concrete `Preferences` class
///    (`packages/tfc_dart/lib/core/preferences.dart:221+`) has exactly such a
///    parameter, routing reads to secure storage; mirroring it onto the wire
///    would make one client-supplied boolean into remote access to the secure
///    store (SEC-01).
///
/// `dart:mirrors` reflects the real type rather than its source text, and it
/// is available under `dart test` but not under `flutter test` — which is
/// another reason the interface package is pure Dart.
///
/// ## Phase 17 moved this count on purpose, and here is what it bought
///
/// The wire grew four families — [AccessTemplateApi], [AccessAdminApi],
/// [AuditApi], [BackendConfigApi] — and four `StateManApi` getters to reach
/// them by. That is **thirty-two new members**, the largest single growth
/// this surface has had, and every one of them is a thing any connected client
/// may invoke against a gateway. So they are written out below as literals,
/// family by family, rather than allowed to arrive as a number that went up:
/// *a surface that grows silently is an access-control decision nobody made*,
/// and this file exists precisely to make somebody make it.
///
/// The four new interfaces are added to [wireSurface] and not merely tolerated
/// through the getters. A getter whose type is not walked would put
/// twenty-eight methods on the wire with nothing here counting them — which is
/// the same hole WR-07 closed for superinterfaces, arriving by a different
/// door.
///
/// One name has since been cut: `accessTemplates.template`. The access audit
/// of all twenty-nine names found it had no caller anywhere, including its own
/// store; remote implementations derive it from `list()`. Its removal is the
/// other edge of this file's blade — a removed member silently breaks a
/// deployed client that still calls it, and no deployed client ever did.
library;

import 'dart:mirrors';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The eighteen members of the wire's primary interface.
///
/// `writeStatus` and `holdToRun` were added in Phase 5 (05-04), which is the
/// deliberate act this file exists to force: `writeStatus` because the wire
/// already exposed it and an interface that cannot be asked about a cmd is an
/// interface whose write recovery no contract check can judge, and
/// `holdToRun` because a deadman is a capability, not a convenience. Every
/// other hold verb lives on the returned `HoldHandle`, which is a concrete
/// class and not part of the walked surface — that is why a whole hold
/// protocol costs one member here and not seven.
///
/// `accessTemplates`, `accessAdmin`, `audit` and `backendConfig` were added in
/// Phase 17 (17-03), and they are four getters rather than thirty-three
/// members for the same reason `holdToRun` is one member rather than seven: a
/// sub-interface costs one line here and is walked in full below.
///
/// Deliberately absent, each for a reason recorded in `state_man_api.dart`:
/// `isKeyDisabled`, the four substitution members, any health method —
/// `PIPE.*` keys are subscribed through `listen` like any plant tag — and
/// `tick`, which would be a write primitive with no engage in front of it.
/// Also absent, and this one is Phase 17's: **`session`, `signIn`, `whoAmI` or
/// any other way to become an identity over the pipe.** This phase relays what
/// an identity may do; it does not relay the act of becoming one.
const Set<String> expectedStateManApi = {
  'listen',
  'subscribe',
  'read',
  'readFresh',
  'readMany',
  'write',
  'writeStatus',
  'holdToRun',
  'keys',
  'browse',
  'timeseries',
  'historyViews',
  'preferences',
  'accessTemplates',
  'accessAdmin',
  'audit',
  'backendConfig',
  'dispose',
};

/// Browse is three navigation calls plus path resolution — `resolvePath` is
/// required, not optional: without it the page editor opens the browse panel
/// on an already-bound value with nothing selected.
const Set<String> expectedBrowseApi = {
  'fetchRoots',
  'fetchChildren',
  'fetchDetail',
  'resolvePath',
};

/// Three named queries over a named series and a time range.
///
/// This set is the reason a client cannot make the database do arbitrary work:
/// every argument these three take is a value the gateway validates, and there
/// is no fourth method that takes a statement, an expression or a filter
/// string. A `query` method added here would be an unexpected name. (A fourth
/// name, `countTimeseriesDataMultiple`, was cut by the 2026-09-07 dead-code
/// audit — no end caller anywhere.)
const Set<String> expectedTimeseriesApi = {
  'queryTimeseriesData',
  'queryTimeseriesDataMultiple',
  'queryTimeseriesDataDownsampled',
};

/// The eleven history-view methods, names mirrored verbatim from the database
/// layer they will be served by.
const Set<String> expectedHistoryViewApi = {
  'createHistoryView',
  'updateHistoryView',
  'deleteHistoryView',
  'selectHistoryViews',
  'getHistoryViewKeys',
  'getHistoryViewGraphs',
  'getHistoryViewKeyNames',
  'addHistoryViewPeriod',
  'deleteHistoryViewPeriod',
  'listHistoryViewPeriods',
  'getGlobalRetentionHorizon',
};

/// The fifteen members of the preferences *interface*, plus the change
/// notification DB-03 needs. Nothing from the concrete class.
const Set<String> expectedPreferencesApi = {
  'getKeys',
  'getAll',
  'getBool',
  'getInt',
  'getDouble',
  'getString',
  'getStringList',
  'containsKey',
  'setBool',
  'setInt',
  'setDouble',
  'setString',
  'setStringList',
  'remove',
  'clear',
  'onPreferencesChanged',
};

/// The nine template members, names mirrored verbatim from
/// `AccessTemplateStore`. Every one of the six writes changes **who may write a
/// key**, which is why the whole family is graded `users` at the far end.
///
/// `template` (one row by name) was cut by the access audit: no caller
/// anywhere, including its own store — the store reads rows through its
/// private `_row()`. Remote implementations derive it from `list()`.
const Set<String> expectedAccessTemplateApi = {
  'list',
  'bindings',
  'keysBoundTo',
  'create',
  'update',
  'rename',
  'delete',
  'bind',
  'unbind',
};

/// The eleven role-and-account members, names mirrored verbatim from
/// `AccessAdminStore`.
///
/// `updateRole` is the most consequential name in this file: it is the one
/// that can hand somebody `force` on a running line, and — when the row is
/// `Operator` — hand it to every logged-out panel on the floor. It is here as
/// a deliberate decision, not as a convenience.
///
/// `createUser` and `setUserPassword` are the only two members on the whole
/// wire that carry a credential. Both take a params class that withholds it
/// from `toString`; the value is hashed server-side, and no digest is computed
/// on the client because a client-computed digest is the password.
const Set<String> expectedAccessAdminApi = {
  'roles',
  'listUsers',
  'createRole',
  'updateRole',
  'deleteRole',
  'renameRole',
  'createUser',
  'deleteUser',
  'setUserRole',
  'setUserStationAccount',
  'setUserPassword',
};

/// Three reads of the audit trail, and there is no fourth.
///
/// **This set is the reason a client cannot forge an audit row.** There is no
/// `record`, no `append`, no `write`: the relay records its own rows
/// server-side through the injected `AuditSink`, where the `who` is an
/// identity the server verified by constant-time digest compare. A `record`
/// method added here would be an unexpected name, exactly as `query(sql)`
/// would be on the timeseries family.
const Set<String> expectedAuditApi = {
  'entries',
  'memberCountsByAction',
  'distinctWho',
};

/// The five backend-configuration members (ACCESS-04).
///
/// `read` and `write` are also names on [StateManApi], and they are different
/// operations that happen to share a verb — the wire keeps them apart by the
/// `backendConfig.` prefix. That is why the union check below counts fewer
/// names than the per-type tables add up to, and why both numbers are written
/// down.
const Set<String> expectedBackendConfigApi = {
  'read',
  'validate',
  'write',
  'previous',
  'restorePrevious',
};

/// Every type that is reachable from the wire, and its agreed table.
const Map<String, Set<String>> wireSurface = {
  'StateManApi': expectedStateManApi,
  'BrowseApi': expectedBrowseApi,
  'TimeseriesApi': expectedTimeseriesApi,
  'HistoryViewApi': expectedHistoryViewApi,
  'PreferencesApi': expectedPreferencesApi,
  'AccessTemplateApi': expectedAccessTemplateApi,
  'AccessAdminApi': expectedAccessAdminApi,
  'AuditApi': expectedAuditApi,
  'BackendConfigApi': expectedBackendConfigApi,
};

/// The types behind [wireSurface], in the same order.
const List<Type> wireTypes = [
  StateManApi,
  BrowseApi,
  TimeseriesApi,
  HistoryViewApi,
  PreferencesApi,
  AccessTemplateApi,
  AccessAdminApi,
  AuditApi,
  BackendConfigApi,
];

/// Every method, getter and setter reachable on [type], including inherited
/// ones.
///
/// Superinterfaces are walked, not just the class's own declarations. A member
/// arriving via `abstract interface class TimeseriesApi implements RawQueryApi`
/// is fully part of the wire surface and would otherwise be completely
/// invisible here — in a test whose entire job is to be the access-control
/// policy, which is exactly where `query(String sql)` would come in through
/// the side door.
///
/// Constructors and private members are excluded; a setter's trailing `=` is
/// stripped so `foo` and `foo=` do not read as two separate wire methods.
/// `Object`'s own members are not part of anybody's wire table, so the
/// superclass walk stops there.
Set<String> declaredMemberNames(Type type) =>
    _walkSurface(type, (m) => [MirrorSystem.getName(m.simpleName)])
        .map((name) =>
            name.endsWith('=') ? name.substring(0, name.length - 1) : name)
        .toSet();

/// Every parameter name declared anywhere on [type], inherited included — the
/// `secret:` check has the identical hole otherwise.
Iterable<String> declaredParameterNames(Type type) => _walkSurface(
    type, (m) => m.parameters.map((p) => MirrorSystem.getName(p.simpleName)));

/// Collects [read] over every public, non-constructor member of [type] and of
/// everything it inherits from.
Set<String> _walkSurface(
    Type type, Iterable<String> Function(MethodMirror) read) {
  final seen = <String>{};
  final visited = <ClassMirror>{};

  void walk(ClassMirror mirror) {
    if (!visited.add(mirror)) return;
    for (final member in mirror.declarations.values.whereType<MethodMirror>()) {
      if (member.isConstructor || member.isPrivate) continue;
      seen.addAll(read(member));
    }
    mirror.superinterfaces.forEach(walk);
    final parent = mirror.superclass;
    if (parent != null && parent.reflectedType != Object) walk(parent);
  }

  walk(reflectClass(type));
  return seen;
}

void main() {
  group('the wire surface is closed', () {
    for (var i = 0; i < wireTypes.length; i++) {
      final type = wireTypes[i];
      final name = wireSurface.keys.elementAt(i);
      final expected = wireSurface[name]!;

      test('$name exposes exactly the agreed method table', () {
        expect(declaredMemberNames(type), expected,
            reason: 'a new member on $name is a new thing every connected '
                'client may invoke, and a removed one silently breaks a '
                'deployed client that still calls it. Change this set only '
                'when that is the intent — this is also the reason '
                'query(sql) can never appear on the wire.');
      });
    }

    test('the whole surface is 80 members over nine types, 78 distinct names',
        () {
      final actual = <String>{
        for (final type in wireTypes) ...declaredMemberNames(type),
      };
      final expected = <String>{
        for (final table in wireSurface.values) ...table,
      };
      expect(actual, expected,
          reason: 'the union is checked as well as the parts, so a member '
              'moved from one sub-interface to another still has to be a '
              'deliberate edit here');

      // 49 until Phase 17, then +4 StateManApi getters and +29 access
      // methods; 81 since the access audit cut accessTemplates.template —
      // no caller anywhere, including its own store; remote implementations
      // derive it from list(). 80 since the 2026-09-07 dead-code audit cut
      // timeseries.countTimeseriesDataMultiple the same way — no end caller
      // anywhere, seven mirror layers deep.
      final total = wireTypes
          .map((type) => declaredMemberNames(type).length)
          .fold<int>(0, (sum, length) => sum + length);
      expect(total, 80,
          reason: 'the count is written down so a same-size swap — one member '
              'removed, another added — cannot slip through as a coincidence. '
              '80 = 49 before Phase 17, plus four StateManApi getters, plus '
              'the twenty-eight access methods behind them after the access '
              'audit cut accessTemplates.template, minus the dead-code '
              'audit\'s countTimeseriesDataMultiple');

      // The union is SHORTER than the sum, and the gap is named rather than
      // left as an arithmetic surprise: BackendConfigApi.read and .write share
      // their names with StateManApi's. They are different operations that
      // happen to share a verb, kept apart on the wire by the
      // `backendConfig.` family segment. Asserting both numbers is what stops
      // a future collision from being absorbed silently by the set.
      expect(actual, hasLength(78),
          reason: 'exactly two names appear on two types — read and write, on '
              'StateManApi and BackendConfigApi. A third collision would drop '
              'this to 77 while the per-type tables above still passed, so it '
              'is counted here on purpose');
      expect(
          expectedStateManApi
              .intersection(expectedBackendConfigApi)
              .toList()
            ..sort(),
          ['read', 'write'],
          reason: 'and the two are named, not merely counted — a different '
              'pair of colliding names would keep the length at 79 and mean '
              'something entirely different');
    });
  });

  group('no secret material can be requested over the pipe', () {
    for (var i = 0; i < wireTypes.length; i++) {
      final type = wireTypes[i];
      final name = wireSurface.keys.elementAt(i);

      test('$name declares no parameter named secret', () {
        expect(declaredParameterNames(type), isNot(contains('secret')),
            reason: 'SEC-01: secrets are mounted files, never preference '
                'rows, and never anything a remote client can ask for. The '
                'concrete Preferences class takes {bool secret = false} and '
                'routes the read to secure storage; mirroring that parameter '
                'onto $name would turn one client-supplied boolean into '
                'remote retrieval of the secure store.');
      });
    }

    test('no credential is a bare parameter on any wire member', () {
      final bare = <String>[
        for (final type in wireTypes)
          for (final parameter in declaredParameterNames(type))
            if (parameter.toLowerCase().contains('password') ||
                parameter.toLowerCase().contains('passphrase') ||
                parameter.toLowerCase().contains('token'))
              parameter,
      ];
      expect(bare, isEmpty,
          reason: 'AccessAdminApi.createUser and .setUserPassword do carry a '
              'credential, and both carry it inside a params class whose '
              'toString withholds it. A bare `String password` argument would '
              'be the same value with nowhere to hang that discipline: the '
              'first log line that prints the argument list is a credential in '
              'a file that outlives the database. Enforced here rather than by '
              'convention, because the type system will not object.');
    });

    test('the walk itself sees members arriving via a superinterface', () {
      // WR-07. The reflection used to read `declarations` alone, which
      // returns only what a class declares itself — so the one shape this
      // file exists to forbid could arrive through a superinterface and be
      // completely invisible to every assertion above.
      expect(declaredMemberNames(_DerivedFixture), {'query', 'ownMember'},
          reason: 'a member inherited from a superinterface is fully part of '
              'the wire surface');
      expect(declaredParameterNames(_DerivedFixture), contains('secret'),
          reason: 'the secret check had the identical hole');
    });

    test('no member name suggests a statement-taking escape hatch', () {
      final suspicious = <String>[
        for (final type in wireTypes)
          for (final member in declaredMemberNames(type))
            if (member.toLowerCase().contains('sql') ||
                member.toLowerCase().contains('rawquery') ||
                member.toLowerCase().contains('execute'))
              member,
      ];
      expect(suspicious, isEmpty,
          reason: 'the four timeseries methods take a series name and a time '
              'range, all of which the gateway validates. A method that '
              'takes a statement hands the database to whoever holds a '
              'socket, and no gateway-side sanitizing makes that safe.');
    });
  });
}

/// Fixtures for the walk's own regression test: exactly the shape that used to
/// slip past — a statement-taking method and a `secret:` parameter, reachable
/// only through a superinterface. Nothing on the wire implements these.
abstract interface class _InheritedFixture {
  Future<void> query(String sql, {bool secret});
}

abstract interface class _DerivedFixture implements _InheritedFixture {
  void ownMember();
}
