/// The one [GatewayPreferencesSlot] for this container.
///
/// Its own file, and not a second declaration inside `state_man.dart` beside
/// `gatewayAlarmSlotProvider`, because both `preferences.dart` and
/// `state_man.dart` need it and those two already point at each other:
/// `state_man.dart` reads `preferencesProvider`, which is exactly why the slot
/// exists. Declaring it in either would make the pair import each other, and
/// the next person reading that cycle would have to reconstruct which half was
/// the plumbing.
///
/// `preferencesProvider` reads the slot; `stateManProvider` fills it once the
/// relay client exists, fails it if that build throws, and clears it on
/// dispose. See [GatewayPreferencesSlot] for what each of those does to a
/// caller that is parked on it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/relayed_preferences.dart';

final gatewayPreferencesSlotProvider = Provider<GatewayPreferencesSlot>((ref) {
  final slot = GatewayPreferencesSlot();
  ref.onDispose(slot.dispose);
  return slot;
});
