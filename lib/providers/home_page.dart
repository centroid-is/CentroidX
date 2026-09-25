/// Reading a session's home page, and the one-shot boot navigation to it.
///
/// See `lib/core/home_page.dart` for what a home page is.
library;

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart' show AccessSession, kAnonymousUsername;

import 'access.dart';

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
    try {
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
/// forgive it from a global pointer route, outside any widget. A
/// [ChangeNotifier] so the route gate can hold the plant's pages back until
/// it is known where the panel opens — see [holdsPages].
class BootHomePageDebt extends ChangeNotifier {
  BootHomePageDebt({bool owed = true}) : _owed = owed;

  bool _owed;
  bool _answered = false;

  /// Whether the boot navigation may still be taken.
  bool get owed => _owed;

  /// Whether the plant's pages must wait: the navigation is still owed and
  /// no lookup has answered yet, so nobody knows which page this panel opens
  /// on.
  ///
  /// `PageAccessGate` shows its checking screen instead of a page while this
  /// is true. The router starts on `/` — Home, or the redirect to the first
  /// page on a station whose Home was deleted — and the session's home page
  /// is a database read behind the session's own. Without the hold, that page
  /// was built the moment the session resolved, ran its subscriptions for the
  /// length of the second read, and was then taken away: an operator saw a
  /// cabinet page they never asked for flash up before their own.
  ///
  /// Released by [settle], by [forgive], and by [answered] — a lookup that
  /// could not read the account at all still opens the panel, where it is,
  /// rather than holding it on a screen until somebody touches it.
  bool get holdsPages => _owed && !_answered;

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
  void settle() {
    if (!_owed && _answered) return;
    _owed = false;
    _answered = true;
    notifyListeners();
  }

  /// Somebody touched the screen, or the panel opened somewhere on purpose.
  void forgive() {
    if (!_owed) return;
    _owed = false;
    notifyListeners();
  }

  /// A lookup answered, but could not say — no database yet, or one that
  /// would not answer. The navigation stays owed for a session that resolves
  /// later; the pages are released now, because waiting on a database that
  /// has already failed is waiting forever.
  void answered() {
    if (_answered) return;
    _answered = true;
    notifyListeners();
  }
}

/// This process's [BootHomePageDebt]. The shell overrides it with the instance
/// its global pointer route forgives. Anywhere else — a test, the page editor
/// harness — owes nothing: only a real start of the app moves a panel on its
/// own, and a harness that mounts a scaffold must not go reading the database
/// for a navigation nobody asked for.
final bootHomePageDebtProvider =
    Provider<BootHomePageDebt>((ref) => BootHomePageDebt(owed: false));
