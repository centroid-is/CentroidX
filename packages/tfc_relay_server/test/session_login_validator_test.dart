@TestOn('vm')

/// The validator that removes the need for a provisioned station credential
/// file — increment A of the 2026-09-08 ruling: *"remove the need of station
/// credential file, i am pretty certain we concluded that it is not
/// required."*
///
/// `SessionLoginValidator` admits a hello that presents **no credential at
/// all**, and what it admits is deliberately nobody: a self-naming sentinel
/// identity with the **empty group set**, which the session-level
/// policy then grades (`anonymous_session_test.dart`), which used to hold to
/// liveness alone. The sign-in that turns nobody into somebody is a later
/// increment; this file is the credential mechanism's half.
///
/// Five properties:
///
///  1. **A credential-less hello is accepted as the awaiting-sign-in
///     sentinel** — empty groups, no digest, names that read as "nobody
///     signed in" in every log and audit row they can reach.
///  2. **A presented station token is delegated verbatim** to the wrapped
///     `FileTokenValidator` while one is configured (the migration posture),
///     and **refused when none is** (the end state) — with a reason that
///     never echoes the credential.
///  3. **The sweep never reaps a panel sitting at the sign-in screen**:
///     `stillValid` answers true for the sentinel, always. And it stays
///     fail-closed for everything else: an identity this validator cannot
///     account for is not honoured.
///  4. **Delegated revocation still works** — the file+database cases 17-04b
///     built are reachable through the decorator unchanged.
///  5. **The credential mechanism still knows no permission vocabulary**:
///     the same stripped-source pin `file_token_validator_test.dart` holds
///     over the parser holds over this file.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/file_token_validator.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/auth/session_login_validator.dart';
import 'package:tfc_relay_server/src/token_validator.dart';

/// Long enough to clear [FileTokenValidator.minTokenLength], visibly not a
/// word anyone types by accident.
const _stationOneToken = 'ST101-1nZq4tGm7Yb2Kd8Vw6Rc0Pf3';

const _panelRole = 'Line Panel';

AuthenticatedUser _account(String username, String roleName,
        {bool stationAccount = true}) =>
    AuthenticatedUser(
        username: username, roleName: roleName, stationAccount: stationAccount);

/// A user source a case can edit underneath a running validator — the same
/// shape `file_token_validator_test.dart` uses, because the delegation arms
/// here are that file's cases reached through one more layer.
final class _UserSource {
  _UserSource(this.accounts);

  Map<String, ResolvedUser> accounts;

  ResolvedUser? resolve(String username) => accounts[username];
}

_UserSource _seedUsers() => _UserSource({
      'ST101-panel': ResolvedUser(
          user: _account('ST101-panel', _panelRole),
          groups: const {AccessGroup.operate}),
    });

HelloParams _helloWith(String? token) => HelloParams(
      protocol: protocolVersion,
      supported: const [protocolVersion],
      client: const PeerInfo('panel-under-test', '0.1.0'),
      token: token,
    );

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('relay-session-login-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

String _writeTokenFile(Directory dir, Object? contents) {
  final file = File('${dir.path}/tokens.json');
  file.writeAsStringSync(contents is String ? contents : jsonEncode(contents));
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['600', file.path]);
  }
  return file.path;
}

Map<String, Object?> _oneStation() => {
      'tokens': {
        _stationOneToken: {
          'username': 'ST101-panel',
          'station': 'ST101',
        },
      },
    };

Future<FileTokenValidator> _fileValidator(_UserSource users) async =>
    FileTokenValidator.load(_writeTokenFile(_tempDir(), _oneStation()),
        accounts: users.resolve);

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

/// The validator's source with whole comment lines removed — the house
/// stripping rule, matching `file_token_validator_test.dart`.
String _strippedValidatorSource() {
  final file = File(
      '${_packageRoot().path}/lib/src/auth/session_login_validator.dart');
  expect(file.existsSync(), isTrue,
      reason: 'the anti-vacuity half: a pin over a file that is not there '
          'finds zero of everything');
  final stripped = file
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
  expect(stripped, contains('class SessionLoginValidator'),
      reason: 'the second anti-vacuity half: a stripper that ate the whole '
          'file would find zero of everything too');
  return stripped;
}

