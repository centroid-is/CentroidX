/// 18-06's structural pin: one definition of each helper Phase 18 extracted,
/// repo-wide, enforced by reading source.
///
/// **Why a scan and not a suite.** A behavioural suite cannot see a re-added
/// private duplicate: 18-06 demonstrated it, by re-adding the exact
/// `_redactUpstreamError` that 18-02 deleted and running `tfc_dart`'s whole
/// offline lane — green, every test, because the copy behaves identically to
/// the shared function it shadows. Phase 14 hit the same shape twice
/// (mutations that compiled clean and turned nothing red). Only a scan can see
/// a second copy that behaves like the first, so this file walks every
/// `packages/*/lib/**.dart` in the repository and counts.
///
/// **The rule every needle follows (18-BASELINE F6):** a pattern derived from
/// the broken form cannot see the fixed form. Every sweep here matches the
/// helper's *identity* — a declaration idiom, a call signature, an output
/// vocabulary — never the shape of a bug, with one deliberate exception
/// (`bitwiseUlidDecodeLines`, whose entire job is to forbid the bug shape).
/// Each sweep's doc states what it is blind to, because a bound the sweep
/// cannot see is a bound the next reader cannot see either.
///
/// **The sweeps are line-based and deliberately literal**, in
/// `freeze_test.dart`'s style and for its stated reason. Full-line comments
/// are skipped (a doc paragraph explaining a forbidden idiom must not trip
/// the sweep that forbids it — 18-01 deviation 3 hit exactly that); trailing
/// comments are NOT stripped, which is a known, accepted bluntness.
///
/// **Anti-vacuity comes first.** An empty walk satisfies every "no more than
/// one" assertion below, so the walk's scope is proven non-empty, every needle
/// is proven to still exist where it is declared, and every sweep is proven to
/// bite a planted offender — before anything is counted.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

// ---------------------------------------------------------------- the scope
//
// Relative to this package's root, which is where `dart test` runs from.
// `..` is the repository's `packages/` directory, so the walk covers every
// package's `lib/` tree — a copy re-added in ANY package is caught, including
// packages Phase 18 never touched.

final Directory packagesRoot = Directory('..');

/// Packages whose `lib/` must be inside the walk, by name. If any of these is
/// missing the walk is reading the wrong directory and every count below is a
/// count of nothing.
const List<String> mustBeWalked = <String>[
  'tfc_relay_protocol',
  'tfc_dart',
  'tfc_relay_local',
  'tfc_relay_server',
  'tfc_relay_client',
  'tfc_stateman_contract',
];

/// The floor on how many `.dart` files the walk must find. 348 at the time of
/// writing; the floor is far below that so ordinary growth and pruning never
/// touch it, while a walk pointed at nothing (or at one package) fails loudly.
const int walkedFileFloor = 200;

// ------------------------------------------------------------- the allowlist

/// The ONE file allowed to carry its own copies of extracted helpers, and why.
///
/// `FakeStateMan` is the contract suite's reference implementation. A
/// reference that imports the thing it is a reference for cannot catch a bug
/// in that thing — 18-01 task 3's ruling — so it keeps, deliberately and
/// independently:
///
///  * its own ULID decoder, `referenceUlidMs` (18-01; policed by the
///    agreement arm in `ulid_reference_agreement_test.dart`, which pins both
///    decoders against expected milliseconds, not merely against each other);
///  * its own sweep cadence, `_sweepInterval` with an inlined 5 ms floor
///    (18-03 finding F-A: recorded, deliberately not repointed);
///  * its own staleness chain (18-03 F-A) and its own inline
///    positive-evidence predicate (18-04's "site 3");
///  * its own live-hold set (18-05's census, site 5).
///
/// The independence is allowed to exist. It is NOT allowed to be wrong: the
/// bitwise-decode sweep below refuses the `<< 5` bug shape even here.
///
/// **Exactly one path, ever.** The allowlist-integrity arm pins the length AND
/// resolves the path against the real walk, so widening this to a glob — or
/// adding a second entry — fails before any census runs.
const Map<String, String> referenceCopyAllowList = <String, String>{
  'tfc_stateman_contract/lib/testing/fake_state_man.dart':
      "18-01 task 3: the contract suite's reference implementation stays "
          'independent — a reference that imports the thing it is a reference '
          'for is a weaker reference. Checked by an agreement arm, not trusted.',
};

/// The single allowlisted path, as a suffix every sweep matches against.
final String fakeStateManSuffix = referenceCopyAllowList.keys.single;

// ---------------------------------------------- the pinned end-state numbers
//
// Each number is the CORRECTED census from the plan's own SUMMARY, not the
// plan's original guess — every plan in this phase found its own census blind
// at least once (18-BASELINE F6, 18-01's `_mintedAtOf`, 18-02's renamed-copy
// blindness, 18-03 F-A, 18-04 F2, 18-05 F2). A number here with no argument
// beside it is a bug in this file.

