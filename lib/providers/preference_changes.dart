/// Every edit to the shared configuration store, whichever store that is.
///
/// `Preferences.onPreferencesChanged` exists on the drift-backed class;
/// `ClientPreferencesApi.onPreferencesChanged` exists on the relayed one. Both
/// are `Stream<String>` of changed keys and both mean the same thing — but
/// they are not the same type, and [PreferencesApi] deliberately does not
/// declare it (adding it would oblige every fake in the repository to grow a
/// controller).
///
/// So the transport is resolved once, here, and callers watch a stream instead
/// of a store. `stateManProvider` is the caller that matters: it re-applies
/// `key_mappings` the moment somebody saves one, and it must do that on both
/// transports.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/preferences.dart' show Preferences;

import '../core/relayed_preferences.dart';
import 'preferences.dart';

final preferenceChangesProvider = StreamProvider<String>((ref) async* {
  final prefs = await ref.watch(preferencesProvider.future);
  final stream = switch (prefs) {
    RelayedPreferences() => prefs.onPreferencesChanged,
    Preferences() => prefs.onPreferencesChanged,
    // A store that announces nothing — an in-memory one in a test, say. An
    // empty stream is the honest answer: nothing will ever change under it.
    _ => const Stream<String>.empty(),
  };
  yield* stream;
});
