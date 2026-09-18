import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:meta/meta.dart';

/// The one KDF cost hook in the repository.
///
/// Production-strength derivation is tens of seconds per call in the debug-mode
/// test VM, which turns any test that hashes or encrypts into a minutes-long
/// run. This single field is what every suite reaches for instead.
///
/// [Pbkdf2Kdf.iterationsForTest] and `SecureEnvelope.kdfIterationsForTest` are
/// forwarding getter/setter pairs onto this field, **not** second stores. That
/// shape is the point and not an accident of it: roughly twenty setter sites
/// across four suites spell the hook `Pbkdf2Kdf.iterationsForTest`, and they
/// keep compiling *and* keep meaning what they meant because the forwarder
/// exists. Do not "simplify" it away.
///
/// Setting this makes PBKDF2 cheap **and** selects Argon2id's cheap parameter
/// set — see [Argon2idKdf.params]. A second hook is how a suite ends up running
/// real derivations somewhere nobody noticed, and the symptom — "the tests got
/// slow" — never points at the cause.
///
/// It is a cost **dial**, not a switch. [Pbkdf2Kdf.iterations] reads the value
/// as an iteration count; [Argon2idKdf.params] reads the same value as KiB of
/// memory. Cost is monotone in it for both algorithms, so a flip from one
/// non-null value to another is a real parameter change rather than a silent
/// no-op.
abstract final class KdfTestCost {
  @visibleForTesting
  static int? iterationsForTest;
}

/// The one PBKDF2 derivation in the repository.
///
/// This used to live in `lib/pages/server_config.dart` as part of
/// `SecureEnvelope`. It is here because a provider must not import a page file,
/// and because password hashing needed the same derivation — having two copies
/// is how the two drift apart. Since Argon2id landed, passwords are hashed with
/// [Argon2idKdf] and this serves the config-export envelope plus the
/// verification of every `pbkdf2-sha256` row written before the change.
///
/// ## On the accelerated backend
///
/// `Cryptography.instance` is a process-global. The Flutter app assigns
/// `FlutterCryptography.defaultInstance` to it (see
/// `lib/pages/server_config.dart`), and this pure-Dart code picks that up
/// automatically at runtime. That is why the accelerated backend — which ships
/// as a Flutter plugin — stays on the Flutter side and is deliberately absent
/// from this package's pubspec. Naming it here would break
/// `test/package_purity_test.dart` and the relay's server target for no gain;
/// the string is left unwritten on purpose, since that test reads file text.
/// That backend implements no Argon2 at all, so unlike PBKDF2 the password path
/// runs pure Dart wherever it runs, panel included.
abstract final class Pbkdf2Kdf {
  /// Tune per device; higher = slower/stronger. This is the value
  /// `SecureEnvelope` has always used, and every envelope already written
  /// records its own count, so changing it here does not strand them.
  static const int defaultIterations = 200000;

  /// Forwards onto [KdfTestCost.iterationsForTest], which is the one store.
  ///
  /// Kept under this name because roughly twenty setter sites across four
  /// suites already spell it this way, and none of them changes meaning.
  @visibleForTesting
  static int? get iterationsForTest => KdfTestCost.iterationsForTest;

  @visibleForTesting
  static set iterationsForTest(int? value) =>
      KdfTestCost.iterationsForTest = value;

  /// The iteration count to use when a caller does not name one.
  static int get iterations =>
      KdfTestCost.iterationsForTest ?? defaultIterations;

  /// PBKDF2-HMAC-SHA256 over [passphrase] and [salt].
  ///
  /// [iterations] defaults to [Pbkdf2Kdf.iterations]. Callers decrypting an
  /// existing envelope, or verifying a stored password hash, must pass the
  /// count recorded alongside that ciphertext instead — otherwise raising
  /// [defaultIterations] silently invalidates everything written before it.
  static Future<SecretKey> deriveKey({
    required String passphrase,
    required List<int> salt,
    int? iterations,
    int bits = 256,
  }) {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations ?? Pbkdf2Kdf.iterations,
      bits: bits,
    );
    return kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt, // salt
    );
  }
}