/// ULID timestamp decoders, by declaration idiom: the shared `ulidMs`
/// (`src/ulid.dart`, 18-01) plus the fake's `referenceUlidMs`. NOT 1 — a
/// census asserting 1 would invite deleting the reference copy and the
/// agreement arm that polices it (18-01's own summary says so).
const int declaredUlidDecoderDeclarations = 2;

/// Crockford base-32 accumulations (`* 32 + digit` / `* _base32 + digit`):
/// the same two files, by behaviour instead of by name — the polarity that
/// caught `_mintedAtOf` when the name-based census could not.
const int declaredCrockfordAccumulations = 2;

/// `redactUpstreamError` declarations: one, in `src/redact.dart` (18-02).
const int declaredRedactDeclarations = 1;

/// `redactUpstreamError` call sites — 3 in `tfc_dart`, 7 in `tfc_relay_local`.
/// **This number must not FALL**: a falling call-site count is deleted
/// behaviour, not a successful extraction (18-02's headline rule). It moves
/// only when a caller is deliberately added or removed.
const int declaredRedactCallSites = 10;

/// `maxRedactedErrorLength` declarations: one, in `src/redact.dart`.
const int declaredRedactCapDeclarations = 1;

/// `staleAfter ~/ 4` cadence bodies: the kernel (`src/freshness.dart:117`,
/// 18-03) plus the fake's deliberate copy (18-03 F-A). NOT 1, for the same
/// reason as the ULID count.
const int declaredCadenceBodies = 2;

/// Named minimum-interval constants carrying the 5 ms literal: one, in
/// `src/freshness.dart`. The two delegates (`backend_freshness.dart`,
/// `freshness_sweep.dart`) alias the shared name and carry no literal — that
/// is what makes them delegates rather than copies.
const int declaredMinimumIntervalLiterals = 1;

/// `< staleAfter` deadline comparisons: the kernel (`isStaleNow`) plus the
/// fake's `DateTime`-spelled chain (18-03 F-A). Both sweep objects route
/// through the kernel and carry no comparison of their own.
const int declaredStaleDeadlineComparisons = 2;

/// Classes named `*WriteOutcomeLog`: one, in `src/write_outcome_log.dart`
/// (18-04). NOTE, from 18-04's own summary: "2 → 1" does NOT mean one
/// implementation of the four-piece rule — see the next constant.
const int declaredWriteOutcomeLogClasses = 1;

/// Implementations of the positive-evidence rule, by behaviour (the
/// `mintedAt(Ms)` vs `started(At)Ms` comparison, both polarities): THREE, two
/// of them on purpose — the shared class, `tfc_relay_local`'s five-answer
/// plant-side log (stays by 18-04 task 3's ruling), and the fake's inline
/// predicate (18-04 site 3). A fourth is a new copy nobody ruled on.
const int declaredPositiveEvidenceRules = 3;

/// Live-hold collections, by the WIDENED pattern (18-05 F2: the obvious
/// `Set<HoldHandle>` spelling sees 3 of these 6, because four are written with
/// inferred types). SIX, not one — 18-05's census correction: the shared
/// registry plus five deliberate others, each named below. A seventh is a new
/// registry.
const int declaredLiveHoldCollections = 6;

/// Where the six live-hold collections live, and why each is deliberate
/// (18-05's census table, verbatim in spirit). Suffix-matched against the
/// walk. Sites keyed by tag are keyed by tag ON PURPOSE — one-session-one-
/// hold-per-key (05-REVIEW WR-02) — and merging them into the shared registry
/// would change a session-scoping rule, not remove duplication.
const Map<String, String> liveHoldCollectionSites = <String, String>{
  'tfc_relay_protocol/lib/src/hold_registry.dart':
      '18-05: the shared registry — the one this phase extracted',
  'tfc_relay_client/lib/src/remote_state_man.dart':
      'per-session, keyed by tag on purpose (WR-02); releases on disconnect',
  'tfc_relay_server/lib/src/value_handlers.dart':
      'per-session, keyed by tag on purpose (WR-02); refuses a second engage',
  'tfc_stateman_contract/lib/src/channel/channel_state_man.dart':
      'the channel fake\'s own set — contract-kit, out of 18-05\'s scope',
  'tfc_stateman_contract/lib/testing/fake_state_man.dart':
      'the reference implementation keeps its own (18-01\'s rule)',
  'tfc_stateman_contract/lib/testing/broken_hold.dart':
      'deliberately broken variants — it exists to FAIL; never merge it',
};

/// The two packages whose local hold registries 18-05 deleted. Zero live-hold
/// collections may exist in either — one reappearing is the phase silently
/// undoing itself.
const List<String> holdRegistryDeletionPackages = <String>[
  'tfc_dart',
  'tfc_relay_local',
];

