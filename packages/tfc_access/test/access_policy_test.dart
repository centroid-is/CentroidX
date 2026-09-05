import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';

void main() {
  group('AccessSurface', () {
    test('has exactly three values', () {
      // Exact, not `greaterThan`. A fourth write surface is a decision: every
      // surface this enum names has to have an answer in `groupForPref` or
      // `groupForTag`, and a value added without one would ride the unmapped
      // branch forever without anybody noticing.
      expect(AccessSurface.values, hasLength(3));
    });

    test('values are tag, pref, route in that order', () {
      expect(AccessSurface.values, [
        AccessSurface.tag,
        AccessSurface.pref,
        AccessSurface.route,
      ]);
    });

    test('wire names match spec section 2 surface column vocabulary', () {
      expect(AccessSurface.values.map((s) => s.wireName), [
        'tag',
        'pref',
        'route',
      ]);
    });

    test('byWireName resolves each of the three wire names', () {
      expect(AccessSurface.byWireName('tag'), AccessSurface.tag);
      expect(AccessSurface.byWireName('pref'), AccessSurface.pref);
      expect(AccessSurface.byWireName('route'), AccessSurface.route);
    });

    test('byWireName returns null for anything outside the vocabulary', () {
      // 'auth' is a real value in spec section 2's surface column and is
      // deliberately not a write surface, so the enum and the column are not
      // the same set.
      expect(AccessSurface.byWireName('auth'), isNull);
      expect(AccessSurface.byWireName(''), isNull);
      expect(AccessSurface.byWireName('Tag'), isNull);
      expect(AccessSurface.byWireName('preferences'), isNull);
    });
  });

  group('AccessPolicy construction', () {
    test('is const-constructible with no arguments', () {
      const policy = AccessPolicy();
      expect(policy, isA<AccessPolicy>());
    });

    test('two instances built the same way answer identically', () {
      const a = AccessPolicy();
      const b = AccessPolicy();
      for (final key in ['page_editor_data', 'nonsense', '', 'BATCH.recipes']) {
        expect(a.groupForPref(key), b.groupForPref(key));
        expect(a.groupForTag(key), b.groupForTag(key));
      }
      expect(a.groupForRoute('/advanced/page-editor'),
          b.groupForRoute('/advanced/page-editor'));
    });
  });

  group('the operate floor: every tag write requires a group', () {
    test('an unbound tag key answers the operate floor, never null', () {
      // The 2026-09-02 ruling replacing the fail-open half: every tag write
      // requires at least `operate`, and the return type carries it — there
      // is no null to collapse into "no group required". The plant does not
      // lock on the day this merges because the anonymous session maps to
      // the Operator role, which holds `operate`; what changes is that an
      // account deliberately stripped of `operate` can no longer press any
      // plain control.
      const policy = AccessPolicy();
      expect(policy.groupForTag('CN01.MOT01'), AccessGroup.operate);
      expect(policy.groupForTag(''), AccessGroup.operate);
      expect(policy.groupForTag('anything_at_all'), AccessGroup.operate);
      expect(policy.groupForTag('server_config_envelope'), AccessGroup.operate);
    });

    test('groupForTag consults the injected binding lookup', () {
      final policy = AccessPolicy(
        tagBindings: (key, member) {
          if (key == 'CN01.MOT01' && member == 'p_cfg_ManualFreq') {
            return AccessGroup.setpoints;
          }
          if (key == 'CN01.MOT01' && member == 'p_cmd_JogFwd') {
            return AccessGroup.operate;
          }
          return null;
        },
      );
      expect(policy.groupForTag('CN01.MOT01', member: 'p_cfg_ManualFreq'),
          AccessGroup.setpoints);
      expect(policy.groupForTag('CN01.MOT01', member: 'p_cmd_JogFwd'),
          AccessGroup.operate);
    });

    test('groupForTag floors to operate when the binding lookup answers null',
        () {
      // A member no bound template mentions gets the same floor as an
      // unbound key: bindings can only raise the requirement above operate,
      // never lower it past the floor.
      final policy = AccessPolicy(tagBindings: (key, member) => null);
      expect(policy.groupForTag('CN01.MOT01', member: 'p_stat_RunMode'),
          AccessGroup.operate);
    });

    test('a binding lookup that throws is treated as no binding — the floor',
        () {
      // An unreadable template table must not escalate past the floor: the
      // guard still answers `operate`, which the anonymous Operator role
      // holds, so a Postgres outage cannot take jogging off the floor — and
      // cannot open a bound setpoint wider than any unbound key either.
      final policy = AccessPolicy(
        tagBindings: (key, member) => throw StateError('template table is gone'),
      );
      expect(policy.groupForTag('CN01.MOT01', member: 'p_cmd_JogFwd'),
          AccessGroup.operate);
      expect(policy.groupForTag('CN01.MOT01'), AccessGroup.operate);
      expect(
        policy.groupForWireSurface('tag', 'CN01.MOT01', member: 'p_cmd_JogFwd'),
        AccessGroup.operate,
      );
    });
  });

  group('the asymmetry: config keys fail CLOSED', () {
    test('an unrecognised preference key requires administer', () {
      // The mirror of the tag direction, and the return type carries this half
      // too: non-nullable, so there is no "unrestricted" answer to reopen.
      const policy = AccessPolicy();
      expect(policy.groupForPref('nobody_classified_this'),
          AccessGroup.administer);
      expect(policy.groupForPref('some.new.subsystem.key'),
          AccessGroup.administer);
    });

    test('groupForPref never answers null, including for the empty string', () {
      const policy = AccessPolicy();
      for (final key in ['', ' ', 'x', 'page_editor_data', 'chat.history']) {
        expect(policy.groupForPref(key), isA<AccessGroup>());
      }
    });
  });

  group('groupForRoute', () {
    test('an unknown path defaults to operate', () {
      const policy = AccessPolicy();
      expect(policy.groupForRoute('/trends'), AccessGroup.operate);
    });

    test('a null path defaults to operate', () {
      const policy = AccessPolicy();
      expect(policy.groupForRoute(null), AccessGroup.operate);
    });

    test('a raised route passed in by the app answers its group', () {
      // Plan 03-06 passes kRaisedRoutes in; this package must not import the
      // app's route table.
      const policy = AccessPolicy(routes: {
        '/advanced/page-editor': AccessGroup.configure,
        '/advanced/server-config': AccessGroup.administer,
      });
      expect(policy.groupForRoute('/advanced/page-editor'),
          AccessGroup.configure);
      expect(policy.groupForRoute('/advanced/server-config'),
          AccessGroup.administer);
      expect(policy.groupForRoute('/advanced/unlisted'), AccessGroup.operate);
    });
  });

  group('groupForWireSurface', () {
    test("the 'tag' wire name delegates to groupForTag and floors to operate",
        () {
      const policy = AccessPolicy();
      expect(policy.groupForWireSurface('tag', 'CN01.MOT01'),
          AccessGroup.operate);

      final bound = AccessPolicy(
        tagBindings: (key, member) =>
            member == 'p_cfg_ManualFreq' ? AccessGroup.setpoints : null,
      );
      expect(
        bound.groupForWireSurface('tag', 'CN01.MOT01',
            member: 'p_cfg_ManualFreq'),
        AccessGroup.setpoints,
      );
    });

    test("the 'pref' wire name delegates to groupForPref and never answers null",
        () {
      const policy = AccessPolicy();
      expect(policy.groupForWireSurface('pref', 'never_seen_before'),
          AccessGroup.administer);
      expect(policy.groupForWireSurface('pref', ''), AccessGroup.administer);
    });

    test("the 'route' wire name delegates to groupForRoute", () {
      const policy = AccessPolicy(routes: {
        '/advanced/page-editor': AccessGroup.configure,
      });
      expect(policy.groupForWireSurface('route', '/advanced/page-editor'),
          AccessGroup.configure);
      expect(policy.groupForWireSurface('route', '/trends'),
          AccessGroup.operate);
    });

    test('an unmapped surface answers administer rather than passing', () {
      // T-03-02. A surface string this file does not know is either a new
      // write surface nobody classified or a typo, and both land on the
      // strictest answer. Never null, never operate, never a throw — the
      // guards call this on the write path and an ArgumentError there would be
      // an outage rather than a denial.
      const policy = AccessPolicy();
      for (final surface in [
        'auth', // a real value in spec section 2, deliberately not a write surface
        '',
        'Tag',
        'preferences',
        'tags',
        'pref ',
      ]) {
        expect(
          policy.groupForWireSurface(surface, 'page_editor_data'),
          AccessGroup.administer,
          reason: 'unmapped surface "$surface" must fail closed',
        );
      }
    });

    test('an unmapped surface does not throw even with a bound lookup', () {
      final policy = AccessPolicy(
        tagBindings: (key, member) => AccessGroup.operate,
      );
      expect(policy.groupForWireSurface('nonsense', 'anything'),
          AccessGroup.administer);
    });
  });

  _task2Tests();
}