/// The parameters an Argon2id hash was, or will be, derived at.
///
/// The first three ride in the stored value (see [PasswordHash.encode]); the
/// fourth is implied by the length of the hash itself.
typedef Argon2idParams = ({
  int memoryKib,
  int iterations,
  int parallelism,
  int hashLength,
});

/// The one Argon2id derivation in the repository — the password path.
///
/// Three facts decided this, each of which a later reader would otherwise have
/// to re-derive:
///
/// 1. **Argon2id is memory-hard and PBKDF2 is not**, and the 200 000 iterations
///    [Pbkdf2Kdf.defaultIterations] carries is below current OWASP guidance for
///    PBKDF2-HMAC-SHA256 (600 000). Those two together are why the algorithm
///    changed rather than the count.
/// 2. **The accelerated Flutter backend implements no Argon2.** PBKDF2 picks up
///    a native implementation through the process-global `Cryptography.instance`
///    when the app installs one; Argon2 gets nothing, so this runs pure Dart on
///    the panel. (The plugin's package name is deliberately left unwritten in
///    this file — see [Pbkdf2Kdf]'s doc.)
/// 3. **The parameters were measured on the panel, not copied from OWASP.** A
///    sign-in derives in **151 ms median on `hq-skjar`, AOT, with zero missed
///    frames**. OWASP's own figures assume a native implementation, and a
///    developer Mac is roughly 2.2x faster than the panel, so choosing there
///    would have chosen wrong.
abstract final class Argon2idKdf {
  /// 32 MiB. 1.7x OWASP's memory floor, and the largest step that still leaves
  /// a 6.6x margin under the one-second stop-and-report threshold for a station
  /// slower than the rig. The next step up, 64 MiB, is where measured jank
  /// starts (one dropped frame, 30 ms worst gap).
  static const int memoryKib = 32768;

  /// RFC 9106's second-recommended pass count. Going from 2 to 3 at this memory
  /// costs 43 ms on the rig and buys a 1.5x work factor.
  static const int iterations = 3;

  /// RFC 9106's recommended lane count. Worth it for speed rather than for the
  /// event loop: `p=1` measured 232.6 ms against `p=4`'s 150.0 ms for the same
  /// memory and passes.
  static const int parallelism = 4;

  /// 256 bits. [PasswordHash] has always stored a 32-byte hash and
  /// [PasswordHasher.constantTimeEquals] documents that; changing the width is
  /// a different decision, and the stored form does not carry it.
  static const int hashLength = 32;

  /// One isolate per lane. Named rather than left null so the value does not
  /// silently depend on the package default staying 8: the implementation
  /// computes `min(parallelism, maxIsolates ?? 8)`, so anything at or above
  /// [parallelism] behaves identically today and would not tomorrow. Turning
  /// isolates off measured 226.8 ms against 150.0 ms *and* moved the mixing
  /// onto the calling isolate, where [blocksPerProcessingChunk] becomes
  /// load-bearing.
  static const int maxIsolates = 4;

  /// How often the mixing loop yields. Chosen from the missed-frame column
  /// rather than the wall-time one, and inert in the shipping configuration
  /// because the isolates run the loop. It is the only thing standing between a
  /// login and a frozen screen if the isolate path is ever unavailable: with
  /// isolates off, never yielding dropped 13 frames on the rig while this value
  /// kept the worst gap at ticker noise, for no measurable cost.
  static const int blocksPerProcessingChunk = 128;

  /// The six above, as one value, for comparison and for [params].
  static const Argon2idParams productionParams = (
    memoryKib: memoryKib,
    iterations: iterations,
    parallelism: parallelism,
    hashLength: hashLength,
  );