void main() {
  final walk = libDartFiles(packagesRoot);

  group('the walk is looking at something', () {
    test('the packages root exists and holds the named packages', () {
      expect(packagesRoot.existsSync(), isTrue,
          reason: 'no directory at "${packagesRoot.path}" (resolved from '
              '${Directory.current.path}), so every count in this file is a '
              'count over nothing and every "no more than one" assertion is '
              'vacuously green — the exact failure mode this file exists to '
              'refuse');
      for (final name in mustBeWalked) {
        expect(Directory('${packagesRoot.path}/$name/lib').existsSync(), isTrue,
            reason: 'packages/$name/lib is missing from the walk, so a copy '
                're-added there would be invisible');
      }
    });

    test('the walk finds at least $walkedFileFloor dart files', () {
      expect(walk.length, greaterThanOrEqualTo(walkedFileFloor),
          reason: 'only ${walk.length} files walked (348 at the time of '
              'writing). A walk this small is reading the wrong directory');
    });

    test('every needle still exists where it is declared', () {
      // A sweep hunting a string the repository no longer spells passes for
      // ever (freeze_test.dart's rule). Each helper file is read directly.
      const needles = <String, String>{
        'lib/src/ulid.dart': 'int? ulidMs(',
        'lib/src/redact.dart': 'String? redactUpstreamError(',
        'lib/src/freshness.dart': 'bool isStaleNow(',
        'lib/src/write_outcome_log.dart': 'final class WriteOutcomeLog',
        'lib/src/hold_registry.dart': 'class HoldRegistry',
      };
      needles.forEach((path, needle) {
        final file = File(path);
        expect(file.existsSync(), isTrue,
            reason: '$path is gone. If a later plan moved it, this scan must '
                'move with it or it decays into a scan of nothing '
                "(18-03 F-B / 18-05's own warning about path-reading pins)");
        expect(file.readAsStringSync(), contains(needle),
            reason: '$path no longer contains "$needle", so the sweeps below '
                'are hunting an identity this repository does not declare');
      });
    });

    test('the allowlist is exactly one path and it resolves to one real file',
        () {
      expect(referenceCopyAllowList, hasLength(1),
          reason: 'the reference-copy allowlist is EXACTLY one path — '
              'fake_state_man.dart, with 18-01 task 3\'s argument beside it. '
              'A second entry needs a ruling of its own, written where this '
              'message is');
      final resolved =
          // `/`-normalised: the allowlist keys are written with forward
          // slashes, and `File.path` uses the platform separator, so this
          // `endsWith` matched nothing on Windows and the arm below reddened
          // about an allowlisted path that was present all along.
          walk
              .where((f) =>
                  f.path.replaceAll(r'\', '/').endsWith(fakeStateManSuffix))
              .toList();
      expect(resolved, hasLength(1),
          reason: 'the allowlisted path "$fakeStateManSuffix" matched '
              '${resolved.length} files in the walk. Zero means the entry is '
              'stale (or was widened to a glob, which this arm exists to '
              'refuse); more than one means it stopped naming a single file');
      expect(resolved.single.readAsStringSync(), contains('referenceUlidMs'),
          reason: 'the allowlisted file no longer contains the reference '
              'decoder it was exempted for — a standing exemption for a file '
              'nobody is watching. Delete the entry or say why it stays');
    });

    test('every sweep reports zero over an empty directory', () {
      final empty = Directory.systemTemp.createTempSync('no-dup-empty-');
      addTearDown(() => empty.deleteSync(recursive: true));
      final none = dartFilesUnder(empty);
      expect(none, isEmpty);
      expect(ulidDecoderDeclarationLines(none), isEmpty);
      expect(crockfordAccumulationLines(none), isEmpty);
      expect(bitwiseUlidDecodeLines(none), isEmpty);
      expect(redactDeclarationLines(none), isEmpty);
      expect(redactVocabularyLines(none), isEmpty);
      expect(redactCallSiteLines(none), isEmpty);
      expect(redactCapDeclarationLines(none), isEmpty);
      expect(cadenceBodyLines(none), isEmpty);
      expect(minimumIntervalLiteralLines(none), isEmpty);
      expect(staleDeadlineComparisonLines(none), isEmpty);
      expect(writeOutcomeLogClassLines(none), isEmpty);
      expect(positiveEvidenceRuleLines(none), isEmpty);
      expect(liveHoldCollectionLines(none), isEmpty,
          reason: 'a sweep that reports an occurrence over an empty directory '
              'is inventing rather than measuring');
    });

    test('every sweep bites a planted offender', () {
      final planted = _plant('offenders.dart', '''
int? _ulidMs(String cmd) => null;
int? _mintedAtOf(String cmd) => null;
void a() { var ms = 0; const digit = 1; ms = ms * 32 + digit; }
void b() { var ms = 0; const digit = 1; ms = (ms << 5) | digit; }
String? _redactUpstreamError(String? raw) => raw;
void c(Object s) { s.toString().replaceAll('x', '<endpoint>'); }
void d(String? e) { _redactUpstreamError(e); }
const int _maxRedactedErrorLength = 200;
Duration e(Duration staleAfter) => staleAfter ~/ 4;
const Duration minimumInterval = Duration(milliseconds: 5);
bool f(int nowMs, int arrived, Duration staleAfter) =>
    !(nowMs - arrived < staleAfter.inMilliseconds);
final class ShadowWriteOutcomeLog {}
bool g(int mintedAt, int _startedMs) => mintedAt < _startedMs;
class HoldHandle {}
final _liveHolds = <HoldHandle>{};
''');
      expect(ulidDecoderDeclarationLines(planted), hasLength(2),
          reason: 'the declaration sweep must see BOTH the `_ulidMs` and the '
              '`_mintedAtOf` spellings — a name grep blind to the renamed '
              'copy is how 18-01 nearly reported 3 of 4');
      expect(crockfordAccumulationLines(planted), hasLength(1));
      expect(bitwiseUlidDecodeLines(planted), hasLength(1));
      expect(redactDeclarationLines(planted), hasLength(1));
      expect(redactVocabularyLines(planted), hasLength(1));
      expect(redactCallSiteLines(planted), hasLength(1));
      expect(redactCapDeclarationLines(planted), hasLength(1));
      expect(cadenceBodyLines(planted), hasLength(1));
      expect(minimumIntervalLiteralLines(planted), hasLength(1));
      expect(staleDeadlineComparisonLines(planted), hasLength(1));
      expect(writeOutcomeLogClassLines(planted), hasLength(1));
      expect(positiveEvidenceRuleLines(planted), hasLength(1));
      expect(liveHoldCollectionLines(planted), hasLength(1),
          reason: 'a sweep that cannot see its own planted offender has been '
              'passing on nothing — which is worse than no sweep, because it '
              'reads as a guarantee');
    });

    test('a comment explaining the bug shape does NOT trip the bitwise sweep',
        () {
      // 18-01 deviation 3: the first draft of ulid.dart's doc quoted the
      // literal `(ms << 5) | digit` to explain the bug and made the phase's
      // bug-shape census return hits against PROSE. The sweep must be able to
      // coexist with its own documentation.
      final planted = _plant(
        'commentary.dart',
        '/// Never decode with `ms = (ms << 5) | digit` — dart2js coerces\n'
        '// bitwise ops to 32 bits: (ms << 5) | digit folds every real date.\n'
        'void nothing() {}\n',
      );
      expect(bitwiseUlidDecodeLines(planted), isEmpty,
          reason: 'a file that merely explains the forbidden idiom was '
              'reported as containing it, so the sweep cannot coexist with '
              'its own documentation (18-01 deviation 3)');
    });
  });

  // --------------------------------------------------- assertion 1: ulidMs

  group('one ULID timestamp decoder (18-01), plus the policed reference', () {
    test('exactly $declaredUlidDecoderDeclarations decoder declarations, at '
        'the two ruled sites', () {
      final hits = ulidDecoderDeclarationLines(walk);
      expect(hits, hasLength(declaredUlidDecoderDeclarations),
          reason: 'the ULID decoder census moved. 18-01 deleted the private '
              'copies in local_state_man.dart, value_handlers.dart and '
              'backend_writes.dart (`_mintedAtOf`) and left exactly two '
              'declarations: the shared `ulidMs` and the fake\'s '
              '`referenceUlidMs`. A NEW hit is a re-added copy — delete it '
              'and import `package:tfc_relay_protocol` instead; a MISSING hit '
              'means the shared decoder or the policed reference was deleted, '
              'and the reference must not go without its agreement arm going '
              'too (18-01 task 3). Hits:\n${hits.join('\n')}');
      expect(hits.where((h) => h.contains('tfc_relay_protocol/lib/src/ulid.dart')),
          hasLength(1),
          reason: 'the shared decoder is not where 18-01 put it');
      expect(hits.where((h) => h.contains(fakeStateManSuffix)), hasLength(1),
          reason: 'the reference decoder left the one allowlisted file');
    });

    test('exactly $declaredCrockfordAccumulations base-32 accumulations — the '
        'behaviour polarity of the same census', () {
      final hits = crockfordAccumulationLines(walk);
      expect(hits, hasLength(declaredCrockfordAccumulations),
          reason: 'a decoder under a name this file has never heard of still '
              'has to multiply by 32 and add a digit. 18-01\'s name census '
              'was blind to `_mintedAtOf`; this polarity is why a rename does '
              'not escape. Hits:\n${hits.join('\n')}');
    });
  });

  // ------------------------------------- assertion 2: no bitwise ULID decode

  group('zero bitwise ULID decodes anywhere — including the allowlisted file '
      '(18-01)', () {
    test('no code line shifts-and-ors an accumulator', () {
      final hits = bitwiseUlidDecodeLines(walk);
      expect(hits, isEmpty,
          reason: 'the `<< 5 |` decode is the live dart2js bug 18-01 removed '
              'from three shipping copies: bitwise ops coerce to 32 bits '
              'under dart2js, so every timestamp from 1970-02-19 onward '
              'mis-dates, which on the writeStatus path is the difference '
              'between "a re-send is safe" and "unknown". The reference copy '
              'in fake_state_man.dart is ALLOWED to exist and is NOT allowed '
              'to be wrong — there is no allowlist for this sweep. Use '
              '`ms = ms * 32 + digit`. Hits:\n${hits.join('\n')}');
    });
  });

  // ------------------------------------- assertion 3: redactUpstreamError

  group('one redactor (18-02), with its callers intact', () {
    test('exactly $declaredRedactDeclarations declaration, in redact.dart',
        () {
      final hits = redactDeclarationLines(walk);
      expect(hits, hasLength(declaredRedactDeclarations),
          reason: '18-02 deleted the private copy in tfc_dart\'s '
              'write_translation.dart and the public one in tfc_relay_local\'s '
              'upstream_link.dart, leaving one declaration in '
              'tfc_relay_protocol/lib/src/redact.dart. A second declaration '
              'is a re-added copy whose eight rules WILL drift — that drift '
              'was undetectable for a whole phase before 18-02 (one incidental '
              'assertion covered one of eight rules). Hits:\n${hits.join('\n')}');
      expect(hits.single, contains('tfc_relay_protocol/lib/src/redact.dart'));
    });

    test('the output vocabulary appears in redact.dart alone — the sweep a '
        'RENAMED copy cannot escape', () {
      // 18-02 grep D: a copy under another name cannot change its output
      // vocabulary without ceasing to be a copy. `<endpoint>` is the needle
      // because it is unique to this redactor; `<redacted>` is deliberately
      // NOT used — tls_config.dart spells it for an unrelated TLS redaction,
      // and a needle two features share is a sweep that cries wolf.
      final hits = redactVocabularyLines(walk)
          .where(
              (h) => !h.contains('tfc_relay_protocol/lib/src/redact.dart'))
          .toList();
      expect(hits, isEmpty,
          reason: 'a lib/ file outside redact.dart emits the redactor\'s '
              '`<endpoint>` vocabulary — that is a copy under a different '
              'name (the realistic failure, per 18-06\'s plan; 18-02 grep D). '
              'Delete it and call redactUpstreamError. Hits:\n${hits.join('\n')}');
    });

    test('the $declaredRedactCallSites call sites are still calling — this '
        'count must not FALL', () {
      final hits = redactCallSiteLines(walk);
      expect(hits, hasLength(declaredRedactCallSites),
          reason: 'baseline 10 call sites (3 tfc_dart, 7 tfc_relay_local). A '
              'FALLING count is deleted behaviour — an adapter that stopped '
              'redacting leaks endpoints and credentials to panels (T-08-33). '
              'A RISING count is fine if deliberate: update this number in '
              'the same commit and say which caller was added. '
              'Hits:\n${hits.join('\n')}');
    });

    test('exactly $declaredRedactCapDeclarations cap constant', () {
      final hits = redactCapDeclarationLines(walk);
      expect(hits, hasLength(declaredRedactCapDeclarations),
          reason: 'maxRedactedErrorLength is declared once, in redact.dart '
              '(18-02). A second declaration is where the two caps drift '
              'apart. Hits:\n${hits.join('\n')}');
    });
  });

  // ------------------------------------------ assertion 4: freshness kernel

  group('one freshness kernel (18-03), plus the allowlisted reference copy',
      () {
    test('exactly $declaredCadenceBodies cadence bodies, at the two ruled '
        'sites', () {
      final hits = cadenceBodyLines(walk);
      expect(hits, hasLength(declaredCadenceBodies),
          reason: '18-03 moved the quarter-with-a-floor arithmetic into '
              'freshness.dart; both sweep objects delegate to it. The second '
              'permitted body is fake_state_man.dart\'s (18-03 F-A — '
              'deliberately independent, recorded not fixed). A THIRD is a '
              're-added copy: delete it and call freshnessIntervalFor. '
              'BLIND SPOT, stated: this needle is the literal '
              '`staleAfter ~/ 4`, so a copy that renames the parameter '
              'escapes it — the minimum-interval and deadline sweeps below '
              'are the partial cover. Hits:\n${hits.join('\n')}');
      expect(
          hits.where(
              (h) => h.contains('tfc_relay_protocol/lib/src/freshness.dart')),
          hasLength(1));
      expect(hits.where((h) => h.contains(fakeStateManSuffix)), hasLength(1));
    });

    test('exactly $declaredMinimumIntervalLiterals named 5 ms floor constant',
        () {
      final hits = minimumIntervalLiteralLines(walk);
      expect(hits, hasLength(declaredMinimumIntervalLiterals),
          reason: 'minimumFreshnessInterval carries the 5 ms literal once, in '
              'freshness.dart (18-03). The delegates in '
              'backend_freshness.dart and freshness_sweep.dart alias the '
              'shared NAME and carry no literal — that is what makes them '
              'delegates. A new named interval constant with its own 5 ms '
              'literal is a floor that can drift from the kernel\'s. '
              'Hits:\n${hits.join('\n')}');
      expect(hits.single,
          contains('tfc_relay_protocol/lib/src/freshness.dart'));
    });

    test('exactly $declaredStaleDeadlineComparisons staleness deadline '
        'comparisons', () {
      final hits = staleDeadlineComparisonLines(walk);
      expect(hits, hasLength(declaredStaleDeadlineComparisons),
          reason: 'the `< staleAfter` verdict lives in isStaleNow '
              '(freshness.dart, 18-03) and, deliberately, in the fake\'s own '
              'chain (18-03 F-A). A third comparison is a third staleness '
              'verdict that can disagree with the kernel about whether an '
              'operator is looking at a live number. Hits:\n${hits.join('\n')}');
      expect(
          hits.where(
              (h) => h.contains('tfc_relay_protocol/lib/src/freshness.dart')),
          hasLength(1));
      expect(hits.where((h) => h.contains(fakeStateManSuffix)), hasLength(1));
    });
  });

  // ------------------------------------- assertion 5: one WriteOutcomeLog

  group('one WriteOutcomeLog class (18-04) — and exactly three '
      'implementations of the four-piece rule, two on purpose', () {
    test('exactly $declaredWriteOutcomeLogClasses class named '
        '*WriteOutcomeLog', () {
      final hits = writeOutcomeLogClassLines(walk);
      expect(hits, hasLength(declaredWriteOutcomeLogClasses),
          reason: '18-04 deleted BackendWriteOutcomeLog (the phase\'s only '
              'UNDECLARED copy — byte-identical across nine members with no '
              'comment admitting it) and left one class in '
              'tfc_relay_protocol/lib/src/write_outcome_log.dart. A second '
              'class of this name is that history restarting. '
              'Hits:\n${hits.join('\n')}');
      expect(hits.single,
          contains('tfc_relay_protocol/lib/src/write_outcome_log.dart'));
    });

    test('exactly $declaredPositiveEvidenceRules positive-evidence '
        'comparisons, both polarities, at the three ruled sites', () {
      // 18-04 F2: the first behaviour census was written in the positive
      // polarity only and was blind to the negated spelling — widening it is
      // what FOUND the fake's inline predicate. Both polarities, always.
      final hits = positiveEvidenceRuleLines(walk);
      expect(hits, hasLength(declaredPositiveEvidenceRules),
          reason: '"2 classes -> 1" never meant one implementation of the '
              'four-piece rule. There are three, two on purpose: the shared '
              'class (positive polarity), tfc_relay_local\'s five-answer '
              'plant-side log (stays by 18-04 task 3\'s ruling — 5 answers, '
              '10 min TTL, 4096-cap LRU: a different design, not a copy), and '
              'the fake\'s inline predicate (18-01\'s independence rule). A '
              'FOURTH is a new copy nobody ruled on; a MISSING one is a '
              'deleted ruling. Hits:\n${hits.join('\n')}');
      expect(
          hits.where((h) =>
              h.contains('tfc_relay_protocol/lib/src/write_outcome_log.dart')),
          hasLength(1));
      expect(
          hits.where(
              (h) => h.contains('tfc_relay_local/lib/src/local_state_man.dart')),
          hasLength(1));
      expect(hits.where((h) => h.contains(fakeStateManSuffix)), hasLength(1));
    });
  });

  // ------------------------------------------ assertion 6: hold registries

  group('the live-hold census holds at $declaredLiveHoldCollections '
      '(18-05: seven -> six, NOT two -> one)', () {
    test('exactly $declaredLiveHoldCollections live-hold collections, each at '
        'a named site', () {
      final hits = liveHoldCollectionLines(walk);
      expect(hits, hasLength(declaredLiveHoldCollections),
          reason: '18-05 merged tfc_dart\'s and tfc_relay_local\'s registries '
              'into the shared HoldRegistry and left five deliberate others '
              '(see liveHoldCollectionSites — two are keyed by tag ON '
              'PURPOSE, per-session, WR-02; merging those would change a '
              'session-scoping rule, not remove duplication). A SEVENTH '
              'collection is a new registry nobody ruled on. '
              'Hits:\n${hits.join('\n')}');
      for (final site in liveHoldCollectionSites.entries) {
        expect(hits.where((h) => h.contains(site.key)), hasLength(1),
            reason: '${site.key} (${site.value}) no longer holds exactly one '
                'live-hold collection — the census sites and the tree have '
                'drifted apart, and this table must be corrected in the same '
                'commit as whatever moved');
      }
    });

    test('zero live-hold collections in the two packages 18-05 emptied', () {
      final hits = liveHoldCollectionLines(walk)
          .where((h) => holdRegistryDeletionPackages
              .any((p) => h.contains('$p/lib/')))
          .toList();
      expect(hits, isEmpty,
          reason: '18-05 deleted the local registries in '
              'backend_hold.dart and local_state_man.dart; both now delegate '
              'to the shared HoldRegistry. A collection reappearing in either '
              'package is the phase silently undoing itself — a second live '
              'set is a second answer to "what is still feeding the plant". '
              'Hits:\n${hits.join('\n')}');
    });
  });

  // ------------------------------------------- assertion 7: the pubspec floor

  group('the dependency floor of tfc_relay_protocol', () {
    test('runtime dependencies are exactly {tfc_access}, path-only', () {
      // 18-CONTEXT decision 1's floor — nothing this phase moved here may
      // bring logger, dart:io or ANY dependency — as AMENDED by 17-03, which
      // landed tfc_access (a path dependency inside this repository, pure
      // Dart, policed by that package's own package_purity_test) between this
      // plan's writing and its execution. The property this arm holds is the
      // one the package choice rests on: this package is imported by the
      // Flutter app, so a registry dependency entering here enters every
      // client's version solve. Task 5(c) proved this arm is the ONLY thing
      // holding it.
      final lines = File('pubspec.yaml').readAsLinesSync();
      final start = lines.indexWhere((l) => l.trim() == 'dependencies:');
      expect(start, greaterThanOrEqualTo(0),
          reason: 'pubspec.yaml has no dependencies: section at all. That was '
              'true until 17-03; if it is true again, tfc_access left and '
              'this arm should go back to asserting the section is absent');
      final section = <String>[];
      for (var i = start + 1; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('#') || line.trim().isEmpty) continue;
        if (!line.startsWith(' ')) break; // next top-level key ends the block
        section.add(line);
      }
      final names = <String>[
        for (final line in section)
          if (RegExp(r'^  \S').hasMatch(line))
            line.trim().replaceAll(':', '').split(' ').first,
      ];
      expect(names, <String>['tfc_access'],
          reason: 'tfc_relay_protocol\'s runtime dependencies are exactly '
              '{tfc_access} (17-03) and nothing else — this package is '
              'imported by the Flutter app, and a "helpful" import here puts '
              'a version constraint on every client in the plant '
              '(18-CONTEXT decision 1). Found: $names. Remove the addition, '
              'or take the argument to a phase that owns this pubspec');
      expect(section.join('\n'), contains('path:'),
          reason: 'tfc_access must stay a PATH dependency — nothing fetched '
              'from a registry may enter this package\'s runtime solve');
      expect(section.join('\n'), isNot(contains('logger')),
          reason: 'logger in the protocol package is the exact wrong-half-of-'
              'a-helper failure 18-CONTEXT decision 1 names');
    });
  });
}

/// Writes [contents] to [name] in a fresh temp directory, cleaned up after,
/// and returns the planted files — the same shape as freeze_test.dart's.
List<File> _plant(String name, String contents) {
  final directory = Directory.systemTemp.createTempSync('no-dup-plant-');
  addTearDown(() => directory.deleteSync(recursive: true));
  final file = File('${directory.path}/$name')..writeAsStringSync(contents);
  return <File>[file];
}

// ---------------------------------------------------------------- the sweeps
//
// Line-based and deliberately literal (freeze_test.dart's argument: a bound
// the sweep cannot see is a bound the next reader cannot see either). Each
// returns `path:line: text` hits over CODE lines — full-line comments are
// skipped; trailing comments are not.

/// Every `.dart` file under every `<package>/lib/` below [root].
List<File> libDartFiles(Directory root) {
  if (!root.existsSync()) return const <File>[];
  final files = <File>[];
  for (final entry in root.listSync()) {
    if (entry is! Directory) continue;
    final lib = Directory('${entry.path}/lib');
    if (!lib.existsSync()) continue;
    files.addAll(dartFilesUnder(lib));
  }
  return files;
}

/// Every `.dart` file under [directory], or none if it does not exist.
List<File> dartFilesUnder(Directory directory) => directory.existsSync()
    ? directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList()
    : const <File>[];

/// `path:line: text` for every code line of [files] matching [pattern].
List<String> _codeLines(List<File> files, Pattern pattern) {
  final hits = <String>[];
  for (final file in files) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('//')) continue;
      if (pattern.allMatches(line).isNotEmpty) {
        // `/`-normalised at the ONE place hits are minted. `File.path` uses
        // the platform separator, every census arm below asks
        // `contains('<package>/lib/src/<file>.dart')`, and on Windows those
        // matched nothing: nine arms reddened about helpers that were present,
        // at the right sites, all along — the sweep found the code and the
        // comparison lost it. Same fix, same reason, as the allowlist arm.
        hits.add('${file.path.replaceAll(r'\', '/')}:${i + 1}: '
            '${line.trim()}');
      }
    }
  }
  return hits;
}

