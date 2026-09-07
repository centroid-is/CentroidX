@TestOn('vm')

/// The token file after the 17-04b redirect: it names **which USER a station
/// is**, and it grants nothing — not even a role name.
///
/// D-06 as ruled, redirected 2026-09-07: *"we will use a user for a station"*.
/// Each panel gets an `app_user` row; the token file entry is
/// `{"username", "station"}` and nothing else. The gateway resolves
/// user → role → groups from the database through a [UserResolver] seam **at
/// validation time**, so the file carries zero authorisation content: 17-04's
/// interim format — where the file still named a role — is refused the same
/// way the pre-Phase-17 `"view"`/`"operate"` grants are.
///
/// Five properties:
///
///  1. **A well-formed entry loads and produces a verified station account.**
///     The `AuthenticatedUser` on the identity is the row the server resolved,
///     not the file's claim — which is what makes gateway-mode audit
///     attribution honest (ACCESS-06).
///  2. **An entry that says anything about a role is refused at load, by
///     name.** Legacy permission values, 17-04's role names, anything: a
///     `role` key is the file answering "and therefore may do X", and the
///     ruling is refuse-and-name-the-replacement, never translate.
///  3. **No `AccessGroup` name and no role name appears in the parser.** The
///     sibling pin is new with the redirect: the parser could once spell the
///     two seed role names because it printed them as guidance; now it cannot
///     spell a role at all.
///  4. **An unknown user, an unreachable user source and a person's account
///     are distinguishable refusals at `hello`**, never an identity with an
///     empty group set. An operator who cannot connect must be able to tell
///     "your account was deleted" from "the database is down" from "that is a
///     person, not a panel".
///  5. **Everything the credential mechanism already did, it still does** —
///     the length floor, the digest-keyed map, the duplicate-station refusal,
///     the loose-permission refusal, and the revocation sweep's cases — plus
///     the sweep now follows the *account row*: a deleted user, a re-roled
///     user, a demoted role and an account that stopped being a station are
///     all revocations the database can perform with the file untouched.
///
/// The `hello`-over-a-real-socket half of SEC-03 stays in `auth_test.dart`.
/// This file is the loader and the validator, driven directly.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/file_token_validator.dart';
import 'package:tfc_relay_server/src/token_validator.dart';

/// Tokens long enough to clear [FileTokenValidator.minTokenLength], and
/// visibly not words anyone would type by accident.
const _stationOneToken = 'ST101-1nZq4tGm7Yb2Kd8Vw6Rc0Pf3';
const _stationTwoToken = 'ST201-9aXe5uHj1Lo4Nm7Bs2Tv8Qi6';

/// What an operator mints for ST101 after its token leaked: a new secret for
/// the same station and the same account.
const _stationOneReplacement = 'ST101-4hYp8sWk2Cf6Nx1Dj9Ur5Lz7';

/// Two role names, as `app_role.name` rows. They exist only inside the user
/// source now — the token file cannot spell them, and that is property 3.
const _panelRole = 'Line Panel';
const _displayRole = 'Wall Display';

AuthenticatedUser _account(String username, String roleName,
        {bool stationAccount = true}) =>
    AuthenticatedUser(
        username: username, roleName: roleName, stationAccount: stationAccount);

/// A user source backed by a map a case can edit underneath a running
/// validator — which is what the access database being edited looks like from
/// here. One resolver, the whole user → role → groups chain: that is the seam
/// 17-11 fills from `AccessRepository`.
final class _UserSource {
  _UserSource(this.accounts);

  Map<String, ResolvedUser> accounts;

  /// Set to throw, standing in for a database nobody can reach.
  Object? failure;

  int calls = 0;

  /// Every username this source was ever asked about, in order — what lets an
  /// arm assert that a value was looked up *as a username* rather than being
  /// recognised as something else.
  final List<String> asked = [];

  ResolvedUser? resolve(String username) {
    calls++;
    asked.add(username);
    final boom = failure;
    if (boom != null) throw boom;
    return accounts[username];
  }
}

