/// The real credential check behind the Phase 3 seam: a mounted JSON file
/// naming each station, the account it authenticates as and **the name of the
/// role it holds** — plus the two operations a revocation needs.
///
/// **The file, and why it is keyed by token.**
/// `{"tokens": {"<token>": {"username": "...", "station": "...",
/// "role": "..."}}}`. Keyed by the credential rather than by the station so a
/// hello is answered by one lookup instead of a scan that compares every secret
/// in the file against the presented one — a loop whose *length* is a function
/// of how early the match is found.
///
/// **`role` is a role NAME, and the file grants nothing.** D-06, ruled by Jón
/// on 2026-09-07. The name is matched against `app_role.name` — the same string
/// `AuthenticatedUser.roleName` carries and `AccessSession.roleName` reports —
/// and the groups behind it come from the database through the [GroupResolver]
/// seam, never from the file. Phase 17's constitution is *"one master access
/// control system, the websocket can build on top of that"*: the credential
/// mechanism may answer **which identity is this**, and the moment it answers
/// *"and therefore may do X"* it has crossed into the master system's
/// territory. `file_token_validator_test.dart` pins that by grepping this
/// file's source for the seven `AccessGroup` names and requiring zero.
///
/// **What is actually held in memory is a digest, not a credential.** The
/// parsed map is keyed by the SHA-256 of each token, so this object can be
/// dumped, inspected in a debugger or serialised by accident without
/// publishing the plant's keys. It also makes the lookup honest: the `==`
/// inside `Map` compares *digests*, which are fixed-length and preimage
/// resistant, and the confirmation that follows is
/// [_constantTimeEquals] over two 32-byte buffers. A Dart `String` `==` short
/// circuits on the first differing code unit and this is the one place in
/// this codebase where that is worth caring about (T-06-28).
///
/// **Five classes of bad file are refused at load, and a load failure fails
/// `RelayServer.start()`:**
///
///  1. a file that is missing, unreadable, or readable by group or other —
///     a `FileSystemException`, because the *mounting* is wrong;
///  2. a file whose JSON, whose `tokens` object or whose entry shape is wrong,
///     including a file still using the pre-Phase-17 `stationId` key;
///  3. a token below [FileTokenValidator.minTokenLength];
///  4. two tokens naming one station, which makes a revocation ambiguous;
///  5. **a `role` that names a permission rather than a role** — the fifth,
///     added by this phase. See [_refuseRoleThatNamesAPermission].
///
/// There is deliberately no permissive fallback, for the same reason a
/// misspelled PEM has none (`server_config.dart:169-175`): a gateway that
/// admitted every panel because somebody fat-fingered a path would look
/// perfectly healthy from every screen in the plant. The same argument is why
/// [FileTokenValidator.load] throws when no [GroupResolver] is wired.
///
/// **One class of refusal moved.** An unknown role used to be refused at
/// *load*, because the two legal values were compiled in. A role name is
/// database data, so it cannot be checked against the file alone: it is now
/// refused at `hello`, through the resolver, and distinguishably from the
/// database being unreachable.
///
/// Without this file SEC-03 has a seam and nothing behind it — any peer that
/// can reach the port is a panel, and pulling a station's token off the disk
/// changes nothing about the session it already has.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show SHA256Digest;
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../token_validator.dart';
import 'identity.dart';

