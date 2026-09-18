/// The gateway's front door: which link owns a key, and which keys the gateway
/// refuses to own at all.
///
/// ## The order is not invented here
///
/// `StateMan.subscribe` (`packages/tfc_dart/lib/core/state_man.dart:2054-2084`)
/// already establishes it, and this file carries the *shape* rather than the
/// code:
///
/// ```dart
/// if (ConnMetaRouter.isMetaKey(key)) return _connMeta.subscribe(key);  // :2057
/// key = resolveKey(key);          // :2059  substitution
/// _throwIfUnresolved(key);        // :2060
/// _throwIfDisabled(key);          // :2061
/// final m2400 = _resolveM2400Key(key);              // :2064
/// final modbusDc = _resolveModbusDeviceClient(key); // :2077
/// return _monitor(key);           // :2083  fall through to OPC UA
/// ```
///
/// `read` uses the same order with M2400 first (`:1802-1879`). **Three
/// departures**, all deliberate, all written here so the next reader finds the
/// decision instead of re-litigating it:
///
///  1. **`PIPE.` takes `@conn`'s slot.** `@conn` short-circuits at `:1805` on
///     read, `:2057` on subscribe and `:1994` on write — before the disabled
///     check, before any client is consulted, never through keymappings.
///     [PipeKeyRoute] lands in exactly that position. `@conn/<alias>/<field>`
///     itself is *not* served here: it is a shipped reserved prefix in the
///     app-side `StateMan` with an almost identical field catalogue
///     (`conn_meta.dart:37-63` — `reconnectCount` is `birth_count` under
///     another name, `uptimeSec` is `last_death_at` inverted), and 08-CONTEXT
///     **ruling 4** says the gateway serves `PIPE.*` only, gateway-native,
///     with an alias layer available as a reversible later addition if page
///     churn proves painful. Two reserved namespaces for pipeline health is
///     one too many; that is the recorded decision, not an oversight.
///  2. **Substitution is gone.** `resolveKey` (`:1709-1733`) is deliberately
///     **not** ported: `state_man_api.dart:26-31` froze `setSubstitution` /
///     `substitutions` / `substitutionsChanged` / `resolveKey` as a
///     *client-local key rewrite* — the client resolves the key and subscribes
///     to the resolved one. So a key still carrying a `$` is
///     [RouteRefusal.substitutionUnsupported], the value-shaped equivalent of
///     `_throwIfUnresolved` (`:1704-1707`) and for its stated reason: a key
///     with an unresolved variable addresses a node that cannot exist, and
///     "cannot exist" must not arrive looking like a dead tag.
///  3. **The write path still routes M2400.** The shipped `write`
///     (`:1992-2045`) skips the M2400 entirely because the device is read-only.
///     Here the router routes it like anything else and the *link* answers
///     [WriteRejected] — `state_man_api.dart:114-117` names
///     `M2400DeviceClientAdapter.write`'s `UnsupportedError` as what not to
///     copy, because a throw on the write path reads to the operator as "the
///     write failed", which is the one thing a refusal to try does not prove
///     about the plant.
///
/// ## What this file does not redeclare
///
/// The keymapping model is `tfc_dart`'s. `KeyMappings`, `KeyMappingEntry`,
/// `OpcUANodeConfig`, `M2400NodeConfig` and `ModbusNodeConfig` are what the
/// live plant file deserializes into and what the page editor writes; a
/// parallel model here would be a second migration path for every future
/// field. What this file adds is the *router* and the *ingest result*.
library;

import 'dart:convert';

import 'package:tfc_dart/core/state_man_types.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'upstream_link.dart';

/// Why the gateway will not route a key.
///
/// An enum on a sealed result, so 08-05's `switch` is exhaustive and a new
/// reason is a compile error at every call site rather than a case that
/// silently falls to a default.
enum RouteRefusal {
  /// The key is inside `PIPE.` — the gateway's own namespace (HLTH-03).
  reservedPrefix,

  /// The key still carries a `$` variable. Substitution is client-local and
  /// does not exist on the gateway (`state_man_api.dart:26-31`).
  substitutionUnsupported,

  /// The key belongs to a server the operator switched off. Deliberately
  /// distinguishable from [unmapped]: "you turned it off" and "nothing here
  /// knows this name" want different people doing different things.
  aliasDisabled,

  /// Two links are configured against the same `server_alias`, so there is no
  /// principled way to decide which of them owns the key.
  ambiguousAlias,

  /// No mapping for the key, or no link claimed it.
  unmapped,
}