/// ULID decoder declarations, union over every name the thing has ever had
/// (18-01: `_mintedAtOf` defeated the single-name grep once already).
/// Blind to: a decoder under a FIFTH name — which is what the accumulation
/// sweep below exists to catch.
List<String> ulidDecoderDeclarationLines(List<File> files) => _codeLines(
    files, RegExp(r'int\?\s+_?(ulidMs|mintedAtOf|referenceUlidMs)\s*\(\s*String'));

/// Crockford base-32 accumulation, by behaviour: `* 32 + digit` or the
/// kernel's `* _base32 + digit`. Blind to: an accumulator not named `digit`.
List<String> crockfordAccumulationLines(List<File> files) =>
    _codeLines(files, RegExp(r'\*\s*(32|_base32)\s*\+\s*digit'));

/// The dart2js bug shape: a five-bit shift-and-or accumulation. The ONE sweep
/// here that matches a bug shape on purpose — its job is to forbid the bug,
/// not to find copies. No allowlist, including fake_state_man.dart.
List<String> bitwiseUlidDecodeLines(List<File> files) =>
    _codeLines(files, RegExp(r'<<\s*5\s*\)?\s*\|'));

/// `redactUpstreamError` declarations, both the public and private spelling.
/// Blind to: a renamed copy — the vocabulary sweep closes that.
List<String> redactDeclarationLines(List<File> files) =>
    _codeLines(files, RegExp(r'String\?\s+_?redactUpstreamError\s*\('));