_UserSource _seedUsers() => _UserSource({
      'ST101-panel': ResolvedUser(
          user: _account('ST101-panel', _panelRole),
          groups: const {AccessGroup.operate}),
      'HALL-display': ResolvedUser(
          user: _account('HALL-display', _displayRole),
          groups: const <AccessGroup>{}),
    });

HelloParams _helloWith(String? token) => HelloParams(
      protocol: protocolVersion,
      supported: const [protocolVersion],
      client: const PeerInfo('panel-under-test', '0.1.0'),
      token: token,
    );

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('relay-token-file-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Writes a token file and locks it to the owner, which is the only mode the
/// loader accepts on POSIX.
String _writeTokenFile(Directory dir, Object? contents, {String mode = '600'}) {
  final file = File('${dir.path}/tokens.json');
  file.writeAsStringSync(
      contents is String ? contents : jsonEncode(contents));
  if (!Platform.isWindows) {
    Process.runSync('chmod', [mode, file.path]);
  }
  return file.path;
}

/// The one-station file every accept-path case starts from, in the new shape:
/// a username and a station, and **nothing else to carry**.
Map<String, Object?> _oneStation() => {
      'tokens': {
        _stationOneToken: {
          'username': 'ST101-panel',
          'station': 'ST101',
        },
      },
    };

Map<String, Object?> _twoStations() => {
      'tokens': {
        _stationOneToken: {
          'username': 'ST101-panel',
          'station': 'ST101',
        },
        _stationTwoToken: {
          'username': 'HALL-display',
          'station': 'ST201',
        },
      },
    };

/// The package root, for the source-text pins below.
Directory _packageRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('name: tfc_relay_server')) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('could not find the tfc_relay_server package root');
}

/// The parser's source with whole comment lines removed — the house stripping
/// rule, so a doc comment explaining a deleted word does not trip the pin.
String _strippedParserSource() {
  final file =
      File('${_packageRoot().path}/lib/src/auth/file_token_validator.dart');
  expect(file.existsSync(), isTrue,
      reason: 'the anti-vacuity half: a pin over a file that is not there '
          'finds zero of everything');
  final stripped = file
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
  expect(stripped.split('\n').length, greaterThan(200),
      reason: 'the second anti-vacuity half: a stripper that ate the whole '
          'file would find zero of everything too');
  return stripped;
}