/// Where a key goes. Sealed: claimed, gateway-native, or refused.
sealed class KeyRoute {
  const KeyRoute();

  /// The key this route answers for.
  String get key;
}

/// A link claimed the key and minted a handle for it.
final class ClaimedRoute extends KeyRoute {
  /// The link that claimed it.
  final UpstreamLink link;

  /// The handle the link minted, **epoch and all**, so the caller never
  /// re-resolves inside one epoch. A handle is stale the moment the link's
  /// epoch moves, and every read/write/peek/subscribe path on [UpstreamLink]
  /// checks that before it touches the wire (SRV-07).
  final UpstreamRef ref;

  const ClaimedRoute(this.link, this.ref);

  @override
  String get key => ref.key;

  @override
  String toString() => 'ClaimedRoute(${link.alias} -> $ref)';
}

/// The key is one of the gateway's own `PIPE.*` names.
///
/// No link is consulted to produce this, ever. That is the whole of departure
/// 1 and it is what makes a keymapping unable to shadow a health key.
final class PipeKeyRoute extends KeyRoute {
  @override
  final String key;

  const PipeKeyRoute(this.key);

  @override
  String toString() => 'PipeKeyRoute($key)';
}

/// The gateway will not route this key, and says why.
///
/// A value, never an exception. A refusal that throws turns one bad mapping
/// into a dead poll cycle, which is the same failure the sanitize rule exists
/// to prevent one layer down.
final class RefusedRoute extends KeyRoute {
  @override
  final String key;

  /// The machine-readable reason. Switch on this, do not parse [message].
  final RouteRefusal reason;

  /// The human-readable one, which always names the key. A refusal that names
  /// only a NodeId or only an alias is unactionable to the person reading the
  /// screen; they typed a key.
  final String message;

  const RefusedRoute(this.key, this.reason, this.message);

  @override
  String toString() => 'RefusedRoute($key, $reason: $message)';
}

/// One configured link, plus the `server_alias` value it answers to.
///
/// **Two different aliases live on one link and conflating them breaks the
/// live plant file.** [UpstreamLink.alias] is the link's *name* — it appears
/// in `StatusParams.alias` and in `PIPE.upstream.<alias>.*`, so it is always a
/// real, non-empty, dot-free string (`PipeKeys` refuses anything else at the
/// mint). [serverAlias] is the value in the keymapping file's `server_alias`
/// field, and it is **nullable because null is a real shipped value**: the
/// live file's 430 entries carry `"server_alias": null` on every OPC UA entry,
/// left over from the single-server era, and `_getClientWrapper` matches that
/// null to the wrapper whose `config.serverAlias` is also null
/// (`state_man.dart:1670-1679`).
///
/// So a link named `st101` may perfectly well answer to the *unnamed* server.
/// One field could not carry both facts.
final class UpstreamLinkBinding {
  /// The link itself.
  final UpstreamLink link;

  /// The keymapping `server_alias` this link answers to. Null is the unnamed
  /// server and is a real configuration, not a placeholder.
  final String? serverAlias;

  UpstreamLinkBinding(this.link, {required String? serverAlias})
      // Normalized here so that a `""` out of imported JSON and a missing
      // field are one bucket, exactly as `StateManConfig.normalizeAlias`
      // (`state_man.dart:454-455`) already decided for the shipped config.
      : serverAlias = StateManConfig.normalizeAlias(serverAlias);

  /// The simple case: the link's name *is* the `server_alias` it answers to.
  factory UpstreamLinkBinding.named(UpstreamLink link) =>
      UpstreamLinkBinding(link, serverAlias: link.alias);

  @override
  String toString() =>
      'UpstreamLinkBinding(${link.alias} @ ${serverAlias ?? '<unnamed>'})';
}

/// What an ingest of a keymapping file applied, and what it refused.
///
/// **The first five fields are the shipped shape, field for field.**
/// `StateMan.updateKeyMappings` (`state_man.dart:2086-2223`) returns
/// `KeyMappingsUpdateResult {added, removed, changed, resubscribed,
/// reloadReasons}` (`:702-735`) and — this is the part HLTH-03 depends on —
/// **it never throws**. It classifies. [rejected] is the sixth field on that
/// shape rather than a new exception, because a keymapping file is an
/// operator-editable input and an input that can refuse itself wholesale is a
/// denial of service one typo wide (T-08-14).
final class KeyMappingsIngestResult {
  /// Accepted keys present in the new mappings but not the old.
  final Set<String> added;

