/// Every write to `access_template` and to `access_key_binding`, behind one
/// object and one gate.
///
/// A template decides who may write what; a binding decides which keys it
/// decides it for. Both halves are authorization data, which is why spec §7c
/// and §7d put them behind `users` rather than `configure` — otherwise anybody
/// who can edit a page could re-scope the rules that govern the plant.
///
/// Two front ends drive this store: the key repository (04-07, 04-08) and
/// accepted MCP proposals (04-09). Both go through here, so neither can be the
/// one that forgot to check.
///
/// ## Why the group is declared here rather than looked up
///
/// The same reasoning `guarded_history_views.dart` writes at
/// [kHistoryViewDeleteGroup]: neither table is a preference key, this store
/// consults no policy table, and a second source for one answer drifts. If you
/// are here to change what is gated, change [kAccessTemplateGroup]; do not add
/// a rule to `kPrefAccessRules`.
///
/// ## The one thing this store must not do
///
/// It never touches the key-mapping preference blob. Not to read a key list,
/// not to validate a key name, not as a convenience. Key mappings are a
/// `configure`-gated preference and this store is the `users` boundary; a read
/// would be harmless and a write would be the hole the 2026-08-30 ruling
/// closed, so a grep gate forbids that preference key's literal name anywhere
/// in this file — including in a comment, which is why this paragraph spells
/// it out in prose. The boundary is then trivially checkable. Do not add one.
library;

import 'package:drift/drift.dart';
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';
import '../database_drift.dart';

/// The `who` recorded when nobody is signed in.
const String _anonymousWho = 'anonymous';

/// The permission every write in this file requires — over **both** tables.
///
/// `users`, not `configure`, in spec §7c's terms: a template changes who may
/// do what, which is the same concern as roles and the trail, not machine
/// configuration.
///
/// **What changing this line would mean.** Set to `AccessGroup.configure` and
/// anybody who can edit a page or import a key map could re-scope the rules
/// that govern the plant — grant themselves `force` on a drive by editing the
/// template that restricts it, and bind or unbind keys at will. That is the
/// exact confusion the `users` gate exists to prevent, and
/// `access_template_store_test.dart` drives a `configure`-only session into
/// every one of the six writes so the line is checked rather than remembered.
///
/// **It governs the binding table too.** Ruled 2026-08-30, reversing the shape
/// spec §7b implies: the binding is not a field on `KeyMappingEntry` but its
/// own `access_key_binding` table, precisely so this gate is true of the
/// **data** and not only of the button. See [AccessTemplateStore.bind].
const AccessGroup kAccessTemplateGroup = AccessGroup.users;

/// A template could not be deleted because keys still name it (spec §7d).
///
/// **This is deliberately not an [AccessDenied].** `AccessDenied` means "you
/// may not", and is answered by signing in as somebody who may. This means
/// "not until those keys are dealt with", and an Engineering user holding
/// `users` gets it too — no sign-in resolves it. Rendering it through the
/// shared locked prompt would tell an operator to go and find somebody who
/// cannot help either.
///
/// [boundKeys] is what lets 04-07 show the list in the delete dialog and
/// 04-09 tell the agent something useful. It is sorted, and it is read from
/// `access_key_binding` at the moment of the attempt — see
/// [AccessTemplateStore.delete] for why that matters.
class TemplateInUseException implements Exception {
  const TemplateInUseException(this.templateName, this.boundKeys);

  /// The template that was not deleted.
  final String templateName;

  /// The keys still bound to it, sorted.
  final List<String> boundKeys;

  @override
  String toString() => 'TemplateInUseException: "$templateName" is still bound '
      'to ${boundKeys.length} key(s): ${boundKeys.join(', ')}. Clear those '
      'bindings first — deleting the template would leave every one of them '
      'unrestricted.';
}

/// A template name was not one `AccessTemplate.isValidTemplateName` accepts.
///
/// Thrown **before** the gate is consulted: a name that cannot be stored is a
/// caller bug, not an authorization event, and recording it as a denial would
/// put noise in the trail and a lock prompt in front of a typo.
class InvalidTemplateNameException implements Exception {
  const InvalidTemplateNameException(this.name);