/// Resolves a role **name** to the groups that role holds, or null when no such
/// role exists.
///
/// The seam D-06 declares and 17-11 fills from `AccessRepository`. It is the
/// one place the relay learns what a station may do, and it points at the
/// database rather than at the file.
///
/// **Synchronous, and for the same reason `KeyPolicy` is.** An `await` on this
/// path is an `await` on the hello path, and `TokenValidator.validate`'s doc
/// spells out what that costs: `RelayServer.reloadTokens` awaits the credential
/// set's reload and then sweeps the sessions that already carry an identity,
/// which is safe today only because `validate` contains no `await`. A validator
/// that awaited real work would let a hello resolve against the pre-reload
/// credential set while the sweep runs past a session whose identity is still
/// null — and that session would then hold a revoked identity for the life of
/// its socket.
///
/// The roles are a handful of rows and cache trivially. The implementation is
/// expected to answer from memory and to be refreshed by the same reload that
/// refreshes the token set (17-11 hangs both off `PreferencesWatcher`'s
/// existing LISTEN/NOTIFY tick). **"Make it async" is the obvious next edit and
/// it is the wrong one.**
///
/// A `throw` means *the role source is unreachable*, which is a different
/// answer from null and is treated differently — see
/// [FileTokenValidator.validate] and [FileTokenValidator.stillValid].
typedef GroupResolver = Set<AccessGroup>? Function(String roleName);

/// A [TokenValidator] whose answers can change while the gateway is running.
///
/// A **second interface** rather than two more members on [TokenValidator],
/// so `PermissiveTokenValidator` and every test stand-in in this workspace —
/// `session_hello_test.dart`'s `_RejectingValidator` among them — are
/// untouched by revocation existing. `RelayServer.reloadTokens` type-tests for
/// this and throws when the live validator is not one, rather than no-opping:
/// a deployment that believes rotation works and has it silently do nothing is
/// worse off than one that is told at the first attempt.
abstract interface class RevocableTokenValidator implements TokenValidator {
  /// Re-reads the credential set from wherever it lives. Throws exactly what
  /// the initial load throws, and on a throw the previously loaded set is
  /// **kept** — a rotation that produced a broken file must not disconnect the
  /// plant.
  Future<void> reload();

  /// Whether the credential a live session authenticated with still buys
  /// [identity].
  ///
  /// False in all five ways a credential stops being valid:
  ///
  ///  * the station's token is **gone**;
  ///  * it now maps to a **different station**, or a different account;
  ///  * the station's **role name has changed** — a demotion that only took
  ///    effect on the next reconnect would be a demotion an operator could
  ///    postpone indefinitely by not reconnecting;
  ///  * the **groups behind that role name have changed** — the fifth, added
  ///    by Phase 17. The role set is part of the credential now, so the sweep
  ///    must see a change made in the *database* and not only one made in the
  ///    file. It matters more than it used to: after this phase a role name
  ///    decides `configure` and `administer` as well as the old flat write
  ///    permission;
  ///  * the token has been **replaced**, which is the remediation a leaked
  ///    credential actually gets. Nothing about the station's
  ///    [StationIdentity] changes when an operator mints a new secret for it,
  ///    so this is the case an identity comparison structurally cannot see,
  ///    and it is the primary incident's primary fix.
  ///
  /// [credentialDigest] is [TokenAccepted.credentialDigest] as recorded on the
  /// session. It is nullable rather than required because a session may have
  /// been authenticated by a validator that produced none, in which case the
  /// answer necessarily falls back to what the file says about the station —
  /// which cannot distinguish a replacement from a re-save.
  bool stillValid(StationIdentity identity, Uint8List? credentialDigest);
}

/// Reads per-station tokens from a mounted JSON file.
final class FileTokenValidator implements RevocableTokenValidator {
  FileTokenValidator._(this.path, this._groups, this._set);

  /// The role name a station that used to be `"operate"` should now hold.
  ///
  /// Named here, and printed in the refusal, because the message this file
  /// produces on a legacy token file is what somebody reads at three in the
  /// morning while a plant is not starting. "That value is no longer allowed"
  /// leaves them guessing; naming the row to create does not.
  ///
  /// These are role **names**, not permissions — that is the entire point of
  /// the change — so they are safe to spell here. 17-11 seeds both rows in
  /// `app_role` by migration if they are absent.
  static const String replacementPanelRoleName = 'Station Panel';

  /// The role name a station that used to be `"view"` should now hold.
  static const String replacementDisplayRoleName = 'Station Display';

