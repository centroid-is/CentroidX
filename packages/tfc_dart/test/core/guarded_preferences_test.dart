import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_preferences.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/interface.dart';

/// The keys these tests use, and the group [AccessPolicy] answers for each.
///
/// Read out of plan 03-01's rule table rather than invented here: a test that
/// asserts a guard denied `some_made_up_key` proves nothing if the policy would
/// have denied every key. `_operateKey` is the one an anonymous panel may
/// write, and it is what makes the denials below mean something.
const _operateKey = 'theme_mode'; // operate
const _configureKey = 'page_editor_data'; // configure
const _administerKey = 'state_man_config'; // administer

/// A key no rule matches, exact, prefix or suffix. The fail-closed default is
/// the only thing that can answer for it.
const _unclassifiedKey = 'totally_unclassified_key_xyz';

const _station = 'svn-nes-ot-cl02';

const _policy = AccessPolicy();

/// Anonymous is the Operator role by construction, and the Operator role on a
/// real station holds `operate`. Handing it an empty group set would make every
/// denial below pass for the wrong reason.
AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

AccessSession _configureSession() => const AccessSession(
      user: AuthenticatedUser(username: 'sigga', roleName: 'Shift Leader'),
      groups: {AccessGroup.operate, AccessGroup.configure},
    );

AccessSession _administerSession() => const AccessSession(
      user: AuthenticatedUser(username: 'jon', roleName: 'Engineering'),
      groups: {
        AccessGroup.operate,
        AccessGroup.configure,
        AccessGroup.administer,
      },
    );

/// A [Preferences] backed by a plain map that records every call it receives,
/// in order, into a log it may share with the audit sink.
///
/// `noSuchMethod` is the fallback on purpose, and it delegates to `Object`'s —
/// so a member the guard forwards that this double forgot to implement throws
/// loudly rather than answering null. That is the opposite of what the guard
/// itself may do, which is why the production file has none.
class _RecordingPreferences implements Preferences {
  _RecordingPreferences({
    Map<String, Object?>? initial,
    List<String>? log,
    this.localCache,
  }) : _sharedLog = log {
    if (initial != null) store.addAll(initial);
  }

  final Map<String, Object?> store = {};
  final Map<String, String> secrets = {};

  /// This double's own calls.
  final List<String> calls = [];

  /// The ordering log it shares with the audit sink, so "the row precedes the
  /// write" is assertable as one sequence.
  final List<String>? _sharedLog;

  void _log(String call) {
    calls.add(call);
    _sharedLog?.add(call);
  }

  /// When true every read throws — the unreadable store of T-03-28.
  bool failReads = false;

  final MySecureStorage _secureStorage = _NoSecrets();
  final StreamController<String> _changes =
      StreamController<String>.broadcast();

  @override
  final PreferencesApi? localCache;

  List<String> get writes => calls
      .where((c) => !c.startsWith('get') && !c.startsWith('containsKey'))
      .toList();

