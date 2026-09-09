@TestOn('vm')
@Tags(['meta'])

/// DB-04, as an executable assertion: the method table is closed, and adding a
/// `query(sql)`-shaped method or parameter fails a test that names the offender.
///
/// `surface_test.dart` freezes the table's *contents* — forty-three bare
/// strings a human edits in a diff. This file is deliberately a different
/// thing: it asserts the table's **shape**, and it never restates a name.
/// Everything below iterates a set that is declared somewhere else, so a
/// thirty-fifth data-service method or a thirteenth harness lever is covered on
/// the day it is added rather than on the day somebody remembers this file
/// exists. The two files would be redundant if this one carried a second copy
/// of the literal, which is exactly why it does not.
///
/// Three properties, and each of them is one sentence from ROADMAP criterion 4:
///
///  * **Every declared name has a handler and every handler has a declared
///    name.** Stated as one equality against `DataServiceMethods.all` so the
///    failure prints the whole difference. `channel_sub_apis_test.dart:78-93`
///    makes the argument one layer down and this is the same argument on the
///    real wire: a declared name with no handler is METHOD_NOT_FOUND from a
///    table claiming to carry it, and a handler with no declared name is
///    surface nobody counted.
///  * **No harness lever is reachable from the wire.** `rpc_names.dart:378-381`
///    declares the lever set as data specifically so this test could iterate it.
///    `seedTimeseries` is the one that matters most: a client that can insert
///    samples can forge history, and a chart is read as evidence
///    (`data_services_contract.dart:78-81`).
///  * **Nothing on this wire takes a statement.** A name sweep, which is
///    mechanical and weak, and a parameter sweep over the four wire interfaces,
///    which is the one that bites — because the shape DB-04 forbids is not a
///    method whose *name* says SQL, it is a method that takes a fragment of one.
///
/// **Falsification is by wrong input, never by a seam in production code.**
/// `surface_test.dart:304-348` established the idiom and this file copies it:
/// every arm that proves a check bites feeds the comparison a deliberately
/// wrong set while leaving the shipped baseline alone. `_registered` has no
/// setter and `_on` is private, and that is correct — the way to show a closure
/// check works is not to open the class so a test can misuse it.
library;

import 'dart:io';
// The parameter sweep is about the *declarations* of four interfaces, so it
// reads them the way `api_surface_test.dart:171-194` does. Restating their
// parameter lists here would restate exactly the thing that must not drift.
import 'dart:mirrors';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/token_validator.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

import 'support/permissive_resolver.dart';

/// The file carrying the method-not-found fallback and 06-04's two reasons.
final _fallbackComment = File('lib/src/relay_session.dart');

/// The client's forwarding layer, read across the package boundary the way
/// `handler_table_test.dart:316-329` reads the contract kit.
final _clientSubApis = File('../tfc_relay_client/lib/src/client_sub_apis.dart');

/// A session over an in-memory channel, with no client on the far end.
///
/// `surface_test.dart:223-245` verbatim: nothing is called on it, only its
/// ledger is read, so the far end stays empty on purpose.
RelaySession _session() {
  final pair = channelPair();
  final api = FakeStateMan();
  final session = RelaySession.serve(
    resolver: const PermissiveSeriesResolver(),
    channel: pair.server,
    api: api,
    config: ServerConfig(),
    handles: HandleTable(),
    buffer: ConflatingSendBuffer(maxPending: 4096),
    validator: const PermissiveTokenValidator(),
    serverSupported: const [protocolVersion],
  );
  addTearDown(() async {
    await session.close(1000, 'method table closure test over');
    await api.dispose();
  });
  return session;
}

/// The data-service half of a session's ledger.
///
/// Selected by the dot, and the rule is worth stating because the whole
/// equality below rests on it. Every data-service name is `family.methodName`
/// (`methods.dart:73-76`) and the only other dotted things on this wire are
/// the two `session.*` auth names, which `declaredDottedNames` carries by
/// constant — the ten undotted names are `hello`, `ping`, `subscribe`,
/// `unsubscribe`, `write`, `writeStatus`, `ackAlarm`, `read`, `readFresh`,
/// `readMany`, and the one client notification is `h`.
///
/// Selecting by the dot rather than by intersecting with
/// `DataServiceMethods.all` is the difference between a check and a tautology:
/// an intersection would quietly drop a registered `historyViews.dropTable`
/// instead of reporting it, which is precisely direction two. It also means
/// `preferences.changed` — dotted, and declared in the same class but in none
/// of its sets — fails this comparison by name if a handler is ever attached
/// to it, which is the point of the arm below.
Set<String> dataServiceNames(Set<String> ledger) =>
    ledger.where((name) => name.contains('.')).toSet();

