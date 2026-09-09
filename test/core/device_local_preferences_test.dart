@TestOn('vm')

/// The device-local/shared boundary, held against the constants it is spelled
/// from and against the keys that must stay on the other side of it.
///
/// The boundary is the one thing in this change that can break a plant
/// quietly: a key that must be per-station being routed to the backend
/// re-points every station from one, and a key that must be shared being
/// routed to the station makes two panels disagree. Neither shows up as an
/// error anywhere. So both directions are pinned here, per key, with the
/// reason living beside the entry in `device_local_preferences.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/device_local_preferences.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/startup_url.dart';
import 'package:tfc/core/system_clock.dart';
import 'package:tfc/core/update_channel.dart';

void main() {
  group('the device-local side', () {
    // Spelled from the constants, not from literals: if a key's constant is
    // renamed or its literal changed, the set follows it and this arm keeps
    // meaning what it says. A literal here would go stale silently.
    test('the transport config is device-local — a panel must be able to '
        'find the backend before it can ask the backend anything', () {
      expect(isDeviceLocalPreferenceKey(GatewayConfig.prefsKey), isTrue);
    });

    test('startup_url is device-local — a shared row overwrites every '
        "station's own choice on each sync (#354)", () {
      expect(isDeviceLocalPreferenceKey(startupUrlPrefsKey), isTrue);
    });

    test('the update channel is device-local — a station is moved to a '
        'prerelease build one at a time, on purpose', () {
      expect(isDeviceLocalPreferenceKey(updateChannelPrefsKey), isTrue);
    });

    test('ntp servers are device-local — applied at boot, before any '
        'gateway link exists', () {
      expect(isDeviceLocalPreferenceKey(ntpServersPrefsKey), isTrue);
    });

    test('every access.* key is device-local — the signed-in session is '
        'stored through one of them, and a shared session is one station '
        "holding another station's sign-in", () {
      expect(isDeviceLocalPreferenceKey('access.session'), isTrue);
      expect(isDeviceLocalPreferenceKey('access.inactivity_timeout_minutes'),
          isTrue);
      expect(isDeviceLocalPreferenceKey('access.inactivity_timeout_disabled'),
          isTrue);
    });

    test('the MCP config and its legacy spellings are device-local — the '
        'server runs on this machine and binds this machine\'s port', () {
      expect(isDeviceLocalPreferenceKey('mcp.config'), isTrue);
      expect(isDeviceLocalPreferenceKey('mcp_server_enabled'), isTrue);
      expect(isDeviceLocalPreferenceKey('mcp_server_port'), isTrue);
      expect(isDeviceLocalPreferenceKey('mcp_tools_plant_enabled'), isTrue);
    });

    test('the per-screen look is device-local — a panel in a wet room and a '
        'desk machine do not share a theme', () {
      expect(isDeviceLocalPreferenceKey('theme_mode'), isTrue);
      expect(isDeviceLocalPreferenceKey('color_scheme'), isTrue);
      expect(isDeviceLocalPreferenceKey('asset_stack_config'), isTrue);
      expect(isDeviceLocalPreferenceKey('color_picker_recent_colors'), isTrue);
    });

    test('the dbus login fields are device-local — they name a host this '
        'particular machine logs into', () {
      for (final key in const [
        'connectionType',
        'host',
        'username',
        'autoLogin',
        'sshPrivateKeyPath',
      ]) {
        expect(isDeviceLocalPreferenceKey(key), isTrue, reason: key);
      }
    });
  });

  group('the shared side', () {
    // The negative arm, and the one that matters most: these are the keys
    // whose whole purpose is that every panel agrees on them. A change that
    // quietly moved any of them to the device-local side would reintroduce
    // exactly the divergence this work exists to remove.
    test('alarm_man_config is NOT device-local — an alarm rule edited on one '
        'panel is the plant\'s rule, not that panel\'s', () {
      expect(isDeviceLocalPreferenceKey('alarm_man_config'), isFalse);
    });

    test('the shared configuration keys are NOT device-local', () {
      for (final key in const [
        'key_mappings',
        'page_editor_data',
        'page_editor_top_level_order',
        'collector_config',
        'state_man_config',
        'server_config_envelope',
      ]) {
        expect(isDeviceLocalPreferenceKey(key), isFalse, reason: key);
      }
    });

    test('an unknown key is shared — the shared store is the default and a '
        'key becomes device-local only by being named here', () {
      expect(isDeviceLocalPreferenceKey('some_new_config'), isFalse);
      // Near-misses on the prefixes, so a prefix cannot swallow a shared key
      // by accident.
      expect(isDeviceLocalPreferenceKey('accessible_pages'), isFalse);
      expect(isDeviceLocalPreferenceKey('mcpx'), isFalse);
    });
  });

  group('the set and the predicate cannot disagree', () {
    test('every named key answers true through the predicate', () {
      for (final key in kDeviceLocalPreferenceKeys) {
        expect(isDeviceLocalPreferenceKey(key), isTrue, reason: key);
      }
    });

    test('no named key is also reachable by a prefix — a key in both places '
        'is one of the two that nobody will remember to update', () {
      for (final key in kDeviceLocalPreferenceKeys) {
        for (final prefix in kDeviceLocalPreferencePrefixes) {
          expect(key.startsWith(prefix), isFalse,
              reason: '$key is already covered by the prefix "$prefix"');
        }
      }
    });

    test('the sets are unmodifiable — a boundary a caller can widen at '
        'runtime is not a boundary', () {
      expect(() => kDeviceLocalPreferenceKeys.add('x'), throwsUnsupportedError);
      expect(() => kDeviceLocalPreferencePrefixes.add('x'),
          throwsUnsupportedError);
    });
  });
}
