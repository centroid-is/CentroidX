/// Reading a session's home page, and the one-shot boot navigation to it.
///
/// See `lib/core/home_page.dart` for what a home page is.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart' show AccessSession, kAnonymousUsername;

import '../core/access_authority.dart';
import 'access.dart';
import 'access_admin.dart' show relayedAccountSummary;

/// A home-page lookup's answer.
///
/// [known] is false when the account could not be read at all — no database
/// yet, or one that would not answer — so a caller can tell "this account
/// opens on Home" (`known`, [page] null) from "nobody could say".
typedef HomePageAnswer = ({bool known, String? page});

/// Reads the stored home page of the account [session] answers as: the
/// signed-in account, or the reserved anonymous account when nobody is.
typedef HomePageLookup = Future<HomePageAnswer> Function(AccessSession session);

/// The [HomePageLookup] navigation uses. A provider so tests can hand it pages
/// without a database.
///
/// Read at the moment of navigation rather than carried on the session: a
/// session is rebuilt on every activity extension and role refresh, and a home
/// page riding along would have to be threaded through each of them to stay
/// right. It is only needed at the three moments a panel moves on its own —
/// boot, sign-in and a session ending.
final homePageLookupProvider = Provider<HomePageLookup>((ref) {
  return (session) async {
    // The transport question first, and asked of the authority rather than
    // resolved out of a null repository — the rule `guard_wiring_test` states
    // and the three defects it names were each a caller deciding what a null
    // repository meant on its own. A gateway panel has no repository **by
    // design and permanently**, so "nobody could say yet" would be a debt it
    // can never settle: the boot navigation would stay owed for the life of
    // the process, waiting on a database that is not coming.
    //
    // On the relay the account's row is read from the gateway's roster
    // (`UserSummary.homePage`). A session the gateway will not show the
    // roster to — see [relayedAccountSummary] — is answered KNOWN, page null:
    // the panel opens on Home and stops owing anybody a move, rather than
    // owing one that no later answer can settle.
    final authority = await ref.read(accessAuthorityProvider.future);
    try {
      if (authority == AccessAuthority.relay) {
        final row = await relayedAccountSummary(ref, session);
        return (known: true, page: row?.homePage);
      }
      final repo = await ref.read(accessRepositoryProvider.future);
      if (repo == null) return (known: false, page: null);
      final row = await repo.user(session.user?.username ?? kAnonymousUsername);
      return (known: true, page: row?.homePage);
    } on Object catch (e) {
      Logger().w('Could not read the home page for $session: $e');
      return (known: false, page: null);
    }
  };
});

/// The navigation to the session's home page that a freshly started panel
/// still owes its operator.
///
/// Owed from process start, and settled the first time the home page is
/// actually known — a panel that booted before its database answered still
/// gets there once it does. Forgiven, never to be taken, the moment anybody
/// touches the screen: an operator who has already started working while the
/// database was slow must not be pulled somewhere else seconds or minutes
/// later. The shell also forgives it up front for a deep link from the
/// platform, and for an engine rebuild that put the operator back where they
/// were (`lib/core/last_route.dart`).
///
/// A plain object rather than provider state because the shell has to
/// forgive it from a global pointer route, outside any widget.
class BootHomePageDebt {
  BootHomePageDebt({bool owed = true}) : _owed = owed;

  bool _owed;

  /// Whether the boot navigation may still be taken.
  bool get owed => _owed;

  /// The attempt some scaffold is making right now, or null.
  ///
  /// At boot more than one scaffold can be mounted and the panel moves once,
  /// so a second scaffold waits on this rather than starting its own lookup —
  /// and, when it completes, tries itself if the debt is still [owed]. Waiting
  /// rather than skipping is the point: the scaffold that started the attempt
  /// can be gone by the time the answer arrives (`PageAccessGate` swaps its
  /// waiting scaffold for the page's the frame after the session resolves),
  /// and a skipped turn was then nobody's turn.
  Future<void>? inFlight;

  /// The navigation was taken, or the home page turned out to be where the
  /// panel already is. Only a scaffold still mounted when the answer arrives
  /// may say so: one that was unmounted during the lookup moved nothing.
  void settle() => _owed = false;

  /// Somebody touched the screen, or the panel opened somewhere on purpose.
  void forgive() => _owed = false;
}

/// This process's [BootHomePageDebt]. The shell overrides it with the instance
/// its global pointer route forgives. Anywhere else — a test, the page editor
/// harness — owes nothing: only a real start of the app moves a panel on its
/// own, and a harness that mounts a scaffold must not go reading the database
/// for a navigation nobody asked for.
final bootHomePageDebtProvider =
    Provider<BootHomePageDebt>((ref) => BootHomePageDebt(owed: false));
