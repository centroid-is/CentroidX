/// Moving the panel to a session's home page.
///
/// Three moments move a panel on its own, and all three come through
/// [goToHomePage] so they resolve a home page identically:
///
///  * **boot** — the session the panel starts as (`BaseScaffold`);
///  * **a session ending** — sign-out, inactivity, or a person's session
///    falling back to the panel's own account (`BaseScaffold`);
///  * **signing in from the app bar** — only when the account has a page of
///    its own (`showAccessSignInDialogAndGoHome`). Signing in from a refusal
///    stays put: that person signed in to open the page they are on.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_access/tfc_access.dart' show AccessSession;

import '../core/home_page.dart';
import '../providers/home_page.dart';
import '../providers/menu.dart';

/// Looks up [session]'s home page and beams there.
///
/// Stays put when the page is already showing, when [onlyIfSet] is true and
/// the account has no page of its own, or when [proceed] — asked after the
/// lookup, because the operator and the session can both move during it —
/// says the moment has passed. Returns the lookup's answer so the boot path
/// can tell whether the page was known at all.
///
/// Validated against the full menu tree, not the session's visible menu, for
/// the reason `resolveHomePath` gives: whether *this* session may open the
/// page is the route gate's question, and it answers with an honest refusal
/// rather than a silently different page.
Future<HomePageAnswer> goToHomePage({
  required BuildContext context,
  required WidgetRef ref,
  required AccessSession session,
  bool onlyIfSet = false,
  bool Function(String currentPath)? proceed,
}) async {
  final answer = await ref.read(homePageLookupProvider)(session);
  if (!context.mounted) return answer;
  if (onlyIfSet && answer.page == null) return answer;
  final beamer = Beamer.of(context);
  final current = beamer.configuration.uri.path;
  if (proceed != null && !proceed(current)) return answer;
  final target =
      resolveHomePath(answer.page, menuItems: ref.read(menuTreeProvider));
  if (current == target) return answer;
  beamer.beamToNamed(target);
  return answer;
}
