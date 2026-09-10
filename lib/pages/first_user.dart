/// Commissioning: the one screen that creates the first Engineering account.
///
/// Roles are seeded, users are not, so without this the sign-in dialog ships
/// with nobody able to pass it. Creation is permitted only while `app_user` is
/// empty, and the window closes permanently behind the first account — no
/// default password to forget to change, no bootstrap flag to leave switched
/// on.
///
/// The window check on this page is a **courtesy**. The guard is the
/// in-transaction emptiness re-check inside
/// [AccessRepository.createFirstUser]: checking here and inserting there is a
/// check-then-act race, and this is the one window in the design that must not
/// have a hole in it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:tfc_dart/core/access/access_repository.dart';

import '../providers/access.dart';
import '../widgets/access_sign_in_dialog.dart';
import '../widgets/base_scaffold.dart';

/// The intro. Says what is being created, not merely that something is.
const String _kIntro =
    'Roles are seeded; users are not. This creates the first Engineering '
    'account.';

/// Why there is no second chance.
const String _kOneShot =
    'This window is open only while no users exist. Once this account is '
    'created it closes permanently — there is no default password and no '
    'bootstrap flag.';

/// The consequence of the window standing open, stated plainly rather than
/// left in the deployment doc where the person at the panel will not read it.
const String _kClaimable =
    'A freshly deployed station is claimable by whoever reaches it first. Do '
    'this at commissioning.';

/// The honesty line. This milestone records who changed what; it does not stop
/// anybody, and a screen that implied otherwise would be the more dangerous
/// outcome.
const String _kHonesty =
    'Signing in records who changed what. It is a guardrail, not a security '
    'boundary.';

/// The closed state. Names the deployment doc rather than linking it, because
/// the station that needs it may be the one that cannot be signed into.
const String _kClosed =
    'An account already exists, so this window is closed. Recovery is a '
    'deployment task — see docs/access-control-deployment.md.';

/// No database configured, or the connection has not opened yet.
///
/// Deliberately distinct from [_kClosed]: `firstUserWindowOpenProvider`
/// answers false in both cases, and telling a commissioning engineer that
/// somebody already claimed a station they just unboxed would send them
/// looking for the wrong problem.
const String _kNoDatabase =
    'This station has no reachable database, so the first account cannot be '
    'created yet. Configure the connection in Server Config and come back.';

/// The heading of the success state.
///
/// This screen used to have no success state at all. The window *is* shut the
/// instant the insert lands, so a successful creation fell straight through to
/// [_kClosed] and told the commissioning engineer that somebody else had
/// already claimed the station — at the exact moment they had claimed it
/// themselves, and with the account sitting in the database working fine. The
/// two outcomes are opposites and must never render the same.
const String _kCreatedTitle = 'Account created';

/// The body of the success state.
///
/// Names the account so the engineer can see what to type, says the window is
/// shut (which is the true half of [_kClosed], and the half worth keeping),
/// and points at the one thing left to do.
String _kCreatedBody(String username) =>
    'The account "$username" now holds the Engineering role, and this window '
    'is closed behind it. Sign in with it to continue.';

/// The sign-in action on the success state, for tests and automation.
const Key kFirstUserSignInKey = Key('first-user-sign-in');

/// Route target for [AppRoutes.firstUser].
///
/// Field-less on purpose so `createLocationBuilder` can register it as
/// `const FirstUserPage()`. All of the logic lives in [FirstUserBody].
class FirstUserPage extends StatelessWidget {
  const FirstUserPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const BaseScaffold(
      title: 'First account',
      body: FirstUserBody(),
    );
  }
}

/// The page content, split from [FirstUserPage] so tests can pump it without
/// [BaseScaffold]'s routing context.
///
/// [BaseScaffold] calls `context.currentBeamLocation`, so it cannot be pumped
/// without a Beamer ancestor. `IpSettingsBody` and `ServerConfigBody` are the
/// same split for the same reason.
class FirstUserBody extends ConsumerStatefulWidget {
  const FirstUserBody({
    super.key,
    this.openSignIn = showAccessSignInDialog,
  });

  /// How the confirmation's sign-in action opens the prompt. Injectable for
  /// the same reason `AccessStatusAction`, `AccessGate` and
  /// `AccessDeniedPrompt` take it: a widget test can then assert the button
  /// opens sign-in without standing up a dialog route and a Beamer ancestor
  /// (`showAccessSignInDialog` beams on the value the dialog pops with).
  final AccessSignInOpener openSignIn;

  @override
  ConsumerState<FirstUserBody> createState() => _FirstUserBodyState();
}