void main() {
  group('the file names a user and grants nothing', () {
    test('a well-formed entry loads as a verified station account', () async {
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          accounts: _seedUsers().resolve);

      final verdict =
          await validator.validate(_helloWith(_stationOneToken));

      expect(verdict, isA<TokenAccepted>(),
          reason: 'the anti-vacuity half for everything below: a validator '
              'that refused every hello would satisfy no assertion here, but '
              'a reader skimming a cast would not see that');
      final identity = (verdict as TokenAccepted).identity;
      expect(identity.user.username, 'ST101-panel');
      expect(identity.user.roleName, _panelRole,
          reason: 'the role came from the account row the server resolved, '
              'not from the file — the file has nowhere left to put one');
      expect(identity.station, 'ST101');
      expect(identity.user.stationAccount, isTrue,
          reason: 'ACCESS-06, improved by the redirect: this flag is what the '
              'app_user row says, verified by the server, so a trail viewer '
              'rendering a panel differently from a person is rendering a '
              'fact rather than the file\'s claim');
      expect(identity.session.can(AccessGroup.operate), isTrue,
          reason: 'the groups came from the resolver — user, then its role, '
              'then that role\'s groups — never from the file');
    });

    test('a legacy permission grant in a role key is refused at load, and '
        'the message says the token names a user', () async {
      for (final legacy in const ['operate', 'view']) {
        final path = _writeTokenFile(_tempDir(), {
          'tokens': {
            _stationOneToken: {
              'username': 'ST101-panel',
              'station': 'ST101',
              'role': legacy,
            },
          },
        });

        await expectLater(
            FileTokenValidator.load(path, accounts: _seedUsers().resolve),
            throwsA(isA<FormatException>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains(legacy),
                  contains(path),
                  contains('username'),
                  contains('station'),
                ))),
            reason: 'D-06 as redirected: a Phase 17 backend refuses to start '
                'on a token file that says anything about a role, and the old '
                'two-value grant is doubly dead — it was a permission the '
                'relay compiled in, and it rode in a file. **No silent '
                'translation** — carrying "$legacy" over would let a legacy '
                'grant survive unexamined. The message is what somebody reads '
                'at 3am, so it names the file, the offending value, and the '
                'shape to write instead');
      }
    });

    test('17-04\'s own interim format — a role NAME in the file — is refused '
        'the same way', () async {
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          _stationOneToken: {
            'username': 'ST101-panel',
            'station': 'ST101',
            'role': _panelRole,
          },
        },
      });

      await expectLater(
          FileTokenValidator.load(path, accounts: _seedUsers().resolve),
          throwsA(isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains(_panelRole), contains(path)))),
          reason: 'the interim format was a thin improvement — a name instead '
              'of a permission — but the role still rode in the file, and a '
              'role assignment that lives beside the credential is a role '
              'assignment nobody re-examines. It belongs on the app_user row, '
              'where the same screen that grants it can revoke it');
    });

    test('a role key is refused whatever its value — every permission name '
        'included', () async {
      // The regression sweep for the old generalisation arm: `configure` and
      // `administer` as role values were the nightmare case under 17-04's
      // format (a role row named after a group would grant it by spelling).
      // Under the redirect they are refused before their value is even read
      // as vocabulary, because the key itself is the offence.
      for (final group in AccessGroup.values) {
        final path = _writeTokenFile(_tempDir(), {
          'tokens': {
            _stationOneToken: {
              'username': 'ST101-panel',
              'station': 'ST101',
              'role': group.name,
            },
          },
        });

        await expectLater(
            FileTokenValidator.load(path, accounts: _seedUsers().resolve),
            throwsA(isA<FormatException>()),
            reason: '"${group.name}" in a role key is the credential '
                'mechanism answering "and therefore may do X" — and a file '
                'with any role key at all is a file with somewhere to put '
                'that answer');
      }
    });

    test('a file in the new shape is not refused', () async {
      // The live control for the three refusal arms above, and it must share
      // their fixture shape: a loader that refused every file would pass all
      // three and start nothing. Today's finding elsewhere in this phase: a
      // fixture that also refuses proves nothing.
      await expectLater(
          FileTokenValidator.load(
              _writeTokenFile(_tempDir(), _oneStation()),
              accounts: _seedUsers().resolve),
          completes);
    });

    test('the legacy entry shape is refused, and says which keys changed',
        () async {
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          _stationOneToken: {'stationId': 'ST101', 'role': 'operate'},
        },
      });

      await expectLater(
          FileTokenValidator.load(path, accounts: _seedUsers().resolve),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              allOf(contains('stationId'), contains('station'),
                  contains('username')))),
          reason: 'a half-migrated file is the dangerous one: the old key '
              'names would otherwise load as an entry with no station at all. '
              'The message must say which keys moved, because the operator '
              'holding this file is the one who has to rewrite it');
    });

    test('no permission name appears in the parser', () {
      final stripped = _strippedParserSource();

      for (final group in AccessGroup.values) {
        expect(stripped, isNot(contains(group.name)),
            reason: 'the parser names "${group.name}". The relay keeps the '
                'credential mechanism and no policy: it may answer "which '
                'identity is this" and it may not answer "and therefore may '
                'do X"');
      }
    });

    test('no role name appears in the parser either', () {
      // The redirect's sibling pin. 17-04's parser could spell its two seed
      // role names because its refusal printed them as guidance; under the
      // user model the guidance is a *shape* and an account row, so the
      // parser has no reason left to know what any role is called. The two
      // names pinned here are the two it used to compile in.
      final stripped = _strippedParserSource();

      for (final roleName in const ['Station Panel', 'Station Display']) {
        expect(stripped, isNot(contains(roleName)),
            reason: 'the parser spells the role name "$roleName". A parser '
                'that can name a role is a parser one refactor away from '
                'matching on it, and the token file it reads may not carry '
                'authorisation content of any kind — not a permission, and '
                'not a role name either');
      }
    });
  });

  group('an unresolvable user is refused at hello, not admitted empty', () {
    test('an unknown username is refused', () async {
      final users = _seedUsers();
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          _stationOneToken: {
            'username': 'GHOST-panel',
            'station': 'ST101',
          },
          _stationTwoToken: {
            'username': 'ST101-panel',
            'station': 'ST201',
          },
        },
      });
      final validator =
          await FileTokenValidator.load(path, accounts: users.resolve);

      final ghost = await validator.validate(_helloWith(_stationOneToken));
      final real = await validator.validate(_helloWith(_stationTwoToken));

      expect(real, isA<TokenAccepted>(),
          reason: 'the anti-vacuity half, and it goes first: the same user '
              'source, the same file, the same validator. Without it the '
              'refusal below passes against a validator that refuses '
              'everybody, which this milestone has already been bitten by');
      expect((real as TokenAccepted).identity.session.can(AccessGroup.operate),
          isTrue);

      expect(ghost, isA<TokenRejected>(),
          reason: 'D-06 fail-closed, carried over to the user model: an '
              'unknown username is refused at hello, not admitted with an '
              'empty group set. An empty set is indistinguishable in the '
              'audit trail from an account whose role deliberately grants '
              'nothing, and those two must not look the same');
      expect((ghost as TokenRejected).reason, contains('GHOST-panel'));
      expect(ghost.reason, isNot(contains(_stationOneToken)),
          reason: 'the reason travels into a -32003 message and into the '
              'gateway\'s log; naming the credential there publishes it');
    });

    test('a username that names a role is refused as a user, never resolved '
        'as a role', () async {
      // The redirect's sharpest edge. The database HAS a role called
      // "Line Panel" — it is the role behind ST101-panel — and no account by
      // that name. A gateway with any role-resolution path left in it would
      // recognise the value; the ruled model has exactly one lookup, and it
      // is the user table.
      final users = _seedUsers();
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          _stationOneToken: {
            'username': _panelRole,
            'station': 'ST101',
          },
          _stationTwoToken: {
            'username': 'ST101-panel',
            'station': 'ST201',
          },
        },
      });
      final validator =
          await FileTokenValidator.load(path, accounts: users.resolve);

      final asRole = await validator.validate(_helloWith(_stationOneToken));
      final real = await validator.validate(_helloWith(_stationTwoToken));

      expect(real, isA<TokenAccepted>(),
          reason: 'the live control: the same source admits a username it '
              'does know, so the refusal above is the lookup missing and not '
              'the fixture refusing everything');
      expect(asRole, isA<TokenRejected>(),
          reason: 'a role name in the username field is NOT treated as a '
              'role. It went to the user table, it found no account, and '
              'that is a refusal — anything else is the parallel role model '
              'sneaking back in through the identity field');
      expect(users.asked, contains(_panelRole),
          reason: 'and it was refused for the right reason: the value was '
              'looked up AS A USERNAME. A validator that never asked would '
              'pass the isA above by refusing on some other ground');
    });

    test('an unreachable user source is a different refusal', () async {
      final users = _seedUsers();
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          accounts: users.resolve);

      final reachable = await validator.validate(_helloWith(_stationOneToken));
      expect(reachable, isA<TokenAccepted>(),
          reason: 'the anti-vacuity half: this validator accepts this token '
              'when the user source answers, so the refusal below is caused '
              'by the outage and not by the fixture');

      users.failure = StateError('the access database is not reachable');
      final unreachable =
          await validator.validate(_helloWith(_stationOneToken));

      expect(unreachable, isA<TokenRejected>());

      final ghostUsers = _seedUsers();
      final ghostValidator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), {
            'tokens': {
              _stationOneToken: {
                'username': 'GHOST-panel',
                'station': 'ST101',
              },
            },
          }),
          accounts: ghostUsers.resolve);
      final ghost = await ghostValidator.validate(_helloWith(_stationOneToken))
          as TokenRejected;

      expect((unreachable as TokenRejected).reason, isNot(ghost.reason),
          reason: 'an operator who cannot connect must be able to tell "your '
              'account was deleted" from "the database is down". One is fixed '
              'by editing app_user and one is fixed by looking at Postgres; a '
              'single message sends the wrong person to the wrong place');
      expect(unreachable.reason,
          contains(FileTokenValidator.userSourceDownMarker));
      expect(ghost.reason,
          isNot(contains(FileTokenValidator.userSourceDownMarker)));
    });

    test('a person\'s account on a wall token is refused', () async {
      final users = _seedUsers();
      users.accounts['jon'] = ResolvedUser(
          user: _account('jon', 'Plant Engineering', stationAccount: false),
          groups: const {AccessGroup.operate, AccessGroup.configure});
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          _stationOneToken: {
            'username': 'jon',
            'station': 'ST101',
          },
          _stationTwoToken: {
            'username': 'ST101-panel',
            'station': 'ST201',
          },
        },
      });
      final validator =
          await FileTokenValidator.load(path, accounts: users.resolve);

      final person = await validator.validate(_helloWith(_stationOneToken));
      final panel = await validator.validate(_helloWith(_stationTwoToken));

      expect(panel, isA<TokenAccepted>(),
          reason: 'the live control: the same source, and an account that IS '
              'marked as a station is admitted');
      expect(person, isA<TokenRejected>(),
          reason: 'ACCESS-06 is only honest if the identity is honestly a '
              'panel. A token mounted beside a screen signs in forever and '
              'every write it makes lands on this name in the trail — '
              'attributing that to a person whose password was never typed '
              'is the attribution lying. The account exists and its role '
              'resolves; what it lacks is the stationAccount marking, and '
              'that is the whole refusal');
      expect((person as TokenRejected).reason, contains('jon'));
      expect(person.reason, isNot(contains(_stationOneToken)));
    });

    test('load with no resolver throws', () async {
      await expectLater(
          FileTokenValidator.load(_writeTokenFile(_tempDir(), _oneStation())),
          throwsA(isA<ArgumentError>()),
          reason: 'there is no permissive fallback, on this file\'s own stated '
              'reasoning about a misspelled PEM: a gateway that admitted every '
              'panel because nobody wired the user source would look perfectly '
              'healthy from every screen in the plant');
    });

    test('the user source is consulted at validation time, never cached from '
        'load', () async {
      final users = _seedUsers();
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          accounts: users.resolve);
      expect(users.calls, 0,
          reason: 'loading the file resolved nobody: the file names '
              'identities, and who they currently are is a question for the '
              'moment a hello arrives, not for the moment the file was read');

      final before = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      expect(before.identity.user.roleName, _panelRole);

      // The account is re-roled in the database. No file changed, nothing
      // reloaded.
      users.accounts['ST101-panel'] = ResolvedUser(
          user: _account('ST101-panel', _displayRole),
          groups: const <AccessGroup>{});

      final after = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      expect(after.identity.user.roleName, _displayRole,
          reason: 'the next hello is graded by what the database says NOW. A '
              'validator that answered from a copy taken at load would hand '
              'out the old role until the next file rotation — and the file '
              'is exactly the thing a database edit does not touch');
      expect(after.identity.session.can(AccessGroup.operate), isFalse);
    });
  });

  group('the credential mechanism is unchanged', () {
    test('a token file with two stations sharing an id is refused', () async {
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          _stationOneToken: {
            'username': 'ST101-panel',
            'station': 'ST101',
          },
          _stationTwoToken: {
            'username': 'ST101-spare',
            'station': 'ST101',
          },
        },
      });

      await expectLater(
          FileTokenValidator.load(path, accounts: _seedUsers().resolve),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              allOf(contains('ST101'), contains(path)))),
          reason: 'two tokens answering to one station makes a revocation '
              'ambiguous: pulling one of them leaves the other still valid for '
              'the identity that was supposed to lose access, and the sweep '
              'cannot tell which live session to close');
    });

    test('two stations sharing one account is refused', () async {
      // New with the redirect, and it is the ruling made structural: "a user
      // for a station" is one each way. Two panels on one account would blur
      // the trail (which panel wrote?) and widen every revocation (deleting
      // the account darkens two screens when the operator meant one).
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          _stationOneToken: {
            'username': 'ST101-panel',
            'station': 'ST101',
          },
          _stationTwoToken: {
            'username': 'ST101-panel',
            'station': 'ST201',
          },
        },
      });

      await expectLater(
          FileTokenValidator.load(path, accounts: _seedUsers().resolve),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              allOf(contains('ST101-panel'), contains(path)))),
          reason: 'one account per station: an audit row records a username, '
              'and a username two stations share is a write the trail cannot '
              'place');
    });

    test('a token shorter than the floor is refused', () async {
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          'short-token': {
            'username': 'ST101-panel',
            'station': 'ST101',
          },
        },
      });

      await expectLater(
          FileTokenValidator.load(path, accounts: _seedUsers().resolve),
          throwsA(isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(
                  contains('ST101'),
                  contains('${FileTokenValidator.minTokenLength}'),
                  contains(path)))),
          reason: 'a short credential is a guessable one, and the message must '
              'name the station rather than the token so a support ticket that '
              'pastes it does not paste a credential');
    });

    test('a group- or world-readable token file is refused', () async {
      final path = _writeTokenFile(_tempDir(), _oneStation(), mode: '644');

      await expectLater(
          FileTokenValidator.load(path, accounts: _seedUsers().resolve),
          throwsA(isA<FileSystemException>()
              .having((e) => e.message, 'message', contains('readable'))),
          reason: 'the credential set is the plant\'s keys; a file every '
              'account on the machine can read is a credential set every '
              'account on the machine has');
    }, skip: Platform.isWindows ? 'POSIX file modes' : null);

    test('a token file the gateway cannot read at all fails the load',
        () async {
      final dir = _tempDir();

      await expectLater(
          FileTokenValidator.load('${dir.path}/absent.json',
              accounts: _seedUsers().resolve),
          throwsA(isA<FileSystemException>()),
          reason: 'there is no permissive fallback: a gateway that accepted '
              'every panel because somebody misspelled a path would look '
              'perfectly healthy');
    });

    test('an unknown or absent credential is refused, and the refusal never '
        'repeats it', () async {
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          accounts: _seedUsers().resolve);

      const impostor = 'IMPOSTOR-4d2f8e1c6b9a3057fe4d2c8b';
      final unknown = await validator.validate(_helloWith(impostor));
      final absent = await validator.validate(_helloWith(null));

      expect(unknown, isA<TokenRejected>());
      expect(absent, isA<TokenRejected>());
      expect((unknown as TokenRejected).reason, isNot(contains(impostor)),
          reason: 'the reason reaches the client inside a -32003 message; a '
              'gateway that echoes the credential back has published it to '
              'every log that catches the refusal');
      expect((absent as TokenRejected).reason, isNotEmpty);
    });

    test('a credential the file does not carry never reaches the user source',
        () async {
      // The ordering the constant-time compare depends on: the digest lookup
      // decides, and a miss must not become a database round trip an attacker
      // can time.
      final users = _seedUsers();
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          accounts: users.resolve);
      final before = users.calls;

      await validator.validate(_helloWith('IMPOSTOR-4d2f8e1c6b9a3057fe4d2c8b'));

      expect(users.calls, before,
          reason: 'a refused credential asked the user source nothing');
      await validator.validate(_helloWith(_stationOneToken));
      expect(users.calls, greaterThan(before),
          reason: 'the anti-vacuity half: a validator that never called the '
              'resolver at all would pass the assertion above');
    });

    test('stillValid follows the file, not the session', () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _twoStations());
      final validator =
          await FileTokenValidator.load(path, accounts: _seedUsers().resolve);

      final one = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      final two = await validator.validate(_helloWith(_stationTwoToken))
          as TokenAccepted;
      expect(validator.stillValid(one.identity, one.credentialDigest), isTrue);
      expect(validator.stillValid(two.identity, two.credentialDigest), isTrue);

      _writeTokenFile(dir, _oneStation());
      expect(validator.stillValid(two.identity, two.credentialDigest), isTrue,
          reason: 'nothing has been reloaded yet — a validator that answered '
              'from the disk on every call would be doing file I/O on the '
              'hello path');

      await validator.reload();
      expect(validator.stillValid(one.identity, one.credentialDigest), isTrue);
      expect(validator.stillValid(two.identity, two.credentialDigest), isFalse,
          reason: 'ST201\'s token is gone from the file, so its live session '
              'is the one the sweep must close');
    });

    test('a user whose role changed is no longer the identity the session '
        'holds — and no file was touched', () async {
      // Under 17-04 this case was file-driven: the role NAME rode in the
      // file, so seeing the change required a reload. Under the redirect the
      // role lives on the app_user row, so the sweep sees a re-role through
      // the live resolver with the file digest unchanged — which is exactly
      // the shape 17-11's database-tick sweep wires.
      final users = _seedUsers();
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          accounts: users.resolve);

      final operating = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      expect(operating.identity.user.roleName, _panelRole);
      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isTrue,
          reason: 'the anti-vacuity half: nothing has changed yet, and a '
              'stillValid that answered false for everything would close the '
              'whole plant on every sweep');

      users.accounts['ST101-panel'] = ResolvedUser(
          user: _account('ST101-panel', _displayRole),
          groups: const <AccessGroup>{});

      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isFalse,
          reason: 'a session minted before the change is still carrying the '
              'old role. Leaving it live is the demotion not taking effect '
              'until the panel happens to reconnect — which an operator can '
              'postpone indefinitely by not reconnecting');
    });

    test('a user deleted out from under a live session is a revocation',
        () async {
      final users = _seedUsers();
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          accounts: users.resolve);
      final operating = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isTrue);

      users.accounts.remove('ST101-panel');

      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isFalse,
          reason: 'deleting the account is the revocation an operator '
              'actually performs under the user model — the token file does '
              'not even need to be visited. The next sweep closes the '
              'session; this arm is what keeps that path from quietly dying');
    });

    test('an account that stops being a station account is no longer the '
        'identity the session holds', () async {
      final users = _seedUsers();
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          accounts: users.resolve);
      final operating = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isTrue);

      // Same name, same role, same groups — only the marking changed.
      users.accounts['ST101-panel'] = ResolvedUser(
          user: _account('ST101-panel', _panelRole, stationAccount: false),
          groups: const {AccessGroup.operate});

      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isFalse,
          reason: 'unmarking the account is how an admin says "this is not a '
              'panel any more", and a hello made after the change would be '
              'refused — so a session from before it must not outlive the '
              'ruling it was admitted under. This is the "disabled user" '
              'case: the session dies on the next sweep');
    });

    test('a role that kept its name and lost its groups is no longer the '
        'identity the session holds', () async {
      // The role set is part of the credential: the sweep must see a change
      // made in the *database* and not only one made in the file. D-08.
      final users = _seedUsers();
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          accounts: users.resolve);

      final operating = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isTrue,
          reason: 'the anti-vacuity half: nothing has changed yet');

      // Nobody touched the file, and nobody touched the user row. Somebody
      // unticked a group on the role behind it.
      users.accounts['ST101-panel'] = ResolvedUser(
          user: _account('ST101-panel', _panelRole),
          groups: const <AccessGroup>{});

      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isFalse,
          reason: 'after this phase the role decides more than the old flat '
              'write permission, so a demotion that only took effect on the '
              'next reconnect is strictly worse than it used to be. The poll '
              'that calls this is 17-11\'s; without it this is dead code, '
              'which is exactly what this arm is here to stop it quietly '
              'becoming');
    });

    test('an unreachable user source does not close every live session',
        () async {
      // Deliberately the opposite of the hello path, and the asymmetry is the
      // point. Refusing at hello is safe: it runs once, the operator is told,
      // and nothing that was running stops. Refusing here runs on a poll
      // against every live session, so answering "revoked" when Postgres
      // blinks would take the plant's screens down for the length of a
      // network hiccup — the same trade `AccessPolicy.groupForTag`'s swallow
      // already makes on the write path of every jog.
      final users = _seedUsers();
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          accounts: users.resolve);
      final operating = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;

      users.failure = StateError('the access database is not reachable');

      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isTrue,
          reason: 'an unreadable user source is not evidence of a demotion');

      users.failure = null;
      users.accounts['ST101-panel'] = ResolvedUser(
          user: _account('ST101-panel', _panelRole),
          groups: const <AccessGroup>{});
      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isFalse,
          reason: 'the anti-vacuity half: once the source answers again, a '
              'real demotion is still seen. A stillValid that had simply '
              'stopped comparing would pass the assertion above');
    });

    test('a replaced token is no longer the credential the session holds',
        () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _oneStation());
      final validator =
          await FileTokenValidator.load(path, accounts: _seedUsers().resolve);

      final accepted = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      expect(
          validator.stillValid(accepted.identity, accepted.credentialDigest),
          isTrue);

      _writeTokenFile(dir, {
        'tokens': {
          _stationOneReplacement: {
            'username': 'ST101-panel',
            'station': 'ST101',
          },
        },
      });
      await validator.reload();

      expect(
          validator.stillValid(accepted.identity, accepted.credentialDigest),
          isFalse,
          reason: 'the session is holding the leaked credential. Nothing about '
              'its identity changed — same station, same account — which is '
              'exactly why comparing identities could not see this, and why '
              'the digest of the accepted credential travels beside it');
      expect(validator.stillValid(accepted.identity, null), isTrue,
          reason: 'stated rather than hidden: with no digest to compare, the '
              'answer falls back to the station lookup and cannot tell a '
              'replacement from a re-save');
      expect(
          (await validator.validate(_helloWith(_stationOneReplacement))
                  as TokenAccepted)
              .credentialDigest,
          isNot(accepted.credentialDigest),
          reason: 'the new credential resolves to the same identity through a '
              'different digest — which is the whole mechanism');
    });

    test('reloadIfChanged re-reads only when the file changed', () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _twoStations());
      final validator =
          await FileTokenValidator.load(path, accounts: _seedUsers().resolve);
      final two = await validator.validate(_helloWith(_stationTwoToken))
          as TokenAccepted;

      expect(await validator.reloadIfChanged(), isFalse,
          reason: 'the digest is unchanged, so a config-watch loop that fires '
              'on every notification must cost nothing — re-parsing here is '
              'how a re-save of an identical file churns every live session');

      _writeTokenFile(dir, _oneStation());
      expect(await validator.reloadIfChanged(), isTrue);
      expect(validator.stillValid(two.identity, two.credentialDigest), isFalse);
    });

    test('reload keeps the previous set when the new file is broken', () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _oneStation());
      final validator =
          await FileTokenValidator.load(path, accounts: _seedUsers().resolve);
      final accepted = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;

      _writeTokenFile(dir, 'not json at all');
      await expectLater(validator.reload(), throwsA(isA<FormatException>()));

      expect(
          validator.stillValid(accepted.identity, accepted.credentialDigest),
          isTrue,
          reason: 'a rotation that produced a broken file must not disconnect '
              'the plant');
    });
  });
}
