import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';

/// Read a file relative to the package root, wherever `dart test` was invoked
/// from. Same reasoning as `package_purity_test.dart`: a source-text assertion
/// that cannot find its file must say so, not quietly do nothing.
String _source(String relative) {
  var dir = Directory.current.absolute;
  while (true) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('name: tfc_access')) {
      return File('${dir.path}/$relative').readAsStringSync();
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate the tfc_access package root from '
          '${Directory.current.path}');
    }
    dir = parent;
  }
}

/// The one hand-built `pbkdf2-sha256` record in this file, and the fixture the
/// encoding assertions are written against.
const PasswordHash _pbkdf2Fixture = PasswordHash(
  hashB64: 'aGFzaA==',
  saltB64: 'c2FsdA==',
  iterations: 200000,
);

/// The one hand-built `argon2id` record in this file — the twin of
/// [_pbkdf2Fixture], built through the named constructor.
///
/// Deliberately one call site. The four loose values `PasswordHasher.verify`
/// used to take are gone, and a builder here is what keeps them from creeping
/// back into a dozen argument lists. Every test that needs an argon2id record
/// with parameters of its own choosing goes through this or through
/// [_withParams].
PasswordHash _argon2idHash({
  required int memoryKib,
  required int iterations,
  required int parallelism,
  String hash = 'aGFzaA==',
  String salt = 'c2FsdA==',
}) =>
    PasswordHash.argon2id(
      hashB64: hash,
      saltB64: salt,
      memoryKib: memoryKib,
      iterations: iterations,
      parallelism: parallelism,
    );

/// The same argon2id record with one or more values replaced, built by
/// re-encoding and decoding rather than by a constructor call.
///
/// This is how a row edited in `psql` actually arrives: as text.
PasswordHash _withParams(
  PasswordHash h, {
  int? memoryKib,
  int? iterations,
  int? parallelism,
  String? hash,
  String? salt,
}) =>
    PasswordHash.decode(
      'argon2id\$v=19\$m=${memoryKib ?? h.memoryKib},'
      't=${iterations ?? h.iterations},'
      'p=${parallelism ?? h.parallelism}\$${hash ?? h.hashB64}',
      saltB64: salt ?? h.saltB64,
    );

/// A `pbkdf2-sha256` record, made the way a row written before this plan was:
/// derive with PBKDF2, then read it back through the stored encoding.
///
/// Going through [PasswordHash.decode] rather than a constructor is the point —
/// it is the same path a legacy row takes on the login screen.
Future<PasswordHash> _pbkdf2Hash(String password, {int iterations = 10}) async {
  final salt = List<int>.generate(PasswordHasher.saltBytes, (i) => i + 3);
  final key = await Pbkdf2Kdf.deriveKey(
    passphrase: password,
    salt: salt,
    iterations: iterations,
  );
  final derived = base64Encode(await key.extractBytes());
  return PasswordHash.decode(
    'pbkdf2-sha256\$$iterations\$$derived',
    saltB64: base64Encode(salt),
  );
}