  /// Keys present in the old mappings but not accepted from the new.
  final Set<String> removed;

  /// Keys accepted from both whose entry differs.
  final Set<String> changed;

  /// Changed keys whose live upstream subscription was re-pointed in place.
  ///
  /// **Always empty here, and that is not a stub.** The router holds no
  /// subscriptions — 08-05's fan-in does — so nothing at this layer can have
  /// been re-pointed. The field exists because the shape is the shipped one
  /// and 08-05 fills it without changing the type every caller switches on.
  final Set<String> resubscribed;

  /// Why a full rebuild is still required. Empty when the whole edit applied
  /// live.
  final List<String> reloadReasons;

  /// The keys this ingest refused, and why. **Per key, never per file.**
  final Map<String, RouteRefusal> rejected;

  bool get requiresReload => reloadReasons.isNotEmpty;

  KeyMappingsIngestResult({
    required Set<String> added,
    required Set<String> removed,
    required Set<String> changed,
    required Set<String> resubscribed,
    required List<String> reloadReasons,
    required Map<String, RouteRefusal> rejected,
  })  : added = Set<String>.unmodifiable(added),
        removed = Set<String>.unmodifiable(removed),
        changed = Set<String>.unmodifiable(changed),
        resubscribed = Set<String>.unmodifiable(resubscribed),
        reloadReasons = List<String>.unmodifiable(reloadReasons),
        rejected = Map<String, RouteRefusal>.unmodifiable(rejected);

  @override
  String toString() => 'KeyMappingsIngestResult(added: ${added.length}, '
      'removed: ${removed.length}, changed: ${changed.length}, '
      'resubscribed: ${resubscribed.length}, rejected: ${rejected.length}, '
      'requiresReload: $requiresReload'
      '${requiresReload ? ', reasons: ${reloadReasons.join('; ')}' : ''})';
}

/// Routes a key to exactly one link, or to exactly one named refusal.
///
/// The router **knows no protocol**. It offers the key to each link in the
/// configured order and takes the first handle it gets; the link is what knows
/// whether a mapping entry describes a node it can reach
/// ([UpstreamLink.resolve] answers null for "not mine"). That is what lets the
/// shipped M2400 → Modbus → OPC UA order live in the *caller's list* rather
/// than in a chain of `if`s here.
class KeyRouter {
  /// Links in the order they are offered keys.
  ///
  /// **The order is the shipped one and the caller owns it:** M2400 first,
  /// then Modbus, then OPC UA. The reason is that the first two read a
  /// specific field of the mapping entry (`m2400_node`, `modbus_node`) while
  /// OPC UA is the *fallthrough* — put the fallthrough first and it swallows
  /// keys the two specific protocols were configured for.
  final List<UpstreamLinkBinding> links;

  /// Aliases the operator switched off.
  ///
  /// `null` in this set means the unnamed server is off, which is exactly what
  /// `StateManConfig.disabledServerAliases` (`state_man.dart:456-469`) means
  /// by it.
  final Set<String?> disabledAliases;

  /// Server aliases carried by more than one link.
  ///
  /// Every key on such an alias is refused. The shipped `_getClientWrapper`
  /// takes `firstWhereOrNull` here (`state_man.dart:1670-1679`) and picks the
  /// first silently; that is how a value from ST201 ends up on an ST101 page
  /// with nothing anywhere saying it happened (T-08-13). Two links configured
  /// identically is a mistake in the configuration, and the honest answer to a
  /// mistake is to say so rather than to guess.
  final Set<String?> ambiguousAliases;

  KeyMappings _mappings = KeyMappings(nodes: <String, KeyMappingEntry>{});

  late KeyMappingsIngestResult _lastIngest;

  KeyRouter({
    required List<UpstreamLinkBinding> links,
    required KeyMappings mappings,
    Set<String?> disabledAliases = const <String?>{},
  })  : links = List<UpstreamLinkBinding>.unmodifiable(links),
        disabledAliases = Set<String?>.unmodifiable(
            disabledAliases.map(StateManConfig.normalizeAlias)),
        ambiguousAliases = _ambiguitiesIn(links) {
    // Construction is an ingest like any other, so a file handed to the
    // constructor is reserved-checked exactly as one handed to
    // [applyKeyMappings] is. A squatted name that only got refused on *reload*
    // would be served for the whole first run of the gateway.
    applyKeyMappings(mappings);
  }