  /// The phrase that marks a refusal as *the role source could not be reached*,
  /// as distinct from *no such role*.
  ///
  /// A constant rather than a literal in one message, because the property that
  /// matters is that the two refusals are **distinguishable**: an operator who
  /// cannot connect must be able to tell "your role was deleted" from "the
  /// database is down". One of those is fixed by editing `app_role` and the
  /// other by looking at Postgres, and a single message sends the wrong person
  /// to the wrong place.
  static const String roleSourceDownMarker = 'the role source is unreachable';

  /// The shortest token this gateway will load.
  ///
  /// 24 characters of the alphabet a provisioning script produces is well past
  /// anything an online guessing attack reaches through a WebSocket handshake,
  /// and short enough that nobody is tempted to shorten it further. The floor
  /// is enforced at *load*, not at hello: the operator who typed a four-letter
  /// token finds out when the gateway refuses to start, standing next to it,
  /// rather than never.
  static const int minTokenLength = 24;

  /// The file this validator was loaded from, re-read by [reload].
  final String path;

  /// Where the groups behind a role name come from. See [GroupResolver].
  final GroupResolver _groups;

  _TokenSet _set;

  /// Reads and validates [path], or throws.
  ///
  /// Async because it is I/O and because `RelayServer.start()` — the only
  /// production caller — is already async. Refusals are [FormatException] for
  /// a file whose *contents* are wrong and [FileSystemException] for one whose
  /// *mounting* is wrong, so a deployment can tell "fix the JSON" from "fix
  /// the mount" without reading the message.
  ///
  /// **[groups] is nominally optional and actually required.** Omitting it
  /// throws an [ArgumentError] before a byte is read, on this file's own stated
  /// reasoning about a misspelled PEM: a gateway that admitted every panel
  /// because nobody wired the role source would look perfectly healthy from
  /// every screen in the plant. It is a named parameter with a throw rather
  /// than a `required` one so that the failure is a *runtime* refusal an
  /// embedder is told about at start-up, which is where D-06's "no
  /// `GroupResolver` wired → `RelayServer.start()` throws" lands.
  static Future<FileTokenValidator> load(String path,
      {GroupResolver? groups}) async {
    if (groups == null) {
      throw ArgumentError.value(
          null,
          'groups',
          'the token file names role NAMES; with no GroupResolver this gateway '
              'cannot learn what any of them means, and a station admitted '
              'without one would be a station nobody graded');
    }
    return FileTokenValidator._(path, groups, await _read(path));
  }

  @override
  Future<void> reload() async => _set = await _read(path);

  /// Re-reads only when the file's bytes changed, and reports whether they
  /// did.
  ///
  /// The digest-not-content discipline `preferences_watch.dart:19-25` already
  /// uses on the backend: a config watch fires on every notification, and a
  /// re-save of an identical file must cost nothing. Without this, a `NOTIFY`
  /// storm would re-parse the file and — because `reloadTokens` sweeps after
  /// every reload — walk the whole registry each time.
  ///
  /// Deliberately **not** on [RevocableTokenValidator]: an in-memory
  /// implementation has no digest to compare, and an interface member that
  /// only one implementation can mean is an interface member that gets
  /// implemented as `=> true`.
  Future<bool> reloadIfChanged() async {
    final next = await _read(path);
    if (_hex(next.digest) == _hex(_set.digest)) return false;
    _set = next;
    return true;
  }