  /// Argon2's own lower bound: `memory >= 8 * parallelism`. Named because
  /// [params] floors the hook against it and [PasswordHasher.verify] rejects a
  /// stored row that violates it.
  static const int minMemoryKibPerLane = 8;

  /// The passes used when [KdfTestCost.iterationsForTest] is set. One is the
  /// minimum the algorithm allows, which is the point: the hook's own value is
  /// the dial, and holding `t` and `p` fixed keeps that dial one-dimensional.
  static const int testIterations = 1;

  /// The lane count used when [KdfTestCost.iterationsForTest] is set.
  static const int testParallelism = 1;

  /// Isolates are **off** while [KdfTestCost.iterationsForTest] is set.
  ///
  /// Not a performance choice. A `testWidgets` binding runs the test body in a
  /// fake-async zone: `pumpAndSettle` advances a simulated clock, and no amount
  /// of it advances the real one. An isolate round trip needs real time, so a
  /// derivation that spawns isolates never completes under a widget test — the
  /// write it was part of silently never lands, and the failure surfaces as
  /// "the row is missing" rather than as anything about the KDF.
  ///
  /// The calling isolate is the right place for a test derivation anyway: it is
  /// bounded by the hook, and [blocksPerProcessingChunk] keeps it yielding.
  static const int testMaxIsolates = 0;

  /// The parameters to derive a *new* hash at.
  ///
  /// With the hook clear this is [productionParams]. With the hook set, the
  /// hook's value is read as KiB of memory — floored at
  /// `minMemoryKibPerLane * testParallelism`, because a suite that clamps the
  /// hook to 1 must still produce a parameter set the KDF accepts — at
  /// [testIterations] passes and [testParallelism] lanes.
  ///
  /// Deliberately a function of the hook value rather than a fixed cheap set. A
  /// fixed set would make every non-null-to-non-null flip in the suite a silent
  /// no-op, and the assertions that depend on such a flip would keep passing
  /// while testing nothing. It is also what lets one bounded, clearly
  /// non-production value be genuinely slow where a test needs a derivation
  /// that actually takes time.
  static Argon2idParams get params {
    final hook = KdfTestCost.iterationsForTest;
    if (hook == null) return productionParams;
    return (
      memoryKib: max(hook, minMemoryKibPerLane * testParallelism),
      iterations: testIterations,
      parallelism: testParallelism,
      hashLength: hashLength,
    );
  }

  /// Argon2id over [password] and [salt] at exactly [params].
  ///
  /// Callers verifying a stored hash must pass the parameters recorded in the
  /// row rather than the ambient ones — otherwise a later change to the
  /// constants above locks every existing user out, which is the whole reason
  /// the parameters ride in the stored value.
  static Future<List<int>> deriveBytes({
    required String password,
    required List<int> salt,
    required Argon2idParams params,
  }) async {
    // DartArgon2id from package:cryptography/dart.dart, not the `Argon2id(...)`
    // factory. The factory takes only the four core parameters and routes
    // through Cryptography.instance, which puts maxIsolates and
    // blocksPerProcessingChunk out of reach — two of the six measured constants
    // would silently vanish, including the one that keeps the screen alive if
    // the isolate path is ever unavailable.
    //
    // The isolate count is the one knob that does not come from [params]: it
    // changes what the derivation costs to compute, not what it computes, so it
    // is not part of a stored row and must not be. Under the test hook it is
    // [testMaxIsolates] — see that constant for why a widget test cannot wait
    // for an isolate.
    final kdf = DartArgon2id(
      parallelism: params.parallelism,
      memory: params.memoryKib,
      iterations: params.iterations,
      hashLength: params.hashLength,
      maxIsolates: KdfTestCost.iterationsForTest == null
          ? maxIsolates
          : testMaxIsolates,
      blocksPerProcessingChunk: blocksPerProcessingChunk,
    );
    final key = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt, // salt
    );
    return key.extractBytes();
  }
}

