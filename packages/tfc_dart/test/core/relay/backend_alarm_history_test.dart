/// `AlarmHistoryWriter` without a database, and without a plant.
///
/// Two properties live here rather than in the Postgres lane, because neither
/// of them is about what the server does:
///
///  1. **A backend with no database refuses by name.** `alarm.dart:472` is
///     `if (preferences.database == null) return;` — a silent no-op on the
///     persistence path, which is exactly the silence-as-success Phase 13 spent
///     a phase removing (P-12). A station composed without a database must not
///     evaluate alarms into a void and report success; it must say which member
///     was called, which collaborator is missing, and what to change.
///  2. **No value is ever interpolated into a statement.** Operator-authored
///     alarm titles and descriptions reach SQL (T-14-21), and the strongest
///     available statement of "they are bound" is that the statements are
///     compile-time constants — a `const` string cannot carry a runtime value,
///     and the language is the proof. The Postgres lane's arm 11 then measures
///     the other half: an injection payload round-tripping into the row intact
///     with the table still standing.
///
/// Everything that needs a server is in
/// `test/integration/alarm_history_edges_test.dart`, tagged `db`.
library;

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/relay/backend_alarm_history.dart';

/// The three statements, taken in a `const` context.
///
/// This list is half of arm 11 and it is checked by the compiler rather than by
/// an expectation: a statement that stopped being a compile-time constant —
/// because somebody interpolated an alarm title into it — would not fail this
/// test, it would fail to compile it. What is left to assert at runtime is that
/// the statements really are parameterised, because a constant statement with
/// no placeholders is one that forgot to pass its values at all.
const List<String> constantStatements = <String>[
  AlarmHistoryWriter.insertStatement,
  AlarmHistoryWriter.closeStatement,
  AlarmHistoryWriter.openRowsStatement,
];

/// The payload every injection arm in this phase uses.
const String injectionPayload = "'); DROP TABLE alarm_history; --";