  /// Whether the credential this session presented still buys the identity it
  /// is carrying.
  ///
  /// **The digest is the question, and the row is only half of it.**
  /// Asking `byStation[station] == …` answers "is this station still entitled
  /// to this", which is true of a station whose token was replaced — and a
  /// replacement is what a leaked credential is remediated with. Looking the
  /// *digest* up and then comparing what it buys subsumes four of the five
  /// cases at once: a removed token is not in the map, a renamed or re-roled
  /// station resolves to a different row, and a replaced token is not in the
  /// map either, because the digest of the credential the session is holding
  /// is not the digest of the one the file now carries.
  ///
  /// The fifth case is not in the file at all. The role **name** can be
  /// unchanged while the groups behind it have been edited in `app_role`, so
  /// the resolver is asked again and the answer compared against what the
  /// session is carrying.
  ///
  /// **An unreachable role source answers "no evidence of a change", not
  /// "revoked", and the asymmetry with [validate] is deliberate.** Refusing at
  /// `hello` is safe: it runs once, the operator is told, and nothing that was
  /// running stops. This runs on a poll against every live session, so
  /// answering "revoked" when Postgres blinks would close every screen in the
  /// plant for the length of a network hiccup. It is the same trade
  /// `AccessPolicy.groupForTag`'s deliberate swallow already makes on the write
  /// path of every jog, and for the same reason.
  ///
  /// A session with no digest falls back to the station comparison. That is
  /// the honest answer for a validator that produced none rather than a
  /// pretence of one.
  @override
  bool stillValid(StationIdentity identity, Uint8List? credentialDigest) {
    final row = credentialDigest == null
        ? _set.byStation[identity.station]
        : _set.entryFor(credentialDigest)?.row;
    if (row == null) return false;
    if (row.username != identity.user.username) return false;
    if (row.station != identity.station) return false;
    if (row.roleName != identity.user.roleName) return false;

    final Set<AccessGroup>? groups;
    try {
      groups = _groups(row.roleName);
    } on Object {
      // See the doc above: unreadable is not the same as revoked, and this one
      // runs against every live session.
      return true;
    }
    // A role deleted out from under a live session is a revocation, and it is
    // the one an operator performs when they mean it.
    if (groups == null) return false;
    return _sameGroups(groups, identity.session.groups);
  }

  @override
  Future<TokenVerdict> validate(HelloParams params) async {
    final token = params.token;
    // Note what is *not* in any of these reasons. The client did send the
    // credential, which is exactly why `TokenRejected`'s "nothing the client
    // did not already send" rule is not enough on its own: the reason travels
    // into a `-32003` message, into the gateway's log and into whatever the
    // operator's screen makes of both (T-06-26).
    if (token == null || token.isEmpty) {
      // NB: this message, and every other string literal in this file, is
      // written around the seven AccessGroup names — the pin in
      // `file_token_validator_test.dart` is a plain substring grep and
      // deliberately so, which means ordinary English words that contain a
      // group name are out of bounds here too. That is a cheap constraint and
      // an unarguable pin; a word-boundary regex would be neither.
      return const TokenRejected('no credential presented on hello; this '
          'gateway reads a token file, and every station needs its own token '
          'mounted beside it');
    }
    final entry = _set.lookup(token);
    if (entry == null) {
      // Deliberately before the resolver is asked: a credential this gateway
      // does not carry never becomes a round trip to the role source, so a
      // miss cannot be timed against a hit and an unknown token cannot be used
      // to make the database work.
      return const TokenRejected('the credential presented is not in this '
          'gateway\'s token file; it was removed, or this panel was '
          'provisioned against another gateway');
    }

    final row = entry.row;
    final Set<AccessGroup>? groups;
    try {
      groups = _groups(row.roleName);
    } on Object {
      // The opposite of `AccessPolicy.groupForTag`'s swallow, and deliberately
      // so: that one runs on the write path of every jog and must not take the
      // plant down. This one runs once, at connect, where refusing is the safe
      // answer and the operator is told which of the two things went wrong.
      return TokenRejected('station ${row.station} holds the role '
          '"${row.roleName}" and $roleSourceDownMarker, so this gateway cannot '
          'tell what that role may do. A session admitted now would be a '
          'session nobody graded');
    }
    if (groups == null) {
      // **Not** an identity with an empty group set. An empty set is
      // indistinguishable in the audit trail from a role that loaded
      // successfully and grants nothing, and those two must not look the same
      // (D-06, fail-closed).
      return TokenRejected('station ${row.station} names the role '
          '"${row.roleName}", and this gateway\'s role source has no such '
          'role. Create it, or point the station\'s token file at a role that '
          'exists — it is not admitted with nothing, because a station that '
          'was granted nothing on purpose must not look the same as one whose '
          'role was deleted');
    }

    final user = AuthenticatedUser(
      username: row.username,
      roleName: row.roleName,
      stationAccount: true,
    );
    // The digest, not the token: what the session records beside its identity
    // is what lets a later sweep tell "still this station" from "still this
    // credential". See [TokenAccepted.credentialDigest].
    return TokenAccepted(
      StationIdentity(
        user: user,
        station: row.station,
        session: AccessSession(user: user, groups: groups),
      ),
      credentialDigest: entry.digest,
    );
  }

