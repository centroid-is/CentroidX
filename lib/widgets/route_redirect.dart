/// The stand-in for a path that must not be rendered: it sends the operator
/// somewhere real instead.
///
/// Registered as the "page" for paths that must refuse direct navigation —
/// `/` when the Home page has been deleted, or an unpublished (draft) page's
/// path — so typing an address or following a stale link lands the operator
/// on a real page instead of a dead not-found screen.
///
/// ## Why it re-arms, and why it is not blank
///
/// Beamer's `RoutesBeamLocation` **stacks every sub-matching route**, and `/`
/// sub-matches everything. So on a station whose Home page has been deleted,
/// the `/` stub is not a page the operator passes through at boot and leaves
/// behind: it is mounted at the bottom of the navigator stack underneath every
/// page in the app, for the whole life of the process, with its [State] alive.
///
/// That is what made the original one-shot version a plant-floor fault. It
/// beamed from `initState`, which runs **once**. Anything that later navigated
/// back to `/` popped the page above and revealed the very same `State` —
/// `initState` does not run again, no redirect was scheduled, and the app sat
/// on `Scaffold(body: SizedBox.shrink())`: white, no app bar, no navigation
/// bar, nothing to press. The app was perfectly healthy and rendering frames,
/// which is exactly how an operator reports it as a freeze.
///
/// The thing that navigates back to `/` is the access layer.
/// `BaseScaffold._returnToStartupPage` beams to `resolveStartupPath(...)` on
/// every elevated-to-anonymous transition — a sign-out, or an inactivity
/// expiry — and a station with no `startup_url` stored resolves that to `/`.
/// So on a station with no Home page, *every session that ended* painted the
/// panel white until somebody restarted the app.
///
/// Two changes, and both are load-bearing:
///
///  * **It listens to the router, and it knows [from].** The redirect is
///    re-armed on every route change the delegate announces — not on a widget
///    lifecycle hook, because the failing case is precisely the one where no
///    lifecycle hook runs — and it fires only when the router is actually
///    showing [from]. The [from] guard is what stops a buried `/` stub beaming
///    away from whatever page the operator is on; the listener is what makes
///    the redirect happen at all the second time.
///  * **It renders something.** One frame is the design, but a redirect that
///    is wedged for any reason must not look like a crash. Naming where it is
///    going, and offering the button that gets there, costs a frame nobody
///    sees and is the difference between "the panel is busy" and "the panel is
///    dead" for the person standing in front of it.
///
/// **No `BaseScaffold`, deliberately.** The chrome would be the nicer answer
/// and it is what every other route in the app renders — but this stub is
/// mounted *beneath every page on the station*, and `BaseScaffold` mounts an
/// `AccessDeniedPrompt`, which subscribes to `accessDenialsProvider`. A second
/// subscription in a sibling route is a second dialog for one refused write,
/// on every page, forever. The trade is taken the other way round: this page
/// says what it is in plain words and keeps its own single control, and the
/// navigation bar comes back with the page it is taking the operator to.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';

/// The body, so a test can assert this page rendered at all — and, more to the
/// point, that it rendered *something*.
const Key kRouteRedirectBodyKey = Key('route-redirect-body');

/// The manual way on, for when the automatic one has not landed.
const Key kRouteRedirectGoKey = Key('route-redirect-go');

/// What the page says it is doing. A sentence, not a spinner: a bare spinner
/// on a station is indistinguishable from a hung app, which is the failure
/// this whole file exists to stop reproducing.
String kRouteRedirectNote(String target) => 'This page is not available here. '
    'Taking you to $target.';

class RouteRedirect extends StatefulWidget {
  const RouteRedirect({
    super.key,
    required this.from,
    required this.target,
  });

  /// The path this stub stands at.
  ///
  /// Required, and compared against the router's current location before
  /// anything is beamed. The stub for `/` is mounted underneath every page on
  /// a station with no Home page, so a redirect that did not check would drag
  /// the operator off whatever they were looking at on the next rebuild.
  final String from;

  /// The path to land on instead.
  final String target;

  @override
  State<RouteRedirect> createState() => _RouteRedirectState();
}

class _RouteRedirectState extends State<RouteRedirect> {
  /// The router this widget is listening to, so the listener can be removed
  /// from the same object it was added to even if the host swaps delegates.
  BeamerDelegate? _listening;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Wired here rather than in `initState` because finding the router is an
    // inherited-widget lookup.
    final beamer = _beamer();
    if (!identical(beamer, _listening)) {
      _listening?.removeListener(_onRouteChanged);
      _listening = beamer;
      _listening?.addListener(_onRouteChanged);
    }
    _armRedirect();
  }

  @override
  void dispose() {
    _listening?.removeListener(_onRouteChanged);
    _listening = null;
    super.dispose();
  }

  void _onRouteChanged() {
    if (!mounted) return;
    _armRedirect();
  }

  /// Schedules the beam for after this frame, if this stub is the page the
  /// router is actually showing.
  ///
  /// Post-frame because beaming rebuilds the router, which cannot happen
  /// during a build or inside the router's own notification. Re-entrancy is
  /// harmless: the beam itself notifies, which arms this again, and the
  /// location guard below turns that second pass into a no-op.
  void _armRedirect() {
    if (widget.target == widget.from) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final beamer = _beamer();
      if (beamer == null) return;
      // Not the page on screen — a buried stub, or one whose redirect has
      // already landed. Either way there is nothing to do, and beaming from
      // down there would drag the operator off the page they are on.
      if (beamer.configuration.uri.path != widget.from) return;
      beamer.beamToReplacementNamed(widget.target);
    });
  }

  void _goNow() {
    final beamer = _beamer();
    if (beamer == null) return;
    if (beamer.configuration.uri.path == widget.target) return;
    beamer.beamToReplacementNamed(widget.target);
  }

  /// The router, or null when this widget has been mounted without one.
  ///
  /// The same two lookups `Beamer.of` does, in the same order, without its
  /// assert. A page whose entire job is to never be a dead end must not be the
  /// thing that throws out of a post-frame callback because of how its host
  /// was built.
  BeamerDelegate? _beamer() {
    final delegate = Router.maybeOf(context)?.routerDelegate;
    if (delegate is BeamerDelegate) return delegate;
    return BeamerProvider.of(context)?.routerDelegate;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // On screen for a single frame in the ordinary case. Rendered anyway: see
    // the library comment — a blank page is how a healthy app gets reported as
    // a dead one.
    return Scaffold(
      body: Center(
        key: kRouteRedirectBodyKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.subdirectory_arrow_right,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              kRouteRedirectNote(widget.target),
              textAlign: TextAlign.center,
              maxLines: null,
              overflow: TextOverflow.visible,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              key: kRouteRedirectGoKey,
              onPressed: _goNow,
              child: Text('Go to ${widget.target}'),
            ),
          ],
        ),
      ),
    );
  }
}