  /// The simple case: each link answers to the `server_alias` that is its own
  /// name. This is the constructor the plan describes — an ordered
  /// `List<UpstreamLink>`, a `KeyMappings` and a set of disabled aliases — and
  /// it is right for every deployment where the integrator named the servers.
  /// The live plant file is not one of those, which is why the binding
  /// constructor above exists.
  factory KeyRouter.overLinks(
    List<UpstreamLink> links, {
    required KeyMappings mappings,
    Set<String?> disabledAliases = const <String?>{},
  }) =>
      KeyRouter(
        links: [for (final link in links) UpstreamLinkBinding.named(link)],
        mappings: mappings,
        disabledAliases: disabledAliases,
      );

  /// The mappings currently in force.
  KeyMappings get mappings => _mappings;

  /// Every key the router will attempt to route.
  ///
  /// Rejected keys are **not** here. A refused mapping is not a mapping.
  Iterable<String> get keys => _mappings.nodes.keys;

  /// Mapped keys no configured link claims — for the boot log.
  ///
  /// A key in this set is the worst kind of broken: it passed ingest, it
  /// appears servable to every panel, and it will answer `errorConfig`
  /// forever. The rig ran a whole shift with 14/14 subscribed keys in this
  /// state and the only trace anywhere was q=770 on the wire
  /// (RIG-TEST-FINDINGS.md F2). Named once, at boot, next to the reserved-
  /// prefix offenders — not one line per panel that asks.
  ///
  /// Only [RouteRefusal.unmapped]: a disabled alias is an operator's
  /// deliberate act, an ambiguous one already refuses loudly per key, and a
  /// reserved name is already logged by `reservedKeyMappingNames`.
  Set<String> get unclaimedKeys => <String>{
        for (final key in keys)
          if (route(key)
              case RefusedRoute(reason: RouteRefusal.unmapped))
            key,
      };

  /// What the most recent ingest — including the one at construction —
  /// applied and refused.
  KeyMappingsIngestResult get lastIngest => _lastIngest;

  /// Takes [next] as the keymapping file, per key.
  ///
  /// **Never throws, classifies instead**, which is the whole of HLTH-03's
  /// usefulness: one bad mapping in a file of 1,500 costs exactly that
  /// mapping. The shipped `updateKeyMappings` established this shape and the
  /// only thing added here is the sixth field.
  ///
  /// Two classes of key are refused:
  ///
  ///  * **`PIPE.` names** ([RouteRefusal.reservedPrefix]), tested with
  ///    [PipeKeys.isPipeKey]. That spelling lives in the protocol package for
  ///    a reason worth repeating: `PIPE.` acquires producers in three packages
  ///    at once, a key name is matched by AlarmMan configuration out in the
  ///    plant, and a second spelling does not fail a test — it compiles, keeps
  ///    every suite green, and quietly stops matching every deployment. So the
  ///    reserved list and the producer cannot drift apart by a typo, because
  ///    there is only one place to make one. **Do not write the literal here.**
  ///  * **`$` names** ([RouteRefusal.substitutionUnsupported]), which can never
  ///    route on the gateway at all (departure 2). Refusing them at the door
  ///    rather than per read is the same argument as `_throwIfUnresolved`'s:
  ///    an unresolved key addresses a node that cannot exist, and four faults
  ///    with one symptom is how a templated key stays broken without anyone
  ///    being able to say why.
  ///
  /// The test is a **prefix** test in both directions. `ST101.PIPE.flow` is a
  /// conveyor tag on a plant that has pipes, and rejecting it would cost that
  /// tag silently: a page reading unknown forever, and nothing in any log
  /// saying why.
  KeyMappingsIngestResult applyKeyMappings(KeyMappings next) {
    final rejected = <String, RouteRefusal>{};
    final accepted = <String, KeyMappingEntry>{};
    for (final entry in next.nodes.entries) {
      final refusal = _refuseAtIngest(entry.key);
      if (refusal != null) {
        rejected[entry.key] = refusal;
        continue;
      }
      accepted[entry.key] = entry.value;
    }

    final previous = _mappings.nodes;
    final added = <String>{};
    final removed = <String>{};
    final changed = <String>{};
    final reloadReasons = <String>[];

    for (final key in accepted.keys) {
      if (!previous.containsKey(key)) added.add(key);
    }
    for (final entry in previous.entries) {
      final now = accepted[entry.key];
      if (now == null) {
        removed.add(entry.key);
        continue;
      }
      // The shipped comparison, verbatim in spirit: encode both and compare
      // the JSON. The model is generated and has no `==`, and a field added to
      // it later is compared for free.
      if (jsonEncode(now.toJson()) != jsonEncode(entry.value.toJson())) {
        changed.add(entry.key);
        final reason = _reloadReasonFor(entry.key, entry.value, now);
        if (reason != null) reloadReasons.add(reason);
      }
    }

    _mappings = KeyMappings(nodes: accepted);
    return _lastIngest = KeyMappingsIngestResult(
      added: added,
      removed: removed,
      changed: changed,
      // Nothing at this layer holds a subscription to re-point; see the field.
      resubscribed: const <String>{},
      reloadReasons: reloadReasons,
      rejected: rejected,
    );
  }

