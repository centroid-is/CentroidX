@TestOn('vm')

/// The token file after Phase 17: it says **which identity this is**, and it
/// grants nothing.
///
/// D-06, ruled 2026-09-07. `role` stops being `"view"|"operate"` — a role
/// vocabulary the relay owned — and becomes a **role name** matched against
/// `app_role.name`, exactly the string `AuthenticatedUser.roleName` already
/// carries. The groups behind that name come from the database through a
/// [GroupResolver] seam, never from the file.
///
/// Five properties:
///
///  1. **A well-formed entry loads and produces a station account.**
///  2. **A `role` naming a permission is refused at load, by name.** Silently
///     mapping `"operate"` onto a group set would be the parallel role model
///     surviving as data — the duplication this phase exists to delete, with a
///     longer half-life. The ruling is explicit: refuse, and name the
///     replacement.
///  3. **No `AccessGroup` name appears in the parser.** The credential
///     mechanism may answer "which identity is this". The moment it answers
///     "and therefore may do X" it has crossed into the master system's
///     territory.
///  4. **An unknown role name and an unreachable role source are two
///     distinguishable refusals at `hello`**, never an identity with an empty
///     group set. An empty set is indistinguishable from a role that
///     deliberately grants nothing, and an operator who cannot connect must be
///     able to tell "your role was deleted" from "the database is down".
///  5. **Everything the credential mechanism already did, it still does** — the
///     length floor, the digest-keyed map, the duplicate-station refusal, the
///     loose-permission refusal, and the revocation sweep's cases.
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
/// the same station and the same role.
const _stationOneReplacement = 'ST101-4hYp8sWk2Cf6Nx1Dj9Ur5Lz7';

/// Two role names, as `app_role.name` rows. Neither is a permission, which is
/// the whole point of the format change.
const _panelRole = 'Line Panel';
const _displayRole = 'Wall Display';

/// A resolver backed by a map a case can edit underneath a running validator —
/// which is what the database being edited looks like from here.
final class _Roles {
  _Roles(this.groups);

  Map<String, Set<AccessGroup>> groups;

  /// Set to throw, standing in for a database nobody can reach.
  Object? failure;

  int calls = 0;

  Set<AccessGroup>? resolve(String roleName) {
    calls++;
    final boom = failure;
    if (boom != null) throw boom;
    return groups[roleName];
  }
}

