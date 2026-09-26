/// The rows the audit trail goldens are pictures of.
///
/// ## Inert on purpose
///
/// No `setUp`, no `setUpAll`, no top-level mutable state, and no
/// `DateTime.now()` anywhere. `alarm_fixture.dart` is the shape this copies and
/// the reason is the same one: a fixture file is *imported* by a golden file,
/// so anything it runs at import time runs before the golden's own `setUpAll`
/// and would be a baseline nobody could reproduce from reading the test. Every
/// instant here is a `DateTime.utc` literal, so `formatTimestamp` — which reads
/// the components off the value's own zone — renders the same string on a
/// machine in Reykjavík and one in Auckland.
///
/// ## Synthetic, and deliberately so
///
/// Every username, station, key and value below is invented. Nothing in this
/// file came off a plant, and no auth row carries an old or new value — the
/// writer withholds them (`packages/tfc_access/lib/src/audit.dart`), so a
/// fixture that supplied them would be picturing something the database cannot
/// hold (T-05-74).
///
/// ## What is in the populated set, and why each row is there
///
/// | Row | What it proves |
/// |---|---|
/// | a denied `configure` write | the leading mark is red, and red is the page's only saturated colour |
/// | an allowed `setpoints` write | an allowed row carries **no** colour at all |
/// | a write with `origin: 'system'` | the inline origin chip, so twelve reconnect rows are identifiable without twelve taps |
/// | a `login` | the orange auth mark, and a row with no `old → new` at all |
/// | a `login.failed` | red beats orange when both would apply — the sign-in did not happen |
/// | a write with `origin: 'mcp'` | `auditOriginLabel` renders the second non-default origin |
/// | a `surface: 'admin'` row | **Phase 6's surface, in a Phase 5 baseline on purpose** |
///
/// That last row is the one worth explaining. `kKnownAuditSurfaces` is a
/// change-detector and not a whitelist, and `AuditEntryLine` branches on
/// `isAuthEntry` and on nothing else — so an unrecognised surface is supposed to
/// take the write shape and render. Putting `role.update` into this fixture buys
/// the visual proof of that in an image that already exists, instead of a
/// seventh baseline showing a row visually identical to one of the others. It
/// also means Phase 6 needs no new golden: its surface is already in the
/// picture. It survives the default filters unchanged, because `admin` rows
/// carry `groupRequired: 'users'` and the `users` chip is selected by default.
library;

import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_access/tfc_access.dart';

/// The instant the newest row in every fixture happened.
///
/// `DateTime.utc`, never `DateTime.now()`: `formatTimestamp` reads `.day`,
/// `.hour` and friends off the value's own zone, so a UTC literal renders one
/// fixed string everywhere and a local one would render a different image in
/// every timezone.
final DateTime kAuditGoldenBase = DateTime.utc(2026, 8, 30, 14, 5, 9);

/// The `who` values the fixtures use, in the order the dropdown would list
/// them. Invented names.
const List<String> kAuditGoldenWhoOptions = <String>[
  'jon',
  'kari',
  'lina',
  'station',
];

/// The correlation id of the multi-member action, in the 32-hex shape
/// `newActionId()` produces.
const String kAuditGoldenGroupActionId = 'c4f9a1e07b6d24835ae0192cf7db3465';

/// How many rows the multi-member action has in the table.
///
/// Nine, of which the fixture supplies three — so `hiddenCount` is six and the
/// parent renders `6 of 9 members hidden by filters`. The number cannot be
/// derived from the rows: all filtering happens in SQL, so the six excluded
/// siblings are not in the result set at all, which is the whole reason
/// `AuditTrailStore.memberCountsByAction` exists.
const int kAuditGoldenGroupTotal = 9;

/// One audit row, with every column defaulted to the ordinary case so a fixture
/// names only the columns it is about.
///
/// The same shape `audit_trail_row_test.dart` and `test/pages/audit_trail_test.
/// dart` use, so a row read in one file reads the same way in the others.
AuditRecord auditGoldenRow({
  required int id,
  Duration? ago,
  String who = 'jon',
  String station = 'ST101',
  String roleName = 'engineer',
  String surface = 'tag',
  String itemKey = 'ST101.CN04.p_par_SpeedRef',
  String? member,
  String? oldValue = '20',
  String? newValue = '35',
  String groupRequired = 'setpoints',
  bool allowed = true,
  String origin = 'operator',
  String? actionId,
  String? reason,
}) =>
    AuditRecord(
      at: kAuditGoldenBase.subtract(ago ?? Duration(minutes: id - 1)),
      who: who,
      station: station,
      roleName: roleName,
      surface: surface,
      itemKey: itemKey,
      member: member,
      oldValue: oldValue,
      newValue: newValue,
      groupRequired: groupRequired,
      allowed: allowed,
      origin: origin,
      actionId: actionId ?? 'action-$id',
      reason: reason,
    );