void main() {
  group('a credential-less hello is admitted as nobody', () {
    test('a null token is accepted as the awaiting-sign-in sentinel, with '
        'the empty group set and no digest', () async {
      final validator = SessionLoginValidator();
      final verdict = await validator.validate(_helloWith(null));
      expect(verdict, isA<TokenAccepted>(),
          reason: 'the whole point of the sign-in model: a panel with no '
              'provisioned credential must be able to reach the sign-in '
              'screen, which lives on the far side of the handshake');
      final accepted = verdict as TokenAccepted;
      expect(accepted.identity.isAnonymous, isTrue,
          reason: 'admitted AS the anonymous identity — the same one a '
              'not-signed-in panel holds in direct mode, and from here on '
              'graded by the same AccessPolicy rather than held to a state '
              'the master system cannot see');
      expect(accepted.credentialDigest, isNull,
          reason: 'no credential was presented, so there is nothing for a '
              'revocation sweep to hold — a digest here would be a claim '
              'about a secret that does not exist');
      for (final group in AccessGroup.values) {
        expect(accepted.identity.session.can(group), isFalse,
            reason: 'no anonymous source was wired on this validator, and '
                'the default is EMPTY. That is the fail-closed default and '
                'it is the whole reason `anonymous` is a constructor '
                'argument: a built-in set would be this file grading, and a '
                'gateway that granted ${group.name} because nobody wired the '
                'source would look perfectly healthy from every screen');
      }
    });

    test('an empty-string token is the same admission', () async {
      final verdict = await SessionLoginValidator().validate(_helloWith(''));
      expect(verdict, isA<TokenAccepted>());
      expect((verdict as TokenAccepted).identity.isAnonymous, isTrue);
    });

    test('it reads as direct mode\'s anonymous everywhere it can be printed',
        () {
      final identity = SessionLoginValidator().anonymousIdentity();
      // **This arm is inverted on purpose, and the inversion is the change.**
      // It used to demand the opposite — that the identity must NEVER read as
      // Operator, because it was a third state that held nothing and saying
      // "Operator" would have overstated it. Anonymous IS Operator, by
      // construction and on both transports (`AccessSession.anonymous`, whose
      // doc says so in the same words), so reading as anything else is what
      // would now be wrong: it would put two vocabularies in one trail column
      // for one state.
      expect(identity.user.username, StationIdentity.anonymousWho,
          reason: 'the `who` an audit row records, and every direct-mode '
              'guard already writes this exact string for this state');
      expect(identity.session.roleName, kOperatorRoleName);
      expect(identity.session.isElevated, isFalse,
          reason: 'nobody is signed in, which is what makes session.login '
              'reachable — the direct-mode transition, not a new one');
    });
  });

  group('a presented credential', () {
    test('with no station file wrapped, a presented token is refused — and '
        'the reason never echoes it', () async {
      final verdict =
          await SessionLoginValidator().validate(_helloWith(_stationOneToken));
      expect(verdict, isA<TokenRejected>(),
          reason: 'the end state: the gateway reads no token file, so a '
              'credential in the hello is a credential nothing can honour — '
              'admitting it as nobody would hide the misconfiguration from '
              'the panel that most needs to hear about it');
      final reason = (verdict as TokenRejected).reason;
      expect(reason, isNot(contains(_stationOneToken)),
          reason: 'a refusal that echoes the credential publishes it into a '
              'log, a -32003 message and whatever the panel prints');
      expect(reason.toLowerCase(), contains('sign'),
          reason: 'the operator reading this refusal needs to be pointed at '
              'the replacement, the way D-06\'s load refusals point at the '
              'account row');
    });

    test('with a station file wrapped, a valid token is delegated verbatim',
        () async {
      final users = _seedUsers();
      final file = await _fileValidator(users);
      final validator = SessionLoginValidator(stations: file);
      final verdict = await validator.validate(_helloWith(_stationOneToken));
      expect(verdict, isA<TokenAccepted>());
      final accepted = verdict as TokenAccepted;
      expect(accepted.identity.user.username, 'ST101-panel',
          reason: 'the migration posture: every deployed token file keeps '
              'working, unchanged, until its station has crossed over');
      expect(accepted.identity.station, 'ST101');
      expect(accepted.credentialDigest, isNotNull,
          reason: 'the digest is what makes a replaced token detectable; '
              'delegation must not strip it');
      expect(accepted.identity.session.can(AccessGroup.operate), isTrue,
          reason: 'anti-vacuity: the delegated identity is the resolved one, '
              'not the sentinel — a decorator that answered nobody for '
              'every hello would pass every fail-closed arm above');
    });

    test('with a station file wrapped, an unknown token is the file '
        'validator\'s own refusal', () async {
      final validator =
          SessionLoginValidator(stations: await _fileValidator(_seedUsers()));
      final verdict = await validator
          .validate(_helloWith('WRONG-0aB1cD2eF3gH4iJ5kL6mN7'));
      expect(verdict, isA<TokenRejected>());
      expect((verdict as TokenRejected).reason, contains('token file'),
          reason: 'the refusal is the delegate\'s, verbatim: the decorator '
              'adds an admission, it rewrites no judgement');
    });
  });

  group('stillValid — the sweep', () {
    test('an anonymous identity is always still valid: a panel at the '
        'sign-in screen '
        'holds nothing a sweep could revoke', () async {
      final bare = SessionLoginValidator();
      expect(bare.stillValid(bare.anonymousIdentity(), null), isTrue);
      final wrapped =
          SessionLoginValidator(stations: await _fileValidator(_seedUsers()));
      expect(wrapped.stillValid(wrapped.anonymousIdentity(), null), isTrue,
          reason: 'with or without a wrapped file: the sweep walks every '
              'live session on every tick, and closing the sign-in screen '
              'once per poll would make the gateway unusable before anyone '
              'could sign in');
    });

    test('a delegated identity follows the file and the database, unchanged',
        () async {
      final users = _seedUsers();
      final file = await _fileValidator(users);
      final validator = SessionLoginValidator(stations: file);
      final accepted = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;
      expect(
          validator.stillValid(accepted.identity, accepted.credentialDigest),
          isTrue);
      // The database demotion 17-11 measured end to end: same account, same
      // role name, a group unticked on the role — the file untouched.
      users.accounts['ST101-panel'] = ResolvedUser(
          user: _account('ST101-panel', _panelRole),
          groups: const <AccessGroup>{});
      expect(
          validator.stillValid(accepted.identity, accepted.credentialDigest),
          isFalse,
          reason: 'the property the ruling must not cost: demote in '
              'app_role, and the live session is retired on the next sweep');
    });

    test('a signed-in person is judged live against the account source — '
        'the same sweep, one more provenance', () async {
      final source = _UserSource({
        'jon': ResolvedUser(
            user: _account('jon', 'Engineering', stationAccount: false),
            groups: const {AccessGroup.operate, AccessGroup.configure}),
      });
      final validator = SessionLoginValidator(accounts: source.resolve);
      final person = StationIdentity(
        user: _account('jon', 'Engineering', stationAccount: false),
        station: 'PACK-02',
        session: AccessSession(
            user: _account('jon', 'Engineering', stationAccount: false),
            groups: const {AccessGroup.operate, AccessGroup.configure}),
      );
      expect(validator.stillValid(person, null), isTrue,
          reason: 'an untouched account keeps its session — the sweep '
              'closes nothing whose credential still means what it meant');

      // The demotion: same account, same role name, a group unticked.
      source.accounts['jon'] = ResolvedUser(
          user: _account('jon', 'Engineering', stationAccount: false),
          groups: const {AccessGroup.operate});
      expect(validator.stillValid(person, null), isFalse,
          reason: 'demote in app_role and the signed-in person\'s live '
              'session is retired on the next sweep — the 4001 property, '
              'now for people');

      // The deletion: the operator\'s own revocation lever.
      source.accounts.remove('jon');
      expect(validator.stillValid(person, null), isFalse,
          reason: 'an account deleted out from under a live login is a '
              'revocation');
    });

    test('a signed-in person whose row was re-pointed is retired: the row '
        'is compared whole', () async {
      final source = _UserSource({
        'jon': ResolvedUser(
            user: _account('jon', 'Engineering', stationAccount: false),
            groups: const {AccessGroup.operate}),
      });
      final validator = SessionLoginValidator(accounts: source.resolve);
      final person = StationIdentity(
        user: _account('jon', 'Engineering', stationAccount: false),
        station: 'PACK-02',
        session: AccessSession(
            user: _account('jon', 'Engineering', stationAccount: false),
            groups: const {AccessGroup.operate}),
      );
      expect(validator.stillValid(person, null), isTrue);
      source.accounts['jon'] = ResolvedUser(
          user: _account('jon', 'Viewer', stationAccount: false),
          groups: const {AccessGroup.operate});
      expect(validator.stillValid(person, null), isFalse,
          reason: 'a re-roled account minted now would be a different '
              'identity, so the one being carried is stale — '
              'AuthenticatedUser\'s value equality is the comparison');
    });

    test('an unreachable account source answers "no evidence of a change", '
        'never "revoked" — the poll asymmetry, for people too', () async {
      final validator = SessionLoginValidator(
          accounts: (_) =>
              throw StateError('the account source is unreachable'));
      final person = StationIdentity(
        user: _account('jon', 'Engineering', stationAccount: false),
        station: 'PACK-02',
        session: AccessSession(
            user: _account('jon', 'Engineering', stationAccount: false),
            groups: const {AccessGroup.operate}),
      );
      expect(validator.stillValid(person, null), isTrue,
          reason: 'this runs on a poll against every live session; '
              'answering "revoked" when Postgres blinks would sign every '
              'person in the plant out for the length of a network hiccup '
              '— FileTokenValidator.stillValid\'s exact trade');
    });

    test('an identity this validator cannot account for is not honoured',
        () async {
      final somebody = StationIdentity(
        user: _account('ST101-panel', _panelRole),
        station: 'ST101',
        session: AccessSession(
            user: _account('ST101-panel', _panelRole),
            groups: const {AccessGroup.operate}),
      );
      expect(SessionLoginValidator().stillValid(somebody, null), isFalse,
          reason: 'fail closed: with no station file there is no way this '
              'identity was minted by this validator, and a sweep that '
              'answered "still fine" for it would keep alive a session '
              'whose provenance nothing can explain');
      expect(
          SessionLoginValidator()
              .stillValid(somebody, Uint8List.fromList(List.filled(32, 7))),
          isFalse,
          reason: 'a digest with nothing to look it up in is the same '
              'answer');
    });
  });

  group('reload', () {
    test('with no station file there is nothing to reload, and "changed" is '
        'honestly false', () async {
      final validator = SessionLoginValidator();
      await validator.reload();
      expect(await validator.reloadIfChanged(), isFalse);
    });

    test('with a station file, reloadIfChanged delegates: a removed token '
        'stops validating', () async {
      final users = _seedUsers();
      final dir = _tempDir();
      final path = _writeTokenFile(dir, _oneStation());
      final file = await FileTokenValidator.load(path,
          accounts: users.resolve);
      final validator = SessionLoginValidator(stations: file);
      final accepted = await validator.validate(_helloWith(_stationOneToken))
          as TokenAccepted;

      _writeTokenFile(dir, const {'tokens': <String, Object?>{}});
      expect(await validator.reloadIfChanged(), isTrue,
          reason: 'the digest changed, so the delegate re-parsed — the '
              'decorator must not swallow the answer the embedder\'s poll '
              'keys its logging on');
      expect(
          validator.stillValid(accepted.identity, accepted.credentialDigest),
          isFalse,
          reason: 'the file-driven revocation, through the decorator: '
              'pulled from the file, the credential buys nothing');
    });
  });

  group('the credential mechanism still knows no permission vocabulary', () {
    test('no AccessGroup name appears in the stripped source', () {
      final stripped = _strippedValidatorSource();
      expect(AccessGroup.values.length, 7,
          reason: 'the pin is over the whole vocabulary; if the enum grew, '
              'grow this test\'s understanding, not past it');
      for (final group in AccessGroup.values) {
        expect(stripped, isNot(contains(group.name)),
            reason: 'the moment this file can spell "${group.name}" it can '
                'grade — and grading is the master system\'s, never the '
                'credential mechanism\'s (17-CONTEXT constitution)');
      }
    });

    test('no seed role name appears either', () {
      final stripped = _strippedValidatorSource();
      for (final roleName in const ['Station Panel', 'Station Display']) {
        expect(stripped, isNot(contains(roleName)));
      }
    });
  });
}