/// The algorithm tag in the stored [PasswordHash.encode] form.
const String _pbkdf2Sha256Tag = 'pbkdf2-sha256';
const String _argon2idTag = 'argon2id';

/// The Argon2 version field, second of the four `$`-separated parts.
///
/// `Argon2id.version` is `@nonVirtual` and always 19. [PasswordHash.decode]
/// requires exactly this and throws otherwise: a future Argon2 version is not
/// something this code can verify, and guessing is how a login silently returns
/// the wrong answer.
const String _argon2idVersionField = 'v=19';

/// What `AppUser.passwordHash` holds for an account with **no password**.
///
/// A panel account that signs in on its username alone still needs a value in
/// that column — it is `TEXT NOT NULL` — and it must not be one that could ever
/// be confused for a credential. This is that value.
///
/// Three properties, and each is deliberate:
///
///  * **It contains a `$`.** A `$`-less value is a legacy bare-base64 PBKDF2
///    hash ([PasswordHash.decode]), so an empty string or a bare word would be
///    read as a hash of *something* and silently derived against.
///  * **`none` is not a [PasswordHashAlgorithm].** [PasswordHash.decode]
///    therefore throws on it and [PasswordHash.tryDecode] answers null, which
///    the login path already treats as a failed credential. So a caller that
///    forgets to ask [isPasswordless] first **fails the sign-in** rather than
///    letting it through — the safe direction for the one mistake this
///    constant makes possible.
///  * **It is a whole-string match, not a prefix.** There are no parameters to
///    carry and nothing to parse, so there is nothing to get wrong.
///
/// The account's `salt` column is written empty alongside it. Nothing derives
/// against either value.
const String kNoPasswordMarker = r'none$v=1';

/// Whether [storedPasswordHash] is the [kNoPasswordMarker] — the account has no
/// password and signs in on its username alone.
///
/// Ask this **before** decoding. It is a fact about the row, not a credential
/// check, and it is the only thing in this package that answers it.
bool isPasswordless(String storedPasswordHash) =>
    storedPasswordHash == kNoPasswordMarker;

/// Which derivation produced a [PasswordHash].
enum PasswordHashAlgorithm {
  pbkdf2Sha256(_pbkdf2Sha256Tag),
  argon2id(_argon2idTag);

  const PasswordHashAlgorithm(this.tag);

  /// The tag as it appears in the stored value.
  final String tag;
}

/// A derived password hash together with everything needed to re-derive it.
///
/// ## Why the parameters are fields
///
/// The `AppUser` table (access-control spec §2, quoted as final) has
/// `passwordHash` and `salt` and no column for a cost parameter. Rather than
/// add one, the parameters ride inside `passwordHash` in the PHC-ish forms
///
///     pbkdf2-sha256$<iterations>$<hash_b64>
///     argon2id$v=19$m=<KiB>,t=<iters>,p=<lanes>$<hash_b64>
///
/// — see [encode] / [decode]. They have to travel with the hash somehow: a
/// later change to [Pbkdf2Kdf.defaultIterations] or to [Argon2idKdf]'s
/// constants would otherwise lock every existing user out. The self-describing
/// form left room for a second algorithm without another migration, and the
/// `argon2id` tag is that second algorithm.
@immutable
class PasswordHash {
  /// A `pbkdf2-sha256` record.
  ///
  /// Kept as the unnamed constructor, with this shape, so every existing
  /// `const PasswordHash(hashB64:, saltB64:, iterations:)` in the tree keeps
  /// compiling.
  const PasswordHash({
    required String hashB64,
    required String saltB64,
    required int iterations,
  }) : this._(
          algorithm: PasswordHashAlgorithm.pbkdf2Sha256,
          hashB64: hashB64,
          saltB64: saltB64,
          iterations: iterations,
          memoryKib: null,
          parallelism: null,
        );

