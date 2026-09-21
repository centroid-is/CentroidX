import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart'
    show GuardedConfigStore;
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart'
    show ConfigWriteResult;
import 'package:tfc_dart/core/preferences.dart';

import '../core/relayed_config_items.dart';
import '../page_creator/page.dart';
import 'config_store.dart';
import 'device_local_store_open.dart';
import 'gateway.dart';
import 'preferences.dart';

part 'page_manager.g.dart';

/// The page layout as it was the last time this station spoke to the database,
/// loaded from local SharedPreferences before `runApp`.
///
/// [pageManagerProvider] is the authority and this is never consulted once it
/// has answered. It exists only to fill the wait: that provider hangs off
/// `preferencesProvider` → `databaseProvider`, and measured against the real
/// plant config the plant page appeared in 75 ms when Postgres was reachable,
/// 5 ms when the port refused — and **10 012 ms** when the host was routable
/// but never answered, which is what a powered-off server or a cut link looks
/// like on a plant network. For those ten seconds the operator got a blank
/// page. Loading this copy costs 2.3 ms and the app already did it, then threw
/// the result away.
///
/// Null when nothing has been cached yet (a first run, or a station whose
/// local store was wiped) — the app then behaves exactly as it did before.
/// `main()` overrides it; the default keeps every other entry point and every
/// test working without one.
final bootstrapPageManagerProvider = Provider<PageManager?>((ref) => null);

/// The kinds a page layout is assembled from. A diff touching neither is not
/// this provider's business.
const Set<ConfigKind> _pageKinds = {ConfigKind.page, ConfigKind.asset};

PreferencesApi? _localPreferencesOrNull(Ref ref) {
  try {
    return ref.read(localPreferencesProvider);
  } on StateError {
    return null;
  }
}

