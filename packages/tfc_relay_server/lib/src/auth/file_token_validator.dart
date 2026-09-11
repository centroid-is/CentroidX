/// The real credential check behind the Phase 3 seam: a mounted JSON file
/// naming each station and **the account it authenticates as** — plus the two
/// operations a revocation needs.
///
/// **The file, and why it is keyed by token.**
/// `{"tokens": {"<token>": {"username": "...", "station": "..."}}}`. Keyed by
/// the credential rather than by the station so a hello is answered by one
/// lookup instead of a scan that compares every secret in the file against the
/// presented one — a loop whose *length* is a function of how early the match
/// is found.
///
/// **The token names a USER, and the file grants nothing — not even a role
/// name.** D-06 as ruled, redirected by Jón on 2026-09-07: *"we will use a
/// user for a station"*. Each panel PC gets an `app_user` row; the entry's
/// `username` is matched against that row through the [UserResolver] seam,
/// the row carries the role, and the role carries the groups. The whole
/// user → role → groups chain is the database's answer at the moment of a
/// hello, so the file carries zero authorisation content: it is purely a
/// credential naming an identity. Phase 17's constitution is *"one master
/// access control system, the websocket can build on top of that"*: the
/// credential mechanism may answer **which identity is this**, and the moment
/// it says anything more it has crossed into the master system's territory.
/// `file_token_validator_test.dart` pins that twice — the seven `AccessGroup`
/// names appear nowhere in this file's stripped source, and neither does a
/// role name.
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
/// **Six classes of bad file are refused at load, and a load failure fails
/// `RelayServer.start()`:**
///
///  1. a file that is missing, unreadable, or readable by group or other —
///     a `FileSystemException`, because the *mounting* is wrong;
///  2. a file whose JSON, whose `tokens` object or whose entry shape is wrong,
///     including a file still using the pre-Phase-17 `stationId` key;
///  3. a token below [FileTokenValidator.minTokenLength];
///  4. two tokens naming one station, which makes a revocation ambiguous;
///  5. **an entry that still carries a `role` key** — whatever its value.
///     The legacy `"view"`/`"operate"` grants and 17-04's interim role-name
///     format are refused by the same rule, because the offence is the same:
///     the file saying anything about authorisation. See
///     [_refuseAnEntryThatCarriesARole];
///  6. two entries authenticating as one account — added with the redirect,
///     because "a user for a station" is one each way. See the duplicate
///     username refusal in [_read].
///
/// There is deliberately no permissive fallback, for the same reason a
/// misspelled PEM has none (`server_config.dart:169-175`): a gateway that
/// admitted every panel because somebody fat-fingered a path would look
/// perfectly healthy from every screen in the plant. The same argument is why
/// [FileTokenValidator.load] throws when no [UserResolver] is wired.
///
/// **One class of refusal lives at `hello`, not at load.** Whether the named
/// account exists — and whether it is marked as a station account — is
/// database data, so it cannot be checked against the file alone: it is
/// refused at `hello`, through the resolver, distinguishably from the
/// database being unreachable and from the account belonging to a person.
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

/// What the user source answered for a username: the verified account row and
/// the groups its role currently holds.
///
/// Two fields on purpose, and both are the database's words rather than the
/// file's. [user] is the `app_user` row as an [AuthenticatedUser] — its
/// `roleName` and `stationAccount` came off the row, which is what makes a
/// gateway-mode audit entry honest (ACCESS-06): the identity a relay write is
/// attributed to is one the **server** resolved, not one the file claimed.
/// [groups] is what that row's role grants at this moment, already chased
/// through `app_role` so the relay never learns the chain's middle.
final class ResolvedUser {
  const ResolvedUser({required this.user, required this.groups});

  /// The account row, verbatim. `stationAccount` is the row's marking, not a
  /// constant — [FileTokenValidator.validate] refuses an account that is not
  /// marked as a station rather than overriding the flag.
  final AuthenticatedUser user;

  /// What the account's role grants, resolved through the database.
  final Set<AccessGroup> groups;
}