  /// An `argon2id` record.
  ///
  /// [iterations] carries Argon2's `t` here. The field's name predates the
  /// second algorithm; it is the number of passes, not a PBKDF2 round count.
  const PasswordHash.argon2id({
    required String hashB64,
    required String saltB64,
    required int memoryKib,
    required int iterations,
    required int parallelism,
  }) : this._(
          algorithm: PasswordHashAlgorithm.argon2id,
          hashB64: hashB64,
          saltB64: saltB64,
          iterations: iterations,
          memoryKib: memoryKib,
          parallelism: parallelism,
        );

  const PasswordHash._({
    required this.algorithm,
    required this.hashB64,
    required this.saltB64,
    required this.iterations,
    required this.memoryKib,
    required this.parallelism,
  });

  /// Which derivation produced [hashB64].
  final PasswordHashAlgorithm algorithm;

  /// Base64 of the derived key bytes.
  final String hashB64;

  /// Base64 of the per-user salt. Stored in `AppUser.salt` raw, not prefixed.
  final String saltB64;

  /// The cost this hash was derived at — not necessarily the current one.
  ///
  /// PBKDF2 rounds for [PasswordHashAlgorithm.pbkdf2Sha256], Argon2's `t` for
  /// [PasswordHashAlgorithm.argon2id].
  final int iterations;

  /// Argon2's `m`, in KiB. Null for a PBKDF2 record.
  final int? memoryKib;

  /// Argon2's `p`, the lane count. Null for a PBKDF2 record.
  final int? parallelism;

  /// The value to write into `AppUser.passwordHash`.
  String encode() => switch (algorithm) {
        PasswordHashAlgorithm.pbkdf2Sha256 =>
          '$_pbkdf2Sha256Tag\$$iterations\$$hashB64',
        PasswordHashAlgorithm.argon2id => '$_argon2idTag\$$_argon2idVersionField'
            '\$m=$memoryKib,t=$iterations,p=$parallelism\$$hashB64',
      };

  /// Parse a value read out of `AppUser.passwordHash`.
  ///
  /// [saltB64] comes from the row's separate `salt` column.
  ///
  /// A value with no `$` in it is a legacy bare-base64 hash written before this
  /// encoding existed; it is taken to be PBKDF2 at the ambient default,
  /// [Pbkdf2Kdf.iterations].
  ///
  /// Throws [FormatException] on a prefixed value that is malformed or names an
  /// algorithm this package does not implement. Callers on the login path
  /// should prefer [tryDecode] — a row mangled in `psql` should fail a login,
  /// not crash the app.
  static PasswordHash decode(String stored, {required String saltB64}) {
    if (!stored.contains(r'$')) {
      return PasswordHash(
        hashB64: stored,
        saltB64: saltB64,
        iterations: Pbkdf2Kdf.iterations,
      );
    }
    final parts = stored.split(r'$');
    switch (parts[0]) {
      case _pbkdf2Sha256Tag:
        if (parts.length != 3) {
          throw FormatException('malformed password hash', stored);
        }
        final iterations = int.tryParse(parts[1]);
        if (iterations == null || iterations < 1) {
          throw FormatException('bad iteration count "${parts[1]}"', stored);
        }
        return PasswordHash(
          hashB64: parts[2],
          saltB64: saltB64,
          iterations: iterations,
        );
      case _argon2idTag:
        // Four parts, not three: the version and the parameter group are their
        // own fields.
        if (parts.length != 4) {
          throw FormatException('malformed password hash', stored);
        }
        if (parts[1] != _argon2idVersionField) {
          throw FormatException(
            'unsupported argon2 version "${parts[1]}"',
            stored,
          );
        }
        final group = parts[2].split(',');
        if (group.length != 3) {
          throw FormatException(
            'malformed argon2id parameter group "${parts[2]}"',
            stored,
          );
        }
        return PasswordHash.argon2id(
          hashB64: parts[3],
          saltB64: saltB64,
          memoryKib: _argon2idParam(group[0], 'm', stored),
          iterations: _argon2idParam(group[1], 't', stored),
          parallelism: _argon2idParam(group[2], 'p', stored),
        );
      default:
        throw FormatException(
          'unsupported password hash algorithm "${parts[0]}"',
          stored,
        );
    }
  }