@Riverpod(keepAlive: true)
Future<PageManager> pageManager(Ref ref) async {
  final prefs = await ref.watch(preferencesProvider.future);
  // The **raw** store, for reads. `configStoreProvider` deliberately never
  // watches `databaseProvider` — its object identity is stable for the life of
  // the process and the remote is attached underneath it — so the manager
  // holds one store for the whole session and the change stream below stays
  // attached across every reconnect. Writes are not this field's business:
  // `save()` stays on the guarded object, because the page editor's save is a
  // person editing pages and is exactly what `configure` is for.
  //
  // **Where the rows come from.** A browser has no SQLite and so no mirror of
  // the plant's page and asset rows; a **relayed station** has a mirror that
  // nothing fills, because `configStoreProvider` attaches no remote when
  // `databaseProvider` answers null — by design, so a gateway client holds no
  // second connection to the plant's Postgres. Both therefore read the rows
  // over the relay (`relayed_config_items.dart`): from the device-local cache
  // at boot, refreshed once a signed-in session can fetch them, and re-read
  // here on every change the backend announces.
  //
  // It was a compile-time constant and could not stay one: the build says
  // whether a mirror *can* exist, and that is a different question from
  // whether this panel's rows are in it. [configRowsComeOverTheWire] is the
  // one place the two are told apart.
  final gateway = await ref.watch(gatewayConfigProvider.future);
  final GuardedConfigStore? guarded =
      configRowsComeOverTheWire(isGateway: gateway.isGateway)
          ? null
          : await ref.watch(configStoreProvider.future);
  final store = guarded?.inner;
  // The device-local store, where the one-shot import put `page_editor_data`.
  // A process with no device-local store open — a test container that did
  // not set one — reads `prefs` instead, which is where such a test put its
  // blob.
  final local = _localPreferencesOrNull(ref);

  // The save, and the only route pages take to the shared rows. Both kinds
  // are in the replace set because a page and its assets move together —
  // leave `asset` out and an asset the operator deleted would be inserted
  // and never removed — while `checkKind` names the single
  // `kConfigWriteKeys` row that decides who may do it. One gesture, one
  // check, one audit row under `page_editor_data`: 02-05's C-8 is explicit
  // that a new surface or a per-entity item key falls closed to
  // `administer` and locks every operator and shift leader out of the page
  // editor, and the failure reads as a permissions bug rather than a typo.
  //
  // Without a mirror the binding is [_refuseWriteWithoutMirror], and it is
  // bound rather than left null on purpose — see that function.
  Future<ConfigWriteResult> Function(List<ConfigItem> wanted,
      {String? reason, List<ConfigItem>? derivedFrom}) writeItems =
      _refuseWriteWithoutMirror;
  // The access check, before the fallback gate in `save()`: an anonymous
  // session on a station still waiting for the plant's pages is refused
  // and recorded as a refusal, not told to wait.
  Future<void> Function()? preflight;
  if (guarded != null) {
    writeItems = (wanted, {reason, derivedFrom}) => guarded.write(
          wanted,
          kinds: _pageKinds,
          checkKind: ConfigKind.page,
          reason: reason,
          derivedFrom: derivedFrom,
        );
    preflight = () => guarded.refuseUnlessCan(ConfigKind.page);
  }

  final pageManager = PageManager(
    pages: {},
    // The shared store — except where there is no mirror. `load()` reads the
    // top-level order out of `prefs` whenever the store cannot answer it, and
    // a browser's shared store is the relay: it parks until the client exists,
    // fails when that client could not be built, and refuses until somebody
    // signs in. Every one of those made the home page error on a read for a
    // row the plant cannot serve this client anyway (the order is a
    // preference over page rows the browser cannot receive). The device-local
    // store answers null, which is the built-in layout, which is what the
    // browser has.
    prefs: store == null ? (local ?? prefs) : prefs,
    store: store,
    writeItems: writeItems,
    blobPrefs: local,
    preflight: preflight,
  );

  if (store == null) {
    final relayed = await ref.watch(relayedConfigItemsProvider.future);
    // Rows first, when there are any; the ordinary load otherwise — the
    // blob this client has never held and then the built-in default, which
    // is what a fresh browser shows until it signs in and fetches.
    await pageManager.loadFromItems(relayed.itemsOf(kRelayedConfigKinds));
    // Freshness: each replaced snapshot is loaded whole and announced. The
    // same object, re-filled, so everything watching this provider sees
    // the plant's pages as they now are — the page view keys its assets by
    // instance and rebuilds what actually changed.
    final follow = relayed.changed.listen((_) {
      unawaited(pageManager
          .loadFromItems(relayed.itemsOf(kRelayedConfigKinds))
          .then((_) => ref.notifyListeners())
          .catchError((Object e) {
        // `loadFromItems` does not throw; an unawaited future with no
        // handler is an unhandled asynchronous error if that ever stops
        // being true.
        return;
      }));
    });
    ref.onDispose(() => unawaited(follow.cancel()));
    return pageManager;
  }

  await pageManager.load();

  // ## The rollout-day window, and why it has to close without a restart
  //
  // Page rows cannot pre-exist the migration that mints them, so on cutover
  // day *every* station loads before its mirror holds any — it comes up on
  // the blob, read-only, holding pages with no row identity. Without this
  // listener it holds them for the whole session, and the first Save mints
  // fresh random ids for all of them and rewrites ~410 rows, severing every
  // identity the migration just minted. That save commits cleanly; nothing
  // downstream detects it. So the window is closed at the reconcile, not at
  // the next boot.
  //
  // Only while the manager is serving a fallback: a manager already on rows
  // is the steady state, and re-loading it out from under a live layout on
  // every incoming diff is a different feature with a different blast radius
  // (Phase 4). `servingFallback` is a named flag on the manager rather than
  // `pages.isEmpty` because a station on the blob has a hundred pages.
  //
  // The re-load cannot clobber an open editing session: the editor works on
  // `PageManager.copyPages` output, not on this object's map. That session's
  // own save is covered by 03-06's identity adoption — the other half.
  // No `store != null` here: the wire-served arm above returns, so a manager
  // that reaches this line has a mirror by construction. It used to be
  // spelled out because the branch above was a compile-time constant and the
  // analyzer could not see through it.
  if (pageManager.servingFallback) {
    late final StreamSubscription<void> subscription;
    subscription = store.keyMappingChanges.listen((diff) {
      final touchesPages = [
        ...diff.added,
        ...diff.changed,
        ...diff.removed,
      ].any((item) => _pageKinds.contains(item.kind));
      if (!touchesPages) return;
      // Synchronous through the store's snapshot for the rows; the only await
      // inside `load()` is the device-local `topLevelOrder` read.
      unawaited(pageManager.load().then((_) {
        if (!pageManager.servingFallback) {
          // The window is closed. Nothing left to watch for.
          unawaited(subscription.cancel());
        }
        ref.notifyListeners();
      }).catchError((Object e) {
        // `load()` does not throw, but an unawaited future with no handler is
        // an unhandled asynchronous error if that ever stops being true.
        return;
      }));
    });
    ref.onDispose(() => unawaited(subscription.cancel()));
  }

  return pageManager;
}

/// The save a platform with no mirror answers: a refusal by name, and nothing
/// written anywhere.
///
/// **A boundary, not an oversight.** The row route the browser reads its
/// pages through (`configItems.*`) carries no write, on purpose: a save is
/// a merge against the plant's current rows, a `configure` check, and a
/// `config_change` row attributed through the relay's audit — the discipline
/// `ConfigStore` applies against a mirror, and a design of its own for a
/// client that has none. Until it exists, editing pages is station work.
///
/// The alternative — leaving `writeItems` unbound — takes `PageManager.save`
/// down its legacy path and writes the whole layout as a blob into the
/// device-local store, which in a browser is `localStorage`: the operator
/// would watch a save succeed, this one tab would serve the edited layout on
/// its next load, and no other screen on the plant would ever see it. That
/// is the silent-divergence class `relayed_preferences.dart` opens by
/// describing, and a refusal is the only honest answer until page rows
/// travel the relay.
Future<ConfigWriteResult> _refuseWriteWithoutMirror(
  List<ConfigItem> wanted, {
  String? reason,
  List<ConfigItem>? derivedFrom,
}) async {
  throw UnsupportedError(
      'This client reads the plant\'s pages over the relay and cannot write '
      'them back: the row route is reads only, and a browser holds no '
      'mirror to merge a save against. Nothing was written. Edit the pages '
      'on a station.');
}
