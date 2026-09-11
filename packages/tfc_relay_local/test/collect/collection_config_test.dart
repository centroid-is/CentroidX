/// The process-level collection decision, and the four refusals that make
/// side-by-side safe.
///
/// The app's collector derives its table name from `entry.name ?? entry.key`
/// (`collector.dart:215`, `:50`) out of the same `collect` blocks this gateway
/// reads, and the tables have no primary key and no unique index
/// (`database_drift.dart:677-691`, `:907`) — so an unconfigured gateway that
/// collected would write byte-identical table names beside the app's rows and
/// every count a panel shows would double, silently. Every case in this file
/// is about making that impossible by construction: absent means no database
/// object at all, present-but-silent means disabled, and the only route into
/// the app's tables is a deliberate, two-field act.
///
/// No hardware, no database, no sockets: every case here is allocation and
/// arithmetic, which is what keeps this plan runnable with the machine
/// offline.
@TestOn('vm')
library;

import 'package:tfc_dart/tfc_dart.dart'
    show kMaxQueuedRowsPerTable, kMaxQueuedRowsTotal;
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:test/test.dart';

import '../support/free_port.dart';

/// The smallest gateway config file: one link, a mappings path, no collection.
Map<String, dynamic> gatewayJson() => <String, dynamic>{
      'server': <String, dynamic>{'port': 0},
      'key_mappings': 'svn-key-mappings.json',
      'links': <dynamic>[
        <String, dynamic>{
          'alias': 'ST101',
          'protocol': 'opcua',
          'endpoint': 'opc.tcp://10.104.29.11:4840',
        },
      ],
    };

/// A collection block that names a database, fully spelled.
///
/// The port is drawn, not literal — freeze 5's sweep is blunt on purpose
/// and nothing here ever binds it, so a free one costs one socket and
/// keeps the allow-list empty (gateway_config_test.dart made the same
/// choice for the same reason).
Map<String, dynamic> collectionJson(int port) => <String, dynamic>{
      'enabled': true,
      'endpoint': <String, dynamic>{
        'host': '10.104.29.100',
        'port': port,
        'database': 'hmi',
        'username': 'gateway',
        'password': 'not-a-real-password',
      },
    };

