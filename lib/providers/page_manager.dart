import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tfc_dart/core/config/config_item.dart';

import '../page_creator/page.dart';
import 'config_store.dart';
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
  final guarded = await ref.watch(configStoreProvider.future);
  final store = guarded.inner;

  final pageManager = PageManager(
    pages: {},
    prefs: prefs,
    store: store,
    // The save, and the only route pages take to the shared rows. Both kinds
    // are in the replace set because a page and its assets move together —
    // leave `asset` out and an asset the operator deleted would be inserted
    // and never removed — while `checkKind` names the single
    // `kConfigWriteKeys` row that decides who may do it. One gesture, one
    // check, one audit row under `page_editor_data`: 02-05's C-8 is explicit
    // that a new surface or a per-entity item key falls closed to
    // `administer` and locks every operator and shift leader out of the page
    // editor, and the failure reads as a permissions bug rather than a typo.
    writeItems: (wanted, {reason}) => guarded.write(
      wanted,
      kinds: _pageKinds,
      checkKind: ConfigKind.page,
      reason: reason,
    ),
  );

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