  void _read(String call) {
    _log(call);
    if (failReads) throw StateError('store unreadable');
  }

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async {
    _read('getKeys(allowList: $allowList)');
    return allowList == null
        ? store.keys.toSet()
        : store.keys.where(allowList.contains).toSet();
  }

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) async {
    _read('getAll(allowList: $allowList)');
    if (allowList == null) return Map<String, Object?>.from(store);
    return Map<String, Object?>.fromEntries(
        store.entries.where((e) => allowList.contains(e.key)));
  }

  @override
  Future<bool?> getBool(String key, {bool secret = false}) async {
    _read('getBool($key, secret: $secret)');
    return secret ? secrets[key] == 'true' : store[key] as bool?;
  }

  @override
  Future<int?> getInt(String key, {bool secret = false}) async {
    _read('getInt($key, secret: $secret)');
    return secret ? int.tryParse(secrets[key] ?? '') : store[key] as int?;
  }

  @override
  Future<double?> getDouble(String key, {bool secret = false}) async {
    _read('getDouble($key, secret: $secret)');
    return secret ? double.tryParse(secrets[key] ?? '') : store[key] as double?;
  }

  @override
  Future<String?> getString(String key, {bool secret = false}) async {
    _read('getString($key, secret: $secret)');
    return secret ? secrets[key] : store[key] as String?;
  }

  @override
  Future<List<String>?> getStringList(String key, {bool secret = false}) async {
    _read('getStringList($key, secret: $secret)');
    return secret
        ? secrets[key]?.split(',')
        : (store[key] as List<String>?)?.toList();
  }

  @override
  Future<bool> containsKey(String key, {bool secret = false}) async {
    _read('containsKey($key, secret: $secret)');
    return secret ? secrets.containsKey(key) : store.containsKey(key);
  }

  @override
  Future<void> setBool(String key, bool value,
      {bool saveToDb = true, bool secret = false}) async {
    _log('setBool($key, $value, saveToDb: $saveToDb, secret: $secret)');
    secret ? secrets[key] = '$value' : store[key] = value;
  }

  @override
  Future<void> setInt(String key, int value,
      {bool saveToDb = true, bool secret = false}) async {
    _log('setInt($key, $value, saveToDb: $saveToDb, secret: $secret)');
    secret ? secrets[key] = '$value' : store[key] = value;
  }

  @override
  Future<void> setDouble(String key, double value,
      {bool saveToDb = true, bool secret = false}) async {
    _log('setDouble($key, $value, saveToDb: $saveToDb, secret: $secret)');
    secret ? secrets[key] = '$value' : store[key] = value;
  }

  @override
  Future<void> setString(String key, String value,
      {bool saveToDb = true, bool secret = false}) async {
    _log('setString($key, $value, saveToDb: $saveToDb, secret: $secret)');
    secret ? secrets[key] = value : store[key] = value;
  }

  @override
  Future<void> setStringList(String key, List<String> value,
      {bool saveToDb = true, bool secret = false}) async {
    _log(
        'setStringList($key, ${value.join('|')}, saveToDb: $saveToDb, secret: $secret)');
    secret ? secrets[key] = value.join(',') : store[key] = value;
  }

  @override
  Future<void> remove(String key, {bool secret = false}) async {
    _log('remove($key, secret: $secret)');
    secret ? secrets.remove(key) : store.remove(key);
  }

  @override
  Future<void> clear({Set<String>? allowList}) async {
    _log('clear(allowList: $allowList)');
    if (allowList == null) {
      store.clear();
    } else {
      store.removeWhere((k, _) => allowList.contains(k));
    }
  }

  @override
  Database? get database => null;

  @override
  MySecureStorage get secureStorage => _secureStorage;

  @override
  Stream<String> get onPreferencesChanged => _changes.stream;

  @override
  Future<bool> isKeyInDatabase(String key) async {
    _log('isKeyInDatabase($key)');
    return store.containsKey(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoSecrets implements MySecureStorage {
  @override
  Future<void> delete({required String key}) async {}
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String value}) async {}
}

class _RecordingAuditSink implements AuditSink {
  _RecordingAuditSink({List<String>? log}) : _sharedLog = log;

  final List<AuditRecord> rows = [];
  final List<String> calls = [];
  final List<String>? _sharedLog;

  /// The sink whose non-throwing contract lives only in a doc comment.
  bool shouldThrow = false;

  @override
  Future<void> record(AuditRecord entry) async {
    rows.add(entry);
    final call = 'audit(${entry.itemKey}, allowed: ${entry.allowed})';
    calls.add(call);
    _sharedLog?.add(call);
    if (shouldThrow) throw StateError('audit database is down');
  }
}