  /// Why [key] cannot be a keymapping at all, or null if it can.
  RouteRefusal? _refuseAtIngest(String key) {
    if (PipeKeys.isPipeKey(key)) return RouteRefusal.reservedPrefix;
    if (key.contains(r'$')) return RouteRefusal.substitutionUnsupported;
    return null;
  }

  /// Whether a changed entry can be applied live, following the shipped rule:
  /// only edits whose state is frozen at construction time ask for a reload.
  static String? _reloadReasonFor(
      String key, KeyMappingEntry before, KeyMappingEntry after) {
    if (before.m2400Node != null || after.m2400Node != null) {
      return '$key: M2400 extraction is captured per stream when the '
          'subscription is built, so an edit to it cannot be applied in place';
    }
    if (before.modbusNode != null || after.modbusNode != null) {
      return '$key: a classic Modbus register spec is frozen at construction';
    }
    return null;
  }

  /// Where [key] goes.
  ///
  /// Never throws. Every answer is one of the three [KeyRoute] arms, so a
  /// caller cannot forget a case and cannot invent a default link.
  KeyRoute route(String key) {
    // Departure 1. FIRST — above the disabled check, above the mappings
    // lookup, above every link. `PipeKeys.isPipeKey` is a prefix test, which
    // is what reserves a health key invented in a later phase on the day it is
    // invented; see the note on the ingest path about why the spelling lives
    // in the protocol package.
    if (PipeKeys.isPipeKey(key)) return PipeKeyRoute(key);

    // Departure 2.
    if (key.contains(r'$')) {
      return RefusedRoute(
        key,
        RouteRefusal.substitutionUnsupported,
        'the key "$key" still carries a \$ variable. Substitution is a '
        'client-local key rewrite (state_man_api.dart:26-31): the client '
        'resolves the name and subscribes to the resolved one. The gateway '
        'refuses the unresolved form rather than serving a node that cannot '
        'exist',
      );
    }

    final entry = _mappings.nodes[key];
    if (entry == null) {
      return RefusedRoute(
        key,
        RouteRefusal.unmapped,
        'no keymapping entry for "$key"',
      );
    }

    // The three-way `??` chain, `KeyMappings.lookupServerAlias`
    // (`state_man.dart:645-650`), reached through `KeyMappingEntry.server`
    // (`:586-589`) which is the same chain.
    final alias = StateManConfig.normalizeAlias(entry.server);

    if (disabledAliases.contains(alias)) {
      return RefusedRoute(
        key,
        RouteRefusal.aliasDisabled,
        'the server "${alias ?? '<unnamed>'}" that serves "$key" is switched '
        'off',
      );
    }

    if (ambiguousAliases.contains(alias)) {
      final claimants = [
        for (final binding in links)
          if (binding.serverAlias == alias) binding.link.alias,
      ].join(', ');
      return RefusedRoute(
        key,
        RouteRefusal.ambiguousAlias,
        'more than one link is configured against server_alias '
        '"${alias ?? '<unnamed>'}" — $claimants — so "$key" has no single '
        'owner. Picking the first would put one PLC\'s value on another '
        'PLC\'s page',
      );
    }

    for (final binding in links) {
      final ref = binding.link.resolve(key, entry);
      if (ref == null) continue;
      return ClaimedRoute(binding.link, ref);
    }

    return RefusedRoute(
      key,
      RouteRefusal.unmapped,
      'no configured link claimed "$key". It has a mapping entry, so this is '
      'a link that is not configured rather than a name nobody wrote down',
    );
  }

  /// Aliases held by more than one binding.
  static Set<String?> _ambiguitiesIn(List<UpstreamLinkBinding> links) {
    final seen = <String?>{};
    final twice = <String?>{};
    for (final binding in links) {
      if (!seen.add(binding.serverAlias)) twice.add(binding.serverAlias);
    }
    return Set<String?>.unmodifiable(twice);
  }
}