  static Future<_TokenSet> _read(String path) async {
    final file = File(path);
    // `stat` before `read`: a world-readable credential file has already
    // leaked, and reading it into this process first does not make that
    // better, but refusing before the bytes are in memory keeps the failure
    // path from being the one that loads them.
    _refuseLoosePermissions(file);
    final bytes = await file.readAsBytes();
    final text = utf8.decode(bytes);

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw FormatException('the token file $path is not valid JSON: '
          '${error.message}');
    }
    if (decoded is! Map || decoded['tokens'] is! Map) {
      throw FormatException('the token file $path has no "tokens" object; the '
          'shape is {"tokens": {"<token>": {"username": "...", '
          '"station": "...", "role": "<a role name>"}}}');
    }

    final byDigest = <String, _Entry>{};
    final byStation = <String, _TokenRow>{};
    (decoded['tokens'] as Map).forEach((rawToken, rawEntry) {
      if (rawToken is! String || rawEntry is! Map) {
        throw FormatException('the token file $path has an entry that is not '
            'a token mapped to an object');
      }
      _refuseTheLegacyEntryShape(rawEntry, path);

      final station = rawEntry['station'];
      if (station is! String || station.isEmpty) {
        throw FormatException('the token file $path has an entry with no '
            'station; every token names the station it belongs to, and the '
            'station is what a revocation is about');
      }
      final username = rawEntry['username'];
      if (username is! String || username.isEmpty) {
        throw FormatException('station $station in $path has no username. It '
            'is what an audit row\'s "who" column records, and a write nobody '
            'can attribute is a write the trail cannot answer for');
      }
      if (rawToken.length < minTokenLength) {
        // Names the station, never the token: this message reaches a log and
        // a support ticket.
        throw FormatException('the token for station $station in $path is '
            '${rawToken.length} characters; the floor is $minTokenLength. A '
            'short credential is a guessable one, and a gateway on a plant '
            'LAN answers guesses all day');
      }
      final roleName = rawEntry['role'];
      if (roleName is! String || roleName.isEmpty) {
        throw FormatException('station $station in $path names no role. The '
            'role is a name matched against the access database, not a '
            'permission, and a station with none is a station this gateway '
            'cannot grade');
      }
      _refuseRoleThatNamesAPermission(roleName, station, path);

      final row = _TokenRow(username, station, roleName);
      final clash = byStation[station];
      if (clash != null) {
        throw FormatException('two tokens in $path both name station '
            '$station. One station, one credential: with two, pulling one '
            'of them revokes nothing and the sweep cannot tell which live '
            'session lost its access');
      }
      byStation[station] = row;
      final digest = _sha256(utf8.encode(rawToken));
      byDigest[_hex(digest)] = _Entry(digest, row);
    });