/// The default view's rows, newest first, one action each.
///
/// One action per row on purpose: every one of these renders as a flat
/// [AuditEntryLine] rather than an expander, which is CONTEXT's ruling that an
/// expander appears only when an `actionId` has more than one row. The expanded
/// case has its own fixture below and its own image.
///
/// Written as *what the `WHERE` clause returned*, not as a table to be filtered:
/// every filter this page has is pushed into SQL, and the golden's store answers
/// this list verbatim.
List<AuditRecord> auditGoldenPopulatedRows() => <AuditRecord>[
      // A sign-in. Orange mark, no `old → new` at all — the writer withholds
      // both columns on an auth row and the widget renders no slot for them.
      auditGoldenRow(
        id: 1,
        who: 'lina',
        roleName: 'line lead',
        surface: 'auth',
        itemKey: 'login',
        oldValue: null,
        newValue: null,
        groupRequired: '',
        actionId: 'action-auth-1',
      ),
      // The refusal. Red, and the only saturated colour on the page.
      auditGoldenRow(
        id: 2,
        who: 'kari',
        roleName: 'operator',
        station: 'ST201',
        itemKey: 'ST201.MV01.p_par_SealTime',
        oldValue: '1.8',
        newValue: '2.4',
        groupRequired: 'configure',
        allowed: false,
      ),
      // An ordinary allowed write. No colour whatsoever.
      auditGoldenRow(
        id: 3,
        itemKey: 'ST101.CN04.p_par_SpeedRef',
        oldValue: '20',
        newValue: '35',
      ),
      // Phase 6's surface, rendering as an ordinary write. See the library doc.
      auditGoldenRow(
        id: 4,
        surface: 'admin',
        itemKey: 'role.update',
        oldValue: 'operate, users',
        newValue: 'operate',
        groupRequired: 'users',
      ),
      // The reconnect noise, identifiable by its chip without expanding it.
      auditGoldenRow(
        id: 5,
        who: 'station',
        roleName: 'service',
        surface: 'pref',
        itemKey: 'mcp.server.enabled',
        oldValue: 'false',
        newValue: 'true',
        groupRequired: 'administer',
        origin: 'system',
      ),
      // A refused sign-in: red rather than orange, because the sign-in did not
      // happen and that is the more urgent of the two facts.
      auditGoldenRow(
        id: 6,
        who: 'kari',
        roleName: 'operator',
        surface: 'auth',
        itemKey: 'login.failed',
        oldValue: null,
        newValue: null,
        groupRequired: '',
        allowed: false,
        actionId: 'action-auth-6',
      ),
      // The second non-default origin, which `auditOriginLabel` spells `MCP`.
      auditGoldenRow(
        id: 7,
        station: 'ST301',
        itemKey: 'ST301.PU02.p_par_Pressure',
        oldValue: '4.0',
        newValue: '4.6',
        groupRequired: 'device',
        origin: 'mcp',
      ),
    ];

/// How far back the multi-member action happened.
///
/// One value shared by all three rows, because a struct write puts one row per
/// changed member at the *same* instant — `auditRecordsForChanges` writes them
/// from one call. Three different timestamps would picture something the writer
/// cannot produce.
const Duration kAuditGoldenGroupAgo = Duration(minutes: 10);

/// The three surviving members of a nine-member struct write.
///
/// All three share [kAuditGoldenGroupActionId], so `groupAuditRows` folds them
/// into one [AuditAction]; the store's companion count says nine, so the action
/// is partial, arrives expanded, and carries the hidden-members line.
List<AuditRecord> auditGoldenPartialGroupRows() => <AuditRecord>[
      auditGoldenRow(
        id: 11,
        ago: kAuditGoldenGroupAgo,
        itemKey: 'ST101.CN04.stRecipe',
        member: 'SpeedRef',
        oldValue: '20',
        newValue: '35',
        actionId: kAuditGoldenGroupActionId,
        reason: 'Batch 4471 changeover',
      ),
      auditGoldenRow(
        id: 12,
        ago: kAuditGoldenGroupAgo,
        itemKey: 'ST101.CN04.stRecipe',
        member: 'RampUpSeconds',
        oldValue: '4',
        newValue: '6',
        actionId: kAuditGoldenGroupActionId,
        reason: 'Batch 4471 changeover',
      ),
      auditGoldenRow(
        id: 13,
        ago: kAuditGoldenGroupAgo,
        itemKey: 'ST101.CN04.stRecipe',
        member: 'TargetWeightGrams',
        oldValue: '1200',
        newValue: '1350',
        actionId: kAuditGoldenGroupActionId,
        reason: 'Batch 4471 changeover',
      ),
    ];

/// What `AuditTrailStore.memberCountsByAction` answers for the partial group.
///
/// Nine against three visible rows. Supplied as its own map rather than counted
/// off the rows, because counting the rows is exactly the mistake the companion
/// query exists to prevent — it would report three of three and the action would
/// claim to be complete.
Map<String, int> auditGoldenPartialGroupTotals() => <String, int>{
      kAuditGoldenGroupActionId: kAuditGoldenGroupTotal,
    };