// ---------------------------------------------------------------------------
// The resolved preference-key inventory, 2026-08-29.
//
// Produced by running, from the repo root:
//
//   grep -rnE "\.(setString|setBool|setInt|setDouble|setStringList|remove)\(" \
//     --include="*.dart" lib packages/tfc_dart/lib/core/alarm.dart \
//     packages/tfc_dart/lib/core/state_man.dart \
//     | grep -vE "Controller|Buffer|stdout|stderr|sink"
//
// and then **resolving each key expression to the literal it produces**, which
// is the step spec §7's original table skipped. `storageKey`,
// `orderStorageKey`, `'$keyPrefix$id'` and `'${bucket}.recipes'` are all
// invisible to a grep for quoted literals; every one of them is a key the app
// writes in normal operation, and two of them are written at boot with nobody
// signed in.
//
// Format: call site | expression as written | literal it resolves to | rule.
//
// --- keys resolved through a named constant -------------------------------
// core/startup_url.dart:24        prefs.remove(startupUrlPrefsKey)                 -> 'startup_url'                 exact -> operate    (const at :7)
// core/startup_url.dart:26        prefs.setString(startupUrlPrefsKey, url)         -> 'startup_url'                 exact -> operate
// core/update_channel.dart:36     p.setString(updateChannelPrefsKey, ...)          -> 'update_channel'              exact -> administer (const at :14)
// providers/access.dart:694       local.setString(kAccessSessionPrefKey, ...)      -> 'access.session'              exact -> operate    (const at :36); written on every poke()
// providers/access.dart:720       local.remove(kAccessSessionPrefKey)              -> 'access.session'              exact -> operate
// providers/collector.dart:27     prefs.setString(Collector.configLocation, ...)   -> 'collector_config'            exact -> administer (const at collector.dart:139)
// providers/theme.dart:23         prefs.setString(_key, mode.name)                 -> 'theme_mode'                  exact -> operate    (ThemeNotifier._key, :11)
// providers/theme.dart:52         prefs.setString(_key, scheme.name)               -> 'color_scheme'                exact -> operate    (ColorSchemeNotifier._key, :40)
// pages/server_config.dart:849    value.remove(StateManConfig.configKey)           -> 'state_man_config'            exact -> administer (const at state_man.dart:457)
// core/state_man.dart:442,450     prefs.setString(configKey, ...)                  -> 'state_man_config'            exact -> administer
// core/guarded_report_store.dart      store.saveReports(...)                           -> 'report_config'                exact -> configure  (ReportManConfig.configKey)
// core/guarded_report_store.dart      store.saveShifts(...)                            -> 'shift_config'                 exact -> configure  (ShiftManConfig.configKey)
//     Written by raw SQL on flutter_preferences rather than through PreferencesApi, because the MCP server writes the
//     same two rows and has no Preferences. GuardedReportStore is the seam that gates and audits them instead.
// panes/color_picker_dialog.dart:66  SharedPreferencesAsync().setStringList(prefsKey, ...)
//                                                                                  -> 'color_picker_recent_colors' exact -> operate    (RecentColors.prefsKey, :29)
// page_creator/page.dart:247      prefs.setString(storageKey, jsonString)          -> 'page_editor_data'            exact -> configure  (PageManager.storageKey, :90)
//                                 ^ written AT BOOT, unawaited, with nobody signed in, from PageManager.load()
// page_creator/page.dart:252      prefs.setString(storageKey, toJson())            -> 'page_editor_data'            exact -> configure
// page_creator/page.dart:257      prefs.setString(orderStorageKey, ...)            -> 'page_editor_top_level_order' exact -> configure  (:91)
// chat/chat_widget.dart:189       prefs.setString(kSelectedProvider, ...)          -> 'llm.selected_provider'       prefix 'llm.' -> administer (const at llm_provider.dart:7)
//
// --- keys resolved through a local switch / ternary ------------------------
// chat/chat_widget.dart:361       prefs.setString(prefKey, ..., secret: true)      -> 'llm.claude.api_key' | 'llm.openai.api_key' | 'llm.gemini.api_key'
//                                                                                     prefix 'llm.' -> administer (switch at :356)
// chat/chat_widget.dart:392       prefs.remove(urlPrefKey)                         -> 'llm.claude.base_url' | 'llm.openai.base_url'
//                                                                                     prefix 'llm.' -> administer (ternary at :388)
// chat/chat_widget.dart:394       prefs.setString(urlPrefKey, sanitizedUrl)        -> same two                     prefix 'llm.' -> administer
//
// --- keys resolved through string interpolation ----------------------------
// page_creator/assets/image_store.dart:96   prefs.setString(key, ...)              -> 'page_editor_image:<sha256-prefix>'
//                                                                                     prefix 'page_editor_image:' -> configure (keyPrefix :78, key built :94)
// page_creator/assets/image_store.dart:129  prefs.remove('$keyPrefix$id')          -> 'page_editor_image:<sha256-prefix>'  prefix -> configure
// page_creator/assets/recipes.dart:269      prefs.setString(prefKey, ...)          -> '<bucket>.recipes'           suffix '.recipes' -> setpoints (built :266)
//                                 ^ on the READ path: fires when an anonymous operator merely opens a recipes asset
// page_creator/assets/recipes.dart:281      prefs.setString(prefKey, ...)          -> '<bucket>.recipes'           suffix -> setpoints
// providers/chat.dart:340,525     prefs.setString('$kConversationPrefix$id', ...)  -> 'chat.conversation.<id>'      prefix 'chat.' -> operate (const at chat.dart:57)
// providers/chat.dart:370,405,449,905  prefs.remove('$kConversationPrefix<id>')    -> 'chat.conversation.<id>'      prefix 'chat.' -> operate
// providers/chat.dart:453,494,505,535,538  prefs.remove(kChatHistory)              -> 'chat.history'                prefix 'chat.' -> operate
// providers/chat.dart:529,548     prefs.setString(kConversationList, ...)          -> 'chat.conversations'          prefix 'chat.' -> operate
// providers/chat.dart:532,558     prefs.setString(kActiveConversation, id)         -> 'chat.active_conversation'    prefix 'chat.' -> operate
//
// --- keys written as bare literals -----------------------------------------
// providers/state_man.dart:26     prefs.setString('key_mappings', ...)             -> 'key_mappings'                exact -> configure
// pages/key_repository.dart:637   prefs.setString('key_mappings', json)            -> 'key_mappings'                exact -> configure
// pages/key_repository.dart:1933  prefs.setString('key_mappings', ...)             -> 'key_mappings'                exact -> configure
// page_creator/assets/common.dart:444  prefs.setString('key_mappings', ...)        -> 'key_mappings'                exact -> configure
// core/state_man.dart:626         prefs.setString('key_mappings', ...)             -> 'key_mappings'                exact -> configure
// core/alarm.dart:220             preferences.setString('alarm_man_config', ...)   -> 'alarm_man_config'            exact -> configure
//                                 ^ AlarmMan.create writes the default AT BOOT when the key is absent (providers/alarm.dart:13)
// core/alarm.dart:303             preferences.setString('alarm_man_config', ...)   -> 'alarm_man_config'            exact -> configure
//                                 ^ _saveConfig, reached only from addAlarm/removeAlarm/updateAlarm — the configure-gated
//                                   alarm editor. NOT reached from ackAlarm, so acknowledging an alarm writes nothing.
// tech_docs/tech_doc_upload_service.dart:267  prefsReader.setString('page_editor_data', ...)
//                                                                                  -> 'page_editor_data'            exact -> configure
//                                 ^ a FOURTH writer of the page-editor key, spelled as a literal rather than through
//                                   PageManager.storageKey, so a grep for storageKey does not find it either.
// pages/page_view.dart:264        prefs.setString('asset_stack_config', ...)       -> 'asset_stack_config'          exact -> operate
// pages/dbus_login.dart:127       prefs.setString('connectionType', ...)           -> 'connectionType'              exact -> administer
// pages/dbus_login.dart:128       prefs.setString('host', ...)                     -> 'host'                        exact -> administer
// pages/dbus_login.dart:129       prefs.setString('username', ...)                 -> 'username'                    exact -> administer
// pages/dbus_login.dart:130       prefs.setBool('autoLogin', ...)                  -> 'autoLogin'                    exact -> administer
// pages/dbus_login.dart:131       prefs.setString('sshPrivateKeyPath', ...)        -> 'sshPrivateKeyPath'           exact -> administer
//
// --- hits that are NOT preference writes -----------------------------------
// pages/server_config.dart:3095   decrypted.remove('database')      Map<String, dynamic>.remove on a decoded config map.
// pages/config_edit.dart:838,871  ..remove('allOf') / ..remove(r'$ref')            Map.remove on a JSON schema.
// providers/tech_doc.dart:169, mcp/state_man_state_reader.dart:159, tech_docs/tech_doc_picker.dart:50,
// tech_docs/tech_doc_library_section.dart:784, pages/key_repository.dart:746-1263, pages/ip_settings.dart:1188,
// pages/alarm_editor.dart:113-323, page_creator/asset_update.dart:147, pages/history_view.dart:616-1600,
// page_creator/assets/*.dart (ratio_number/alarm_visibility/conveyor/graph/option_variable/rate_value/bpm/third_party),
// pages/page_editor.dart:1764-4723, widgets/panes/standard_dialog.dart, widgets/panes/side_pane.dart,
// widgets/bit_mask_grid.dart:79, widgets/browse_panel.dart, core/state_man.dart:729-2244
//                                 Collection/Map/Set.remove and OverlayEntry.remove. No preference key involved.
//
// --- expressions that do NOT resolve to a literal --------------------------
// core/preferences.dart:54,59,64,69,74,79   _prefs.setX(key, value)
//     Not a call site with a key of its own: this is SharedPreferencesWrapper, the PreferencesApi implementation every
//     resolved call site above delegates *through*. It is the seam plan 03-06 wraps, so every key listed above passes
//     this line exactly once. Nothing to classify here.
// tech_docs/tech_doc_library_section.dart:1203  _prefs.setString(key, value)
//     _SharedPrefsReader, the PrefsReader adapter (:1198). Its only caller is
//     TechDocUploadService.deleteAndCleanAssets, whose single write is :267 above -> 'page_editor_data'. Covered by the
//     exact rule for that key, not by the default.
// widgets/preferences.dart:949-957,979,981  target.setX(e.key, ...) / prefs.remove(e.key)
//     The preferences *editor*: the key is whatever row the user is editing, so it is unbounded by construction and
//     resolves to no literal. Covered by whichever rule matches the key being edited, and reaching this screen at all
//     already requires `administer` — Phase 2 raised /advanced/preferences to it.
//
// --- keys classified that the grep does NOT find ---------------------------
// core/server_config_db.dart:55   ServerConfigDb.prefsKey = 'server_config_envelope'   exact -> administer
//     publish()/remove() write Drift directly, bypassing PreferencesApi entirely — bypass #1 in spec §6, rerouted later
//     in this phase. The rule is declared now so the reroute lands on a classified key rather than on the default.
// providers/access.dart:41        kAccessInactivityMinutesPrefKey = 'access.inactivity_timeout_minutes'  exact -> operate
//     Read-only today (:145). Declared now so the write path a settings screen adds is covered.
// ---------------------------------------------------------------------------