/// Every harness lever [ledger] can reach, in either spelling.
///
/// Iterated from `HarnessMethods.levers`, never restated: the set is declared
/// as data upstream (`rpc_names.dart:378-381`) *for this*, so a thirteenth
/// lever is covered on the day it is added.
///
/// **Both spellings, and the second is the one that would really happen.**
/// The declared constants carry `HarnessMethods.prefix` — `harness.` — which is
/// a greppable boundary rather than a defence. The realistic accident is a
/// lever promoted to a wire name by dropping that prefix, exactly the way the
/// thirty-four data services lost theirs when they moved to `methods.dart`
/// (`client_sub_apis.dart:12-16`); an intersection against the prefixed
/// spelling alone would watch the door nobody would use. The returned set
/// carries whichever spelling was found, so the failure names it.
Set<String> leversOnTheWire(Set<String> ledger) => {
      for (final lever in HarnessMethods.levers) ...[
        if (ledger.contains(lever)) lever,
        if (ledger.contains(_unprefixed(lever))) _unprefixed(lever),
      ],
    };

/// [name] without the harness prefix — the spelling it would carry if somebody
/// moved it onto the real table.
String _unprefixed(String name) => name.startsWith(HarnessMethods.prefix)
    ? name.substring(HarnessMethods.prefix.length)
    : name;

/// Tokens that mark a **method name** as taking a statement.
///
/// Mechanical, and this file says plainly that it is the weak half.
/// `api_surface_test.dart:259-273` runs the same sweep over the interfaces;
/// this is that sweep re-run over the names that are actually on the wire,
/// which is where a method a client can call has to be counted.
///
/// `query(` cannot fire on any name here — nothing on this wire has a
/// parenthesis in it — and it is kept anyway because ROADMAP criterion 4 names
/// `query(sql)` literally and a reader looking for that string should find it
/// at the check rather than only in a plan. That it cannot fire is the honest
/// summary of this arm: **a name pattern cannot tell `queryTimeseriesData`
/// from a method that takes a statement**, because the difference is in the
/// parameters and not in the word "query" (10-RESEARCH §A.4). The parameter
/// sweep below is the one carrying the property.
const _statementNameTokens = <String>[
  'sql',
  'rawquery',
  'raw',
  'query(',
  'exec',
  'statement',
];

/// Tokens that mark a **parameter name** as a fragment of a statement.
///
/// Five of the six are the words a fragment arrives under: `sql`, `where`,
/// `expression`, `statement`, `raw`.
///
/// The sixth is `orderby`, and it is here deliberately rather than as an
/// oversight. `ORDER BY` is a SQL clause exactly as `WHERE` is, and
/// `TimeseriesApi` really does take one from the client
/// (`state_man_api.dart:269-275`) — so a token list that omitted it would
/// report this wire clean while a caller-supplied clause crosses it. It is
/// swept and then exempted **by name** in [exemptParameters], which is the
/// only shape that leaves the decision visible: an omitted token is a decision
/// nobody can see, and an exemption is a decision with an argument attached.
const _statementParameterTokens = <String>[
  'sql',
  'where',
  'expression',
  'statement',
  'raw',
  'orderby',
];

/// The four interfaces whose parameters cross this wire.
const _wireInterfaces = <Type>[
  BrowseApi,
  TimeseriesApi,
  HistoryViewApi,
  PreferencesApi,
];

/// How long an exemption's argument has to be before it counts as one.
///
/// `gate_manifest_test.dart:117`'s `_deviationReasonFloor`, and the same
/// reason: this is a claim of the form "the sweep does not cover this and here
/// is why that is right", which needs the argument rather than a label.
const _exemptionArgumentFloor = 60;

