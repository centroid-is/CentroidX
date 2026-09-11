/// Parity across this phase's three contract legs — the same **set** of checks,
/// not the same number.
///
/// ## Why a count is not enough, in one sentence
///
/// Two counts can agree while two sets differ: a leg that switched one
/// capability off and one gap on reports the same number and judges different
/// properties, and every accounting arm in this phase would stay green while
/// the two legs quietly stopped being comparable. The sabotage below is that
/// exact mutation — one leg's `readOnlyKey` dropped to null — and a count-only
/// comparison passes it.
///
/// So this file compares `Set<String>` of check names, never lengths alone, and
/// it computes each set with the kit's own `contractCases(...)` rather than
/// writing one down. A literal is a number somebody updates to match.
///
/// ## Where the flags come from: the legs' own source
///
/// The obvious way to write this file is to re-declare each leg's capability
/// flags here and compare the results. That file would be green forever: it
/// would be comparing two copies of its own opinion, and a flag changed in a
/// leg would not move it. So each leg's flags are read out of **the leg's own
/// source file**, the way `backend_composition_test.dart` reads `bin/main.dart`
/// (13-10) — a structural arm belongs in the file whose change should break it,
/// and the change that must break this one is an edit to a leg.
///
/// Comments are stripped before the scan for the reason 13-10's helpers record:
/// every one of these files argues about its flags in prose, and a check a
/// comment can satisfy is a check that has already stopped working.
///
/// ## The three legs, and the one difference between them
///
/// | Leg | File | Data services |
/// |---|---|---|
/// | 6, in memory | `test/core/relay/backend_contract_test.dart` | off |
/// | 7, over TimescaleDB | `test/integration/backend_contract_db_test.dart` | on |
/// | 8, over a WebSocket | `test/core/relay/backend_ws_contract_test.dart` | off |
///
/// Legs 6 and 8 must judge the **identical** set — that is criterion 1's
/// parity claim, and it is what makes "the transport hides no framing, ordering
/// or lifetime difference" mean something. Leg 7 differs from them by exactly
/// the eight `dataServicesChecks`, by name, and the three together must cover
/// the whole roster so that no check in `allContractChecks` is judged by
/// nobody.
///
/// ## What this file cannot claim, and says so out loud
///
/// Leg 7 is **registered and unexecuted**: there is no Docker daemon on this
/// machine (13-09 Finding 1). Its set is therefore a claim about what it *would*
/// judge, and the printed summary says `0 ran` rather than letting the
/// reconciliation imply otherwise. The eight data-services checks are
/// consequently judged **in memory and never over the wire** — recorded here as
/// the phase's own finding rather than left for a reader to derive from three
/// files.
@TestOn('vm')
@Tags(['contract'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';
import 'package:tfc_stateman_contract/testing/runner_budget.dart';

/// The five flags `contractCases` is a function of, as one leg declares them.
typedef LegFlags = ({
  bool supportsWrites,
  String? readOnlyKey,
  bool supportsBrowse,
  bool supportsDataServices,
  bool supportsHoldToRun,
});

/// One leg: where it lives, and what it says about itself.
final class Leg {
  const Leg(this.name, this.path, {required this.ran, required this.ranNote});

  /// How the phase's prose names it, so a failure here and the SUMMARY agree.
  final String name;

  /// The file whose `runStateManContract(...)` call is the source of truth.
  final String path;

  /// How many of its registered cases actually started, or null if unknown.
  ///
  /// Not measured here — a leg's own accounting arms measure it, and this file
  /// must not re-run three suites to print a number. It is carried so the
  /// summary cannot quietly imply that a leg which has never executed did.
  final int? ran;

  final String ranNote;
}

const _legs = <Leg>[
  Leg('leg 6 (in memory)', 'test/core/relay/backend_contract_test.dart',
      ran: 43,
      ranNote: 'asserted equal to registered by its own two accounting arms'),
  Leg('leg 7 (over TimescaleDB)',
      'test/integration/backend_contract_db_test.dart',
      ran: 0,
      ranNote: 'REGISTERED AND NEVER EXECUTED — no Docker daemon on this '
          'machine (13-09 Finding 1). Its set is what it would judge, not '
          'what it has'),
  Leg('leg 8 (over a real WebSocket)',
      'test/core/relay/backend_ws_contract_test.dart',
      ran: 43,
      ranNote: 'asserted equal to registered by its own two accounting arms'),
];

/// [source] with `//` line comments and `///` docs removed.
///
/// Line comments only, and that is enough: no flag in any of the three legs is
/// written inside a `/* */` block, and a stripper that tried to handle both
/// would need to know about strings to avoid eating a `//` inside one.
String _stripComments(String source) => source
    .split('\n')
    .map((line) {
      final at = line.indexOf('//');
      return at < 0 ? line : line.substring(0, at);
    })
    .join('\n');

/// The `runStateManContract(...)` argument list of the file at [path].
///
/// From the call to its matching close paren, by counting depth — a regex
/// would stop at the first `)` inside `const <String>{}` or a lambda.
String _contractCall(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue,
      reason: '$path does not exist, so this sweep is comparing two legs and '
          'calling it three. A leg that moved must be re-pointed here, not '
          'dropped: the whole claim of this file is that every check in the '
          'roster is judged by somebody');
  final source = _stripComments(file.readAsStringSync());
  final start = source.indexOf('runStateManContract(');
  expect(start, greaterThanOrEqualTo(0),
      reason: '$path no longer calls runStateManContract. Either it stopped '
          'being a contract leg — in which case the roster it was covering is '
          'now covered by nobody — or the umbrella was renamed and this sweep '
          'is reading a file that no longer says anything');
  var depth = 0;
  for (var i = start + 'runStateManContract'.length; i < source.length; i++) {
    if (source[i] == '(') depth++;
    if (source[i] == ')') {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  fail('$path has an unbalanced runStateManContract( call');
}

/// Whether `name:` is passed `true` in [call]; absent means the kit's default.
bool _boolFlag(String call, String name, {required bool orDefault}) {
  final match =
      RegExp('$name:\\s*(true|false)\\b').firstMatch(call);
  if (match == null) return orDefault;
  return match.group(1) == 'true';
}

/// The `readOnlyKey:` argument, resolved to the string it names or to null.
///
/// The legs all pass the shared constant rather than a literal — which is the
/// point of the constant — so this resolves the one spelling that appears and
/// refuses anything else rather than guessing. A leg that started passing its
/// own string would be the very drift this sweep exists to catch, and it must
/// arrive as a failure here and not as a silent `null`.
String? _readOnlyKeyFlag(String call) {
  final match = RegExp(r'readOnlyKey:\s*([A-Za-z0-9_.]+|null)').firstMatch(call);
  if (match == null) return null; // not passed: the kit drops the case
  final spelling = match.group(1)!;
  if (spelling == 'null') return null;
  if (spelling == 'contractReadOnlyKey') return contractReadOnlyKeySpelling;
  fail('a leg passes readOnlyKey: $spelling, which is neither the shared '
      'constant nor null. Every leg naming the same key is what makes this '
      'sweep a comparison rather than a coincidence — a leg with its own '
      'string judges checkReadOnlyKeyIsRejectedNotThrown against a different '
      'device promise, and the sets would agree while the properties did not');
}

/// The one read-only key string, repeated here on purpose.
///
/// `harnessed_backend_state_man.dart` declares `contractReadOnlyKey` and every
/// leg passes it; this sweep reads the legs' SOURCE, so it needs the value the
/// name resolves to. Importing the constant would be the right thing if this
/// file were resolving a symbol — it is resolving a spelling, and the arm above
/// refuses any spelling but that one, which is what keeps the two in step.
const contractReadOnlyKeySpelling = 'ST301.CN21.SEN01.temp';

LegFlags _flagsOf(Leg leg) {
  final call = _contractCall(leg.path);
  return (
    supportsWrites: _boolFlag(call, 'supportsWrites', orDefault: true),
    readOnlyKey: _readOnlyKeyFlag(call),
    supportsBrowse: _boolFlag(call, 'supportsBrowse', orDefault: true),
    supportsDataServices:
        _boolFlag(call, 'supportsDataServices', orDefault: true),
    supportsHoldToRun: _boolFlag(call, 'supportsHoldToRun', orDefault: true),
  );
}

/// What [flags] entitle a leg to — computed by the kit, never written down.
Set<String> _casesFor(LegFlags flags) => contractCases(
      supportsWrites: flags.supportsWrites,
      readOnlyKey: flags.readOnlyKey,
      supportsBrowse: flags.supportsBrowse,
      supportsDataServices: flags.supportsDataServices,
      supportsHoldToRun: flags.supportsHoldToRun,
    ).keys.toSet();

void main() {
  useRunnerBudgets();

  late Map<String, Set<String>> judged;
  late Map<String, LegFlags> flags;

  setUpAll(() {
    flags = {for (final leg in _legs) leg.name: _flagsOf(leg)};
    judged = {for (final leg in _legs) leg.name: _casesFor(flags[leg.name]!)};
  });

  final inMemory = _legs[0].name;
  final db = _legs[1].name;
  final ws = _legs[2].name;

  group('the WebSocket leg judges the same checks as the in-memory one', () {
    test('the two sets are equal, name for name', () {
      expect(judged[ws], judged[inMemory],
          reason: 'the WebSocket leg and the in-memory leg judge different '
              'properties. Two legs whose counts agree can still differ by a '
              'capability switched off against a key dropped, and then every '
              'accounting arm in the phase stays green while the pair stops '
              'being a comparison at all — which is the only thing running the '
              'suite twice buys. Whatever moved, the two legs must be brought '
              'back into step rather than the difference tolerated');
    });

    test('neither leg has a check the other has not', () {
      final onlyWs = judged[ws]!.difference(judged[inMemory]!);
      final onlyMemory = judged[inMemory]!.difference(judged[ws]!);
      expect(onlyWs, isEmpty,
          reason: 'the WebSocket leg judges ${onlyWs.length} check(s) the '
              'in-memory leg does not, so a property is being asserted over '
              'the wire and nowhere else; a failure there could be the '
              'transport or the adapter and nothing would say which');
      expect(onlyMemory, isEmpty,
          reason: 'the in-memory leg judges ${onlyMemory.length} check(s) the '
              'WebSocket leg does not, so those properties are unjudged over '
              'the transport every panel in the plant connects on. That is '
              'the shape criterion 1 asks about, and it is exactly what a '
              'count-only comparison cannot see');
    });

    test('both legs name the same read-only key', () {
      expect(flags[ws]!.readOnlyKey, flags[inMemory]!.readOnlyKey,
          reason: 'the read-only key is a statement about what the DEVICE '
              'refuses, and it is the one flag whose value silently removes a '
              'case instead of a group: a leg that names none drops '
              'checkReadOnlyKeyIsRejectedNotThrown and reports one fewer '
              'check, which reads as an off-by-one and gets the number '
              'updated');
      expect(flags[ws]!.readOnlyKey, isNotNull,
          reason: 'no leg names a read-only key, so the case that proves a '
              'refusal comes back as a WriteRejected instead of a throw is '
              'unjudged by all three legs at once — and the arithmetic below '
              'would reconcile perfectly, because the roster it reconciles '
              'against is computed from the same flags');
    });
  });

  group('the db leg differs by exactly one named group', () {
    test('it judges everything the in-memory leg does, and more', () {
      expect(judged[db]!.containsAll(judged[inMemory]!), isTrue,
          reason: 'the db leg is meant to be ADDITIVE — the same suite over '
              'the same class with the three data services composed in. A '
              'check the offline leg judges and it does not is a property that '
              'stops being judged the moment somebody runs only the db lane');
    });

    test('the difference is the data-services group, by name', () {
      final extra = judged[db]!.difference(judged[inMemory]!);
      expect(extra, dataServicesChecks.keys.toSet(),
          reason: 'the db leg differs from the offline legs by cases that are '
              'not the ones supportsDataServices owns. That is a second '
              'capability moving inside the first one\'s arithmetic, which is '
              'the failure this whole file exists to catch');
    });
  });

  group('the three legs together cover the roster', () {
    test('every non-access check is judged by at least one leg, and the '
        'access family is the one named orphan set', () {
      final covered = <String>{
        for (final leg in _legs) ...judged[leg.name]!,
      };
      final orphaned = allContractChecks.keys.toSet().difference(covered);
      // The access family (17-05, 51 -> 78 on the kit roster) is judged by
      // NO backend leg yet — pinned here as a NAMED SET rather than lowered
      // to a count, so a 28th unjudged check still reddens this arm.
      // access checks — 17-06/17-08 opt this leg in; 17-14 empties the gap.
      expect(orphaned, accessChecks.keys.toSet(),
          reason: 'a check outside the access family is judged by no leg in '
              'this phase at all. A check nobody runs is a property nobody '
              'has, and the per-leg accounting arms cannot see it: each of '
              'them reconciles against its own flags, so a check that fell '
              'out of every leg reconciles everywhere');
      expect(covered.length + accessChecks.length, allContractChecks.length,
          reason: 'the union of the three legs is ${covered.length} against a '
              'roster of ${allContractChecks.length}, and the named access '
              'gap must account for every check the union is short of');
    });

    test('the offline legs plus the named db-lane and access gaps reconcile '
        'to the roster', () {
      final gap = allContractChecks.keys.toSet().difference(judged[ws]!);
      // access checks — 17-06/17-08 opt this leg in; 17-14 empties the gap.
      expect(gap, {...dataServicesChecks.keys, ...accessChecks.keys},
          reason: 'what the WebSocket leg is short of is not the groups its '
              'own file names. The gap has to be pinned by name and not by '
              'size, or a third capability can go false inside the first '
              'two\'s arithmetic');
      expect(judged[ws]!.length + gap.length, allContractChecks.length,
          reason: 'judged plus the named gap must reconcile to the whole '
              'roster; if it does not, a check exists that is neither run nor '
              'accounted for');
    });

    test('the summary a reader of the phase verification looks at first', () {
      final buffer = StringBuffer()
        ..writeln('Phase 13 contract legs — what each judges, and what it ran:');
      for (final leg in _legs) {
        final set = judged[leg.name]!;
        final missing = allContractChecks.keys.toSet().difference(set);
        final group = missing.isEmpty
            ? 'nothing — it judges the whole roster'
            : (missing.setEquals(
                    {...dataServicesChecks.keys, ...accessChecks.keys})
                ? 'the ${dataServicesChecks.length} data-services checks '
                    '(supportsDataServices: false) and the '
                    '${accessChecks.length} access checks (17-06/17-08 opt '
                    'this leg in; 17-14 empties the gap)'
                : missing.setEquals(accessChecks.keys.toSet())
                    ? 'the ${missing.length} access checks (17-06/17-08 opt '
                        'this leg in; 17-14 empties the gap)'
                    : '${missing.length} check(s), NOT a named gap group: '
                        '${missing.toList()..sort()}');
        buffer
          ..writeln('  ${leg.name}:')
          ..writeln('    file:       ${leg.path}')
          ..writeln('    registered: ${set.length} of '
              '${allContractChecks.length}')
          ..writeln('    ran:        ${leg.ran} — ${leg.ranNote}')
          ..writeln('    unjudged:   $group');
      }
      buffer
        ..writeln('  parity: leg 6 and leg 8 judge the SAME SET '
            '(${judged[inMemory]!.length} checks), so the WebSocket carries '
            'every property the in-process call does.')
        ..writeln('  FINDING: the 8 data-services checks are judged only by '
            'leg 7, which has never executed. They are therefore judged '
            'NEITHER against a real TimescaleDB NOR over the wire. See '
            '13-11-SUMMARY and 13-09 Finding 1.')
        ..writeln('  DEFERRED: criterion 3, the rig protocol probes against '
            'centroidx-backend on 10.50.10.11, is human_needed and is not '
            'covered by any leg above.');
      // ignore: avoid_print
      print(buffer.toString());
    });
  });
}

extension on Set<String> {
  /// `this.` is not decoration: inside an extension body a bare
  /// `containsAll(...)` resolves to `package:matcher`'s top-level matcher of
  /// the same name, not to `Set.containsAll`, and the result is a `Matcher`
  /// where a `bool` was wanted.
  bool setEquals(Set<String> other) =>
      length == other.length && this.containsAll(other);
}