_Roles _seedRoles() => _Roles({
      _panelRole: {AccessGroup.operate},
      _displayRole: <AccessGroup>{},
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

/// The one-station file every accept-path case starts from, in the new shape.
Map<String, Object?> _oneStation() => {
      'tokens': {
        _stationOneToken: {
          'username': 'ST101-panel',
          'station': 'ST101',
          'role': _panelRole,
        },
      },
    };

Map<String, Object?> _twoStations() => {
      'tokens': {
        _stationOneToken: {
          'username': 'ST101-panel',
          'station': 'ST101',
          'role': _panelRole,
        },
        _stationTwoToken: {
          'username': 'HALL-display',
          'station': 'ST201',
          'role': _displayRole,
        },
      },
    };

/// The package root, for the source-text pin below.
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

void main() {
  group('the file names a role and grants nothing', () {
    test('a well-formed entry loads as a station account', () async {
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          groups: _seedRoles().resolve);

      final verdict =
          await validator.validate(_helloWith(_stationOneToken));

      expect(verdict, isA<TokenAccepted>(),
          reason: 'the anti-vacuity half for everything below: a validator '
              'that refused every hello would satisfy no assertion here, but '
              'a reader skimming a cast would not see that');
      final identity = (verdict as TokenAccepted).identity;
      expect(identity.user.username, 'ST101-panel');
      expect(identity.user.roleName, _panelRole,
          reason: 'the file gives a role NAME, matched later against '
              'app_role.name — the same string AuthenticatedUser.roleName '
              'carries and the same string AccessSession.roleName reports');
      expect(identity.station, 'ST101');
      expect(identity.user.stationAccount, isTrue,
          reason: 'D-11: the identity a relay write is attributed to is a '
              'panel, not a person. `stationAccount` is the field that already '
              'means exactly that (schema v8), so the trail viewer can render '
              'it differently from a human without a second flag');
      expect(identity.session.can(AccessGroup.operate), isTrue,
          reason: 'the groups came from the resolver, not from the file');
    });

    test('a role naming a permission is refused at load, and the message '
        'names the replacement', () async {
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
            FileTokenValidator.load(path, groups: _seedRoles().resolve),
            throwsA(isA<FormatException>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains(legacy),
                  contains(path),
                  contains(FileTokenValidator.replacementPanelRoleName),
                  contains(FileTokenValidator.replacementDisplayRoleName),
                ))),
            reason: 'D-06, ruled 2026-09-07 with the deployment cost accepted: '
                'a Phase 17 backend refuses to start on a legacy token file, '
                'with a message naming the replacement. **No silent '
                'translation** — translating "$legacy" onto a group set would '
                'let a legacy grant survive unexamined, which is the '
                'duplication this phase exists to delete, only with a longer '
                'half-life. The message is what somebody reads at 3am, so it '
                'names the file, the offending value and what to write '
                'instead');
      }
    });

    test('every permission name is refused in the role field, not only the '
        'two legacy ones', () async {
      // The generalisation, and it is the phase law rather than a nicety: the
      // token file may not name a permission at all. `configure` and
      // `administer` were never legal in the old format either — but after
      // this change they would look like perfectly ordinary role names, and a
      // deployment that created an `app_role` row called "administer" would
      // have a token file granting administer by spelling.
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
            FileTokenValidator.load(path, groups: _seedRoles().resolve),
            throwsA(isA<FormatException>()),
            reason: '"${group.name}" is a permission, not a role. A token file '
                'that names one is the credential mechanism answering "and '
                'therefore may do X"');
      }
    });

    test('an ordinary role name is not refused', () async {
      // The control for both arms above. A loader that refused every role
      // value would pass them and start nothing.
      await expectLater(
          FileTokenValidator.load(
              _writeTokenFile(_tempDir(), _oneStation()),
              groups: _seedRoles().resolve),
          completes);
    });

    test('the legacy entry shape is refused, and says which keys changed',
        () async {
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          _stationOneToken: {'stationId': 'ST101', 'role': _panelRole},
        },
      });

      await expectLater(
          FileTokenValidator.load(path, groups: _seedRoles().resolve),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              allOf(contains('stationId'), contains('station'),
                  contains('username')))),
          reason: 'a half-migrated file is the dangerous one: the old key '
              'names with a new role name would otherwise load as an entry '
              'with no station at all. The message must say which keys moved, '
              'because the operator holding this file is the one who has to '
              'rewrite it');
    });

    test('no permission name appears in the parser', () {
      final file = File(
          '${_packageRoot().path}/lib/src/auth/file_token_validator.dart');
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

      for (final group in AccessGroup.values) {
        expect(stripped, isNot(contains(group.name)),
            reason: 'the parser names "${group.name}". The relay keeps the '
                'credential mechanism and no policy: it may answer "which '
                'identity is this" and it may not answer "and therefore may '
                'do X". Note this pin is satisfied *honestly* — the legacy '
                'refusal recognises a permission by asking '
                'AccessGroup.byName, so it refuses all seven without '
                'spelling any of them');
      }
    });
  });

  group('an unresolvable role is refused at hello, not admitted empty', () {
    test('an unknown role name is refused', () async {
      final roles = _seedRoles();
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          _stationOneToken: {
            'username': 'ST101-panel',
            'station': 'ST101',
            'role': 'Ghost Role',
          },
          _stationTwoToken: {
            'username': 'HALL-display',
            'station': 'ST201',
            'role': _panelRole,
          },
        },
      });
      final validator =
          await FileTokenValidator.load(path, groups: roles.resolve);

      final ghost = await validator.validate(_helloWith(_stationOneToken));
      final real = await validator.validate(_helloWith(_stationTwoToken));

      expect(real, isA<TokenAccepted>(),
          reason: 'the anti-vacuity half, and it goes first: the same '
              'resolver, the same file, the same validator. Without it the '
              'refusal below passes against a validator that refuses '
              'everybody, which this milestone has already been bitten by');
      expect((real as TokenAccepted).identity.session.can(AccessGroup.operate),
          isTrue);

      expect(ghost, isA<TokenRejected>(),
          reason: 'D-06 fail-closed: an unknown role name is refused at hello, '
              'not admitted with an empty group set. An empty set is '
              'indistinguishable in the audit trail from a role that was '
              'loaded successfully and grants nothing, and those two must not '
              'look the same');
      expect((ghost as TokenRejected).reason, contains('Ghost Role'));
      expect(ghost.reason, isNot(contains(_stationOneToken)),
          reason: 'the reason travels into a -32003 message and into the '
              'gateway\'s log; naming the credential there publishes it');
    });

    test('an unreachable role source is a different refusal', () async {
      final roles = _seedRoles();
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          groups: roles.resolve);

      final reachable = await validator.validate(_helloWith(_stationOneToken));
      expect(reachable, isA<TokenAccepted>(),
          reason: 'the anti-vacuity half: this validator accepts this token '
              'when the role source answers, so the refusal below is caused '
              'by the outage and not by the fixture');

      roles.failure = StateError('the access database is not reachable');
      final unreachable =
          await validator.validate(_helloWith(_stationOneToken));

      expect(unreachable, isA<TokenRejected>());

      final ghostRoles = _seedRoles();
      final ghostValidator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), {
            'tokens': {
              _stationOneToken: {
                'username': 'ST101-panel',
                'station': 'ST101',
                'role': 'Ghost Role',
              },
            },
          }),
          groups: ghostRoles.resolve);
      final ghost =
          await ghostValidator.validate(_helloWith(_stationOneToken)) as TokenRejected;

      expect((unreachable as TokenRejected).reason, isNot(ghost.reason),
          reason: 'an operator who cannot connect must be able to tell "your '
              'role was deleted" from "the database is down". One is fixed by '
              'editing app_role and one is fixed by looking at Postgres; a '
              'single message sends the wrong person to the wrong place');
      expect(unreachable.reason, contains(FileTokenValidator.roleSourceDownMarker));
      expect(ghost.reason, isNot(contains(FileTokenValidator.roleSourceDownMarker)));
    });

    test('load with no resolver throws', () async {
      await expectLater(
          FileTokenValidator.load(_writeTokenFile(_tempDir(), _oneStation())),
          throwsA(isA<ArgumentError>()),
          reason: 'there is no permissive fallback, on this file\'s own stated '
              'reasoning about a misspelled PEM: a gateway that admitted every '
              'panel because nobody wired the role source would look perfectly '
              'healthy from every screen in the plant');
    });
  });

  group('the credential mechanism is unchanged', () {
    test('a token file with two stations sharing an id is refused', () async {
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          _stationOneToken: {
            'username': 'ST101-panel',
            'station': 'ST101',
            'role': _panelRole,
          },
          _stationTwoToken: {
            'username': 'ST101-spare',
            'station': 'ST101',
            'role': _displayRole,
          },
        },
      });

      await expectLater(
          FileTokenValidator.load(path, groups: _seedRoles().resolve),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              allOf(contains('ST101'), contains(path)))),
          reason: 'two tokens answering to one station makes a revocation '
              'ambiguous: pulling one of them leaves the other still valid for '
              'the identity that was supposed to lose access, and the sweep '
              'cannot tell which live session to close');
    });

    test('a token shorter than the floor is refused', () async {
      final path = _writeTokenFile(_tempDir(), {
        'tokens': {
          'short-token': {
            'username': 'ST101-panel',
            'station': 'ST101',
            'role': _panelRole,
          },
        },
      });

      await expectLater(
          FileTokenValidator.load(path, groups: _seedRoles().resolve),
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
          FileTokenValidator.load(path, groups: _seedRoles().resolve),
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
              groups: _seedRoles().resolve),
          throwsA(isA<FileSystemException>()),
          reason: 'there is no permissive fallback: a gateway that accepted '
              'every panel because somebody misspelled a path would look '
              'perfectly healthy');
    });

    test('an unknown or absent credential is refused, and the refusal never '
        'repeats it', () async {
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          groups: _seedRoles().resolve);

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

    test('a credential the file does not carry never reaches the role source',
        () async {
      // The ordering the constant-time compare depends on: the digest lookup
      // decides, and a miss must not become a database round trip an attacker
      // can time.
      final roles = _seedRoles();
      final validator = await FileTokenValidator.load(
          _writeTokenFile(_tempDir(), _oneStation()),
          groups: roles.resolve);
      final before = roles.calls;

      await validator.validate(_helloWith('IMPOSTOR-4d2f8e1c6b9a3057fe4d2c8b'));

      expect(roles.calls, before,
          reason: 'a refused credential asked the role source nothing');
      await validator.validate(_helloWith(_stationOneToken));
      expect(roles.calls, greaterThan(before),
          reason: 'the anti-vacuity half: a validator that never called the '
              'resolver at all would pass the assertion above');
    });

    test('stillValid follows the file, not the session', () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _twoStations());
      final validator =
          await FileTokenValidator.load(path, groups: _seedRoles().resolve);

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

    test('a station whose role name was changed is no longer the identity it '
        'holds', () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _oneStation());
      final validator =
          await FileTokenValidator.load(path, groups: _seedRoles().resolve);

      final operating = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      expect(operating.identity.user.roleName, _panelRole);
      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isTrue);

      _writeTokenFile(dir, {
        'tokens': {
          _stationOneToken: {
            'username': 'ST101-panel',
            'station': 'ST101',
            'role': _displayRole,
          },
        },
      });
      await validator.reload();

      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isFalse,
          reason: 'a session minted before the change is still carrying the '
              'old role. Leaving it live is the demotion not taking effect '
              'until the panel happens to reconnect — which an operator can '
              'postpone indefinitely by not reconnecting');
    });

    test('a station whose role kept its name and lost its groups is no longer '
        'the identity it holds', () async {
      // The fifth case, and the one the format change creates: the role set is
      // part of the credential now, so the sweep must see a change made in the
      // *database* and not only one made in the file. D-08.
      final dir = _tempDir();
      final roles = _seedRoles();
      final validator = await FileTokenValidator.load(
          _writeTokenFile(dir, _oneStation()),
          groups: roles.resolve);

      final operating = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isTrue,
          reason: 'the anti-vacuity half: nothing has changed yet, and a '
              'stillValid that answered false for everything would pass the '
              'assertion below and close the whole plant on every reload');

      // Nobody touched the file. Somebody unticked `operate` on the role.
      roles.groups = {
        _panelRole: <AccessGroup>{},
        _displayRole: <AccessGroup>{},
      };

      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isFalse,
          reason: 'after this phase the role name decides configure and '
              'administer as well as operate, so a demotion that only took '
              'effect on the next reconnect is strictly worse than it used to '
              'be. The poll that calls this is 17-11\'s; without it this is '
              'dead code, which is exactly what this arm is here to stop it '
              'quietly becoming');
    });

    test('an unreachable role source does not close every live session',
        () async {
      // Deliberately the opposite of the hello path, and the asymmetry is the
      // point. Refusing at hello is safe: it runs once, the operator is told,
      // and nothing that was running stops. Refusing here runs on a poll
      // against every live session, so answering "revoked" when Postgres
      // blinks would take the plant's screens down for the length of a
      // network hiccup — the same trade `AccessPolicy.groupForTag`'s swallow
      // already makes on the write path of every jog.
      final dir = _tempDir();
      final roles = _seedRoles();
      final validator = await FileTokenValidator.load(
          _writeTokenFile(dir, _oneStation()),
          groups: roles.resolve);
      final operating = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;

      roles.failure = StateError('the access database is not reachable');

      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isTrue,
          reason: 'an unreadable role source is not evidence of a demotion');

      roles.failure = null;
      roles.groups = {_panelRole: <AccessGroup>{}};
      expect(
          validator.stillValid(operating.identity, operating.credentialDigest),
          isFalse,
          reason: 'the anti-vacuity half: once the source answers again, a '
              'real demotion is still seen. A stillValid that had simply '
              'stopped comparing groups would pass the assertion above');
    });

    test('a replaced token is no longer the credential the session holds',
        () async {
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _oneStation());
      final validator =
          await FileTokenValidator.load(path, groups: _seedRoles().resolve);

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
            'role': _panelRole,
          },
        },
      });
      await validator.reload();

      expect(
          validator.stillValid(accepted.identity, accepted.credentialDigest),
          isFalse,
          reason: 'the session is holding the leaked credential. Nothing about '
              'its identity changed — same station, same role — which is '
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
          await FileTokenValidator.load(path, groups: _seedRoles().resolve);
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
          await FileTokenValidator.load(path, groups: _seedRoles().resolve);
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