/// Resolves a **username** to the account it names and the groups behind it,
/// or null when no such account exists.
///
/// The seam the redirect declares and 17-11 fills from `AccessRepository`:
/// one lookup, the whole user → role → groups chain. It is the only place the
/// relay learns who a station is or what it may do, and it points at the
/// database rather than at the file. **17-11's seed changes with it: not two
/// roles, but one `app_user` row per station — its role set on the row — by
/// migration if absent.**
///
/// **Synchronous, and for the same reason `KeyPolicy` is.** An `await` on this
/// path is an `await` on the hello path, and `TokenValidator.validate`'s doc
/// spells out what that costs: `RelayServer.reloadTokens` awaits the credential
/// set's reload and then sweeps the sessions that already carry an identity,
/// which is safe today only because `FileTokenValidator.validate` contains no
/// `await`. A validator that awaited real work would let a hello resolve
/// against the pre-reload credential set while the sweep runs past a session
/// whose identity is still null — and that session would then hold a revoked
/// identity for the life of its socket.
///
/// The accounts and roles are a handful of rows and cache trivially. The
/// implementation is expected to answer from memory and to be refreshed by the
/// same reload that refreshes the token set (17-11 hangs both off
/// `PreferencesWatcher`'s existing LISTEN/NOTIFY tick). **"Make it async" is
/// the obvious next edit and it is the wrong one.** Note too that
/// [FileTokenValidator.stillValid] calls this on **every invocation** against
/// every live session — a resolver that hit Postgres per call would make one
/// sweep tick `N` queries for `N` sessions.
///
/// A `throw` means *the user source is unreachable*, which is a different
/// answer from null and is treated differently — see
/// [FileTokenValidator.validate] and [FileTokenValidator.stillValid].
typedef UserResolver = ResolvedUser? Function(String username);

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
  /// False in all six ways a credential stops being valid — and note that
  /// four of the six are the **database's** to perform, with the file
  /// untouched:
  ///
  ///  * the station's token is **gone** from the file;
  ///  * it now maps to a **different station**, or a different account name;
  ///  * the account has been **deleted** — under the user model this is the
  ///    revocation an operator most naturally performs, and it never visits
  ///    the token file;
  ///  * the account **changed**: its role was swapped, or its station-account
  ///    marking was removed. A demotion that only took effect on the next
  ///    reconnect would be a demotion an operator could postpone indefinitely
  ///    by not reconnecting;
  ///  * the **groups behind the account's role have changed** — same account,
  ///    same role name, a group unticked on the role. It matters more than it
  ///    used to: after this phase a role decides `configure` and `administer`
  ///    as well as the old flat write permission;
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
  FileTokenValidator._(this.path, this._accounts, this._set);

  /// The phrase that marks a refusal as *the user source could not be
  /// reached*, as distinct from *no such account*.
  ///
  /// A constant rather than a literal in one message, because the property
  /// that matters is that the refusals are **distinguishable**: an operator
  /// who cannot connect must be able to tell "your account was deleted" from
  /// "the database is down". One of those is fixed by editing `app_user` and
  /// the other by looking at Postgres, and a single message sends the wrong
  /// person to the wrong place.
  static const String userSourceDownMarker = 'the user source is unreachable';

  /// The shortest token this gateway will load.
  ///
  /// 24 characters of the alphabet a provisioning script produces is well past
  /// anything an online guessing attack reaches through a WebSocket handshake,
  /// and short enough that nobody is tempted to shorten it further. The floor
  /// is checked at *load*, not at hello: the operator who typed a four-letter
  /// token finds out when the gateway refuses to start, standing next to it,
  /// rather than never.
  static const int minTokenLength = 24;

  /// The file this validator was loaded from, re-read by [reload].
  final String path;

  /// Where a username becomes an account and its groups. See [UserResolver].
  final UserResolver _accounts;

  _TokenSet _set;

  /// Reads and validates [path], or throws.
  ///
  /// Async because it is I/O and because `RelayServer.start()` — the only
  /// production caller — is already async. Refusals are [FormatException] for
  /// a file whose *contents* are wrong and [FileSystemException] for one whose
  /// *mounting* is wrong, so a deployment can tell "fix the JSON" from "fix
  /// the mount" without reading the message.
  ///
  /// **[accounts] is nominally optional and actually required.** Omitting it
  /// throws an [ArgumentError] before a byte is read, on this file's own
  /// stated reasoning about a misspelled PEM: a gateway that admitted every
  /// panel because nobody wired the user source would look perfectly healthy
  /// from every screen in the plant. It is a named parameter with a throw
  /// rather than a `required` one so that the failure is a *runtime* refusal
  /// an embedder is told about at start-up, which is where D-06's "nothing
  /// wired → `RelayServer.start()` throws" lands.
  ///
  /// **The resolver is consulted at hello, never here.** Loading the file
  /// resolves nobody: the file names identities, and who they currently are
  /// is a question for the moment a hello arrives. A copy taken now would
  /// hand out stale roles until the next file rotation — and the file is
  /// exactly the thing a database edit does not touch.
  static Future<FileTokenValidator> load(String path,
      {UserResolver? accounts}) async {
    if (accounts == null) {
      throw ArgumentError.value(
          null,
          'accounts',
          'the token file names usernames; with no UserResolver this gateway '
              'cannot learn who any of them is, and a station admitted '
              'without one would be a station nobody graded');
    }
    return FileTokenValidator._(path, accounts, await _read(path));
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
  /// *digest* up and then comparing what it buys subsumes the file-driven
  /// cases at once: a removed token is not in the map, a renamed station or a
  /// re-pointed account resolves to a different row, and a replaced token is
  /// not in the map either, because the digest of the credential the session
  /// is holding is not the digest of the one the file now carries.
  ///
  /// The remaining cases are not in the file at all, and under the user model
  /// that is most of them: the account can be deleted, re-roled or unmarked
  /// as a station, and the groups behind its role can change — all in
  /// `app_user`/`app_role`, with the file digest unchanged. So the resolver
  /// is asked again, live, and the answer compared against what the session
  /// is carrying. The account row is compared **whole** ([AuthenticatedUser]
  /// has value equality), so any edit to who the account is — role, marking,
  /// even the display name an audit viewer renders — retires the session on
  /// the next sweep, and it reconnects into a freshly minted identity.
  ///
  /// **An unreachable user source answers "no evidence of a change", not
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

    final ResolvedUser? resolved;
    try {
      resolved = _accounts(row.username);
    } on Object {
      // See the doc above: unreadable is not the same as revoked, and this one
      // runs against every live session.
      return true;
    }
    // An account deleted out from under a live session is a revocation, and
    // under the user model it is the one an operator performs when they mean
    // it — no token file involved.
    if (resolved == null) return false;
    // The whole row: a re-roled account, one whose station marking was
    // removed, or any other edit to who this is. A hello made now would mint
    // a different identity, so the one being carried is stale.
    if (resolved.user != identity.user) return false;
    return _sameGroups(resolved.groups, identity.session.groups);
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
      // an unarguable pin; a word-boundary regex would be neither. The
      // redirect added a sibling with the same edge: the two seed role names
      // may not appear either, so "Station Panel" as a phrase is out of
      // bounds even in prose that means the object on the wall.
      return const TokenRejected('no credential presented on hello; this '
          'gateway reads a token file, and every station needs its own token '
          'mounted beside it');
    }
    final entry = _set.lookup(token);
    if (entry == null) {
      // Deliberately before the resolver is asked: a credential this gateway
      // does not carry never becomes a round trip to the user source, so a
      // miss cannot be timed against a hit and an unknown token cannot be used
      // to make the database work.
      return const TokenRejected('the credential presented is not in this '
          'gateway\'s token file; it was removed, or this panel was '
          'provisioned against another gateway');
    }

    final row = entry.row;
    final ResolvedUser? resolved;
    try {
      resolved = _accounts(row.username);
    } on Object {
      // The opposite of `AccessPolicy.groupForTag`'s swallow, and deliberately
      // so: that one runs on the write path of every jog and must not take the
      // plant down. This one runs once, at connect, where refusing is the safe
      // answer and the operator is told which of the things went wrong.
      return TokenRejected('station ${row.station} authenticates as '
          '"${row.username}" and $userSourceDownMarker, so this gateway '
          'cannot tell who that is or what its role may do. A session '
          'admitted now would be a session nobody graded');
    }
    if (resolved == null) {
      // **Not** an identity with an empty group set. An empty set is
      // indistinguishable in the audit trail from an account whose role
      // deliberately grants nothing, and those two must not look the same
      // (D-06, fail-closed). Note the value went to the user table and only
      // the user table: a username that happens to spell a role name is an
      // unknown account, never a role looked up by another door.
      return TokenRejected('station ${row.station} authenticates as '
          '"${row.username}", and this gateway\'s user source has no such '
          'account. Create it — one account per station, its role set on the '
          'row — or point the station\'s token file at an account that '
          'exists. It is not admitted with nothing, because a station that '
          'was granted nothing on purpose must not look the same as one '
          'whose account was deleted');
    }
    if (!resolved.user.stationAccount) {
      // ACCESS-06 is only honest if the identity is honestly a panel. A token
      // mounted beside a screen signs in forever, and every write it makes
      // lands on this name in the trail — attributing that to a person whose
      // password was never typed would be the attribution lying.
      return TokenRejected('station ${row.station} authenticates as '
          '"${row.username}", which is a person\'s account rather than a '
          'station account. A wall token signs in forever and its writes are '
          'recorded under this name, so it may only name an account marked '
          'as a station; a person signs in with a password and keeps an '
          'inactivity window');
    }

    // ACCESS-06, improved by the redirect: the user below is not the file's
    // claim about who the station is — it is the account row this server
    // resolved from the database a moment ago. An audit row attributing a
    // gateway-mode write to it is attributing to a verified app_user, honestly
    // marked as a station, with the role the database says it holds.
    //
    // The digest, not the token, travels beside it: what the session records
    // is what lets a later sweep tell "still this station" from "still this
    // credential". See [TokenAccepted.credentialDigest].
    return TokenAccepted(
      StationIdentity(
        user: resolved.user,
        station: row.station,
        session: AccessSession(user: resolved.user, groups: resolved.groups),
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
          '"station": "..."}}}');
    }

    final byDigest = <String, _Entry>{};
    final byStation = <String, _TokenRow>{};
    final stationByUsername = <String, String>{};
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
      _refuseAnEntryThatCarriesARole(rawEntry, station, path);

      final row = _TokenRow(username, station);
      final clash = byStation[station];
      if (clash != null) {
        throw FormatException('two tokens in $path both name station '
            '$station. One station, one credential: with two, pulling one '
            'of them revokes nothing and the sweep cannot tell which live '
            'session lost its access');
      }
      final holder = stationByUsername[username];
      if (holder != null) {
        // The ruling made structural: "a user for a station" is one each
        // way. An audit row records a username, and a username two stations
        // share is a write the trail cannot place — and deleting the account
        // would darken two screens when the operator meant one.
        throw FormatException('stations $holder and $station in $path both '
            'authenticate as "$username". One account per station: a shared '
            'account blurs the trail and widens every revocation, so give '
            'each station its own row');
      }
      byStation[station] = row;
      stationByUsername[username] = station;
      final digest = _sha256(utf8.encode(rawToken));
      byDigest[_hex(digest)] = _Entry(digest, row);
    });

    return _TokenSet(byDigest, byStation, _sha256(bytes));
  }

  /// Refuses a file still written in the pre-Phase-17 shape.
  ///
  /// A half-migrated file is the dangerous one. `stationId` would otherwise
  /// load as an entry with no station at all, and the operator holding this
  /// file is the one who has to rewrite it — so the message says which keys
  /// moved rather than which key is missing.
  static void _refuseTheLegacyEntryShape(Map<Object?, Object?> entry,
      String path) {
    if (!entry.containsKey('stationId')) return;
    throw FormatException('the token file $path is still written in the '
        'pre-Phase-17 shape: an entry carries "stationId". Every entry is now '
        '{"username": "...", "station": "..."} — "stationId" became '
        '"station", "username" names the account row this station '
        'authenticates as, and the role that used to ride beside them lives '
        'on that account in the access database');
  }

  /// Refuses an entry that says anything about a role — whatever the value.
  ///
  /// **The fifth class of bad file, sharpened by the redirect.** D-06 as
  /// ruled 2026-09-07, deployment cost accepted: a gateway refuses to start
  /// on a token file carrying authorisation content rather than translating
  /// it. The legacy `"view"`/`"operate"` grants are the obvious offenders,
  /// but 17-04's own interim format — a role *name* in the file — is refused
  /// by the same rule, because the offence was never the vocabulary: it is
  /// the file having somewhere to put an answer to "and therefore may do X".
  /// A role assignment that rides beside the credential is a role assignment
  /// nobody re-examines; on the `app_user` row, the same screen that grants
  /// it can see it and revoke it.
  ///
  /// Refusing on the **key** rather than the value is also what lets this
  /// parser forget the permission vocabulary entirely: it no longer needs
  /// `AccessGroup.byName` to recognise a grant, and the grep pins hold with
  /// nothing to hide.
  static void _refuseAnEntryThatCarriesARole(
      Map<Object?, Object?> entry, String station, String path) {
    if (!entry.containsKey('role')) return;
    final value = entry['role'];
    throw FormatException('station $station in $path still carries '
        '"role": ${jsonEncode(value)}. The token file names WHICH USER a '
        'station is and grants nothing: an entry is {"username": "...", '
        '"station": "..."}, the username is matched against an account row '
        'in the access database, and the role that decides what the station '
        'may do lives on that row — not in this file. Delete the "role" key '
        'and set the role on the station\'s account instead. This gateway '
        'will not carry the value over for you, because a grant that rides '
        'in a file is a grant nobody re-examined, and moving it onto the '
        'account is the re-examination');
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
/// Two strings, and **nothing about authorisation** — that is the type-level
/// statement of the redirect. 17-04's row still carried a role name; this one
/// cannot say anything about a role because there is nowhere in it to put
/// one, which is the same structural argument [StationIdentity] makes about
/// credentials. Turning a row into an identity requires the [UserResolver],
/// and that is the only path.
final class _TokenRow {
  const _TokenRow(this.username, this.station);

  /// The name matched against an `app_user` row — which is where the role
  /// lives. What an audit row's `who` column records.
  final String username;

  /// What its `station` column records.
  final String station;
}

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