  final String name;

  @override
  String toString() => 'InvalidTemplateNameException: "$name" is not a usable '
      'template name — it must be non-empty, already trimmed and at most 64 '
      'characters.';
}

/// A template the caller named does not exist.
class TemplateNotFoundException implements Exception {
  const TemplateNotFoundException(this.name);

  final String name;

  @override
  String toString() => 'TemplateNotFoundException: no template named "$name".';
}

/// A template the caller wanted to create — or rename onto — already exists.
class TemplateExistsException implements Exception {
  const TemplateExistsException(this.name);

  final String name;

  @override
  String toString() =>
      'TemplateExistsException: a template named "$name" already exists.';
}

/// [AccessTemplateStore.unbind] was called for a key that carries no binding.
///
/// Spec §7c and §7d do not say what an unbind of an unbound key should do.
/// This store throws rather than succeeding quietly, for the same reason the
/// other four "it is not there" cases throw: a silent success would write an
/// audit row claiming a change that did not happen, and the trail's only value
/// is that its rows are true.
class BindingNotFoundException implements Exception {
  const BindingNotFoundException(this.keyName);

  final String keyName;

  @override
  String toString() =>
      'BindingNotFoundException: "$keyName" is not bound to a template.';
}

/// The six writes that decide who may write what, and the four reads that show
/// it.
///
/// Writes — [create], [update], [rename], [delete], [bind], [unbind] — all ask
/// for [kAccessTemplateGroup] and all leave a row, denials included. Reads —
/// [list], [template], [bindings], [keysBoundTo] — are ungated and unaudited:
/// looking at the rules is not an authorization change, and a row per render
/// would bury the writes that matter.
class AccessTemplateStore {
  /// [session] is a **callback, not a value**, for the reason `HistoryViewStore`
  /// gives at its own constructor (`lib/core/guarded_history_views.dart`): this
  /// store is built per operation from providers that outlive any one session,
  /// and a captured [AccessSession] would keep granting whatever the operator
  /// held when it was built, after the inactivity monitor had already dropped
  /// them back to anonymous.
  ///
  /// [onDenied] fires **before** the [AccessDenied] is thrown, so the shared
  /// prompt (`lib/widgets/access_denied_prompt.dart`) appears even at a call
  /// site that swallows the exception.
  AccessTemplateStore({
    required AppDatabase db,
    required AccessSession Function() session,
    required AuditSink audit,
    required String station,
    void Function(AccessDenied denial)? onDenied,
    Logger? logger,
  })  : _db = db,
        _session = session,
        _audit = audit,
        _station = station,
        _onDenied = onDenied,
        _logger = logger ?? Logger();

  final AppDatabase _db;
  final AccessSession Function() _session;
  final AuditSink _audit;
  final String _station;
  final void Function(AccessDenied denial)? _onDenied;

  /// This store's own diagnostic logger, for the audit-sink failures it
  /// swallows. Nothing else logs here.
  final Logger _logger;

  /// The surface every row carries, by its wire name rather than a `'pref'`
  /// literal.
  ///
  /// A template is not a preference key, and neither is a binding. But
  /// `AccessSurface` has three write values and spec §2 enumerates them as the
  /// vocabulary, so adding a fourth for this store would make a year of rows
  /// read differently and give the Phase 5 viewer another value to learn. The
  /// [_templateItemKey] / [_bindingItemKey] prefixes are what let a reader
  /// group these without it — the same decision, with the same cost, that
  /// plans 03-10 and 03-13 recorded in
  /// `.planning/phases/03-the-guards/deferred-items.md` §13 item 2: a Phase 5
  /// filter on `surface = 'pref'` returns configuration writes and template
  /// re-scopes together, and only the prefix separates them.
  static final String _surface = AccessSurface.pref.wireName;

  // ---------------------------------------------------------------------------
  // Reads — ungated, unaudited
  // ---------------------------------------------------------------------------

