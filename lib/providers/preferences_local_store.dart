/// The drift-backed shared store, for the direct-mode surfaces that need more
/// than [PreferencesApi] gives them.
///
/// Three things live on the concrete class and on nothing else: the `secret:`
/// flag (secure storage), `isKeyInDatabase`, and the [Database] handle itself.
/// All three are properties of *this station talking to its own Postgres*, and
/// in gateway mode there is no such conversation — the gateway is the only
/// interface and the gateway keeps the secrets. So this provider refuses there
/// rather than answering something weaker that reads the same.
///
/// A page that needs this is by definition a direct-mode page. Reading it from
/// a surface that must also work over the relay is the mistake it exists to
/// make loud.
library;

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tfc_dart/core/preferences.dart';

import 'preferences.dart';

part 'preferences_local_store.g.dart';

@Riverpod(keepAlive: true)
Future<Preferences> localStorePreferences(Ref ref) async {
  final prefs = await ref.watch(preferencesProvider.future);
  if (prefs is! Preferences) {
    throw StateError(
        'This station is in gateway mode, where the shared preferences store '
        'is the gateway\'s and is reached over the socket. It has no local '
        'database, no secure-storage `secret:` path and no `isKeyInDatabase` — '
        'the gateway holds all three. Whatever asked for this is a direct-mode '
        'surface and needs a gateway answer of its own.');
  }
  return prefs;
}