/// Every preference literal the resolution above produced, and the group it
/// must require. This is the table the rest of the phase rests on: a key
/// missing here is a key that falls to `administer`, and for a key the app
/// writes in normal operation that is a broken station, not a safe default.
const Map<String, AccessGroup> kResolvedPrefInventory = <String, AccessGroup>{
  // Route parity with the configure-gated pages that save them.
  'page_editor_data': AccessGroup.configure,
  'page_editor_top_level_order': AccessGroup.configure,
  'page_editor_image:a1b2c3d4': AccessGroup.configure,
  'key_mappings': AccessGroup.configure,
  'alarm_man_config': AccessGroup.configure,
  'report_config': AccessGroup.configure,
  'shift_config': AccessGroup.configure,

  // A Shift Leader must be able to save a recipe.
  'BATCH.recipes': AccessGroup.setpoints,
  'cn01_mixer.recipes': AccessGroup.setpoints,

  // What a panel writes about itself.
  'theme_mode': AccessGroup.operate,
  'color_scheme': AccessGroup.operate,
  'startup_url': AccessGroup.operate,
  'asset_stack_config': AccessGroup.operate,
  'color_picker_recent_colors': AccessGroup.operate,
  'access.session': AccessGroup.operate,
  'access.inactivity_timeout_minutes': AccessGroup.operate,
  'chat.history': AccessGroup.operate,
  'chat.conversations': AccessGroup.operate,
  'chat.active_conversation': AccessGroup.operate,
  'chat.conversation.7f3a': AccessGroup.operate,

  // Server, database and machine configuration.
  'server_config_envelope': AccessGroup.administer,
  'state_man_config': AccessGroup.administer,
  'collector_config': AccessGroup.administer,
  'update_channel': AccessGroup.administer,
  'llm.selected_provider': AccessGroup.administer,
  'llm.claude.api_key': AccessGroup.administer,
  'llm.openai.api_key': AccessGroup.administer,
  'llm.gemini.api_key': AccessGroup.administer,
  'llm.claude.base_url': AccessGroup.administer,
  'llm.openai.base_url': AccessGroup.administer,

  // The five dbus_login keys. Bare, generic names; each spelled out.
  'connectionType': AccessGroup.administer,
  'host': AccessGroup.administer,
  'username': AccessGroup.administer,
  'autoLogin': AccessGroup.administer,
  'sshPrivateKeyPath': AccessGroup.administer,
};

