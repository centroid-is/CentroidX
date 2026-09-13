/// What a server process serves when nobody told it what to serve.
///
/// The answer used to be "everything", by way of a `flutter_preferences`
/// read whose missing keys defaulted to `true`. Two live paths reached it
/// without anyone touching a toggle: a standalone launch against a migrated
/// plant, where the migration has deleted every MCP key from the shared
/// store, and a Postgres connect failure, where the binary falls onto an
/// in-memory database whose empty table reads identically. Both ran with all
/// nine tool groups enabled.
///
/// The read is gone. The toggles come from whoever spawned the process, and
/// absent they are [McpToolToggles.allDisabled] -- because an absent decision
/// on a capability surface is undecided, not yes.
library;

import 'dart:convert';

import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/tools/read_toggles.dart';
import 'package:tfc_mcp_server/src/tools/tool_toggles.dart';

void main() {
  group('resolveStartupToggles', () {
    test('nothing handed down disables every tool group', () {
      final startup = resolveStartupToggles();

      expect(startup.toggles, McpToolToggles.allDisabled);
      expect(startup.decided, isFalse);
      expect(startup.source, StartupToggleSource.absent);
    });

    test('every one of the nine groups is off, named individually', () {
      // Named one by one rather than compared to the const, so that adding a
      // tenth group with a `?? true` default fails here instead of quietly
      // shipping one enabled group.
      final toggles = resolveStartupToggles().toggles;

      expect(toggles.tagsEnabled, isFalse);
      expect(toggles.alarmsEnabled, isFalse);
      expect(toggles.configEnabled, isFalse);
      expect(toggles.drawingsEnabled, isFalse);
      expect(toggles.trendsEnabled, isFalse);
      expect(toggles.plcCodeEnabled, isFalse);
      expect(toggles.proposalsEnabled, isFalse);
      expect(toggles.techDocsEnabled, isFalse);
      expect(toggles.screenshotsEnabled, isFalse);

      for (final key in McpToolToggles.allJsonKeys) {
        expect(toggles.getByKey(key), isFalse,
            reason: 'group "$key" is enabled with no decision handed down');
      }
    });

    test('an empty environment value is the same as none', () {
      // An exported-but-empty variable is what a shell script that built the
      // value and got nothing leaves behind. It decided nothing.
      final startup = resolveStartupToggles(envJson: '');

      expect(startup.toggles, McpToolToggles.allDisabled);
      expect(startup.source, StartupToggleSource.absent);
    });

    test('the explanation names the variable that would fix it', () {
      final explanation = resolveStartupToggles().explanation;

      expect(explanation, isNotNull);
      expect(explanation, contains(kMcpTogglesEnvVar));
      expect(explanation, contains('--help'));
      // Says what state it is in, not only which knob exists.
      expect(explanation, contains('disabled'));
    });

    test('the explanation promises no tools but ping, not an empty list', () {
      // The one detail the surrounding prose gets wrong, pinned here because
      // it is what an operator reads while looking at a client that lists
      // exactly one tool. Promised an empty list, they conclude the closed
      // start failed and go hunting a bug that is not there.
      for (final message in [kNoTogglesMessage, kUnreadableTogglesMessage]) {
        expect(message, contains('ping'));
        expect(message, isNot(contains('empty tool list')));
      }
    });

    test('environment toggles are taken as given', () {
      final json = jsonEncode(
        const McpToolToggles(tagsEnabled: true, proposalsEnabled: false)
            .toJson(),
      );

      final startup = resolveStartupToggles(envJson: json);

      expect(startup.decided, isTrue);
      expect(startup.source, StartupToggleSource.environment);
      expect(startup.toggles.tagsEnabled, isTrue);
      expect(startup.toggles.proposalsEnabled, isFalse);
      expect(startup.explanation, isNull);
    });

    test('a group left out of a supplied object is off', () {
      // Present-but-partial is still a decision -- `decided` stays true, and
      // no explanation is printed -- but the blob's own defaults are `false`
      // now, so a group it does not name is a group it did not ask for. A
      // spawner that wants a group on has to name it; the app always does,
      // because it sends a full `toJson()`.
      final startup = resolveStartupToggles(envJson: '{"tags": false}');

      expect(startup.decided, isTrue);
      expect(startup.explanation, isNull);
      expect(startup.toggles, McpToolToggles.allDisabled);
    });

    test('a partial object still turns on what it does name', () {
      final startup = resolveStartupToggles(envJson: '{"alarms": true}');

      expect(startup.decided, isTrue);
      expect(startup.toggles.alarmsEnabled, isTrue);
      expect(startup.toggles.tagsEnabled, isFalse);
    });

    test('--toggles decides when the environment is silent', () {
      final startup = resolveStartupToggles(cliJson: '{"tags": true}');

      expect(startup.decided, isTrue);
      expect(startup.source, StartupToggleSource.commandLine);
      expect(startup.toggles.tagsEnabled, isTrue);
      expect(startup.toggles.alarmsEnabled, isFalse);
    });

    test('the environment wins over --toggles', () {
      // A spawning app sets the variable; a stale shell alias must not be
      // able to overrule it.
      final startup = resolveStartupToggles(
        envJson: '{"tags": false}',
        cliJson: '{"tags": true}',
      );

      expect(startup.source, StartupToggleSource.environment);
      expect(startup.toggles.tagsEnabled, isFalse);
    });

    test('unreadable JSON fails closed, and says it was unreadable', () {
      final startup = resolveStartupToggles(envJson: 'not json at all');

      expect(startup.toggles, McpToolToggles.allDisabled);
      expect(startup.decided, isFalse);
      expect(startup.source, StartupToggleSource.unreadable);
      // A typo in a client config is a different errand from a variable
      // nobody set, and the message has to send the reader to the right one.
      expect(startup.explanation, contains('could not be read'));
      expect(startup.explanation, contains(kMcpTogglesEnvVar));
    });

    test('JSON that is not an object fails closed', () {
      final startup = resolveStartupToggles(envJson: '[1, 2, 3]');

      expect(startup.toggles, McpToolToggles.allDisabled);
      expect(startup.source, StartupToggleSource.unreadable);
    });

    test('an unreadable environment value does not fall through to --toggles',
        () {
      // The spawner spoke and was not understood. Reading past it to a lesser
      // source would serve tools the spawner never asked for.
      final startup = resolveStartupToggles(
        envJson: '{oops',
        cliJson: '{"tags": true}',
      );

      expect(startup.toggles, McpToolToggles.allDisabled);
      expect(startup.source, StartupToggleSource.unreadable);
    });
  });

  group('McpToolToggles.allDisabled', () {
    test('is what an empty blob deserializes to', () {
      // This test used to assert the opposite, and the reversal is the
      // change. While `fromJson` defaulted every field to true, an empty map
      // was all-enabled, and `allDisabled` existed only for the case that is
      // not a stored preference at all -- a spawner that handed down nothing.
      // Storage now agrees with that case instead of contradicting it.
      expect(McpToolToggles.fromJson({}), McpToolToggles.allDisabled);
      expect(McpToolToggles.fromJson({}), isNot(McpToolToggles.allEnabled));
    });

    test('and an explicitly all-true blob still deserializes to all-enabled',
        () {
      expect(McpToolToggles.fromJson(McpToolToggles.allEnabled.toJson()),
          McpToolToggles.allEnabled);
    });

    test('round-trips through JSON as all-false', () {
      final restored =
          McpToolToggles.fromJson(McpToolToggles.allDisabled.toJson());
      expect(restored, McpToolToggles.allDisabled);
    });
  });

  group('kTogglesHelpText', () {
    test('documents the variable, the flag, and every group name', () {
      expect(kTogglesHelpText, contains(kMcpTogglesEnvVar));
      expect(kTogglesHelpText, contains('--toggles'));
      for (final key in McpToolToggles.allJsonKeys) {
        expect(kTogglesHelpText, contains(key),
            reason: 'group "$key" cannot be named by someone reading --help');
      }
    });

    test('says the server serves nothing until it is told otherwise', () {
      expect(kTogglesHelpText, contains('no tools'));
      // And is honest about the one exception, for the same reason the
      // stderr messages are.
      expect(kTogglesHelpText, contains('ping'));
    });
  });
}