  /// One `<name>=<positive int>` slot of the argon2id parameter group, in the
  /// order the encoding fixes: `m`, then `t`, then `p`.
  static int _argon2idParam(String field, String name, String stored) {
    const separator = '=';
    if (!field.startsWith('$name$separator')) {
      throw FormatException(
        'expected "$name$separator" in the argon2id parameter group, '
        'got "$field"',
        stored,
      );
    }
    final value = int.tryParse(field.substring(name.length + 1));
    if (value == null || value < 1) {
      throw FormatException('bad argon2id parameter "$field"', stored);
    }
    return value;
  }

  /// [decode], returning null instead of throwing.
  static PasswordHash? tryDecode(String stored, {required String saltB64}) {
    try {
      return decode(stored, saltB64: saltB64);
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PasswordHash &&
      other.algorithm == algorithm &&
      other.hashB64 == hashB64 &&
      other.saltB64 == saltB64 &&
      other.iterations == iterations &&
      other.memoryKib == memoryKib &&
      other.parallelism == parallelism;

  @override
  int get hashCode =>
      Object.hash(algorithm, hashB64, saltB64, iterations, memoryKib,
          parallelism);

  /// Deliberately does not print [hashB64]. A hash in a log line is not a
  /// password, but it is not something to scatter through the trail either.
  @override
  String toString() => switch (algorithm) {
        PasswordHashAlgorithm.pbkdf2Sha256 =>
          'PasswordHash($_pbkdf2Sha256Tag, iterations: $iterations)',
        PasswordHashAlgorithm.argon2id => 'PasswordHash($_argon2idTag, '
            'm: $memoryKib, t: $iterations, p: $parallelism)',
      };
}

/// Password hashing for the local auth provider.
///
/// The honest framing, repeated from the package README: this is an operational
/// guardrail against accident, not an access control. Anyone holding the
/// station's Postgres password can rewrite `app_user` directly. What this buys
/// is that a shoulder-surfed screen, a shared workstation or a mistyped
/// username does not hand over somebody else's role.
///
/// New hashes are Argon2id. `pbkdf2-sha256` rows are verified forever — an
/// existing user must never be locked out by the change — and [needsRehash]
/// answers whether a row is due to be rewritten.
abstract final class PasswordHasher {
  static final Random _rng = Random.secure();

  /// Bytes of salt per user. 16 is what `SecureEnvelope` uses and is ample for
  /// uniqueness; the point of the salt is that two users who pick the same
  /// password do not get the same hash.
  static const int saltBytes = 16;

  /// The shortest hash Argon2 will produce. Below this the KDF's own guard is
  /// an `assert`, so a stored row that short has to be rejected here.
  static const int minHashLength = 4;

  static List<int> _rand(int n) =>
      List<int>.generate(n, (_) => _rng.nextInt(256));

  /// Hash [password] with a fresh random salt, at the current Argon2id
  /// parameters.
  static Future<PasswordHash> hash(String password) async {
    // Read once: the parameters that go into the record must be the ones that
    // were actually used, even if the hook is changed mid-run.
    final params = Argon2idKdf.params;
    final salt = _rand(saltBytes);
    final derived = await Argon2idKdf.deriveBytes(
      password: password,
      salt: salt,
      params: params,
    );
    return PasswordHash.argon2id(
      hashB64: base64Encode(derived),
      saltB64: base64Encode(salt),
      memoryKib: params.memoryKib,
      iterations: params.iterations,
      parallelism: params.parallelism,
    );
  }

  /// Re-derive with the salt and parameters [stored] carries, and compare.
  ///
  /// Takes the decoded record rather than four loose values on purpose: with
  /// loose values a caller can hand an Argon2id row's hash and salt to a
  /// function that derives PBKDF2 over them and returns false — a wrong answer
  /// that looks like a wrong password, on the login path. The thing that reads
  /// the tag has to be the thing that does the deriving.
  ///
  /// Derives at the parameters **in the row**, never at the current ones, so a
  /// later change to [Argon2idKdf]'s constants cannot strand a stored hash.
  ///
  /// Returns false for a wrong password, and also for a row that cannot be
  /// decoded or whose parameters are out of range — a hash, salt or cost
  /// mangled by hand in `psql` must fail a login, not take the app down with a
  /// [FormatException] on the login screen. The range checks are real checks
  /// rather than a reliance on `DartArgon2id`'s own guards, which are `assert`s
  /// and do not run in a release AOT build.
  static Future<bool> verify({
    required String password,
    required PasswordHash stored,
  }) async {
    try {
      if (stored.iterations < 1) return false;
      final expected = base64Decode(stored.hashB64);
      final salt = base64Decode(stored.saltB64);
      if (expected.isEmpty || salt.isEmpty) return false;

      final List<int> derived;
      switch (stored.algorithm) {
        case PasswordHashAlgorithm.pbkdf2Sha256:
          final key = await Pbkdf2Kdf.deriveKey(
            passphrase: password,
            salt: salt,
            iterations: stored.iterations,
            bits: 256,
          );
          derived = await key.extractBytes();
        case PasswordHashAlgorithm.argon2id:
          final memoryKib = stored.memoryKib;
          final parallelism = stored.parallelism;
          if (memoryKib == null || parallelism == null) return false;
          if (parallelism < 1) return false;
          if (memoryKib < Argon2idKdf.minMemoryKibPerLane * parallelism) {
            return false;
          }
          // The hash length is not in the stored form; the hash itself is the
          // record of it, which is what keeps a width change from stranding
          // rows the way a parameter change would.
          if (expected.length < minHashLength) return false;
          derived = await Argon2idKdf.deriveBytes(
            password: password,
            salt: salt,
            params: (
              memoryKib: memoryKib,
              iterations: stored.iterations,
              parallelism: parallelism,
              hashLength: expected.length,
            ),
          );
      }
      return constantTimeEquals(derived, expected);
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  /// Whether [stored] is due to be rewritten at the current parameters.
  ///
  /// The single place that answers "is this row stale", so the login path can
  /// ask rather than re-derive the rule. True for every `pbkdf2-sha256` row —
  /// those are the migration — and for an `argon2id` row whose `m`, `t` or `p`
  /// differ from [Argon2idKdf.params].
  ///
  /// Deliberately ignores [Argon2idKdf.maxIsolates] and
  /// [Argon2idKdf.blocksPerProcessingChunk]: they change what it costs to
  /// compute the hash, not the hash, so moving either must not trigger a
  /// rewrite of every row in the table.
  static bool needsRehash(PasswordHash stored) {
    if (stored.algorithm != PasswordHashAlgorithm.argon2id) return true;
    final current = Argon2idKdf.params;
    return stored.memoryKib != current.memoryKib ||
        stored.iterations != current.iterations ||
        stored.parallelism != current.parallelism;
  }

  /// Compare two byte lists without returning early on the first mismatch.
  ///
  /// Defence in depth on a guardrail, not a security boundary: the whole scheme
  /// is bypassed by anyone with `psql`, and a remote attacker cannot time this
  /// through an HMI login form anyway. But a timing-leaky compare is free to
  /// avoid, and writing the obvious `==` here is the kind of thing that gets
  /// copied into somewhere it does matter.
  ///
  /// The length check does return early. Lengths are not secret — the hash is
  /// always 32 bytes — and there is nothing to compare against otherwise.
  @visibleForTesting
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