/// True when [key] is matched by any rule in [kPrefAccessRules].
///
/// Reimplements the match so the assertions below cannot be satisfied by the
/// same bug that would break `groupForPref`.
bool _matches(PrefAccessRule rule, String key) => switch (rule.kind) {
      PrefRuleKind.exact => key == rule.match,
      PrefRuleKind.prefix => key.startsWith(rule.match),
      PrefRuleKind.suffix => key.endsWith(rule.match),
    };

void _task2Tests() {
  group('PrefRuleKind carries the precedence order', () {
    test('has exactly three kinds', () {
      expect(PrefRuleKind.values, hasLength(3));
    });

    test('values are exact, prefix, suffix — in precedence order', () {
      // groupForPref walks PrefRuleKind.values in order and takes the first
      // match, so this declaration order *is* the precedence. Reordering these
      // changes who may write what.
      expect(PrefRuleKind.values, [
        PrefRuleKind.exact,
        PrefRuleKind.prefix,
        PrefRuleKind.suffix,
      ]);
    });
  });

  group('the resolved preference-key inventory', () {
    kResolvedPrefInventory.forEach((key, expected) {
      test("'$key' requires ${expected.name}", () {
        const policy = AccessPolicy();
        expect(policy.groupForPref(key), expected);
      });
    });

    test('every inventory key is covered by a rule, not by the default', () {
      // The administer entries would pass the per-key assertions above even
      // with no rule at all, because administer *is* the default. This asserts
      // a rule actually matched — the difference between "classified as
      // administer" and "nobody classified it", which is the silent breakage
      // this inventory exists to prevent.
      final unclassified = [
        for (final key in kResolvedPrefInventory.keys)
          if (!kPrefAccessRules.any((rule) => _matches(rule, key))) key,
      ];
      expect(
        unclassified,
        isEmpty,
        reason: 'these keys the app writes in normal operation rest on the '
            'administer default rather than on a declared rule',
      );
    });
  });

  group('preference keys that match nothing fall to administer', () {
    test('matching is case-sensitive', () {
      const policy = AccessPolicy();
      expect(policy.groupForPref('Page_editor_data'), AccessGroup.administer);
      expect(policy.groupForPref('KEY_MAPPINGS'), AccessGroup.administer);
    });

    test('exact rules do not match a key that merely contains them', () {
      const policy = AccessPolicy();
      expect(policy.groupForPref('xpage_editor_data'), AccessGroup.administer);
      expect(policy.groupForPref('page_editor_data_backup'),
          AccessGroup.administer);
    });

    test('the suffix rule needs the dot — bare "recipes" is not a bucket', () {
      const policy = AccessPolicy();
      expect(policy.groupForPref('recipes'), AccessGroup.administer);
    });

    test('the empty string requires administer', () {
      const policy = AccessPolicy();
      expect(policy.groupForPref(''), AccessGroup.administer);
    });
  });

  group('rule precedence is exact, then prefix, then suffix', () {
    test('a prefix rule outranks the default', () {
      const policy = AccessPolicy();
      expect(policy.groupForPref('chat.conversation.abc'), AccessGroup.operate);
    });

    test(
        'a restrictive prefix outranks the permissive .recipes suffix — '
        'network.recipes is administer, not setpoints', () {
      // THE ORDERING TEST. The only suffix rule is the most permissive in the
      // table; the prefix rules are the most restrictive. Were suffix to win,
      // a key named network.recipes would hand a restricted surface to a Shift
      // Leader. No key in the tree collides today, which is exactly why this
      // must be fixed by ordering: the no-double-match test below passes right
      // up until somebody adds the key.
      const policy = AccessPolicy();
      expect(policy.groupForPref('network.recipes'), AccessGroup.administer);
      expect(policy.groupForPref('llm.recipes'), AccessGroup.administer);
      expect(policy.groupForPref('database.recipes'), AccessGroup.administer);
      expect(policy.groupForPref('ip_pool.recipes'), AccessGroup.administer);
      expect(policy.groupForPref('hostname.recipes'), AccessGroup.administer);
      expect(policy.groupForPref('mcp.recipes'), AccessGroup.administer);
    });

    test('a key matching only the suffix still gets setpoints', () {
      // The guard against "fix the ordering by breaking the suffix rule".
      const policy = AccessPolicy();
      expect(policy.groupForPref('BATCH.recipes'), AccessGroup.setpoints);
    });
  });

  group('the rule table itself', () {
    test('no inventory key matches two rules with different groups', () {
      // Makes "precedence never actually arbitrates for a key that exists" a
      // fact rather than a claim. Deliberately scoped to the inventory:
      // network.recipes matches two rules on purpose, and the ordering test
      // above is what covers that case.
      final conflicts = <String>[];
      for (final key in kResolvedPrefInventory.keys) {
        final groups = <AccessGroup>{
          for (final rule in kPrefAccessRules)
            if (_matches(rule, key)) rule.group,
        };
        if (groups.length > 1) {
          conflicts.add('$key -> ${groups.map((g) => g.name).join(', ')}');
        }
      }
      expect(conflicts, isEmpty);
    });

    test('every rule resolves to one of the seven groups', () {
      for (final rule in kPrefAccessRules) {
        expect(AccessGroup.values, contains(rule.group));
      }
    });

    test('the table is grouped exact, then prefix, then suffix', () {
      // Not load-bearing — groupForPref iterates by kind, so a rule in the
      // wrong block cannot change the answer. Asserted so that reading the
      // list top to bottom does not mislead about precedence.
      final order = kPrefAccessRules.map((r) => r.kind.index).toList();
      expect(order, orderedEquals(List.of(order)..sort()));
    });

    test('no rule has an empty match string', () {
      // An empty prefix or suffix matches every key and would silently
      // swallow the whole table.
      for (final rule in kPrefAccessRules) {
        expect(rule.match, isNotEmpty);
      }
    });

    test('the forward-looking dotted rules match no key in the inventory', () {
      // page. / alarm. / keymap. are kept for keys added later. The real names
      // use underscores — that is the defect spec section 7 was amended to fix
      // — so nothing in the tree matches them today, and this test says so
      // rather than the comment merely claiming it.
      for (final forward in ['page.', 'alarm.', 'keymap.']) {
        expect(
          kResolvedPrefInventory.keys.where((k) => k.startsWith(forward)),
          isEmpty,
          reason: '$forward is documented as forward-looking',
        );
      }
    });
  });
}