void main() {
  group('absent means never told about a database', () {
    test('a GatewayConfig with no collection block yields null', () {
      final config = GatewayConfig.fromJson(gatewayJson());

      expect(config.collection, isNull,
          reason: 'absent is not present-and-disabled: a gateway whose config '
              'file never mentions a database must construct no database '
              'object at all, and null is the only value that cannot be '
              'asked to');
    });

    test('the constructor default is null too', () {
      final config = GatewayConfig(
        server: serverConfigFromJson(const <String, dynamic>{'port': 0}),
        links: const [],
        keyMappingsPath: 'mappings.json',
      );

      expect(config.collection, isNull,
          reason: 'every fixture in this package builds GatewayConfig '
              'directly; if the default were anything but null, every one of '
              'them would be a gateway that might write to a plant database');
    });
  });

  group('enabled defaults to false even when the block is present', () {
    test('a block that names an endpoint but not enabled collects nothing',
        () async {
      final json = collectionJson(await freePort())..remove('enabled');

      final config = CollectionConfig.fromJson(json);

      expect(config.enabled, isFalse,
          reason: 'a half-written collection block must not start writing '
              'rows into a plant database; collecting is something an '
              'operator turns ON, never something a block\'s mere presence '
              'implies');
    });

    test('the bare constructor is disabled too', () {
      expect(CollectionConfig().enabled, isFalse,
          reason: 'the zero-argument construction is the one a refactor '
              'reaches for; it must be the inert one');
    });
  });

  group('the side-by-side guarantee: the prefix', () {
    test('tablePrefix defaults to gw_', () {
      expect(CollectionConfig().tablePrefix, 'gw_',
          reason: 'the app\'s collector derives its table names from the '
              'same collect blocks (collector.dart:215), so an unprefixed '
              'gateway writes into the app\'s tables and the row count '
              'doubles with no error anywhere');
    });

    test('the constructor default and the fromJson default are the SAME '
        'spelling (IN-03)', () {
      expect(CollectionConfig.fromJson(const <String, dynamic>{}).tablePrefix,
          CollectionConfig().tablePrefix,
          reason: 'the freeze sweep counts files, not occurrences, so two '
              'independent literals would pass it while drifting apart — '
              'both paths must resolve through defaultTablePrefix');
      expect(CollectionConfig.defaultTablePrefix, 'gw_');
    });

    test('an empty prefix is refused unless soleWriter is set', () {
      expect(
          () => CollectionConfig(tablePrefix: ''),
          throwsA(isA<ArgumentError>().having(
              (e) => e.message.toString(),
              'message',
              allOf(
                  contains('tablePrefix'),
                  contains('soleWriter'),
                  contains('collector')))),
          reason: 'an empty prefix aims the gateway at the very tables the '
              'app\'s collector writes; the refusal must name both fields '
              'and tell the operator what to do first (stop the app\'s '
              'collector on the collector station), because the person '
              'hitting it is mid-cutover and the message is the procedure');
    });

    test('an empty prefix WITH soleWriter constructs fine — the cutover mode',
        () {
      final config =
          CollectionConfig(tablePrefix: '', soleWriter: true);

      expect(config.tablePrefix, isEmpty);
      expect(config.soleWriter, isTrue,
          reason: 'the cutover is a deliberate, two-field act: whoever sets '
              'both fields has read the doc that says to stop the app\'s '
              'collector first. Refusing this arm too would make the cutover '
              'impossible rather than deliberate');
    });

    test('a prefix that cannot travel to SQL is refused, character by '
        'character', () {
      // The prefix reaches SQL by interpolation with the table identifier
      // unescaped (database_drift.dart:687, :907), so this is validation,
      // not tidiness.
      for (final bad in <String>[
        'gw"_',
        "gw'_",
        'gw;_',
        r'gw\_',
        'gw\x00_',
        'gw\n_',
        ' gw_',
      ]) {
        expect(() => CollectionConfig(tablePrefix: bad),
            throwsA(isA<ArgumentError>()),
            reason: 'prefix ${bad.runes.toList()} reaches CREATE TABLE by '
                'string interpolation; a quote or a semicolon in it is a '
                'statement boundary, not a table name');
      }
    });

    test('ordinary prefixes are accepted — the refusal is not a blanket', () {
      for (final fine in <String>['gw_', 'line7_', 'GW2_']) {
        expect(CollectionConfig(tablePrefix: fine).tablePrefix, fine,
            reason: 'a validation that rejects legitimate prefixes is a '
                'validation somebody will delete, taking the guarantee '
                'with it');
      }
    });
  });

  group('enabled with nowhere to write is refused', () {
    test('enabled: true with no endpoint throws at construction', () {
      expect(
          () => CollectionConfig(enabled: true),
          throwsA(isA<ArgumentError>()
              .having((e) => e.message.toString(), 'message',
                  contains('endpoint'))),
          reason: 'a gateway told to collect with nowhere to write must not '
              'start and quietly not collect — that is T-8b-04, a collection '
              'that is on and failing silently forever');
    });

    test('enabled: false with no endpoint constructs fine', () {
      expect(CollectionConfig(enabled: false).endpoint, isNull,
          reason: 'a disabled block with no endpoint is the ordinary parked '
              'state of a config somebody is preparing; refusing it would '
              'force people to invent placeholder endpoints');
    });
  });

  group('the writer names itself in pg_stat_activity', () {
    test('the application name is fixed, not free-form', () {
      expect(CollectionConfig().applicationNameFor(null),
          'centroidx-gateway-collector',
          reason: 'SELECT application_name, count(*) FROM pg_stat_activity '
              'GROUP BY 1 is how an engineer finds out who is writing; the '
              'app\'s collector shows up as tfc_dart '
              '(database.dart:109-121), and this string is how the gateway '
              'shows up as itself');
    });

    test('the publisherId distinguishes two gateways on one LAN', () {
      expect(CollectionConfig().applicationNameFor('svn-gateway-1'),
          'centroidx-gateway-collector-svn-gateway-1',
          reason: 'two gateways writing to one server must be tellable '
              'apart in pg_stat_activity — the same reason publisherId '
              'exists on the wire (08-02)');
    });
  });

  group('the queue caps come from tfc_dart, not re-spelled', () {
    test('the defaults are the shipped constants', () {
      final config = CollectionConfig();

      expect(config.maxQueuedRowsPerTable, kMaxQueuedRowsPerTable,
          reason: 'kMaxQueuedRowsPerTable carries a sizing argument '
              '(database.dart:242-261) — a copy of the number here would '
              'drift the day that argument changes it');
      expect(config.maxQueuedRowsTotal, kMaxQueuedRowsTotal,
          reason: 'same argument, process-wide (database.dart:263-277)');
    });
  });

  group('round-trips through JSON', () {
    test('a fully-spelled config survives the round trip, secrets included',
        () async {
      final config = CollectionConfig.fromJson(<String, dynamic>{
        'enabled': true,
        'table_prefix': 'line7_',
        'sole_writer': false,
        'endpoint': <String, dynamic>{
          'host': '10.104.29.100',
          'port': await freePort(),
          'database': 'hmi',
          'username': 'gateway',
          'password': 'not-a-real-password',
        },
        'ssl_mode': 'require',
        'max_pool_connections': 4,
        'connect_timeout_ms': 7000,
        'query_timeout_ms': 45000,
        'max_queued_rows_per_table': 5000,
        'max_queued_rows_total': 100000,
      });

      final again =
          CollectionConfig.fromJson(config.toJson(includeSecrets: true));

      expect(again, equals(config),
          reason: 'a config written back out must be the config that was '
              'read — a field lost in the round trip is a field the next '
              'restart silently unsets');
    });

    test('the defaults survive the round trip too', () {
      final config = CollectionConfig();

      expect(CollectionConfig.fromJson(config.toJson()), equals(config),
          reason: 'defaults are part of the config: a round trip that '
              'resets the prefix or the caps is a round trip that turns '
              'the guarantee off');
    });

    test('toJson omits the password unless asked — IN-05\'s idiom', () async {
      final config = CollectionConfig.fromJson(collectionJson(await freePort()));

      final rendered = config.toJson();
      final endpoint = rendered['endpoint'] as Map<String, dynamic>;

      expect(endpoint.containsKey('password'), isFalse,
          reason: 'the safe rendering is the default and the round trip '
              'opts in, so the dangerous direction is the one somebody has '
              'to type (UpstreamLinkConfig.toJson made this argument first)');
      expect(
          (config.toJson(includeSecrets: true)['endpoint']
              as Map<String, dynamic>)['password'],
          'not-a-real-password');
    });
  });

  group('the block hangs off GatewayConfig', () {
    test('a gateway file with a collection block parses it', () async {
      final json = gatewayJson()..['collection'] = collectionJson(await freePort());

      final config = GatewayConfig.fromJson(json);

      expect(config.collection, isNotNull);
      expect(config.collection!.enabled, isTrue);
      expect(config.collection!.endpoint!.host, '10.104.29.100',
          reason: 'the collection decision comes from the same file as '
              'everything else the gateway knows; a second config file '
              'would be a second thing to get out of step');
    });

    test('GatewayConfig.toJson round-trips the block and threads '
        'includeSecrets', () async {
      final json = gatewayJson()..['collection'] = collectionJson(await freePort());
      final config = GatewayConfig.fromJson(json);

      final safe = config.toJson();
      final full = config.toJson(includeSecrets: true);

      final safeEndpoint = ((safe['collection'] as Map<String, dynamic>)[
          'endpoint'] as Map<String, dynamic>);
      expect(safeEndpoint.containsKey('password'), isFalse,
          reason: 'includeSecrets is threaded to every part of the '
              'rendering that has one — a collection block that leaked the '
              'postgres password into a support bundle would undo IN-05');

      final again = GatewayConfig.fromJson(full);
      expect(again.collection, equals(config.collection));
    });

    test('a gateway file without the block still round-trips to no block',
        () {
      final config = GatewayConfig.fromJson(gatewayJson());

      final again = GatewayConfig.fromJson(config.toJson());

      expect(again.collection, isNull,
          reason: 'toJson must not invent an empty collection block: '
              'present-and-disabled and absent are different states, and '
              'only absent means "never told about a database"');
    });
  });
}