    return _TokenSet(byDigest, byStation, _sha256(bytes));
  }

  /// Refuses a file still written in the pre-Phase-17 shape.
  ///
  /// A half-migrated file is the dangerous one. `stationId` with a new role
  /// name would otherwise load as an entry with no station at all, and the
  /// operator holding this file is the one who has to rewrite it — so the
  /// message says which keys moved rather than which key is missing.
  static void _refuseTheLegacyEntryShape(Map<Object?, Object?> entry,
      String path) {
    if (!entry.containsKey('stationId')) return;
    throw FormatException('the token file $path is still written in the '
        'pre-Phase-17 shape: an entry carries "stationId". Every entry is now '
        '{"username": "...", "station": "...", "role": "<a role name>"} — '
        '"stationId" became "station", "username" is new and is what an audit '
        'row records, and "role" is now the NAME of a role in the access '
        'database rather than a permission this gateway compiles in');
  }

  /// Refuses a `role` value that names a permission rather than a role.
  ///
  /// **The fifth class of bad file, and the one this phase adds.** D-06, ruled
  /// 2026-09-07 with the deployment cost accepted: a Phase 17 gateway refuses
  /// to start on a legacy token file rather than translating it. Silently
  /// mapping the old `"operate"` onto a group set would let a legacy grant
  /// survive unexamined, which is the duplication this phase exists to delete,
  /// only with a longer half-life.
  ///
  /// **The test is "is this a permission", not "is this one of the two old
  /// values"**, and that is deliberately broader than the migration needs. The
  /// two legacy values were a permission vocabulary; so is every other
  /// [AccessGroup] name. After this change a role value is looked up in the
  /// database, so a deployment that created a role row named after a group
  /// would have a token file granting that group *by spelling* — the exact
  /// thing the format change removed. Asking [AccessGroup.byName] closes all
  /// seven at once and, not incidentally, keeps this file free of the group
  /// vocabulary that `file_token_validator_test.dart` greps it for.
  ///
  /// The other legacy value was not a permission and is named here as data.
  static void _refuseRoleThatNamesAPermission(
      String roleName, String station, String path) {
    if (AccessGroup.byName(roleName) == null &&
        roleName != _legacyReadOnlyRoleValue) {
      return;
    }
    throw FormatException('station $station in $path has role "$roleName", '
        'which is a permission and not the name of a role. The token file '
        'names WHICH IDENTITY a station is and grants nothing: "role" is '
        'matched against a row in the access database, and what that role may '
        'do is decided there. Write "$replacementPanelRoleName" for a panel '
        'that actuates, or "$replacementDisplayRoleName" for a screen that '
        'only reads, and make sure that role exists. This gateway will not '
        'translate the old value for you, because a grant nobody re-examined '
        'is exactly what this refusal is for');
  }

  static void _refuseLoosePermissions(File file) {
    if (Platform.isWindows) return;
    final stat = file.statSync();
    if (stat.type == FileSystemEntityType.notFound) {
      throw FileSystemException(
          'the token file is not there. There is no permissive fallback: a '
          'gateway that admitted every panel because a path was misspelled '
          'would look healthy from every screen in the plant',
          file.path);
    }
    // 0o077 — any group or other bit.
    if (stat.mode & 0x3F != 0) {
      throw FileSystemException(
          'the token file is readable by group or other (mode '
          '${(stat.mode & 0x1FF).toRadixString(8).padLeft(3, '0')}); it must '
          'be 0600 and owned by the gateway. This file is the plant\'s keys, '
          'and a file every account on the machine can read is a credential '
          'set every account on the machine has',
          file.path);
    }
  }
}

/// One loaded credential set: the lookup, the station index, and the digest of
/// the bytes it came from.
final class _TokenSet {
  const _TokenSet(this._byDigest, this.byStation, this.digest);

  /// SHA-256 hex of a token → what that token buys, and the digest bytes
  /// themselves. See the library doc on why the plaintext credential is not a
  /// key here.
  final Map<String, _Entry> _byDigest;

  /// Station → the row that names it, which is what
  /// [FileTokenValidator.stillValid] falls back to when a session carries no
  /// digest. Also what makes a duplicate station detectable at load.
  final Map<String, _TokenRow> byStation;

  /// The digest of the whole file, for [FileTokenValidator.reloadIfChanged].
  final Uint8List digest;