/// The parameters that trip [_statementParameterTokens] and are allowed to.
///
/// **Exactly one, and it carries its own guard's address.** `orderBy` is a
/// free-text-looking parameter on the wire and there is no pretending
/// otherwise; the only reason it is not a SQL door is the allow-list the
/// gateway puts in front of it. Somebody who deletes that allow-list has to
/// come through this line.
const exemptParameters = <String, String>{
  'orderBy': 'orderBy is refused rather than sanitized by the two-value '
      'allow-list in lib/src/data_handlers.dart: a request may ask for '
      'exactly "time ASC" or "time DESC" and anything else is an error before '
      'the source is reached. It needs one, because the string is interpolated '
      'unescaped into database_drift.dart\'s ORDER BY clause, where a subquery '
      'is legal grammar — so "time ASC, (SELECT 1)" is not an injection that '
      'has to escape a quote, it is simply a longer clause. Case is not '
      'normalised and whitespace is not collapsed, because each of those is a '
      'transformation and a transformation is the first step of a sanitizer. '
      'Delete the allow-list and this wire ships the query(sql) RPC the '
      'project forbids, wearing a signature nobody reads as one.',
};

/// The names in [names] that carry a [_statementNameTokens] token.
Set<String> statementShapedNames(Iterable<String> names) => {
      for (final name in names)
        if (_statementNameTokens.any(name.toLowerCase().contains)) name,
    };

/// The parameters in [parameters] that carry a [_statementParameterTokens]
/// token — **before** [exemptParameters] is applied, so the arm that proves
/// the exemption is still needed has something to read.
Set<String> statementShapedParameters(Iterable<String> parameters) => {
      for (final parameter in parameters)
        if (_statementParameterTokens.any(parameter.toLowerCase().contains))
          parameter,
    };

/// Every parameter name declared anywhere on the four wire interfaces.
Iterable<String> _everyWireParameter() =>
    [for (final type in _wireInterfaces) ...declaredParameterNames(type)];

/// Every parameter name declared anywhere on [type], inherited included.
///
/// `api_surface_test.dart:169-194` verbatim in behaviour, and the walk is the
/// point rather than the reflection: reading `declarations` alone returns only
/// what a class declares itself, so a `where:` arriving through a
/// superinterface would be invisible to every arm above. That hole was found
/// and fixed once already (WR-07) and this file has its own copy of the walk,
/// so it gets its own regression arm against [_DerivedFixture].
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

/// The entries of [exemptions] whose argument is shorter than
/// [_exemptionArgumentFloor].
Set<String> thinlyArguedExemptions(Map<String, String> exemptions) => {
      for (final entry in exemptions.entries)
        if (entry.value.length < _exemptionArgumentFloor) entry.key,
    };

/// The entries of [exemptions] whose argument names no file that is on disk.
///
/// A citation is only worth the floor above if it resolves: the argument's job
/// is to send the next reader to the guard, and a path that has moved sends
/// them looking for a check that may no longer exist.
Set<String> uncitedExemptions(Map<String, String> exemptions) => {
      for (final entry in exemptions.entries)
        if (!_dartPaths(entry.value).any((path) => File(path).existsSync()))
          entry.key,
    };

/// The strings that must still appear in an exemption's cited file for its
/// argument to be true.
///
/// Kept beside [exemptParameters] rather than inside it because they are a
/// different kind of claim: the argument is prose for a person, and this is the
/// one sentence of it a machine can check. Both accepted orderings, spelled
/// with their quotes so the tokens match the allow-list literal rather than any
/// mention of the words.
const _exemptionGuardTokens = <String, List<String>>{
  'orderBy': ["'time ASC'", "'time DESC'"],
};

/// The entries of [exemptions] whose cited file no longer contains the guard
/// the argument claims makes them safe.
Set<String> unguardedExemptions(Map<String, String> exemptions) => {
      for (final entry in exemptions.entries)
        if (_exemptionGuardTokens[entry.key] case final tokens?)
          if (!_dartPaths(entry.value)
              .where((path) => File(path).existsSync())
              .map(File.new)
              .map((file) => file.readAsStringSync())
              .any((source) => tokens.every(source.contains)))
            entry.key,
    };

