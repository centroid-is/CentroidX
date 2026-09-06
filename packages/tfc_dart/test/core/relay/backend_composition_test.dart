/// Criterion 4: **the composition the binary builds, assembled by a test.**
///
/// Phase 10's CR-01, restated by 13-CONTEXT: *"a composition nothing assembles
/// is a composition nothing tests, and it was the only one that shipped."*
/// Every collaborator in `lib/core/relay/` has been judged in isolation by its
/// own plan. None of that says anything about the object graph
/// `centroidx-backend` actually constructs — which, last milestone, was a graph
/// no test had ever built.
///
/// This file builds it. `composeBackendRelay` lives under `lib/` for the reason
/// `gateway_config.dart` records about `buildGateway`: **`bin/` is not
/// addressable by any `package:` URI**, so anything a test has to reach has to
/// live under `lib/`, and a structural arm below pins that `bin/main.dart`
/// reaches it exactly once. That pair — one function under `lib/`, one call
/// site in `bin/` — is the entire mechanism by which criterion 4 is satisfiable
/// at all.
///
/// ## The reader and the store are real
///
/// The `Database` and `Preferences` handed to the composition here are the
/// production classes over a real, on-disk SQLite `AppDatabase`
/// (`AppDatabase.create(..., sqliteFolder:)`, `database_drift.dart:915-923`) —
/// not a container, not a mock, not a `Fake…Source`. The plan permits a
/// database pointed at a test container and forbids a fake anything; SQLite is
/// the same production code path with a different executor behind drift, and it
/// runs on a machine with no Docker daemon, which is what this one is
/// (13-09 Finding 1). The no-fakes arm below asserts the runtime type of every
/// collaborator AND of the three sources behind the data services, so a fake
/// substituted anywhere fails with a type name in the message.
library;

import 'dart:convert' show jsonEncode;
import 'dart:io';
import 'dart:mirrors';

import 'package:logger/logger.dart';
import 'package:test/test.dart';

import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/backend_browse.dart';
import 'package:tfc_dart/core/relay/backend_composition.dart';
import 'package:tfc_dart/core/relay/backend_data_services.dart';
import 'package:tfc_dart/core/relay/backend_freshness.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart';
import 'package:tfc_dart/core/relay/backend_state_man.dart';
import 'package:tfc_dart/core/relay/backend_writes.dart';
import 'package:tfc_dart/core/relay/key_mapping_series_resolver.dart';
import 'package:tfc_dart/core/relay/relay_config.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_server/tfc_relay_server.dart';

// --------------------------------------------------------------- the fixture

/// Three plant keys, spelled the way SVN spells them
/// (`svn-plc-tag-convention`): AREAnn.DEVnn.SUBnn.
KeyMappings _mappings() => KeyMappings(nodes: <String, KeyMappingEntry>{
      for (final key in const <String>[
        'ST101.CN01.MOT01.speed',
        'ST101.CN01.MOT01.setpoint',
        'ST201.CN04.MOT01.running',
      ])
        key: KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: key)
            ..serverAlias = key.split('.').first,
        ),
    });

/// The `relay` section, as an operator would write it into the stateman file.
Map<String, dynamic> _relaySection({
  int port = 0,
  String? tokenFile,
  String source = 'none',
}) =>
    <String, dynamic>{
      'relay': <String, dynamic>{
        'port': port,
        'credentials': <String, dynamic>{
          'source': source,
          if (tokenFile != null) 'token_file': tokenFile,
        },
      },
    };

String _encode(Map<String, dynamic> json) => jsonEncode(json);