/// The redactor's unique output vocabulary. A renamed copy cannot change what
/// it emits without ceasing to be a copy (18-02 grep D). `<redacted>` is NOT
/// a needle here — tls_config.dart spells it for an unrelated TLS redaction.
List<String> redactVocabularyLines(List<File> files) =>
    _codeLines(files, '<endpoint>');

/// Call sites: the bare name is a substring of the private one, declarations
/// filtered out by signature. Blind to: a tear-off bound to another name.
List<String> redactCallSiteLines(List<File> files) =>
    _codeLines(files, RegExp(r'redactUpstreamError\('))
        .where((h) => !RegExp(r'String\?\s+_?redactUpstreamError\s*\(')
            .hasMatch(h))
        .toList();

/// `maxRedactedErrorLength` declarations, both spellings.
List<String> redactCapDeclarationLines(List<File> files) =>
    _codeLines(files, RegExp(r'const int _?maxRedactedErrorLength'));

/// The cadence arithmetic, by behaviour (18-03 P2 — the only pattern that
/// ever saw the fake's third copy). Blind to: a renamed parameter.
List<String> cadenceBodyLines(List<File> files) =>
    _codeLines(files, 'staleAfter ~/ 4');

/// Named interval constants carrying their own 5 ms literal. Aliases of the
/// shared name deliberately do not match; broken_hold.dart's 5 ms Timer
/// argument deliberately does not match (it is a duration, not a floor).
List<String> minimumIntervalLiteralLines(List<File> files) => _codeLines(
    files,
    RegExp(
        r'const Duration \w*[iI]nterval\s*=\s*(const\s+)?Duration\(milliseconds:\s*5\)'));