class _FirstUserBodyState extends ConsumerState<FirstUserBody> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  /// The inline error under the form. Never contains the credential.
  String? _error;

  /// True while a `createFirstUser` call is outstanding — the action is
  /// disabled for its duration so a second tap cannot race the first.
  bool _submitting = false;

  /// Set when the repository reports the window shut under us. The provider
  /// may still be answering true from before the race; the repository is the
  /// authority, so this pins the closed state locally.
  bool _lostTheRace = false;

  /// The account this screen created, once `createFirstUser` has returned.
  ///
  /// Non-null is the success state, and it outranks every closed-window branch
  /// in [build]: after a successful create the window is legitimately shut, and
  /// without this the screen answers a successful submit with [_kClosed].
  String? _createdUsername;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit(AccessRepository repo) async {
    final username = _username.text.trim();
    final password = _password.text;

    if (username.isEmpty) {
      setState(() => _error = 'Enter a username.');
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = 'Enter a password.');
      return;
    }
    if (password != _confirm.text) {
      setState(() => _error = 'The passwords do not match.');
      return;
    }

    setState(() {
      _error = null;
      _submitting = true;
    });

    try {
      await repo.createFirstUser(username: username, password: password);
      if (!mounted) return;
      // Re-ask rather than assume: the provider counts the rows, and a page
      // that decided the window was shut on its own say-so would be a second
      // source of truth for the one rule this screen exists to enforce.
      ref.invalidate(firstUserWindowOpenProvider);
      setState(() {
        _submitting = false;
        _createdUsername = username;
        // The form is gone from here on, and there is no reason for the
        // credential to stay live in a controller behind it.
        _password.clear();
        _confirm.clear();
      });
    } on FirstUserWindowClosedError {
      // Somebody claimed the station between the check and the submit. The
      // transaction made the outcome correct; this only has to say so.
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _lostTheRace = true;
      });
    } on Object catch (e, st) {
      // The exception goes to the log, never to the screen. An `ArgumentError`
      // raised on a bad credential can carry the credential in its message,
      // and this is the one screen where the password is in hand — rendering
      // `$e` would put it in a screenshot of a commissioning session.
      Logger().e('createFirstUser failed', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'The account could not be created. '
            'The log has the details.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final repoAsync = ref.watch(accessRepositoryProvider);
    final windowAsync = ref.watch(firstUserWindowOpenProvider);

    // A database that cannot even be constructed is a missing database, not a
    // claimed station.
    if (repoAsync.hasError) return _message(context, _kNoDatabase);
    if (!repoAsync.hasValue) return _loading();
    final repo = repoAsync.requireValue;
    if (repo == null) return _message(context, _kNoDatabase);

    // Before every closed branch below. All three of them are true once this
    // screen has created an account — that is the point of the window — and
    // all three of them would be reporting somebody else's account.
    final created = _createdUsername;
    if (created != null) return _createdMessage(context, created);

    // The window closes on the repository's word before the provider's.
    if (_lostTheRace) return _message(context, _kClosed);
    // The provider swallows its own errors, but if one ever reaches here the
    // safe direction is closed: this screen hands out Engineering.
    if (windowAsync.hasError) return _message(context, _kClosed);
    if (!windowAsync.hasValue) return _loading();
    if (!windowAsync.requireValue) return _message(context, _kClosed);

    return _form(context, repo);
  }

  /// A progress indicator rather than an empty box: this route is reached
  /// deliberately, and a blank page reads as broken.
  Widget _loading() => const Center(child: CircularProgressIndicator());

  Widget _shell(BuildContext context, List<Widget> children) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }

  Widget _message(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return _shell(context, [
      Icon(Icons.lock_outline, size: 40, color: scheme.onSurfaceVariant),
      const SizedBox(height: 16),
      Text(text, textAlign: TextAlign.center),
    ]);
  }

  /// The success state: a padlock and [_kClosed] would say the opposite of
  /// what just happened.
  ///
  /// `colorScheme.tertiary` rather than an `HmiStateColors` green — that
  /// extension is the equipment-state vocabulary (green is running/auto), and
  /// a commissioning account is not a piece of plant. `history_view.dart`'s
  /// validity tick is the same idiom.
  Widget _createdMessage(BuildContext context, String username) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _shell(context, [
      Icon(Icons.check_circle_outline, size: 40, color: scheme.tertiary),
      const SizedBox(height: 16),
      Text(
        _kCreatedTitle,
        style: theme.textTheme.headlineSmall,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      Text(_kCreatedBody(username), textAlign: TextAlign.center),
      const SizedBox(height: 24),
      ElevatedButton(
        key: kFirstUserSignInKey,
        // The dialog, not a route: the sign-in surface this account is for is
        // modal everywhere else in the app, and its "Create the first account"
        // link is already gone now that the window answers closed.
        onPressed: () => widget.openSignIn(context, ref),
        child: const Text('Sign in'),
      ),
    ]);
  }

  Widget _form(BuildContext context, AccessRepository repo) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final secondary = theme.textTheme.bodyMedium
        ?.copyWith(color: scheme.onSurfaceVariant);

    return _shell(context, [
      Text('First account', style: theme.textTheme.headlineSmall),
      const SizedBox(height: 16),
      Text(_kIntro, style: theme.textTheme.bodyLarge),
      const SizedBox(height: 12),
      Text(_kOneShot, style: secondary),
      const SizedBox(height: 12),
      Text(_kClaimable, style: secondary),
      const SizedBox(height: 24),
      TextField(
        controller: _username,
        autofocus: true,
        enabled: !_submitting,
        decoration: const InputDecoration(
          labelText: 'Username',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _password,
        obscureText: true,
        enabled: !_submitting,
        decoration: const InputDecoration(
          labelText: 'Password',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _confirm,
        obscureText: true,
        enabled: !_submitting,
        onSubmitted: _submitting ? null : (_) => _submit(repo),
        decoration: const InputDecoration(
          labelText: 'Confirm password',
          border: OutlineInputBorder(),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(
          _error!,
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
        ),
      ],
      const SizedBox(height: 20),
      ElevatedButton(
        onPressed: _submitting ? null : () => _submit(repo),
        child: const Text('Create account'),
      ),
      const SizedBox(height: 24),
      Text(_kHonesty, style: secondary),
    ]);
  }
}
