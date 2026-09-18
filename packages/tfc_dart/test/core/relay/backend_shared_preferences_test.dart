/// `BackendSharedPreferences` refuses a removal the way it refuses a setter.
///
/// The class reads the plant's shared `config_item` rows and refuses to write
/// them: every setter throws `UnsupportedError` by name, because the backend
/// is not an author of the plant's configuration (its library doc). `remove`
/// and `clear` are writes too, and inherited from `Preferences` they were
/// not refused — they emptied a memory tier this store never reads and
/// announced the key, so a delete over the relay pipe "worked" while the row
/// stayed; and the relay's `clear` reached past them to `DELETE` from the
/// retired `flutter_preferences` table, which is the reintroduced reference
/// `scripts/check-flutter-preferences-retired.sh` exists to catch. These
/// cases pin the refusal, and pin that the keychain arm still goes to the
/// keychain.
///
/// A real `Database` over SQLite in a temp folder, the way
/// `backend_composition_test.dart` builds one: the constructor wants the
/// wrapper, and nothing here reads a row.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/relay/backend_shared_preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

void main() {
  late Directory tmp;
  late Database database;
  late BackendSharedPreferences prefs;

  setUp(() async {
    // An explicit fake, for the reason `backend_composition_test.dart` gives:
    // the Windows lane has no keychain implementation at all, and the macOS
    // one asks for a password.
    SecureStorage.setInstance(_MemorySecrets());
    tmp = Directory.systemTemp.createTempSync('backend-shared-prefs');
    database = Database(await AppDatabase.create(
      DatabaseConfig(applicationName: 'backend-shared-preferences-test'),
      sqliteFolder: tmp,
    ));
    prefs = await BackendSharedPreferences.create(database: database);
  });

  tearDown(() async {
    await database.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Matcher refusedByName(String member) => throwsA(isA<UnsupportedError>()
      .having((e) => e.message, 'message', contains(member)));

  test('remove is refused by name, like every setter', () async {
    await expectLater(
        prefs.remove('alarm_man_config'), refusedByName('remove'),
        reason: 'inherited, remove emptied a memory tier this store never '
            'reads and announced the key: a delete that "worked" while the '
            'row stayed');
  });

  test('clear is refused by name, with an allow list and without', () async {
    await expectLater(prefs.clear(), refusedByName('clear'));
    await expectLater(
        prefs.clear(allowList: const {'alarm_man_config'}),
        refusedByName('clear'),
        reason: 'a refusal that depended on the allow list, or on the plant '
            'being non-empty, would be one nobody could predict from the '
            'interface');
  });

  test('a secret removal still reaches the keychain, not the refusal',
      () async {
    await prefs.setString('token', 'abc', secret: true);
    expect(await prefs.getString('token', secret: true), 'abc');

    await prefs.remove('token', secret: true);

    expect(await prefs.getString('token', secret: true), isNull,
        reason: 'secrets never lived in a shared row; the keychain path is '
            'inherited and must stay exactly where it was');
  });
}

class _MemorySecrets implements MySecureStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      _values[key] = value;

  @override
  Future<void> delete({required String key}) async => _values.remove(key);
}