/// The staleness verdict's deadline comparison, both spellings (18-03's P4 as
/// widened by its own summary — the original was blind to the DateTime
/// spelling the fake uses).
List<String> staleDeadlineComparisonLines(List<File> files) =>
    _codeLines(files, RegExp(r'<\s*staleAfter'));

/// Class declarations named `*WriteOutcomeLog`. Anchored on the `class`
/// keyword so the doc-prose mention in write_outcome_log.dart:33 does not
/// count (18-04's correction to the plan's own pattern).
List<String> writeOutcomeLogClassLines(List<File> files) =>
    _codeLines(files, RegExp(r'class\s+\w*WriteOutcomeLog\b'));

/// The four-piece rule's minted-vs-started comparison, BOTH polarities
/// (18-04 F2: the positive-only census was blind to the negated spelling).
List<String> positiveEvidenceRuleLines(List<File> files) =>
    _codeLines(files, RegExp(r'mintedAt(Ms)?\s*(>=|<)\s*_?started(At)?Ms'));

/// Live-hold collections, the WIDENED pattern (18-05 F2: four of the six are
/// written with inferred types and carry no `Set<` at all). Blind to: a
/// List-backed or record-wrapped registry.
List<String> liveHoldCollectionLines(List<File> files) => _codeLines(
    files,
    RegExp(
        r'<(relay\.)?HoldHandle>\{\}|<String,\s*(relay\.)?HoldHandle>\{\}|Set<(relay\.)?HoldHandle>'));