void main() {
  late Directory tmp;
  late Database database;
  late Preferences prefs;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('backend-composition');
    // The real production class over a real on-disk database. See the library
    // doc for why SQLite and not a container.
    database = Database(await AppDatabase.create(
      DatabaseConfig(applicationName: 'backend-composition-test'),
      sqliteFolder: tmp,
    ));
    prefs = await Preferences.create(db: database);
  });

  tearDown(() async {
    await database.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// The graph, composed from the real everything. Torn down after the case.
  BackendRelayComposition compose({
    Map<String, dynamic>? stateman,
    KeyPolicy? policy,
    TokenValidator? validator,
    PipeMainEndpoint? pipe,
    KeyMappings? keyMappings,
  }) {
    final config = RelayConfig.fromJson(
      stateman ?? _relaySection(),
      source: 'stateman.json',
    )!;
    final composed = composeBackendRelay(
      config: config,
      pipe: pipe ?? PipeMainEndpoint(),
      keyMappings: keyMappings ?? _mappings(),
      database: database,
      prefs: prefs,
      policy: policy,
      validator: validator,
      log: Logger(level: Level.off),
    );
    addTearDown(composed.dispose);
    return composed;
  }

  group('the graph the binary builds', () {
    test('is a RelayServer whose api is the backend adapter', () {
      final composed = compose();

      expect(composed.server, isA<RelayServer>());
      expect(composed.server.api, isA<BackendStateMan>(),
          reason: 'RelayServer takes a StateManApi and this phase supplies '
              'exactly one implementation of it');
      expect(identical(composed.server.api, composed.api), isTrue,
          reason: 'the adapter the record hands back must be the adapter the '
              'server holds, or the test is judging a second object');
    });

    test('returns the server UNSTARTED, so nothing binds a port here', () {
      final composed = compose();

      // `RelayServer.port` throws until start() has bound. The composition
      // returning unstarted is what lets bin/main.dart log the boot line
      // before it binds, and what lets every arm above run without a socket.
      expect(() => composed.server.port, throwsA(isA<StateError>()));
    });

    test(
        'is composed of the PRODUCTION classes, with no fake, stub or '
        'decorator standing in for one', () {
      final composed = compose();
      final api = composed.api;

      // One entry per collaborator in the graph. The role names are what a
      // failure message says, so a substitution is reported as "timeseries is
      // _FakeTimeseries" rather than as a set that differs somewhere.
      final actual = <String, Type>{
        'api': composed.server.api.runtimeType,
        'values (the sweep)': api.values.runtimeType,
        'values (the live half under it)': composed.liveValues.runtimeType,
        'writes': api.writes.runtimeType,
        'browse': api.browse.runtimeType,
        'timeseries': api.timeseries.runtimeType,
        'historyViews': api.historyViews.runtimeType,
        'preferences': api.preferences.runtimeType,
        'resolver': composed.server.resolver.runtimeType,
        'policy': composed.server.policy.runtimeType,
        // The three sources are the reader and the store themselves. Without
        // these three rows the arm would pass against a BackendTimeseries
        // composed over a fake TimeseriesSource — the production wrapper with
        // nothing real behind it, which is the exact shape CR-01 is about.
        //
        // Read by pattern and NOT by `as`: a cast would throw on a substituted
        // collaborator and report a cast error from a test line, before the map
        // below could name which role went wrong. The whole value of this arm
        // is the message it prints, so it must survive long enough to print it.
        'timeseries source': switch (api.timeseries) {
          BackendTimeseries(:final source) => source.runtimeType,
          final other => other.runtimeType,
        },
        'historyViews source': switch (api.historyViews) {
          BackendHistoryViews(:final source) => source.runtimeType,
          final other => other.runtimeType,
        },
        'preferences source': switch (api.preferences) {
          BackendPreferences(:final source) => source.runtimeType,
          final other => other.runtimeType,
        },
      };

      const reason =
          'Phase 10 CR-01: a composition nothing assembles is a composition '
          'nothing tests, and last milestone that was the only one that '
          'shipped. This arm asserts the runtime type of every collaborator '
          'in the graph bin/main.dart builds. A fake, a stub or a decorator '
          'substituted anywhere fails here with its own type name in the '
          'message — which is the only reason the list is worth writing down.';

      expect(actual, <String, Type>{
        'api': BackendStateMan,
        'values (the sweep)': BackendFreshnessSweep,
        'values (the live half under it)': BackendLiveValues,
        'writes': BackendWrites,
        'browse': BackendBrowse,
        'timeseries': BackendTimeseries,
        'historyViews': BackendHistoryViews,
        'preferences': BackendPreferences,
        'resolver': KeyMappingSeriesResolver,
        'policy': AllVisibleOperatorWrites,
        'timeseries source': DatabaseTimeseriesSource,
        'historyViews source': DatabaseHistoryViewSource,
        'preferences source': PreferencesSource,
      }, reason: reason);

      // The plan's Set<Type> literal, kept alongside the per-role map: the map
      // names the offender, the set is the flat statement that no other type
      // appears in the graph at all.
      expect(actual.values.toSet(), <Type>{
        BackendStateMan,
        BackendFreshnessSweep,
        BackendLiveValues,
        BackendWrites,
        BackendBrowse,
        BackendTimeseries,
        BackendHistoryViews,
        BackendPreferences,
        KeyMappingSeriesResolver,
        AllVisibleOperatorWrites,
        DatabaseTimeseriesSource,
        DatabaseHistoryViewSource,
        PreferencesSource,
      }, reason: reason);
    });

    test('the freshness sweep wraps the live half, not the other way round',
        () {
      final composed = compose();

      expect(identical(composed.api.values, composed.freshness), isTrue,
          reason: 'the adapter must read through the sweep, or a value that '
              'has gone quiet is served to a panel still badged good');
    });
  });

  group('the policy is named at the call site, not defaulted', () {
    test('the shipped policy is the one this composition names', () {
      final composed = compose();

      // IDENTITY, not type. `RelayServer`'s default is
      // `const AllVisibleOperatorWrites()`, and Dart canonicalises const
      // instances — so an explicit `policy: const AllVisibleOperatorWrites()`
      // and no argument at all are the same object and indistinguishable by
      // any assertion about type or equality. `backendRelayPolicy` is a
      // deliberately non-const instance for exactly this reason: it is what
      // makes "somebody chose this" a fact a test can read.
      expect(identical(composed.server.policy, backendRelayPolicy), isTrue,
          reason: 'a default that ships is a decision nobody made. The policy '
              'must be the instance backend_composition.dart names, with its '
              'reason written beside it');
      expect(identical(composed.server.policy, const AllVisibleOperatorWrites()),
          isFalse,
          reason: 'if this is the canonicalised const, the composition let '
              'RelayServer default and the arm above is vacuous');
    });

    test('a deployment may hand its own policy in, and it is the one used', () {
      final mine = AllVisibleOperatorWrites();
      final composed = compose(policy: mine);

      expect(identical(composed.server.policy, mine), isTrue);
    });
  });

  group('one credential source, and never two', () {
    test('a token file produces ServerConfig.auth and NO validator argument',
        () {
      final tokens = File('${tmp.path}/relay-tokens.json')
        ..writeAsStringSync('{"tokens":[]}');
      final composed = compose(
        stateman: _relaySection(source: 'token_file', tokenFile: tokens.path),
      );

      expect(composed.server.config.auth, isNotNull);
      expect(composed.server.config.auth!.tokenFilePath, tokens.path);
      // Reaching this line at all is the assertion: RelayServer's constructor
      // throws when it is given both (relay_server.dart:155), so a composition
      // that passed a validator alongside auth could not have been built.
    });

    test('handing a validator alongside a token file is refused HERE, before '
        'RelayServer can throw it at boot', () {
      final tokens = File('${tmp.path}/relay-tokens.json')
        ..writeAsStringSync('{"tokens":[]}');

      expect(
          () => compose(
                stateman: _relaySection(
                    source: 'token_file', tokenFile: tokens.path),
                validator: const PermissiveTokenValidator(),
              ),
          throwsA(isA<ArgumentError>()),
          reason: 'the composition refuses the pair rather than forwarding it, '
              'so the message names the composition root rather than arriving '
              'from relay_server.dart:155 in a container log at 03:00');
    });

    test('the ArgumentError at relay_server.dart:155 really does fire, so the '
        'arm above is not vacuous', () {
      final tokens = File('${tmp.path}/relay-tokens.json')
        ..writeAsStringSync('{"tokens":[]}');
      final config = RelayConfig.fromJson(
        _relaySection(source: 'token_file', tokenFile: tokens.path),
        source: 'stateman.json',
      )!;

      // The deliberately-wrong construction, by hand: the exact pair the
      // composition declines to build.
      //
      // **A NON-const `PermissiveTokenValidator`, and that matters.**
      // `RelayServer` tells "you configured nothing" from "you configured a
      // validator" by IDENTITY against `RelayServer.permissiveDefault`, which
      // IS `const PermissiveTokenValidator()` — Dart canonicalises const
      // instances, so passing the const spelling reads as having configured
      // nothing and does NOT throw. Measured, not assumed: this arm was
      // written with `const` first and passed against the pair it exists to
      // refuse. It is also why `composeBackendRelay` refuses on `!= null`
      // rather than leaning on the server's identity check — a caller could
      // otherwise hand it the canonicalised const and be silently read as
      // having handed nothing.
      expect(
          () => RelayServer(
                api: BackendStateMan(),
                config: config.toServerConfig(),
                // ignore: prefer_const_constructors
                validator: PermissiveTokenValidator(),
                resolver: KeyMappingSeriesResolver(keyMappings: _mappings()),
              ),
          throwsA(isA<ArgumentError>().having((e) => e.message.toString(),
              'message', contains('sources of truth'))),
          reason: 'if this stopped throwing, every credential arm above would '
              'pass against a server that quietly accepted two credential '
              'sources');
    });

    test('a validator deployment must be handed one, and is refused without',
        () {
      expect(
          () => compose(stateman: _relaySection(source: 'validator')),
          throwsA(isA<ArgumentError>()),
          reason: 'credentials.source = validator says the composition root '
              'supplies the check; a root that supplies none would serve the '
              'plant LAN with RelayServer\'s permissive default');
    });
  });

  group('the resolver is built from the keys the workers were registered with',
      () {
    test('it is a KeyMappingSeriesResolver over the same mappings', () {
      final mappings = _mappings();
      final composed = compose(keyMappings: mappings);
      final resolver = composed.server.resolver;

      expect(resolver, isA<KeyMappingSeriesResolver>());
      for (final key in mappings.nodes.keys) {
        expect(resolver.keyForNode(key), key,
            reason: 'a resolver built from different mappings than the pipe\'s '
                'workers is a chart that resolves to a table nobody writes');
      }
      expect(resolver.keyForNode('ST999.CN99.MOT99.speed'), isNull);
    });
  });

  group('the graph actually serves', () {
    test('start() binds a port and close() gives it back', () async {
      final composed = compose(stateman: _relaySection(port: 0));

      await composed.server.start();
      expect(composed.server.port, greaterThan(0),
          reason: 'port 0 draws a free port; a graph that cannot bind is a '
              'graph that has never been shown to serve');
      // Closed by the composition's own dispose (addTearDown in `compose`).
    });
  });

  // ------------------------------------------------------- the carried finding

  group('FINDING: the preferences allow-list narrowing has no home here', () {
    // 13-05 flagged it, 13-06 routed it to this plan's `policy:` argument, and
    // this plan measured that the routing does not work. Both arms below are
    // the finding written as executable statements rather than as prose in a
    // SUMMARY nobody re-reads. Neither changes behaviour; see 13-10-SUMMARY.

    test('KeyPolicy has exactly two members, and neither is about a preference '
        'key', () {
      final declared = reflectClass(KeyPolicy)
          .declarations
          .values
          .whereType<MethodMirror>()
          .where((m) => !m.isConstructor && !m.isStatic)
          .map((m) => MirrorSystem.getName(m.simpleName))
          .toSet();

      expect(declared, <String>{'canSee', 'canWrite'},
          reason: 'The BackendPreferences.clear() allow-list narrowing was '
              'handed to this composition\'s `policy:` argument by 13-06. It '
              'cannot land there: KeyPolicy answers about PLANT TAGS, and '
              '_PolicyPreferences — the class that gates every preference '
              'mutator — is constructed with (source, identityOf) and never '
              'consults a KeyPolicy at all (policy_state_man.dart:945-947). '
              'policy_state_man.dart:892-899 rejects a canWritePreference '
              'member deliberately, as a second policy surface to keep in '
              'step with the first. If this arm is red because somebody added '
              'that member, the narrowing finally HAS a home and this '
              'composition must pass one — see 13-10-SUMMARY.');
    });

    test('an allow-listed clear naming key_mappings still deletes it — the '
        'residual exposure, measured', () async {
      final composed = compose();
      final preferences = composed.api.preferences;

      await preferences.setString('key_mappings', '{"nodes":{}}');
      await preferences.setString('svn.chart.maxPoints', '6000');
      expect(await preferences.containsKey('key_mappings'), isTrue);

      // An UNRESTRICTED clear never reaches here on the wire: _PolicyPreferences
      // .clear refuses `allowList == null` pre-effect (policy_state_man.dart:
      // 1072-1086, 10-REVIEW CR-02), and PolicyStateMan wraps every session
      // unconditionally (relay_session.dart:362) regardless of what `policy:`
      // is. 13-05's and 13-06's hand-forward was written without that fact.
      //
      // What IS still reachable is this: an `operate` session naming the
      // reserved key in its own allow list. `reservedPreferenceKeys`
      // (policy_state_man.dart:95) is quoted in the refusal MESSAGE and is
      // never enforced as an exclusion.
      await preferences.clear(allowList: <String>{'key_mappings'});

      expect(await preferences.containsKey('key_mappings'), isFalse,
          reason: 'THIS IS THE FINDING, not the desired behaviour. 518 KiB of '
              'routing configuration the whole plant is served through, gone '
              'in one gated call, not restored by reconnecting, and not '
              'visible until the next restart. Fixing it is a change to '
              'tfc_relay_server\'s policy layer — enforce '
              'reservedPreferenceKeys as an exclusion, or grow the member the '
              'arm above pins the absence of. It is NOT a change this '
              'composition can make: see 13-10-SUMMARY.');
      expect(await preferences.containsKey('svn.chart.maxPoints'), isTrue,
          reason: 'the allow list is honoured, which is why the call is not '
              'simply broken — it is precise, and that is what makes it '
              'usable as a weapon');
    });
  });

  group('off by default, and it is the upgrade-safety property', () {
    // Both directions, through the same call bin/main.dart makes, on a real
    // file. The structural arms below prove where the guard is; these two prove
    // what it is guarding on.

    Future<RelayBoot> bootFrom(Map<String, dynamic> stateman) {
      final file = File('${tmp.path}/stateman.json')
        ..writeAsStringSync(_encode(stateman));
      return RelayBoot.fromStatemanFile(file.path);
    }

    test('a stateman file with no relay section: OFF, one line, no throw',
        () async {
      final boot = await bootFrom(<String, dynamic>{
        'opcua': <dynamic>[],
        'modbus': <dynamic>[],
      });

      expect(boot.isOn, isFalse);
      expect(boot.config, isNull,
          reason: 'a null config is what makes the relay block in '
              'bin/main.dart unreachable. Every plant backend at SVN gets this '
              'binary before anybody turns the WebSocket on, and it must boot '
              'exactly as it does today');
      expect(boot.bootLogLine, contains('OFF'));
      expect(boot.bootLogLine.split('\n'), hasLength(1),
          reason: 'one line an operator can read off a boot log');
    });

    test('the same file with a relay section: ON, and it composes', () async {
      final boot = await bootFrom(<String, dynamic>{
        'opcua': <dynamic>[],
        ..._relaySection(port: 0),
      });

      expect(boot.isOn, isTrue);
      expect(boot.bootLogLine, contains('ON'));
      final composed = composeBackendRelay(
        config: boot.config!,
        pipe: PipeMainEndpoint(),
        keyMappings: _mappings(),
        database: database,
        prefs: prefs,
        log: Logger(level: Level.off),
      );
      addTearDown(composed.dispose);
      expect(composed.server, isA<RelayServer>(),
          reason: 'without this half the OFF arm above would pass against a '
              'backend that can never turn the relay on at all');
    });
  });

  // ------------------------------------------------- the binary's own block

  group('bin/main.dart is the caller, and only the caller', () {
    late String main;

    setUpAll(() {
      main = _stripComments(File('bin/main.dart').readAsStringSync());
    });

    test('the scan actually reads the file it claims to', () {
      // An absence assertion that never matched anything passes for ever.
      // 13-06's Task 2 was written around exactly this hole.
      expect(main, contains('void main()'));
      expect(main, contains('pipe.addWorker('));
    });

    test('there is exactly ONE composition site', () {
      expect('composeBackendRelay('.allMatches(main).length, 1,
          reason: 'this is what makes the whole file above evidence about the '
              'BINARY rather than about a function the binary might call. Two '
              'composition sites is two object graphs, and the test would be '
              'assembling one of them while the plant ran the other.');
    });

    test('the boot line is printed on BOTH branches, outside the guard', () {
      expect(main, contains('bootLogLine'),
          reason: 'T-13-06-d: one clear line saying whether the WebSocket is '
              'on, every boot, configured or not');

      final guarded = _bodyOf(main, 'if (relayConfig != null)');
      expect(guarded, isNotEmpty,
          reason: 'the relay block must be guarded by a null check on the '
              'config, or a backend with no relay section does not boot');
      expect(guarded, isNot(contains('bootLogLine')),
          reason: 'a boot line inside the guard is a boot line the OFF case '
              'never prints, which is the silent-off failure 13-06 exists to '
              'prevent');
    });

    test('nothing starts a relay outside that guard', () {
      final guarded = _bodyOf(main, 'if (relayConfig != null)');
      expect(guarded, contains('composeBackendRelay('));
      expect(guarded, contains('.start()'),
          reason: 'compose allocates; start() binds. Both belong inside the '
              'guard — off means no socket, not a socket nobody uses');
    });

    test('the config-watch key set gained nothing', () {
      // The relay config lives in the stateman file, not in a preference row,
      // so a relay-config change is applied by restarting the process exactly
      // like a stateman change is today. No file watcher, no new key.
      final watcher = _statementAt(main, 'PreferencesWatcher.forDatabase');
      expect(watcher, contains("'key_mappings'"));
      expect(watcher, contains("'alarm_man_config'"));
      expect(watcher, isNot(contains('relay')),
          reason: 'restart-to-apply goes through the existing shutdown; a '
              'relay key here would be a second restart trigger for a value '
              'that is not in the database at all');
    });

    test('the shutdown path did not grow', () {
      // pipe_shutdown_structure_test.dart owns this property and has been shown
      // to bite four times (12-06 sabotages A-D). It is restated here because
      // this plan is the one that adds a closeable object to the process, and
      // the arm should fail in the file whose change caused it.
      final body = _bodyOf(main, 'Never _shutdown(');
      expect(body, isNotEmpty);
      expect(body, isNot(contains('await')),
          reason: 'RelayServer.close() on this path is the 5.76 s stall '
              'coming back on the most common restart in the plant. The '
              'process is about to exit(0); the sockets go with it');
      expect(body, isNot(contains('close(')));
      expect(main, isNot(contains('.close(')),
          reason: 'the whole file, not just the function: an async helper '
              'awaited from _shutdown would pass the arm above');
    });

    test('the alarmman block is untouched — it is Phase 14\'s', () {
      for (final landmark in const <String>[
        'StateMan.create(',
        'AlarmMan.create(',
        'activeAlarms().listen(',
      ]) {
        expect(main, contains(landmark),
            reason: 'the second StateMan and its activeAlarms() subscription '
                'are Phase 14\'s scope and stay byte-for-byte. A relay block '
                'that "tidied" one of them away would take alarm history with '
                'it, and nothing would say so');
      }
    });
  });
}

// ------------------------------------------------------------- source scanning
//
// Copied from `test/core/pipe_shutdown_structure_test.dart` rather than
// imported: its helpers are library-private, and the alternative — making them
// public so a second file can share them — would make the pin that has bitten
// four times editable from somewhere other than the pin. Three small functions
// are the cheaper duplication.

/// [source] with `//` line comments and `/* */` block comments removed.
String _stripComments(String source) {
  final out = StringBuffer();
  var inBlock = false;
  for (final rawLine in source.split('\n')) {
    var line = rawLine;
    if (inBlock) {
      final end = line.indexOf('*/');
      if (end < 0) {
        out.writeln();
        continue;
      }
      line = line.substring(end + 2);
      inBlock = false;
    }
    final blockStart = line.indexOf('/*');
    if (blockStart >= 0) {
      inBlock = true;
      line = line.substring(0, blockStart);
    }
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//')) {
      out.writeln();
      continue;
    }
    final comment = _lineCommentAt(line);
    if (comment >= 0) line = line.substring(0, comment);
    out.writeln(line);
  }
  return out.toString();
}

/// Where a real `//` comment starts on [line], or -1.
int _lineCommentAt(String line) {
  var singles = 0;
  var doubles = 0;
  for (var i = 0; i < line.length - 1; i++) {
    final c = line[i];
    if (c == "'") singles++;
    if (c == '"') doubles++;
    if (c == '/' && line[i + 1] == '/' && singles.isEven && doubles.isEven) {
      return i;
    }
  }
  return -1;
}

/// The brace-matched body of the construct whose declaration contains
/// [signature]. Empty when there is no such construct.
String _bodyOf(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return '';
  final open = source.indexOf('{', start);
  if (open < 0) return '';
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  return '';
}

/// The whole statement beginning at [anchor], up to its terminating `;`.
String _statementAt(String source, String anchor) {
  final start = source.indexOf(anchor);
  if (start < 0) return '';
  final end = source.indexOf(';', start);
  return end < 0 ? source.substring(start) : source.substring(start, end + 1);
}