void main() {
  group('AlarmHistoryWriter with no database', () {
    late AlarmHistoryWriter writer;
    late List<String> logs;

    setUp(() {
      logs = <String>[];
      writer = AlarmHistoryWriter(
        null,
        logger: Logger(
          filter: ProductionFilter(),
          level: Level.all,
          printer: SimplePrinter(colors: false),
          output: _RecordingOutput(logs),
        ),
      );
    });

    // -------------------------------------------------------------- arm 10 --
    test(
        'arm 10: every write refuses by name — the member, the missing '
        'collaborator, and what to change', () async {
      // Construction itself must NOT throw. The backend may boot before the
      // plant database is reachable, and a writer that refused to exist would
      // take the whole alarm engine down with it — a worse outcome than a gap
      // in the history (T-14-24).
      expect(writer.hasDatabase, isFalse);

      final attempts = <String, Future<Object?> Function()>{
        'openActivation': () => writer.openActivation(
              alarm: _alarm('CN04.MOT01'),
              ruleIndex: 0,
              rule: _alarm('CN04.MOT01').rules.first,
              expression: 'a > 10',
              stamp: _stamp,
            ),
        'closeActivation': () => writer
            .closeActivation(
              id: 1,
              stamp: _stamp,
              reason: AlarmHistoryWriter.reasonCleared,
            )
            .then((_) => null),
        'loadOpenRows': () => writer.loadOpenRows(),
      };

      for (final entry in attempts.entries) {
        await expectLater(
          entry.value(),
          throwsA(
            isA<UnsupportedError>()
                .having((e) => e.message, 'message',
                    contains('AlarmHistoryWriter.${entry.key}'))
                .having((e) => e.message, 'message', contains('Database'))
                .having((e) => e.message, 'message', contains('alarm_history')),
          ),
          reason: '${entry.key} returned quietly instead of refusing. '
              '`alarm.dart:472`\'s `if (preferences.database == null) return;` '
              'is P-12: a persistence path that reports success while writing '
              'nothing. An operator reading a green backend and an empty '
              'alarm_history has no way to tell which of the two is lying.',
        );
      }
    });

    test(
        'arm 10b: the refusal is a throw, not a log — nothing is written to '
        'the log INSTEAD of failing', () async {
      await expectLater(writer.loadOpenRows(), throwsA(isA<UnsupportedError>()));
      expect(
        logs.where((l) => l.contains('alarm_history')),
        isEmpty,
        reason: 'a warning in place of a throw is the same silence with a '
            'paper trail nobody reads',
      );
    });
  });

  group('AlarmHistoryWriter statements', () {
    // -------------------------------------------------------------- arm 11 --
    test(
        'arm 11: every value is bound — the statements are compile-time '
        'constants and carry positional placeholders', () {
      for (final statement in constantStatements) {
        expect(statement, isNot(contains(injectionPayload)));
        expect(statement, isNot(contains(r'${')),
            reason: 'a Dart interpolation in a SQL statement is the T-14-21 '
                'hole; every value goes through Variable.*');
      }

      // The insert carries one placeholder per bound value, and the count is
      // asserted so that a value quietly dropped from the bind list — or
      // quietly inlined into the statement — is a red arm rather than a row
      // with a missing column.
      expect(_placeholders(AlarmHistoryWriter.insertStatement),
          <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      expect(_placeholders(AlarmHistoryWriter.closeStatement), <int>[1, 2, 3]);

      // `deactivated_at` is a real SQL NULL on the activation insert, spelled
      // as a literal so there is no bind that could ever carry `''`. 14-01's
      // arm 6 measured `''::timestamp` raising `invalid input syntax for type
      // timestamp` against a real server; this is the shape that cannot.
      expect(AlarmHistoryWriter.insertStatement, contains('NULL'));
      expect(AlarmHistoryWriter.insertStatement, isNot(contains("''")));

      // The open-row query is direct, and takes no arguments at all: every
      // open row, including the ones whose alarm definition has been deleted.
      expect(_placeholders(AlarmHistoryWriter.openRowsStatement), isEmpty);
      expect(AlarmHistoryWriter.openRowsStatement,
          contains('deactivated_at IS NULL'));
    });

    test(
        'arm 11b: the five deactivation reasons are spelled once — D-4\'s '
        'four, plus the input-recovery bound', () {
      expect(AlarmHistoryWriter.reasons, <String>{
        'cleared',
        'acknowledged',
        'inferred_restart',
        'inferred_config_change',
        'inferred_input_recovery',
      });
      // A stop analysis has to be able to tell a measured clear from a
      // reconstructed one; two spellings of one reason would make that
      // impossible to query for and nobody would notice until the numbers were
      // already wrong. `inferred_input_recovery` joined the roster on the SVN
      // rig's cooler-alarm evidence (2026-09-08): a clear whose verdict is the
      // FIRST after a D-3 suspension is bounded by when the sensor returned,
      // not by when the plant recovered, and writing it as `cleared` would
      // shorten a stop in the direction nobody audits — while writing it as
      // `inferred_restart` would report a sensor outage as a backend restart.
      expect(AlarmHistoryWriter.reasons, hasLength(5));
    });
  });
}

// ------------------------------------------------------------------ fixtures

final AlarmStamp _stamp = AlarmStamp(
  at: DateTime.utc(2026, 9, 6, 12),
  source: AlarmTsSource.plant,
);

AlarmConfig _alarm(String uid) => AlarmConfig(
      uid: uid,
      title: 'A title',
      description: 'A description',
      rules: [
        AlarmRule(
          level: AlarmLevel.error,
          expression: ExpressionConfig(value: Expression(formula: 'a > 10')),
          acknowledgeRequired: false,
        ),
      ],
    );

/// The `$n` placeholders in [sql], in the order they appear.
List<int> _placeholders(String sql) => <int>[
      for (final m in RegExp(r'\$(\d+)').allMatches(sql))
        int.parse(m.group(1)!),
    ];

final class _RecordingOutput extends LogOutput {
  _RecordingOutput(this.lines);

  final List<String> lines;

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}