  /// The presented [token] resolved to the row it matches, or null.
  ///
  /// Two steps on purpose. The map lookup is O(1) and its internal `==`
  /// compares digests rather than secrets; the [_constantTimeEquals] that
  /// follows is the actual credential comparison, over two buffers that are
  /// 32 bytes long whatever the token was. Anyone replacing the second step
  /// with `a == b` re-introduces the early-exit compare the first step was
  /// arranged to avoid — `auth_test.dart` greps this file for exactly that.
  ///
  /// The whole row rather than just the identity, because the caller needs the
  /// digest too: it is what travels onto the session and what makes a
  /// *replaced* token detectable.
  _Entry? lookup(String token) {
    final presented = _sha256(utf8.encode(token));
    final entry = _byDigest[_hex(presented)];
    if (entry == null) return null;
    if (!_constantTimeEquals(entry.digest, presented)) return null;
    return entry;
  }

  /// The row [digest] names, or null when no loaded credential hashes to it.
  ///
  /// No constant-time step here and none needed: the argument is a digest this
  /// gateway itself produced and has been holding since the handshake, not
  /// something a peer just presented, so there is nobody on the other end of
  /// the timing.
  _Entry? entryFor(Uint8List digest) => _byDigest[_hex(digest)];
}

/// One row of the loaded file: the digest the credential hashes to, and what
/// the file says about the station that presents it.
final class _Entry {
  const _Entry(this.digest, this.row);

  /// The stored SHA-256 of the token, kept as bytes so the confirmation in
  /// [_TokenSet.lookup] compares two real buffers rather than re-deriving one
  /// from the other — a comparison of a value against itself is constant time
  /// and proves nothing.
  final Uint8List digest;

  final _TokenRow row;
}

/// What the file says, and only what the file says.
///
/// Three strings, and **no groups** — that is the type-level statement of D-06.
/// The row cannot carry a permission because there is nowhere in it to put one,
/// which is the same structural argument [StationIdentity] makes about
/// credentials. Turning a row into an identity requires the [GroupResolver],
/// and that is the only path.
final class _TokenRow {
  const _TokenRow(this.username, this.station, this.roleName);

  /// What an audit row's `who` column records.
  final String username;

  /// What its `station` column records.
  final String station;

  /// The name matched against `app_role.name`. Never a permission — see
  /// [FileTokenValidator._refuseRoleThatNamesAPermission].
  final String roleName;
}

/// The one legacy `role` value that was not also a permission name.
///
/// Its sibling, the actuating one, needs no constant: it *is* an
/// [AccessGroup] name, so [AccessGroup.byName] already catches it — which is
/// how this file refuses both legacy values while naming neither of the seven
/// groups. See [FileTokenValidator._refuseRoleThatNamesAPermission].
const String _legacyReadOnlyRoleValue = 'view';

/// Whether two group sets hold the same members.
///
/// Hand-written rather than `package:collection`'s `SetEquality` so this
/// package's dependency list does not grow a direct edge for four lines. The
/// sets are at most seven elements.
bool _sameGroups(Set<AccessGroup> a, Set<AccessGroup> b) =>
    a.length == b.length && a.every(b.contains);

/// Whether two fixed-length buffers are equal, in time that does not depend on
/// where they first differ.
///
/// Not a hand-rolled primitive — the hash is `package:pointycastle`'s, already
/// a direct dependency of this package for the certificate work (T-06-SC: this
/// plan installs nothing). What is hand-written is the comparison itself,
/// which is the one thing a library cannot be asked for here: `==` on `String`
/// and on `List<int>` both return the moment they find a difference, and the
/// moment they return is the side channel.
///
/// The length check is outside the accumulator on purpose: the inputs are
/// always digests of the same algorithm, so a length mismatch is a programming
/// error rather than an attacker's probe, and folding it into the loop would
/// only make that bug harder to read.
bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

Uint8List _sha256(List<int> bytes) =>
    SHA256Digest().process(Uint8List.fromList(bytes));

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
