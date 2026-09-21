/// The seam that lets one relayed call be one action in the trail.
///
/// ## The problem it solves
///
/// A configuration write over the relay lands in two places. The policy
/// decorator grades the call and records an `audit_entry` row for the
/// verdict; the backend's writer lands `config_item` rows and a
/// `config_change` row per row it moved. Both carry an `action_id`, and the
/// whole point of that column is that the two sides can be joined: the trail
/// shows one save, and beneath it the rows that save actually changed.
///
/// They can only be joined if both sides use the same string, and only the
/// decorator is in a position to mint it — it is the one thing on the path
/// that sees every graded call exactly once, before the write happens.
///
/// ## Why it is not a parameter
///
/// `PreferencesApi.setString(key, value)` could have taken an `actionId`, and
/// must not. That puts a client-supplied action id on the wire, which is the
/// forgery surface `AuditApi` deliberately has no write member for: a panel
/// could then attribute its own save to an action somebody else performed.
/// The id has to reach the writer without crossing the socket.
///
/// ## Why it is not a field
///
/// A `nextActionId` setter on the source would be the obvious alternative and
/// is a race. `json_rpc_2` dispatches requests without awaiting between
/// frames, and the writer this exists for awaits (it reads the plant's rows
/// before deriving a replace set from them), so request B would overwrite the
/// field between request A's set and request A's write, and A's change rows
/// would carry B's action id. Scoping it to a callback is what makes that
/// unrepresentable.
///
/// ## Optional, exactly like `TypeDescriptions`
///
/// **Not a member of `StateManApi` and not on the wire.** A source that does
/// not implement this is asked nothing and behaves as it always has — its
/// change rows, if it writes any, carry whatever id it mints for itself. The
/// decorator asks `source is ActionScopedWrites` and only then scopes the
/// call, which is the same shape, and the same reasoning, as the optional
/// type dictionary.
library;

/// A source whose writes can be attributed to an action id chosen by the
/// caller that graded them.
abstract interface class ActionScopedWrites {
  /// Runs [write], attributing every configuration change row it lands to
  /// [actionId].
  ///
  /// Implementations must scope the id to this invocation and to the futures
  /// it awaits — a `Zone` value, not a field — because concurrent calls on
  /// one session are ordinary here rather than exotic.
  ///
  /// The return is [write]'s, untouched, and a throw propagates: this is an
  /// attribution wrapper and never a place where a write's outcome changes.
  Future<T> underAction<T>(String actionId, Future<T> Function() write);
}