/// Every test in this file runs with the KDF cost hook clamped to 10.
///
/// A production-strength derivation is far too slow to do dozens of, and this
/// suite performs dozens of them. Since Argon2id landed the clamp governs
/// **both** algorithms through one store: the hook is a cost dial, read as an
/// iteration count by PBKDF2 and as KiB of memory by Argon2id. If this file
/// ever starts taking minutes, the hook has stopped being honoured for one of
/// them — that is the failure this arrangement is meant to make loud, because
/// the symptom ("the tests got slow") never points at the cause on its own.
void main() {
  setUp(() => Pbkdf2Kdf.iterationsForTest = 10);
  tearDown(() => Pbkdf2Kdf.iterationsForTest = null);

  group('the single KDF cost hook', () {
    test('one store: Pbkdf2Kdf.iterationsForTest forwards onto it', () {
      Pbkdf2Kdf.iterationsForTest = 99;
      expect(KdfTestCost.iterationsForTest, 99,
          reason: 'Pbkdf2Kdf.iterationsForTest is a forwarding getter/setter, '
              'not a second store — twenty-odd setter sites across four suites '
              'spell it that way and must keep meaning what they meant');
      KdfTestCost.iterationsForTest = 10;
      expect(Pbkdf2Kdf.iterationsForTest, 10);
    });

    test('setting it makes both algorithms cheap', () {
      KdfTestCost.iterationsForTest = 10;
      expect(Pbkdf2Kdf.iterations, 10);
      final params = Argon2idKdf.params;
      expect(params.memoryKib, 10);
      expect(params.iterations, Argon2idKdf.testIterations);
      expect(params.parallelism, Argon2idKdf.testParallelism);
      expect(params.hashLength, Argon2idKdf.hashLength);
      expect(params, isNot(Argon2idKdf.productionParams));
    });

    test('it is a dial, not a switch: 10 and 99 are different costs', () {
      KdfTestCost.iterationsForTest = 10;
      final at10 = Argon2idKdf.params;
      final pbkdf2At10 = Pbkdf2Kdf.iterations;
      KdfTestCost.iterationsForTest = 99;
      final at99 = Argon2idKdf.params;

      expect(at99, isNot(at10),
          reason: 'a fixed cheap parameter set would make every '
              'non-null-to-non-null flip in the tree a silent no-op, and the '
              'assertions that depend on such a flip would keep passing while '
              'testing nothing');
      expect(at99.memoryKib, greaterThan(at10.memoryKib));
      expect(Pbkdf2Kdf.iterations, greaterThan(pbkdf2At10));
    });

    test('the floor keeps a very small hook value a legal parameter set', () {
      KdfTestCost.iterationsForTest = 1;
      expect(
        Argon2idKdf.params.memoryKib,
        Argon2idKdf.minMemoryKibPerLane * Argon2idKdf.testParallelism,
        reason: 'Argon2id requires memory >= 8 * parallelism, so a suite that '
            'clamps the hook to 1 must not produce a parameter set the KDF '
            'refuses',
      );
    });

    test('clearing it returns both algorithms to production', () {
      KdfTestCost.iterationsForTest = null;
      expect(Pbkdf2Kdf.iterations, Pbkdf2Kdf.defaultIterations);
      expect(Argon2idKdf.params, Argon2idKdf.productionParams);
    });
  });

  group('Argon2idKdf production parameters', () {
    test('are named constants, not values inlined at a call site', () {
      expect(Argon2idKdf.productionParams.memoryKib, Argon2idKdf.memoryKib);
      expect(Argon2idKdf.productionParams.iterations, Argon2idKdf.iterations);
      expect(Argon2idKdf.productionParams.parallelism, Argon2idKdf.parallelism);
      expect(Argon2idKdf.productionParams.hashLength, Argon2idKdf.hashLength);
      expect(Argon2idKdf.hashLength, 32,
          reason: 'PasswordHash stores a 256-bit hash and '
              'PasswordHasher.constantTimeEquals documents that the hash is '
              'always 32 bytes; changing the width is a different decision');
      expect(Argon2idKdf.maxIsolates, greaterThanOrEqualTo(1));
      expect(Argon2idKdf.blocksPerProcessingChunk, greaterThan(0));
    });

    test('meet the strength floor', () {
      expect(
        Argon2idKdf.memoryKib >= 19456 && Argon2idKdf.iterations >= 2,
        isTrue,
        reason: "Argon2id below OWASP's memory and time would be weaker than "
            'the PBKDF2-200k it replaces, which would make this whole change a '
            'regression. The way that mistake arrives is somebody making the '
            'tests faster by editing the production constant instead of the '
            'test hook, so the floor is asserted here rather than only '
            'reasoned about in a plan',
      );
    });
  });

  group('Pbkdf2Kdf.iterations', () {
    test('is defaultIterations when the hook is null', () {
      Pbkdf2Kdf.iterationsForTest = null;
      expect(Pbkdf2Kdf.iterations, Pbkdf2Kdf.defaultIterations);
      expect(Pbkdf2Kdf.defaultIterations, 200000);
    });

    test('is the hook value when the hook is set', () {
      Pbkdf2Kdf.iterationsForTest = 10;
      expect(Pbkdf2Kdf.iterations, 10);
    });
  });

  group('Pbkdf2Kdf.deriveKey', () {
    test('is deterministic for the same passphrase, salt and iterations',
        () async {
      final salt = List<int>.generate(16, (i) => i);
      final a = await Pbkdf2Kdf.deriveKey(passphrase: 'hunter2', salt: salt);
      final b = await Pbkdf2Kdf.deriveKey(passphrase: 'hunter2', salt: salt);
      expect(await a.extractBytes(), await b.extractBytes());
    });

    test('produces different bytes for a different salt', () async {
      final a = await Pbkdf2Kdf.deriveKey(
        passphrase: 'hunter2',
        salt: List<int>.generate(16, (i) => i),
      );
      final b = await Pbkdf2Kdf.deriveKey(
        passphrase: 'hunter2',
        salt: List<int>.generate(16, (i) => i + 1),
      );
      expect(await a.extractBytes(), isNot(await b.extractBytes()));
    });

    test('produces different bytes for a different passphrase', () async {
      final salt = List<int>.generate(16, (i) => i);
      final a = await Pbkdf2Kdf.deriveKey(passphrase: 'hunter2', salt: salt);
      final b = await Pbkdf2Kdf.deriveKey(passphrase: 'hunter3', salt: salt);
      expect(await a.extractBytes(), isNot(await b.extractBytes()));
    });

    test('honours an explicit iteration count over the ambient one', () async {
      // This is the case SecureEnvelope.decrypt depends on: an envelope made
      // at 10 iterations must still decrypt after the default changes.
      final salt = List<int>.generate(16, (i) => i);
      final ambient =
          await Pbkdf2Kdf.deriveKey(passphrase: 'hunter2', salt: salt);
      final explicit = await Pbkdf2Kdf.deriveKey(
        passphrase: 'hunter2',
        salt: salt,
        iterations: 11,
      );
      expect(
          await ambient.extractBytes(), isNot(await explicit.extractBytes()));

      final sameAsAmbient = await Pbkdf2Kdf.deriveKey(
        passphrase: 'hunter2',
        salt: salt,
        iterations: 10,
      );
      expect(await ambient.extractBytes(), await sameAsAmbient.extractBytes());
    });

    test('derives 256 bits by default', () async {
      final key = await Pbkdf2Kdf.deriveKey(
        passphrase: 'hunter2',
        salt: List<int>.generate(16, (i) => i),
      );
      expect((await key.extractBytes()).length, 32);
    });
  });

  group('PasswordHasher.hash', () {
    test('produces a different salt and a different hash every call', () async {
      final a = await PasswordHasher.hash('hunter2');
      final b = await PasswordHasher.hash('hunter2');
      expect(a.saltB64, isNot(b.saltB64));
      expect(a.hashB64, isNot(b.hashB64));
    });

    test('uses 16 bytes of salt', () async {
      final h = await PasswordHasher.hash('hunter2');
      expect(base64Decode(h.saltB64).length, 16);
    });

    test('writes argon2id, and says so in the stored form', () async {
      final h = await PasswordHasher.hash('hunter2');
      expect(h.algorithm, PasswordHashAlgorithm.argon2id);
      expect(h.encode(), startsWith('argon2id\$v=19\$m='));
    });

    test('records the parameters actually used', () async {
      // A later change to the ambient parameters must not invalidate hashes
      // made before it, so the parameters travel with the hash.
      final h = await PasswordHasher.hash('hunter2');
      expect(h.memoryKib, Argon2idKdf.params.memoryKib);
      expect(h.iterations, Argon2idKdf.params.iterations);
      expect(h.parallelism, Argon2idKdf.params.parallelism);
    });

    test('derives the configured hash length', () async {
      final h = await PasswordHasher.hash('hunter2');
      expect(base64Decode(h.hashB64).length, Argon2idKdf.hashLength);
    });
  });

  group('PasswordHasher.verify', () {
    test('returns true for the password that produced the hash', () async {
      final h = await PasswordHasher.hash('hunter2');
      expect(
        await PasswordHasher.verify(password: 'hunter2', stored: h),
        isTrue,
      );
    });

    test('returns false for a wrong password, and does not throw', () async {
      final h = await PasswordHasher.hash('hunter2');
      expect(
        await PasswordHasher.verify(password: 'hunter3', stored: h),
        isFalse,
      );
    });

    test('returns false for an empty password against a non-empty hash',
        () async {
      final h = await PasswordHasher.hash('hunter2');
      expect(
        await PasswordHasher.verify(password: '', stored: h),
        isFalse,
      );
    });

    test('returns false when the salt does not match', () async {
      final h = await PasswordHasher.hash('hunter2');
      final other = await PasswordHasher.hash('hunter2');
      expect(
        await PasswordHasher.verify(
          password: 'hunter2',
          stored: _withParams(h, salt: other.saltB64),
        ),
        isFalse,
      );
    });

    test('returns false when the recorded parameters do not match', () async {
      final h = await PasswordHasher.hash('hunter2');
      expect(
        await PasswordHasher.verify(
          password: 'hunter2',
          stored: _withParams(h, iterations: h.iterations + 1),
        ),
        isFalse,
      );
    });

    // A row mangled by hand in psql must fail a login, not crash the app.
    test('returns false for a non-base64 hash rather than throwing', () async {
      final h = await PasswordHasher.hash('hunter2');
      expect(
        await PasswordHasher.verify(
          password: 'hunter2',
          stored: _withParams(h, hash: 'not base64 !!!'),
        ),
        isFalse,
      );
    });

    test('returns false for a non-base64 salt rather than throwing', () async {
      final h = await PasswordHasher.hash('hunter2');
      expect(
        await PasswordHasher.verify(
          password: 'hunter2',
          stored: _withParams(h, salt: 'not base64 !!!'),
        ),
        isFalse,
      );
    });

    test('returns false for a truncated hash rather than throwing', () async {
      final h = await PasswordHasher.hash('hunter2');
      final short = base64Encode(base64Decode(h.hashB64).sublist(0, 8));
      expect(
        await PasswordHasher.verify(
          password: 'hunter2',
          stored: _withParams(h, hash: short),
        ),
        isFalse,
      );
    });

    test('returns false for empty hash and salt strings', () async {
      expect(
        await PasswordHasher.verify(
          password: 'hunter2',
          stored: _argon2idHash(
            memoryKib: 64,
            iterations: 1,
            parallelism: 1,
            hash: '',
            salt: '',
          ),
        ),
        isFalse,
      );
    });

    // DartArgon2id guards its parameters with `assert`, which does not run in
    // a release AOT build. A row mangled in psql must therefore be rejected by
    // a real check here, and must fail the login rather than reaching the KDF
    // constructor at all.
    test('returns false for memory below 8 * parallelism, without deriving',
        () async {
      expect(
        await PasswordHasher.verify(
          password: 'hunter2',
          stored: _argon2idHash(memoryKib: 4, iterations: 1, parallelism: 1),
        ),
        isFalse,
      );
    });

    test('returns false for a non-positive parallelism, without deriving',
        () async {
      expect(
        await PasswordHasher.verify(
          password: 'hunter2',
          stored: _argon2idHash(memoryKib: 64, iterations: 1, parallelism: 0),
        ),
        isFalse,
      );
    });

    test('returns false for a non-positive iteration count, without deriving',
        () async {
      expect(
        await PasswordHasher.verify(
          password: 'hunter2',
          stored: _argon2idHash(memoryKib: 64, iterations: 0, parallelism: 1),
        ),
        isFalse,
      );
    });

    test('verifies at the parameters in the row, not the ambient ones',
        () async {
      // The whole reason the parameters ride in the stored value. Both
      // directions the suite can reach: clear the hook so the ambient set
      // becomes the production constants, and flip it to a different non-null
      // value. Both stay cheap despite the null, because verify never derives
      // at the ambient parameters.
      final h = await PasswordHasher.hash('hunter2');

      KdfTestCost.iterationsForTest = null;
      expect(Argon2idKdf.params.memoryKib, isNot(h.memoryKib));
      expect(Argon2idKdf.params.iterations, isNot(h.iterations));
      expect(
        await PasswordHasher.verify(password: 'hunter2', stored: h),
        isTrue,
      );

      KdfTestCost.iterationsForTest = 99;
      expect(Argon2idKdf.params.memoryKib, isNot(h.memoryKib));
      expect(
        await PasswordHasher.verify(password: 'hunter2', stored: h),
        isTrue,
      );
    });

    group('pbkdf2-sha256 rows, forever', () {
      test('a pbkdf2-sha256 row still verifies against its password', () async {
        final stored = await _pbkdf2Hash('hunter2', iterations: 200000);
        expect(stored.algorithm, PasswordHashAlgorithm.pbkdf2Sha256);
        expect(stored.encode(), startsWith('pbkdf2-sha256\$200000\$'));
        expect(
          await PasswordHasher.verify(password: 'hunter2', stored: stored),
          isTrue,
          reason: 'existing users must not be locked out by the migration; '
              'that is the whole reason the count travels with the hash',
        );
      });

      test('a pbkdf2-sha256 row still fails against a wrong password',
          () async {
        final stored = await _pbkdf2Hash('hunter2');
        expect(
          await PasswordHasher.verify(password: 'hunter3', stored: stored),
          isFalse,
        );
      });

      test('a pbkdf2-sha256 row verifies at its own count, not the ambient one',
          () async {
        final stored = await _pbkdf2Hash('hunter2', iterations: 11);
        KdfTestCost.iterationsForTest = 10;
        expect(
          await PasswordHasher.verify(password: 'hunter2', stored: stored),
          isTrue,
        );
      });

      test(
          'returns false for a nonsensical iteration count rather than throwing',
          () async {
        // A legacy bare-base64 row, read while the ambient count is itself
        // nonsense. The record decodes — a bare value is not malformed — and
        // verify is what has to refuse it rather than hand a zero iteration
        // count to the KDF.
        final stored = await _pbkdf2Hash('hunter2');
        KdfTestCost.iterationsForTest = 0;
        final bare =
            PasswordHash.decode(stored.hashB64, saltB64: stored.saltB64);
        expect(bare.iterations, 0);
        expect(
          await PasswordHasher.verify(password: 'hunter2', stored: bare),
          isFalse,
        );
      });
    });
  });

  group('PasswordHasher.needsRehash', () {
    test('is true for any pbkdf2-sha256 row', () async {
      final stored = await _pbkdf2Hash('hunter2');
      expect(PasswordHasher.needsRehash(stored), isTrue);
    });

    test('is false for an argon2id row at the current parameters', () async {
      final h = await PasswordHasher.hash('hunter2');
      expect(PasswordHasher.needsRehash(h), isFalse);
    });

    test('is true for an argon2id row whose parameters have moved on',
        () async {
      final h = await PasswordHasher.hash('hunter2');
      KdfTestCost.iterationsForTest = 99;
      expect(PasswordHasher.needsRehash(h), isTrue);
    });
  });

  group('PasswordHasher.constantTimeEquals', () {
    test('is true for identical byte lists', () {
      expect(
        PasswordHasher.constantTimeEquals([1, 2, 3, 4], [1, 2, 3, 4]),
        isTrue,
      );
    });

    test('is false for equal-length but different inputs', () {
      expect(
        PasswordHasher.constantTimeEquals([1, 2, 3, 4], [1, 2, 3, 5]),
        isFalse,
      );
      // Differing in the first byte must give the same answer as differing in
      // the last; the comparison does not return early.
      expect(
        PasswordHasher.constantTimeEquals([9, 2, 3, 4], [1, 2, 3, 4]),
        isFalse,
      );
    });

    test('is false for different-length inputs', () {
      expect(
          PasswordHasher.constantTimeEquals([1, 2, 3], [1, 2, 3, 4]), isFalse);
      expect(
          PasswordHasher.constantTimeEquals([1, 2, 3, 4], [1, 2, 3]), isFalse);
    });

    test('is true for two empty lists', () {
      expect(PasswordHasher.constantTimeEquals(const [], const []), isTrue);
    });
  });

  // The AppUser table (spec §2, quoted as final) has passwordHash and salt but
  // no parameters column, so the parameters ride in the passwordHash field.
  // These helpers are the encode/decode side of that decision; plan 01-06's
  // AccessRepository stores what encode() returns.
  group('PasswordHash stored encoding', () {
    test('encodes pbkdf2 as pbkdf2-sha256\$<iterations>\$<hash_b64>', () {
      expect(_pbkdf2Fixture.algorithm, PasswordHashAlgorithm.pbkdf2Sha256);
      expect(_pbkdf2Fixture.encode(), 'pbkdf2-sha256\$200000\$aGFzaA==');
    });

    test('encodes argon2id as argon2id\$v=19\$m=,t=,p=\$<hash_b64>', () {
      final h = _argon2idHash(memoryKib: 32768, iterations: 3, parallelism: 4);
      expect(h.algorithm, PasswordHashAlgorithm.argon2id);
      expect(h.encode(), 'argon2id\$v=19\$m=32768,t=3,p=4\$aGFzaA==');
    });

    test('round-trips through encode/decode, parameters and all', () async {
      final h = await PasswordHasher.hash('hunter2');
      final decoded = PasswordHash.decode(h.encode(), saltB64: h.saltB64);
      expect(decoded.hashB64, h.hashB64);
      expect(decoded.saltB64, h.saltB64);
      expect(decoded.algorithm, PasswordHashAlgorithm.argon2id);
      expect(decoded.memoryKib, h.memoryKib);
      expect(decoded.iterations, h.iterations);
      expect(decoded.parallelism, h.parallelism);
      expect(decoded, h);
    });

    test('a decoded hash still verifies', () async {
      final h = await PasswordHasher.hash('hunter2');
      final decoded = PasswordHash.decode(h.encode(), saltB64: h.saltB64);
      expect(
        await PasswordHasher.verify(password: 'hunter2', stored: decoded),
        isTrue,
      );
    });

    test('a legacy bare-base64 value decodes at the default iteration count',
        () async {
      // Anything written before this encoding existed has no prefix. It was
      // made at whatever the ambient default was, which is what Pbkdf2Kdf
      // .iterations reports.
      final h = await PasswordHasher.hash('hunter2');
      final decoded = PasswordHash.decode(h.hashB64, saltB64: h.saltB64);
      expect(decoded.iterations, Pbkdf2Kdf.iterations);
      expect(decoded.hashB64, h.hashB64);
    });

    test('decode throws FormatException on a malformed prefixed value', () {
      expect(
        () => PasswordHash.decode('pbkdf2-sha256\$notanint\$aGFzaA==',
            saltB64: 'c2FsdA=='),
        throwsFormatException,
      );
      expect(
        () => PasswordHash.decode('pbkdf2-sha256\$10', saltB64: 'c2FsdA=='),
        throwsFormatException,
      );
      // Three parts, not four: the argon2id form carries a version and a
      // parameter group.
      expect(
        () =>
            PasswordHash.decode('argon2id\$10\$aGFzaA==', saltB64: 'c2FsdA=='),
        throwsFormatException,
      );
      // A version this code cannot verify is not something to guess at.
      expect(
        () => PasswordHash.decode('argon2id\$v=20\$m=32768,t=3,p=4\$aGFzaA==',
            saltB64: 'c2FsdA=='),
        throwsFormatException,
      );
      expect(
        () => PasswordHash.decode('argon2id\$19\$m=32768,t=3,p=4\$aGFzaA==',
            saltB64: 'c2FsdA=='),
        throwsFormatException,
      );
      // A parameter group that will not parse, in every shape it arrives in.
      expect(
        () => PasswordHash.decode('argon2id\$v=19\$m=abc,t=3,p=4\$aGFzaA==',
            saltB64: 'c2FsdA=='),
        throwsFormatException,
      );
      expect(
        () => PasswordHash.decode('argon2id\$v=19\$m=32768,t=3\$aGFzaA==',
            saltB64: 'c2FsdA=='),
        throwsFormatException,
      );
      expect(
        () => PasswordHash.decode('argon2id\$v=19\$t=3,m=32768,p=4\$aGFzaA==',
            saltB64: 'c2FsdA=='),
        throwsFormatException,
      );
      // Non-positive in any slot.
      expect(
        () => PasswordHash.decode('argon2id\$v=19\$m=32768,t=0,p=4\$aGFzaA==',
            saltB64: 'c2FsdA=='),
        throwsFormatException,
      );
      expect(
        () => PasswordHash.decode('argon2id\$v=19\$m=0,t=3,p=4\$aGFzaA==',
            saltB64: 'c2FsdA=='),
        throwsFormatException,
      );
      expect(
        () => PasswordHash.decode('argon2id\$v=19\$m=32768,t=3,p=-1\$aGFzaA==',
            saltB64: 'c2FsdA=='),
        throwsFormatException,
      );
    });

    test('decode throws FormatException on an unknown algorithm', () {
      // scrypt is the tree's standing example of a tag this package does not
      // implement — access_repository_test.dart uses the same value. Adding
      // argon2id narrows the unknown set by one; it does not weaken the
      // rejection.
      expect(
        () => PasswordHash.decode('scrypt\$1\$abc', saltB64: 'c2FsdA=='),
        throwsFormatException,
      );
    });

    test('tryDecode returns null instead of throwing', () {
      expect(
        PasswordHash.tryDecode('pbkdf2-sha256\$notanint\$aGFzaA==',
            saltB64: 'c2FsdA=='),
        isNull,
      );
      expect(
        PasswordHash.tryDecode('scrypt\$1\$abc', saltB64: 'c2FsdA=='),
        isNull,
      );
      expect(
        PasswordHash.tryDecode('argon2id\$10\$aGFzaA==', saltB64: 'c2FsdA=='),
        isNull,
      );
      expect(
        PasswordHash.tryDecode('argon2id\$v=20\$m=32768,t=3,p=4\$aGFzaA==',
            saltB64: 'c2FsdA=='),
        isNull,
      );
      expect(
        PasswordHash.tryDecode('argon2id\$v=19\$m=abc,t=3,p=4\$aGFzaA==',
            saltB64: 'c2FsdA=='),
        isNull,
      );
      expect(
        PasswordHash.tryDecode('argon2id\$v=19\$m=32768,t=0,p=4\$aGFzaA==',
            saltB64: 'c2FsdA=='),
        isNull,
      );
      expect(
        PasswordHash.tryDecode('aGFzaA==', saltB64: 'c2FsdA==')?.hashB64,
        'aGFzaA==',
      );
    });

    test('toString names the algorithm and its parameters, never the hash',
        () {
      expect(_pbkdf2Fixture.toString(), contains('pbkdf2-sha256'));
      expect(_pbkdf2Fixture.toString(), contains('200000'));
      expect(_pbkdf2Fixture.toString(), isNot(contains('aGFzaA==')));

      final argon =
          _argon2idHash(memoryKib: 32768, iterations: 3, parallelism: 4);
      expect(argon.toString(), contains('argon2id'));
      expect(argon.toString(), contains('32768'));
      expect(argon.toString(), isNot(contains('aGFzaA==')));
    });
  });

  group('password_hasher.dart purity', () {
    test('does not reach for Flutter or the cryptography_flutter plugin', () {
      // package_purity_test.dart covers lib/ as a whole; this states the rule
      // at the one file where the temptation is real, because the accelerated
      // backend is a plugin and this is the code that would want it.
      final source = _source('lib/src/password_hasher.dart');
      expect(source, isNot(contains('cryptography_flutter')));
      expect(source, isNot(contains('package:flutter')));
      expect(source, isNot(contains('dart:ui')));
    });
  });

  group('the no-password marker', () {
    test('isPasswordless recognises it and nothing else', () {
      expect(isPasswordless(kNoPasswordMarker), isTrue);
      expect(isPasswordless(''), isFalse,
          reason: 'an empty column is not a decision anybody made');
      expect(isPasswordless('none'), isFalse,
          reason: 'a whole-string match: there is nothing to parse, so there '
              'is nothing to get half right');
      expect(isPasswordless('pbkdf2-sha256\$10\$abc'), isFalse);
    });

    test('it contains a \$, so it is never read as a legacy bare hash', () {
      // A `$`-less value is a legacy base64 PBKDF2 hash. A marker without one
      // would be derived against as if it were a hash of something.
      expect(kNoPasswordMarker, contains(r'$'));
    });

    test('decoding it fails, so forgetting the check locks out rather than '
        'lets in', () {
      expect(PasswordHash.tryDecode(kNoPasswordMarker, saltB64: ''), isNull);
      expect(() => PasswordHash.decode(kNoPasswordMarker, saltB64: ''),
          throwsFormatException,
          reason: '`none` is not a PasswordHashAlgorithm, and that is the '
              'safety property: the failure direction is refusal');
    });

    test('no real encoding can collide with it', () {
      for (final hash in [
        const PasswordHash(hashB64: 'aGk=', saltB64: 'c2E=', iterations: 10),
        const PasswordHash.argon2id(
            hashB64: 'aGk=',
            saltB64: 'c2E=',
            memoryKib: 32768,
            iterations: 3,
            parallelism: 4),
      ]) {
        expect(isPasswordless(hash.encode()), isFalse);
      }
    });
  });
}