  /// Every stored template, ordered by name, with its rules decoded.
  ///
  /// `AccessTemplate.decodeRules` is forgiving by design, so a row written by
  /// a newer build naming a group this one does not have costs that one rule
  /// rather than the whole list.
  Future<List<AccessTemplate>> list() async {
    final rows = await (_db.select(_db.accessTemplateTable)
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .get();
    return rows.map(_toTemplate).toList();
  }

  /// The template named [name], or null when there is none.
  Future<AccessTemplate?> template(String name) async {
    final row = await _row(name);
    return row == null ? null : _toTemplate(row);
  }

  /// Every binding, as key name to template name.
  ///
  /// This is the shape 04-01's `TagBindingResolver.setSnapshot` wants, so
  /// 04-05 has nothing to reshape. Note that the value may name a template
  /// that no longer exists — see [rename]; the resolver reports such a key as
  /// unbound and 04-08 surfaces it.
  Future<Map<String, String>> bindings() async {
    final rows = await _db.select(_db.accessKeyBindingTable).get();
    return {for (final row in rows) row.keyName: row.templateName};
  }

  /// The keys bound to [templateName], sorted.
  ///
  /// One query against `access_key_binding`, using the
  /// `idx_access_key_binding_template_name` index 04-02 created. **One
  /// implementation**, so the list 04-07's delete dialog shows and the list
  /// [delete]'s block uses cannot disagree.
  ///
  /// **Case-sensitive.** Template names are identifiers, not prose: the column
  /// stores what the template is named, and a case-folding match would make
  /// `delete('Conveyor')` report keys it is not about. A named test says so,
  /// because it is the behaviour somebody will trip over.
  Future<List<String>> keysBoundTo(String templateName) async {
    final rows = await (_db.select(_db.accessKeyBindingTable)
          ..where((t) => t.templateName.equals(templateName)))
        .get();
    final keys = rows.map((row) => row.keyName).toList()..sort();
    return keys;
  }

  // ---------------------------------------------------------------------------
  // Template writes
  // ---------------------------------------------------------------------------

  /// Stores a new template. Requires [kAccessTemplateGroup].
  ///
  /// The row carries a null `oldValue` — there was nothing there before — and
  /// the encoded rules in `newValue`.
  Future<void> create(
    AccessTemplate value, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    _requireValidName(value.name);
    final encoded = AccessTemplate.encodeRules(value.rules);
    final actionId = await _requireUsers(
      itemKey: _templateItemKey(value.name),
      reason: _reason('create', reason),
      origin: origin,
      newValue: encoded,
    );

    if (await _row(value.name) != null) {
      throw TemplateExistsException(value.name);
    }

    await _recordAllowed(
      itemKey: _templateItemKey(value.name),
      reason: _reason('create', reason),
      origin: origin,
      newValue: encoded,
      actionId: actionId,
    );
    await _db.into(_db.accessTemplateTable).insert(
          AccessTemplateTableCompanion.insert(
            name: value.name,
            rules: encoded,
            updatedAt: DateTime.now(),
          ),
        );
  }

  /// Re-scopes an existing template. Requires [kAccessTemplateGroup].
  ///
  /// Both the previous and the new rules go into the row, so a re-scope is
  /// readable from the trail without a join against the row before it.
  Future<void> update(
    AccessTemplate value, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    _requireValidName(value.name);
    final encoded = AccessTemplate.encodeRules(value.rules);
    final actionId = await _requireUsers(
      itemKey: _templateItemKey(value.name),
      reason: _reason('update', reason),
      origin: origin,
      newValue: encoded,
    );

    final existing = await _row(value.name);
    if (existing == null) throw TemplateNotFoundException(value.name);

    await _recordAllowed(
      itemKey: _templateItemKey(value.name),
      reason: _reason('update', reason),
      origin: origin,
      oldValue: existing.rules,
      newValue: encoded,
      actionId: actionId,
    );
    await (_db.update(_db.accessTemplateTable)
          ..where((t) => t.name.equals(value.name)))
        .write(AccessTemplateTableCompanion(
      rules: Value(encoded),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Renames a template. Requires [kAccessTemplateGroup].
  ///
  /// **This deliberately does not re-point the bindings.** Keys bound to [from]
  /// keep naming it, that name no longer resolves, and 04-01's resolver
  /// therefore reports them as *unbound* — which means unrestricted until they
  /// are re-bound. 04-07's rename dialog has to warn before this happens
  /// (T-04-16, accepted and surfaced).
  ///
  /// The alternative — quietly re-pointing every binding — is the silent
  /// unbind spec §7d forbids, wearing a friendlier label: a bulk write to the
  /// authorization of N keys, made as a side effect of an operation the user
  /// asked for on one row, and invisible in the trail unless every one of
  /// those N rows is written too. The block on [delete] exists for exactly the
  /// same reason. Do not "helpfully" add it here.
  ///
  /// Two rows, **one `actionId`**: the trail has to be findable from the old
  /// name and from the new one, and a rename is one human action, not two
  /// unrelated events. `oldValue` and `newValue` are the two names — a rename
  /// moves the name, not the rules.
  Future<void> rename(
    String from,
    String to, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    _requireValidName(from);
    _requireValidName(to);
    final actionId = await _requireUsers(
      itemKey: _templateItemKey(from),
      reason: _reason('rename', reason),
      origin: origin,
      oldValue: from,
      newValue: to,
    );

    final existing = await _row(from);
    if (existing == null) throw TemplateNotFoundException(from);
    if (from != to && await _row(to) != null) {
      throw TemplateExistsException(to);
    }

    for (final itemKey in [_templateItemKey(from), _templateItemKey(to)]) {
      await _recordAllowed(
        itemKey: itemKey,
        reason: _reason('rename', reason),
        origin: origin,
        oldValue: from,
        newValue: to,
        actionId: actionId,
      );
    }
    await (_db.update(_db.accessTemplateTable)
          ..where((t) => t.name.equals(from)))
        .write(AccessTemplateTableCompanion(
      name: Value(to),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Destroys a template. Requires [kAccessTemplateGroup], and refuses while
  /// keys still name it.
  ///
  /// The order is deliberate: the `users` check comes **first**, so an
  /// unprivileged caller gets [AccessDenied] and the row says the refusal was
  /// about permission. Only then are the bindings consulted, and a non-empty
  /// list throws [TemplateInUseException] — which every session gets, `users`
  /// included, because it is not a permission failure (spec §7d: block the
  /// delete rather than silently unbinding).
  ///
  /// **The block has no caveat, and that is the whole point of the
  /// 2026-08-30 ruling.** An earlier design took the bound keys from the
  /// caller's `KeyMappings`, which meant the store could not tell "nothing is
  /// bound" from "nobody told me", and had to let the delete through in the
  /// second case — the one case where letting it through unrestricts keys.
  /// Reading `access_key_binding` here removes the distinction and therefore
  /// the caveat: there is no state in which this store has to guess. Do not
  /// "simplify" the bound-key list back into a parameter.
  ///
  /// There is also no foreign key and no cascade behind this (see
  /// `AccessKeyBindingTable.templateName`). A cascade would be exactly the
  /// silent unbind §7d forbids, performed by the database where no audit row
  /// could see it.
  Future<void> delete(
    String name, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    _requireValidName(name);
    final actionId = await _requireUsers(
      itemKey: _templateItemKey(name),
      reason: _reason('delete', reason),
      origin: origin,
    );

    final existing = await _row(name);
    if (existing == null) throw TemplateNotFoundException(name);

    final bound = await keysBoundTo(name);
    if (bound.isNotEmpty) throw TemplateInUseException(name, bound);

    await _recordAllowed(
      itemKey: _templateItemKey(name),
      reason: _reason('delete', reason),
      origin: origin,
      oldValue: existing.rules,
      actionId: actionId,
    );
    await (_db.delete(_db.accessTemplateTable)
          ..where((t) => t.name.equals(name)))
        .go();
  }

  // ---------------------------------------------------------------------------
  // Binding writes
  // ---------------------------------------------------------------------------

  /// Binds [keyName] to [templateName], replacing any binding it already has.
  /// Requires [kAccessTemplateGroup].
  ///
  /// **Why the binding lives here and not on `KeyMappingEntry`.** Ruled
  /// 2026-08-30. Spec §7b still reads as though the binding is an
  /// `accessTemplate: String?` field on the key-mapping blob; it is not, and
  /// the disagreement is deliberate rather than an oversight. The key-mapping
  /// preference is classified `configure` by `kPrefAccessRules`, so a binding
  /// inside it would be authorization data behind the wrong gate — rewritable
  /// through
  /// the key repository's import/export card and through the raw preferences
  /// editor by anybody who can edit a page. Its own table behind this store's
  /// `users` gate makes the gate true of the data and not merely of the
  /// button. §7b's synchronous-resolution requirement survives the move: these
  /// rows are loaded into the same in-memory snapshot the templates are, so a
  /// tap still resolves with no await.
  ///
  /// A [templateName] that does not exist is refused. A dangling binding is
  /// *unrestricted*, so creating one deliberately is not something this store
  /// should make easy. (One can still arise from a [rename]; 04-01's resolver
  /// and 04-08's surface handle that case, and the rename dialog warns.)
  Future<void> bind(
    String keyName,
    String templateName, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    _requireValidName(templateName);
    final actionId = await _requireUsers(
      itemKey: _bindingItemKey(keyName),
      reason: _reason('bind', reason),
      origin: origin,
      newValue: templateName,
    );

    if (await _row(templateName) == null) {
      throw TemplateNotFoundException(templateName);
    }

    final previous = await _bindingRow(keyName);
    await _recordAllowed(
      itemKey: _bindingItemKey(keyName),
      reason: _reason('bind', reason),
      origin: origin,
      oldValue: previous?.templateName,
      newValue: templateName,
      actionId: actionId,
    );
    // One row, replaced rather than duplicated: `key_name` is the primary key,
    // which is what makes "explicit, per key, always" structural.
    await _db.into(_db.accessKeyBindingTable).insertOnConflictUpdate(
          AccessKeyBindingTableCompanion.insert(
            keyName: keyName,
            templateName: templateName,
            updatedAt: DateTime.now(),
          ),
        );
  }

  /// Clears [keyName]'s binding, leaving the key unrestricted. Requires
  /// [kAccessTemplateGroup] — clearing a binding changes who may write that
  /// key just as much as setting one does.
  Future<void> unbind(
    String keyName, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    final actionId = await _requireUsers(
      itemKey: _bindingItemKey(keyName),
      reason: _reason('unbind', reason),
      origin: origin,
    );

    final previous = await _bindingRow(keyName);
    if (previous == null) throw BindingNotFoundException(keyName);

    await _recordAllowed(
      itemKey: _bindingItemKey(keyName),
      reason: _reason('unbind', reason),
      origin: origin,
      oldValue: previous.templateName,
      actionId: actionId,
    );
    await (_db.delete(_db.accessKeyBindingTable)
          ..where((t) => t.keyName.equals(keyName)))
        .go();
  }

  // ---------------------------------------------------------------------------
  // The one implementation of the rule
  // ---------------------------------------------------------------------------

  /// Check, record, throw — the ordering `GuardedStateMan` established and
  /// `guarded_history_views.dart` reuses.
  ///
  /// Returns the `actionId` the caller must carry into its allowed row, so one
  /// human action produces one correlation id however many rows it writes.
  ///
  /// On the deny path the row comes **before** the throw, because it is the
  /// only evidence the guard fired. On the permitted path the caller records
  /// after its own preconditions have passed and before it issues the
  /// statement: a create on a name that already exists, or a delete of a
  /// template keys still name, changed nothing and must leave no row claiming
  /// it did.
  Future<String> _requireUsers({
    required String itemKey,
    required String reason,
    required String origin,
    String? oldValue,
    String? newValue,
  }) async {
    final actionId = newActionId();
    final session = _session();
    if (session.can(kAccessTemplateGroup)) return actionId;

    await _record(_row_(
      session: session,
      itemKey: itemKey,
      oldValue: oldValue,
      newValue: newValue,
      allowed: false,
      reason: reason,
      origin: origin,
      actionId: actionId,
    ));

    final denial = AccessDenied(itemKey, kAccessTemplateGroup);
    try {
      _onDenied?.call(denial);
    } on Object catch (error, stack) {
      // A listener's bug must not change what the caller sees. The refusal is
      // this store's answer; a broken prompt is cosmetic beside it.
      _logger.e('onDenied listener threw for "$itemKey"',
          error: error, stackTrace: stack);
    }
    throw denial;
  }

  Future<void> _recordAllowed({
    required String itemKey,
    required String reason,
    required String origin,
    required String actionId,
    String? oldValue,
    String? newValue,
  }) =>
      _record(_row_(
        session: _session(),
        itemKey: itemKey,
        oldValue: oldValue,
        newValue: newValue,
        allowed: true,
        reason: reason,
        origin: origin,
        actionId: actionId,
      ));

  /// One audit row. `who` comes from the session and from nowhere else.
  ///
  /// [origin] is the **only** thing a caller sets, and that asymmetry is the
  /// point of T-04-14: 04-09 passes `'mcp'` for a change applied on behalf of
  /// an accepted proposal, and the row still names the human who approved it
  /// rather than the agent that suggested it. There is no parameter through
  /// which a caller could name somebody else.
  AuditRecord _row_({
    required AccessSession session,
    required String itemKey,
    required String? oldValue,
    required String? newValue,
    required bool allowed,
    required String reason,
    required String origin,
    required String actionId,
  }) =>
      AuditRecord(
        at: DateTime.now(),
        who: session.user?.username ?? _anonymousWho,
        station: _station,
        roleName: session.roleName,
        surface: _surface,
        itemKey: itemKey,
        oldValue: oldValue,
        newValue: newValue,
        groupRequired: kAccessTemplateGroup.name,
        allowed: allowed,
        origin: origin,
        reason: reason,
        actionId: actionId,
      );

  /// Append [row], and never let the sink's failure become the caller's.
  ///
  /// The same rule, in the same words, as plans 03-04, 03-05 and 03-10. On the
  /// permitted path an escaping sink exception would fail a write the session
  /// was allowed to make. On the deny path it would replace [AccessDenied]
  /// with something no caller catches, skip `onDenied`, and leave the operator
  /// with a control that did nothing and no explanation for it. The price is
  /// that a lost row is only a log line, so the line names the row it lost.
  Future<void> _record(AuditRecord row) async {
    try {
      await _audit.record(row);
    } on Object catch (error, stack) {
      _logger.e(
        'AUDIT ROW LOST: action ${row.actionId}, ${row.who} on '
        '${row.surface}:${row.itemKey}, allowed: ${row.allowed}',
        error: error,
        stackTrace: stack,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  /// The default [AuditRecord.origin] — a person standing at the panel.
  static const String _operatorOrigin = 'operator';

  void _requireValidName(String name) {
    if (!AccessTemplate.isValidTemplateName(name)) {
      throw InvalidTemplateNameException(name);
    }
  }

  Future<AccessTemplateTableData?> _row(String name) =>
      (_db.select(_db.accessTemplateTable)..where((t) => t.name.equals(name)))
          .getSingleOrNull();

  Future<AccessKeyBindingTableData?> _bindingRow(String keyName) =>
      (_db.select(_db.accessKeyBindingTable)
            ..where((t) => t.keyName.equals(keyName)))
          .getSingleOrNull();

  AccessTemplate _toTemplate(AccessTemplateTableData row) => AccessTemplate(
        name: row.name,
        rules: AccessTemplate.decodeRules(row.rules),
      );

  /// Which of the six it was, plus whatever the caller added — the row would
  /// otherwise say only that *something* happened to a template.
  static String _reason(String operation, String? caller) =>
      caller == null || caller.isEmpty ? operation : '$operation: $caller';

  /// The `itemKey` of a template row. The prefix is what the Phase 5 viewer
  /// filters on.
  static String _templateItemKey(String name) => 'access_template.$name';

  /// The `itemKey` of a binding row. A distinct prefix from
  /// [_templateItemKey] — `access_key_binding.` does not start with
  /// `access_template.` — so filtering for one does not drag in the other.
  static String _bindingItemKey(String keyName) =>
      'access_key_binding.$keyName';
}