/// The `*.dart` paths [argument] mentions, relative to this package root.
Iterable<String> _dartPaths(String argument) => RegExp(r'[\w./]+\.dart')
    .allMatches(argument)
    .map((match) => match.group(0)!);

/// Every dotted name a client may call: the thirty-four data services, the
/// twenty-eight access methods (17-09), and — increment B of the 2026-09-08
/// no-station-file ruling — the two `session.*` auth names, which are core
/// session vocabulary that happens to be dotted (spelled `family.method` so
/// "login" bare would not read as a tenth session verb). Spelled from the
/// declared sets and constants so a name can only exist in one place.
Set<String> get declaredDottedNames => {
      ...DataServiceMethods.all,
      ...AccessMethods.all,
      Methods.sessionLogin,
      Methods.sessionLogout,
    };

void main() {
  group('the data-service ledger is closed in both directions', () {
    test('the dotted half of the ledger is exactly the declared sixty-four',
        () {
      final registered = _session().registeredMethods;

      expect(dataServiceNames(registered), declaredDottedNames,
          reason: 'one equality rather than two containment checks, so the '
              'failure prints the whole difference. A declared name missing '
              'from the left is a method a panel calls and the gateway answers '
              'METHOD_NOT_FOUND for — a chart that renders empty on a station '
              'and works on the developer\'s laptop. A dotted name on the left '
              'that nobody declared is the other half: surface that reached '
              'the wire without appearing in any list a reviewer reads, which '
              'is T-02-22 and an access-control change made by accident');
    });

    test('preferences.changed is not registered', () {
      final registered = _session().registeredMethods;

      expect(registered, isNot(contains(DataServiceMethods.preferencesChanged)),
          reason: 'preferences.changed is a notification the gateway *sends*. '
              'A handler for it would be this server answering its own '
              'outbound frame, and it would mean a connected station could '
              'call it — announcing to the gateway that a preference changed '
              'somewhere, which no station is entitled to say. It is absent '
              'from DataServiceMethods.all for the same reason, so the '
              'equality above already fails on it; this arm exists so the '
              'failure a reviewer reads names the frame rather than a set');
    });

    test('neither side of the equality is empty', () {
      // Anti-vacuity. Two empty sets satisfy the equality above and prove
      // nothing at all.
      expect(DataServiceMethods.all, isNotEmpty,
          reason: 'an empty declared set makes the closure check vacuous — it '
              'would then be asserting that nothing is missing from nothing');
      expect(dataServiceNames(_session().registeredMethods), isNotEmpty,
          reason: 'a ledger with no dotted name in it means the dot rule this '
              'file selects on has stopped selecting anything, so the '
              'comparison is being run against an empty left-hand side');
    });
  });

  group('no harness lever is reachable from the wire', () {
    test('the gateway registers none of the twelve levers, in either spelling',
        () {
      final registered = _session().registeredMethods;

      expect(leversOnTheWire(registered), isEmpty,
          reason: 'a lever registered on this gateway is a connected client '
              'being handed the plant\'s own controls. seedTimeseries is the '
              'worst of them and the reason this arm exists: a client that can '
              'insert samples can insert rows into the historian, and an '
              'operator reads a chart as evidence of what the plant did. The '
              'others are no better — setValue tells a panel what the plant is '
              'reading, disconnectUpstream takes a PLC off the wire. None of '
              'them is a method; all twelve are iterated from '
              'HarnessMethods.levers rather than listed here, so a thirteenth '
              'is covered on the day upstream declares it');
    });

    test('the lever set this arm iterates is not empty', () {
      // Anti-vacuity, and it is not theoretical: the intersection above passes
      // trivially if the upstream set is ever emptied or renamed.
      expect(HarnessMethods.levers, isNotEmpty,
          reason: 'an empty lever set makes the arm above assert nothing. If '
              'HarnessMethods.levers was renamed or emptied upstream, this '
              'file is no longer guarding the thing it claims to guard');
      expect(_session().registeredMethods, isNotEmpty,
          reason: 'a session that registered nothing intersects with '
              'everything to give the empty set — the arm above would pass '
              'because the ledger is not being read');
    });
  });

  group('the closure arms bite when fed a wrong ledger', () {
    test('a ledger carrying seedTimeseries is caught, naming the lever', () {
      final forged = {
        ..._session().registeredMethods,
        HarnessMethods.seedTimeseries,
      };

      final found = leversOnTheWire(forged);

      expect(found, {HarnessMethods.seedTimeseries},
          reason: 'the arm must name the lever that appeared. If this gateway '
              'really registered it, a client could insert rows into the '
              'historian and the chart an operator reads as evidence of a cook '
              'cycle would be showing samples the plant never produced — and '
              'the reviewer reading the failure needs to be told which lever, '
              'not that two sets differed');
    });

    test('a lever registered under its wire spelling is caught too', () {
      // The realistic mistake is not registering `harness.seedTimeseries` —
      // nothing in this package can even name that constant outside `test/`.
      // It is registering `seedTimeseries`, the same way the thirty-four data
      // services lost their `harness.` prefix when they became wire names
      // (`client_sub_apis.dart:12-16`). The prefix is a greppable boundary, not
      // a defence, so the arm checks both spellings.
      final forged = {..._session().registeredMethods, 'seedTimeseries'};

      final found = leversOnTheWire(forged);

      expect(found, {'seedTimeseries'},
          reason: 'a lever promoted to a wire name by dropping its prefix is '
              'the way this actually happens, and it is the same forged-history '
              'hazard: a client that can insert samples can insert rows into '
              'the historian');
    });

    test('a ledger missing preferences.clear is caught, naming the method', () {
      final crippled = {..._session().registeredMethods}
        ..remove(DataServiceMethods.prefClear);

      final missing =
          DataServiceMethods.all.difference(dataServiceNames(crippled));

      expect(missing, {DataServiceMethods.prefClear},
          reason: 'direction one has to name the method the table claims to '
              'carry and nothing answers. A settings page calling '
              'preferences.clear against this gateway would get '
              'METHOD_NOT_FOUND, which surfaces on a panel as a reset button '
              'that silently does nothing');
    });

    test('a declared set carrying a name nothing answers is caught', () {
      final overclaimed = {...DataServiceMethods.all, 'historyViews.dropTable'};

      final missing =
          overclaimed.difference(dataServiceNames(_session().registeredMethods));

      expect(missing, {'historyViews.dropTable'},
          reason: 'the other input to the same equality. A name declared in '
              'the protocol package with no handler behind it is a method '
              'every client believes it can call — the gap Phase 10 spent five '
              'plans closing, and the shape it would come back in');
    });

    test('an empty declared set does not make the comparison pass', () {
      // The vacuity the anti-vacuity arm above is guarding against, run rather
      // than argued: with nothing declared, direction two still finds the
      // whole ledger.
      final undeclared =
          dataServiceNames(_session().registeredMethods).difference(const {});

      expect(undeclared, hasLength(declaredDottedNames.length),
          reason: 'emptying the declared set must not silence the check — '
              'every dotted name in the ledger becomes undeclared surface, '
              'which is the honest answer and the reason the equality is '
              'stated in both directions at once');
    });
  });

  group('the two claims that expired when the table closed', () {
    test('the sweep is reading the files it thinks it is', () {
      // Both arms below are greps, and a grep against a file that is not
      // there passes silently. Pin the paths first, so a failure means the
      // claim came back rather than that the reader moved.
      expect(_fallbackComment.existsSync(), isTrue,
          reason: 'the gateway session is not at ${_fallbackComment.path} '
              'relative to this package root. `dart test` runs from the '
              'package root, so check the directory the run was invoked from '
              'before believing the arm below');
      expect(_clientSubApis.existsSync(), isTrue,
          reason: 'the client\'s sub-API file is not at '
              '${_clientSubApis.path}. This is a sibling package read the way '
              '`handler_table_test.dart` reads the contract kit, and if the '
              'layout changed this arm has to move with it rather than '
              'passing vacuously');
    });

    test('the fallback no longer calls its -32601 the gap-proving mechanism',
        () {
      expect(_fallbackComment.readAsStringSync(), isNot(contains('gap-proving')),
          reason: '06-04 kept the method-not-found fallback for two reasons '
              'and the first of them was that the contract kit\'s '
              'expectUnreachableMethod pins -32601 exactly, which made it '
              'Phase 10\'s gap-proving mechanism. Phase 10 is over and both '
              'gap lists are empty, so that reason is spent — the paragraph '
              'has to say so, or the next reader either trusts a mechanism '
              'that no longer has anything to prove or deletes the '
              'registration as vestigial. The second reason has not expired '
              'and is why the registration stays. If a gap ever genuinely '
              'reopens, delete this arm deliberately rather than wording '
              'around the token');
    });

    test('the client no longer claims the gateway answers -32601 to all of them',
        () {
      expect(_clientSubApis.readAsStringSync(), isNot(contains('32601')),
          reason: 'client_sub_apis.dart told its reader that there is no '
              'server handler for any of these thirty-four methods and that '
              'every one of them surfaces the gateway\'s own -32601. That was '
              'true for six phases and stopped being true in 10-05. A comment '
              'that says a feature is missing outlives the feature arriving: '
              'the next person to debug a data-service call reads it, '
              'believes the gateway has no handler, and goes looking on the '
              'wrong side of the socket');
    });
  });

  group('no method on this wire is shaped like a statement', () {
    test('no registered name carries a statement-shaped token', () {
      expect(statementShapedNames(_session().registeredMethods), isEmpty,
          reason: 'a method whose name says SQL is the crudest form of the '
              'thing DB-04 forbids, and the only reason to sweep for it is '
              'that it costs nothing. If this ever fires, the offending name '
              'hands the plant\'s database to whoever holds a socket: no '
              'gateway-side escaping makes a caller-supplied statement safe, '
              'because the caller chose the grammar');
    });

    test('the shipped timeseries names pass the sweep', () {
      // Asserted explicitly rather than left as a consequence of the arm
      // above. A sweep that fires on a name that already ships is a sweep
      // somebody weakens within the week, and the weakening is what actually
      // loses the property. `queryTimeseriesData` is a query *for a named
      // series over a window*; the shape forbidden here is a method that takes
      // a **statement**, and the two are not distinguishable by a name
      // pattern — which is why the parameter arm below is the one doing the
      // work, and why saying otherwise in this reason string would be a lie
      // the next reader would act on.
      expect(statementShapedNames(DataServiceMethods.timeseriesMethods), isEmpty,
          reason: 'timeseries.queryTimeseriesData and its three siblings are '
              'shipped names. If the pattern fires on them the pattern is '
              'wrong, and the correct response is to narrow the pattern here '
              'rather than to rename a wire method or delete the sweep');
    });

    test('a name set carrying historyViews.rawQuery is caught, naming it', () {
      final forged = {
        ..._session().registeredMethods,
        'historyViews.rawQuery',
      };

      expect(statementShapedNames(forged), {'historyViews.rawQuery'},
          reason: 'the arm has to name the offender. A rawQuery on this wire '
              'means any authenticated station can run a statement of its own '
              'choosing against the historian — reading every tag the policy '
              'hides, or dropping the table a shift report is built from');
    });
  });

  group('no parameter on this wire is shaped like a statement', () {
    test('the four wire interfaces declare no statement-shaped parameter', () {
      final swept = statementShapedParameters(_everyWireParameter())
          .difference(exemptParameters.keys.toSet());

      expect(swept, isEmpty,
          reason: 'this is the arm that bites. The gateway forbids '
              'query(sql) by having no method that takes a statement — but a '
              'parameter is a statement fragment just the same, and it '
              'arrives wearing an ordinary signature. A `where` or an '
              '`expression` on any of these four interfaces is a SQL door '
              'with a different door handle. If a new one is genuinely safe, '
              'it joins exemptParameters with the guard that makes it safe '
              'cited there — it does not get quietly dropped from the token '
              'list');
    });

    test('orderBy is still exempt, and still needs to be', () {
      // The companion to the exemption, and the reason the exemption is not a
      // hole held open for nothing. `handler_table_test.dart:293-300` makes
      // the same move for a close code: an exemption whose subject has stopped
      // tripping the sweep is a line nobody will ever delete on purpose.
      expect(statementShapedParameters(_everyWireParameter()), {'orderBy'},
          reason: 'the raw sweep — exemptions not applied — must still name '
              'exactly orderBy. If it names nothing, the sweep has stopped '
              'seeing the one parameter this exemption exists for and the '
              'exemption is now excusing nothing while looking like a '
              'reviewed decision. If it names something else as well, that '
              'second parameter reached the wire without anybody arguing for '
              'it');
    });

    test('a parameter set carrying where is caught, naming it', () {
      final forged = [..._everyWireParameter(), 'where'];

      expect(statementShapedParameters(forged), containsAll(<String>['where']),
          reason: 'a `where` parameter on a timeseries method is the whole of '
              'DB-04 in one word: the client writes the predicate, the '
              'gateway pastes it into the statement, and every row-level '
              'restriction the policy layer applies stops meaning anything');
    });

    test('the walk sees a parameter arriving through a superinterface', () {
      // WR-07's hole, re-proven against this file's own copy of the walk.
      // `api_surface_test.dart:247-257` found it once: reading `declarations`
      // alone returns only what a class declares itself, so the one shape
      // these arms exist to forbid could arrive through a superinterface and
      // be invisible to every assertion above.
      expect(declaredParameterNames(_DerivedFixture),
          containsAll(<String>['sql', 'where']),
          reason: 'a parameter inherited from a superinterface is fully part '
              'of the wire surface. If this fails, every arm above is reading '
              'half the surface and reporting the other half as clean');
    });
  });

  group('the one exemption is argued, not asserted', () {
    test('there is exactly one exempt parameter', () {
      expect(exemptParameters, hasLength(1),
          reason: 'orderBy is the only free-text-looking parameter on this '
              'wire and the list is meant to stay that way. A second entry is '
              'a second SQL-shaped thing somebody decided was fine, and it '
              'should be read as such rather than counted');
    });

    test('the exemption carries an argument, not a label', () {
      expect(thinlyArguedExemptions(exemptParameters), isEmpty,
          reason: 'an exemption nobody had to justify is an exemption nobody '
              'will re-examine. The same floor gate_manifest_test.dart puts '
              'on a supporting case, for the same reason: the entry is the '
              'only place the argument is written down, so a label leaves the '
              'next reader to re-derive whether a SQL fragment on the wire is '
              'safe');
    });

    test('the exemption cites a file that exists', () {
      expect(uncitedExemptions(exemptParameters), isEmpty,
          reason: 'the argument has to point at the guard, not describe it. '
              'orderBy is safe because of a two-value allow-list in a '
              'specific file; a citation that does not resolve is a reader '
              'being sent to look for a check that may have moved or been '
              'deleted');
    });

    test('the guard the exemption cites is still in the cited file', () {
      // The citation and the floor together still only prove that somebody
      // wrote a paragraph. This arm is what makes the paragraph falsifiable:
      // orderBy is exempt *because* of a two-value allow-list, so if that
      // allow-list is deleted the exemption has to stop being true here rather
      // than continuing to read like a reviewed decision. `hostile_params_test`
      // proves the allow-list bites; this proves the exemption is about a
      // guard that is still there.
      expect(unguardedExemptions(exemptParameters), isEmpty,
          reason: 'the exemption for orderBy says a two-value allow-list makes '
              'it safe and names the file holding it. If the allow-list is '
              'gone, a client-supplied ORDER BY clause is reaching an '
              'unescaped SQL interpolation again — the query(sql) RPC this '
              'project forbids, arriving through a parameter this very list '
              'excused');
    });

    test('an exemption with its argument blanked is caught, naming it', () {
      final blanked = {'orderBy': ''};

      expect(thinlyArguedExemptions(blanked), {'orderBy'},
          reason: 'this is what the discipline is for. A future reviewer '
              'adding a parameter to the exempt list with an empty string, or '
              'with "safe" as the reason, has silently widened what this wire '
              'accepts as a SQL fragment');
    });
  });
}

/// Fixtures for the walk's own regression arm: exactly the shape that used to
/// slip past — a statement-taking method and a `where:` parameter, reachable
/// only through a superinterface. Nothing on the wire implements these.
abstract interface class _StatementFixture {
  Future<void> query(String sql, {String? where});
}

abstract interface class _DerivedFixture implements _StatementFixture {
  Future<void> ownMember(int id);
}