/// Everything one test needs, built together so the log is genuinely shared.
class _Fixture {
  _Fixture({
    AccessSession? session,
    Map<String, Object?>? initial,
    String surface = 'pref',
  }) {
    inner = _RecordingPreferences(initial: initial, log: log);
    sink = _RecordingAuditSink(log: log);
    _session = session ?? _anonymous();
    guard = GuardedPreferences(
      inner: inner,
      policy: _policy,
      session: () => _session,
      audit: sink,
      station: _station,
      surface: surface,
      onDenied: denials.add,
    );
  }

  final List<String> log = [];
  final List<AccessDenied> denials = [];
  late final _RecordingPreferences inner;
  late final _RecordingAuditSink sink;
  late final GuardedPreferences guard;
  late AccessSession _session;

  set session(AccessSession s) => _session = s;
}

void main() {
  group('reads pass straight through', () {
    test('getKeys and getAll forward their allowList and return the inner answer',
        () async {
      final f = _Fixture(initial: {'a': 1, 'b': 2});
      expect(await f.guard.getKeys(), {'a', 'b'});
      expect(await f.guard.getKeys(allowList: {'a'}), {'a'});
      expect(await f.guard.getAll(), {'a': 1, 'b': 2});
      expect(await f.guard.getAll(allowList: {'b'}), {'b': 2});
      expect(f.inner.calls, [
        'getKeys(allowList: null)',
        'getKeys(allowList: {a})',
        'getAll(allowList: null)',
        'getAll(allowList: {b})',
      ]);
    });

    test('every typed getter returns the inner value and forwards secret:',
        () async {
      final f = _Fixture(initial: {
        'b': true,
        'i': 7,
        'd': 1.5,
        's': 'hello',
        'l': <String>['x', 'y'],
      });
      f.inner.secrets['s'] = 'shh';

      expect(await f.guard.getBool('b'), isTrue);
      expect(await f.guard.getInt('i'), 7);
      expect(await f.guard.getDouble('d'), 1.5);
      expect(await f.guard.getString('s'), 'hello');
      expect(await f.guard.getStringList('l'), ['x', 'y']);
      expect(await f.guard.getString('s', secret: true), 'shh');
      expect(f.inner.calls.last, 'getString(s, secret: true)');
    });

    test('containsKey forwards secret: and returns the inner answer', () async {
      final f = _Fixture(initial: {'a': 1});
      expect(await f.guard.containsKey('a'), isTrue);
      expect(await f.guard.containsKey('nope'), isFalse);
      f.inner.secrets['k'] = 'v';
      expect(await f.guard.containsKey('k', secret: true), isTrue);
    });

    test('a read of an administer key is never denied to an anonymous session',
        () async {
      // Spec §11 defers read permissions. A guarded read would break a station
      // with nobody signed in, which is every station at boot.
      final f = _Fixture(initial: {_administerKey: 'config'});
      expect(await f.guard.getString(_administerKey), 'config');
      expect(await f.guard.containsKey(_administerKey), isTrue);
      expect(await f.guard.getAll(), contains(_administerKey));
    });

    test('no read writes an audit row', () async {
      final f = _Fixture(initial: {
        _administerKey: 'config',
        'b': true,
        'i': 7,
        'd': 1.5,
        'l': <String>['x'],
      });
      await f.guard.getKeys();
      await f.guard.getAll();
      await f.guard.getBool('b');
      await f.guard.getInt('i');
      await f.guard.getDouble('d');
      await f.guard.getString(_administerKey);
      await f.guard.getStringList('l');
      await f.guard.containsKey(_administerKey);
      expect(f.sink.rows, isEmpty,
          reason: 'eight read members, zero rows: reads are not audited');
    });
  });

  group('a permitted write', () {
    test('reaches inner with key, value, saveToDb and secret unchanged',
        () async {
      final f = _Fixture(session: _configureSession());
      await f.guard.setString(_configureKey, 'layout', saveToDb: false);
      expect(f.inner.writes,
          ['setString($_configureKey, layout, saveToDb: false, secret: false)']);
      expect(f.inner.store[_configureKey], 'layout');
    });

    test('writes one row with the guard surface, allowed, group and origin',
        () async {
      final f = _Fixture(session: _configureSession());
      await f.guard.setString(_configureKey, 'layout');
      final row = f.sink.rows.single;
      expect(row.surface, 'pref');
      expect(row.itemKey, _configureKey);
      expect(row.member, isNull);
      expect(row.allowed, isTrue);
      expect(row.groupRequired, AccessGroup.configure.name);
      expect(row.origin, 'operator');
      expect(row.who, 'sigga');
      expect(row.roleName, 'Shift Leader');
      expect(row.station, _station);
      expect(row.newValue, 'layout');
    });

    test('records the previous value as oldValue', () async {
      final f = _Fixture(
          session: _configureSession(), initial: {_configureKey: 'before'});
      await f.guard.setString(_configureKey, 'after');
      expect(f.sink.rows.single.oldValue, 'before');
      expect(f.sink.rows.single.newValue, 'after');
    });

    test('records a null oldValue when the key was absent', () async {
      final f = _Fixture(session: _configureSession());
      await f.guard.setString(_configureKey, 'first');
      expect(f.sink.rows.single.oldValue, isNull);
    });

    test('writes its row before the delegate runs', () async {
      final f = _Fixture(session: _configureSession());
      await f.guard.setString(_configureKey, 'layout');
      final auditAt = f.log.indexWhere((c) => c.startsWith('audit('));
      final writeAt = f.log.indexWhere((c) => c.startsWith('setString('));
      expect(auditAt, greaterThanOrEqualTo(0));
      expect(writeAt, greaterThan(auditAt),
          reason: 'the row precedes the write, per spec §6');
    });

    test('an unreadable store does not fail the write and audits a null old',
        () async {
      final f = _Fixture(
          session: _configureSession(), initial: {_configureKey: 'before'});
      f.inner.failReads = true;
      await f.guard.setString(_configureKey, 'after');
      expect(f.inner.store[_configureKey], 'after');
      expect(f.sink.rows.single.oldValue, isNull);
      expect(f.sink.rows.single.allowed, isTrue);
    });

    test('two writes carry two different action ids', () async {
      final f = _Fixture(session: _configureSession());
      await f.guard.setString(_configureKey, 'one');
      await f.guard.setString(_configureKey, 'two');
      expect(f.sink.rows, hasLength(2));
      expect(f.sink.rows[0].actionId, hasLength(32));
      expect(f.sink.rows[0].actionId, isNot(f.sink.rows[1].actionId));
    });
  });

  group('a refused write', () {
    test('never reaches inner, writes one row, calls onDenied and throws',
        () async {
      final f = _Fixture();
      await expectLater(
        f.guard.setString(_administerKey, 'nope'),
        throwsA(isA<AccessDenied>()
            .having((e) => e.itemKey, 'itemKey', _administerKey)
            .having((e) => e.required, 'required', AccessGroup.administer)),
      );
      expect(f.inner.calls, isEmpty,
          reason: 'a denied write neither writes nor reads the store');
      final row = f.sink.rows.single;
      expect(row.allowed, isFalse);
      expect(row.groupRequired, AccessGroup.administer.name);
      expect(row.oldValue, isNull);
      expect(row.newValue, 'nope');
      expect(row.who, 'anonymous');
      expect(f.denials, hasLength(1));
      expect(f.denials.single.itemKey, _administerKey);
    });

    test('writes the row before it throws', () async {
      final f = _Fixture();
      try {
        await f.guard.setString(_administerKey, 'nope');
        fail('expected AccessDenied');
      } on AccessDenied {
        // The row must survive the exception — a denial with no row is the
        // repudiation this trail exists to prevent.
      }
      expect(f.log, ['audit($_administerKey, allowed: false)']);
    });
  });

  group('all seven write members are gated', () {
    final members = <String, Future<void> Function(GuardedPreferences g)>{
      'setBool': (g) => g.setBool(_administerKey, true),
      'setInt': (g) => g.setInt(_administerKey, 1),
      'setDouble': (g) => g.setDouble(_administerKey, 1.5),
      'setString': (g) => g.setString(_administerKey, 'v'),
      'setStringList': (g) => g.setStringList(_administerKey, ['v']),
      'remove': (g) => g.remove(_administerKey),
      'clear': (g) => g.clear(),
    };

    for (final entry in members.entries) {
      test('${entry.key} is refused to a session that lacks the group',
          () async {
        final f = _Fixture();
        await expectLater(entry.value(f.guard), throwsA(isA<AccessDenied>()));
        expect(f.inner.calls, isEmpty);
        expect(f.sink.rows.single.allowed, isFalse);
        expect(f.sink.rows.single.groupRequired, AccessGroup.administer.name);
      });

      test('${entry.key} is permitted to a session that holds the group',
          () async {
        final f = _Fixture(session: _administerSession());
        await entry.value(f.guard);
        expect(f.inner.writes, hasLength(1),
            reason: '${entry.key} must reach inner exactly once');
        expect(f.sink.rows.single.allowed, isTrue);
      });
    }
  });

  group('the config surface fails closed', () {
    test('an unrecognised key is refused to anonymous, requiring administer',
        () async {
      final f = _Fixture();
      await expectLater(
        f.guard.setString(_unclassifiedKey, 'v'),
        throwsA(isA<AccessDenied>()
            .having((e) => e.required, 'required', AccessGroup.administer)),
      );
      expect(f.sink.rows.single.groupRequired, AccessGroup.administer.name);
    });

    test('the same unrecognised key is permitted to an administer session',
        () async {
      // The other direction, and it is not decoration: a default that is only
      // ever tested in the refusing direction is satisfied by a guard that
      // refuses everything.
      final f = _Fixture(session: _administerSession());
      await f.guard.setString(_unclassifiedKey, 'v');
      expect(f.inner.store[_unclassifiedKey], 'v');
      expect(f.sink.rows.single.allowed, isTrue);
      expect(f.sink.rows.single.groupRequired, AccessGroup.administer.name);
    });
  });

  group('secret writes', () {
    test('a secret write is gated exactly like a plain one', () async {
      final f = _Fixture();
      await expectLater(
        f.guard.setString(_administerKey, 'hunter2', secret: true),
        throwsA(isA<AccessDenied>()),
      );
      expect(f.inner.calls, isEmpty);
    });

    test('a secret write audits a null oldValue and a null newValue', () async {
      final f = _Fixture(session: _administerSession());
      await f.guard.setString(_administerKey, 'hunter2', secret: true);
      final row = f.sink.rows.single;
      expect(row.allowed, isTrue);
      expect(row.oldValue, isNull);
      expect(row.newValue, isNull,
          reason: 'the trail records that a secret changed, never to what');
      expect(f.inner.secrets[_administerKey], 'hunter2');
    });

    test('a secret write never reads the old secret to audit it', () async {
      final f = _Fixture(session: _administerSession());
      f.inner.secrets[_administerKey] = 'old-credential';
      await f.guard.setString(_administerKey, 'new-credential', secret: true);
      expect(f.inner.calls.where((c) => c.startsWith('get')), isEmpty,
          reason: 'reading the old secret is how it would reach the trail');
      expect(f.sink.rows.single.oldValue, isNull);
    });

    test('a secret remove is gated and audited without values', () async {
      final f = _Fixture(session: _administerSession());
      f.inner.secrets[_administerKey] = 'old-credential';
      await f.guard.remove(_administerKey, secret: true);
      expect(f.inner.secrets, isEmpty);
      expect(f.sink.rows.single.oldValue, isNull);
      expect(f.sink.rows.single.newValue, isNull);
      expect(f.inner.calls.where((c) => c.startsWith('get')), isEmpty);
    });
  });

  group('remove', () {
    test('is gated on the key group and audits a null newValue', () async {
      final f = _Fixture(
          session: _configureSession(), initial: {_configureKey: 'before'});
      await f.guard.remove(_configureKey);
      final row = f.sink.rows.single;
      expect(row.itemKey, _configureKey);
      expect(row.groupRequired, AccessGroup.configure.name);
      expect(row.oldValue, 'before');
      expect(row.newValue, isNull);
      expect(f.inner.store, isEmpty);
    });
  });

  group('clear', () {
    test('is refused to a configure session that lacks administer', () async {
      // There is no key for the policy to look up, so clear carries its own
      // rule. A whole-store wipe is an administer action whatever the allowList
      // says.
      final f = _Fixture(session: _configureSession());
      await expectLater(
        f.guard.clear(),
        throwsA(isA<AccessDenied>()
            .having((e) => e.required, 'required', AccessGroup.administer)),
      );
      await expectLater(
        f.guard.clear(allowList: {_configureKey}),
        throwsA(isA<AccessDenied>()),
      );
      expect(f.inner.calls, isEmpty);
    });

    test('is permitted to an administer session and forwards the allowList',
        () async {
      final f = _Fixture(
          session: _administerSession(),
          initial: {_configureKey: 'a', _operateKey: 'b'});
      await f.guard.clear(allowList: {_configureKey});
      expect(f.inner.writes, ['clear(allowList: {$_configureKey})']);
      expect(f.inner.store.keys, [_operateKey]);
    });

    test('audits an itemKey of "*" with null old and new values', () async {
      final f = _Fixture(session: _administerSession());
      await f.guard.clear();
      final row = f.sink.rows.single;
      expect(row.itemKey, '*');
      expect(row.oldValue, isNull);
      expect(row.newValue, isNull);
      expect(row.groupRequired, AccessGroup.administer.name);
      expect(row.allowed, isTrue);
    });
  });

  group('the surface string', () {
    test('is what the policy is asked about, not just what is recorded',
        () async {
      // _operateKey is writable by anonymous on the 'pref' surface. On a
      // surface the policy does not know it is not, which is only true if the
      // same string drives the lookup and the row.
      final permitted = _Fixture();
      await permitted.guard.setString(_operateKey, 'dark');
      expect(permitted.sink.rows.single.allowed, isTrue);

      final f = _Fixture(surface: 'not-a-surface');
      await expectLater(
        f.guard.setString(_operateKey, 'dark'),
        throwsA(isA<AccessDenied>()
            .having((e) => e.required, 'required', AccessGroup.administer)),
      );
      expect(f.sink.rows.single.surface, 'not-a-surface');
      expect(f.sink.rows.single.groupRequired, AccessGroup.administer.name);
    });

    test('the wire lookup can no longer answer null — the tag surface floors '
        'at operate', () async {
      // This test used to pin that a null answer from the nullable wire
      // lookup was treated as administer on this guard. Since the 2026-09-02
      // operate-floor ruling `groupForWireSurface` is non-nullable — the
      // fail-open path this defended against is unrepresentable — and a
      // guard misconfigured onto the tag surface gets the tag floor, which a
      // session without operate still cannot pass.
      expect(_policy.groupForWireSurface('tag', _operateKey),
          AccessGroup.operate);
      final f = _Fixture(
          surface: 'tag',
          session: AccessSession.anonymous(const {AccessGroup.device}));
      await expectLater(
        f.guard.setString(_operateKey, 'dark'),
        throwsA(isA<AccessDenied>()
            .having((e) => e.required, 'required', AccessGroup.operate)),
      );
      expect(f.inner.calls, isEmpty);
      expect(f.sink.rows.single.allowed, isFalse);
    });
  });

  group('a failing audit sink', () {
    test('does not fail a permitted write', () async {
      final f = _Fixture(session: _configureSession());
      f.sink.shouldThrow = true;
      await f.guard.setString(_configureKey, 'layout');
      expect(f.inner.store[_configureKey], 'layout',
          reason: 'a blinking audit database must not refuse a lawful write');
    });

    test('does not replace AccessDenied on the deny path', () async {
      final f = _Fixture();
      f.sink.shouldThrow = true;
      await expectLater(
        f.guard.setString(_administerKey, 'nope'),
        throwsA(isA<AccessDenied>()),
      );
      expect(f.denials, hasLength(1),
          reason: 'onDenied still fires, so the operator still gets a prompt');
    });
  });

  group('the declared interface', () {
    test('GuardedPreferences is a PreferencesApi', () {
      // Spec §6 names PreferencesApi. The declared supertype is wider because
      // callers use members PreferencesApi does not have, so the spec's own
      // contract gets its own assertion.
      final f = _Fixture();
      expect(f.guard, isA<PreferencesApi>());
      expect(f.guard, isA<Preferences>());
    });

    test('the non-write members forward untouched', () async {
      final localCache = InMemoryPreferences();
      final inner = _RecordingPreferences(localCache: localCache);
      final guard = GuardedPreferences(
        inner: inner,
        policy: _policy,
        session: _anonymous,
        audit: _RecordingAuditSink(),
        station: _station,
      );
      expect(identical(guard.secureStorage, inner.secureStorage), isTrue);
      expect(identical(guard.localCache, localCache), isTrue);
      expect(guard.database, same(inner.database));
      expect(identical(guard.onPreferencesChanged, inner.onPreferencesChanged),
          isFalse,
          reason: 'a broadcast stream getter answers a fresh view each call');

      final seen = <String>[];
      final sub = guard.onPreferencesChanged.listen(seen.add);
      inner._changes.add('a_key');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(seen, ['a_key']);

      expect(await guard.isKeyInDatabase('nope'), isFalse);
    });
  });

  group('systemWrites — the one unchecked path', () {
    test('is a Preferences, and a distinct object rather than the guard', () {
      final f = _Fixture();
      expect(f.guard.systemWrites, isA<Preferences>());
      expect(identical(f.guard.systemWrites, f.guard), isFalse,
          reason: 'the checked and unchecked paths must be two objects, not '
              'two moods of one');
      expect(identical(f.guard.systemWrites, f.guard.systemWrites), isTrue,
          reason: 'the getter answers one stable object');
    });

    test('the same key is refused ordinarily and permitted through systemWrites',
        () async {
      // One test on purpose: two separate tests could both be satisfied by a
      // single wrong implementation that checks nothing anywhere.
      final f = _Fixture();
      await expectLater(
        f.guard.setString(_administerKey, 'boot-default'),
        throwsA(isA<AccessDenied>()),
      );
      expect(f.inner.store, isEmpty);

      await f.guard.systemWrites.setString(_administerKey, 'boot-default');
      expect(f.inner.store[_administerKey], 'boot-default');
      expect(f.sink.rows.map((r) => '${r.allowed}/${r.origin}').toList(),
          ['false/operator', 'true/system']);
    });

    test('writes one row with origin system and the group it would have needed',
        () async {
      final f = _Fixture();
      await f.guard.systemWrites.setString(_administerKey, 'boot-default');
      final row = f.sink.rows.single;
      expect(row.origin, 'system');
      expect(row.allowed, isTrue);
      expect(row.groupRequired, isNotEmpty);
      expect(row.groupRequired, AccessGroup.administer.name,
          reason: 'the trail shows what authority was skipped, not none');
      expect(row.surface, 'pref');
      expect(row.itemKey, _administerKey);
      expect(row.newValue, 'boot-default');
      expect(row.station, _station);
    });

    test('every write member is audited and reaches inner', () async {
      final members =
          <String, Future<void> Function(Preferences p)>{
        'setBool': (p) => p.setBool(_administerKey, true),
        'setInt': (p) => p.setInt(_administerKey, 1),
        'setDouble': (p) => p.setDouble(_administerKey, 1.5),
        'setString': (p) => p.setString(_administerKey, 'v'),
        'setStringList': (p) => p.setStringList(_administerKey, ['v']),
        'remove': (p) => p.remove(_administerKey),
        'clear': (p) => p.clear(),
      };
      for (final entry in members.entries) {
        final f = _Fixture();
        await entry.value(f.guard.systemWrites);
        expect(f.inner.writes, hasLength(1),
            reason: '${entry.key} must reach inner exactly once');
        expect(f.sink.rows.single.origin, 'system',
            reason: '${entry.key} must still land in the trail');
      }
    });

    test('a secret write through it still withholds the value', () async {
      final f = _Fixture();
      await f.guard.systemWrites
          .setString(_administerKey, 'boot-secret', secret: true);
      expect(f.inner.secrets[_administerKey], 'boot-secret');
      expect(f.sink.rows.single.oldValue, isNull);
      expect(f.sink.rows.single.newValue, isNull);
      expect(f.inner.calls.where((c) => c.startsWith('get')), isEmpty);
    });

    test('its reads forward to the same store and are indistinguishable',
        () async {
      final f = _Fixture(initial: {_administerKey: 'config', 'i': 7});
      expect(await f.guard.systemWrites.getString(_administerKey), 'config');
      expect(await f.guard.systemWrites.getInt('i'), 7);
      expect(await f.guard.systemWrites.getKeys(), {_administerKey, 'i'});
      expect(await f.guard.systemWrites.containsKey('i'), isTrue);
      expect(f.sink.rows, isEmpty, reason: 'reads are not audited anywhere');
    });

    test('its non-write members forward to the same inner store', () async {
      final f = _Fixture(initial: {'a': 1});
      final system = f.guard.systemWrites;
      expect(identical(system.secureStorage, f.inner.secureStorage), isTrue);
      expect(system.database, same(f.inner.database));
      expect(system.localCache, same(f.inner.localCache));
      expect(await system.isKeyInDatabase('a'), isTrue);
    });
  });

  group('the escape is a named object, asserted on the source text', () {
    late String source;

    setUpAll(() {
      source = _guardSourceWithoutComments();
    });

    test('no ordinary write member takes a parameter that bypasses the check',
        () {
      // A flag would be one keystroke from being copied into an operator path.
      expect(source, isNot(contains('bool system')));
      expect(source, isNot(contains('system:')));
      expect(source, isNot(contains('unchecked:')));
    });

    test('systemWrites is a getter returning a Preferences', () {
      expect(source, contains('Preferences get systemWrites'));
    });

    test('the class doc names every boot-time call site by file and line', () {
      // The list is plan 03-06's, which owns it and has already grown once.
      // A doc that names them is what makes a seventh caller obviously wrong.
      final raw = _guardSource();
      for (final site in const [
        'lib/providers/state_man.dart:26',
        'packages/tfc_dart/lib/core/state_man.dart:443',
        'lib/page_creator/page.dart:247',
        'packages/tfc_dart/lib/core/alarm.dart:220',
        'lib/providers/collector.dart:27',
        'lib/providers/mcp_bridge.dart:112',
      ]) {
        expect(raw, contains(site), reason: '$site is not named in the doc');
      }
    });
  });
}

/// The guard's own source.
String _guardSource() {
  final file = File('lib/core/access/guarded_preferences.dart');
  expect(file.existsSync(), isTrue,
      reason: 'Run this suite from packages/tfc_dart. Without the file these '
          'source assertions would pass vacuously.');
  return file.readAsStringSync();
}

/// The guard's own source with comments removed, so the doc explaining why
/// there is no bypass flag does not itself fail the test that enforces it.
String _guardSourceWithoutComments() {
  final withoutBlockComments =
      _guardSource().replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutBlockComments
      .split('\n')
      .map((line) {
        final idx = line.indexOf('//');
        return idx == -1 ? line : line.substring(0, idx);
      })
      .join('\n');
}
