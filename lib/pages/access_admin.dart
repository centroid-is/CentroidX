/// The administration screen: roles, accounts, and the paragraph that says
/// what all of it is not.
///
/// **One page, two sections** (06-CONTEXT, "Roles Screen"). A single
/// `/advanced/access` route with the roles section above the users section.
/// `key_repository.dart` already stacks gated sections on one page and is the
/// analog; two Advanced entries would crowd a menu that is already long.
/// The order is the commissioning order — create roles, then accounts, then
/// close the first-user window — which is the sequence
/// `docs/access-control-deployment.md` §4 now spells out.
///
/// **This file composes and nothing else.** No store, no repository, no Drift,
/// no query, no write. Both sections own their own reads, their own writes and
/// their own four terminal states; the one thing this page owns that neither
/// section does is the *page-level* loading affordance, because a section is
/// one card on a screen and a page is the whole screen.
///
/// **No gate here.** The `users` gate is applied at the route, exactly as it is
/// for the other eight raised routes (`lib/access_routes.dart`,
/// `lib/widgets/access_gate.dart`). A second gate inside the page would be a
/// second place to get it wrong.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/access_admin.dart';
import '../widgets/base_scaffold.dart';
import 'access_admin_proposals.dart';
import 'access_roles_section.dart';
import 'access_session_section.dart';
import 'access_users_section.dart';

// ---------------------------------------------------------------------------
// Copy
// ---------------------------------------------------------------------------

/// The route's title, in the app bar and in the Advanced menu.
///
/// One string, declared once, because 06-10 has to repeat it in three places —
/// the route table, the menu entry and the gate's locked scaffold — and three
/// spellings of one screen's name is how a locked page stops looking like the
/// page it locks. Short and unambiguous: "Access" is what the milestone is
/// called everywhere else in this tree.
const String kAccessAdminTitle = 'Access';

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

/// The page-level progress indicator.
///
/// Its own key rather than a bare [CircularProgressIndicator] finder: the two
/// sections may each show a spinner of their own inside a dialog, and a test
/// meaning "the page has not decided yet" must not pass on one of those.
const Key kAccessAdminLoadingKey = Key('access-admin-loading');

// ---------------------------------------------------------------------------
// Heights
//
// Two variable-height lists on one page make this number matter more than it
// does on `key_repository.dart`, which has one. Both figures below were
// measured, not chosen: a nudged constant here is a page that reads correctly
// on a 1080p panel and clips on a cabinet-door screen.
// ---------------------------------------------------------------------------

/// Everything on this page that is not a role row or an account row: the page
/// padding, both section cards' frames and the gap between them.
///
/// **Measured at 800 px wide**, which is the width the widget tests and the
/// goldens run at and the narrower — therefore taller — of the two cases:
///
/// | Piece | Height |
/// |---|---|
/// | page padding, top and bottom | 24 |
/// | roles card frame — margins, header row, subtitle | 136 |
/// | gap | 16 |
/// | users card frame — margins, header row, subtitle | 136 |
///
/// 312 px, rounded up to 320. The two card frames were derived rather than
/// eyeballed: the seeded roles card measures 421 px with four role rows summing
/// to 285 px, and the seeded users card 268 px with a 28 px header and two
/// 52 px rows — 136 px of frame each way, from two independent measurements
/// that agree.
///
/// It carried 440 while a one-sentence note card (104 px, and its 16 px gap)
/// sat at the foot of the page; the note was removed and the number with it.
const double kAccessAdminChromeHeight = 320;

/// The room the two lists are worth showing in at all: the four seeded roles,
/// and a commissioned station's two accounts under their column header.
///
/// **Measured at 800 px wide against the seeded database.** The four seeded
/// roles are not equal: `Operator` 64 px, `Maintenance` 70 px, `Shift Leader`
/// 64 px and `Engineering` 87 px — they differ because the summary line lists
/// the groups the role grants and `Engineering` grants all seven, so it wraps.
/// That is 285 px. The roster is a 28 px column header plus two 52 px rows,
/// 132 px. 417 px, rounded up to 424.
///
/// Below this the page has no room for a list worth reading and is scrolled as
/// a whole instead. It is deliberately **not** the height of a full roster: a
/// site with thirty accounts scrolls, and sizing the floor to the largest
/// plausible roster would put every panel below the threshold and make the
/// fallback the normal case rather than the short-window one.
const double kAccessAdminMinListsHeight = 424;

/// The height below which this page is given its measured height and scrolled,
/// rather than being laid out in the window it was handed.
///
/// The sum of the two measurements above, and derived rather than declared, so
/// that changing either one moves the threshold with it. A 1080p station is far
/// above it and lays out directly.
const double kAccessAdminMinContentHeight =
    kAccessAdminChromeHeight + kAccessAdminMinListsHeight;

/// The gap between sections.
const double _kSectionGap = 16;

/// The page's own padding.
const EdgeInsets _kPagePadding = EdgeInsets.fromLTRB(12, 12, 12, 12);

// ---------------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------------

/// Route target for the administration screen.
///
/// Field-less on purpose so `createLocationBuilder` can register it as
/// `const AccessAdminPage()`, the same way `FirstUserPage` is. All of the
/// content lives in [AccessAdminBody].
class AccessAdminPage extends StatelessWidget {
  const AccessAdminPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const BaseScaffold(
      title: kAccessAdminTitle,
      body: AccessAdminBody(),
    );
  }
}

/// The page content, split from [AccessAdminPage] so tests and goldens can pump
/// it without [BaseScaffold]'s routing context.
///
/// [BaseScaffold] calls `context.currentBeamLocation`, so it cannot be pumped
/// without a Beamer ancestor. `FirstUserBody`, `IpSettingsBody`,
/// `ServerConfigBody` and `KeyRepositoryContent` are the same split for the
/// same reason.
class AccessAdminBody extends ConsumerWidget {
  const AccessAdminBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storeAsync = ref.watch(accessAdminStoreProvider);

    // The one state this page owns that neither section does.
    //
    // A section renders `SizedBox.shrink()` here, on purpose: it is one card
    // on a screen somebody came to for something else, and a spinner that
    // flashes for a frame on every station is what `AccessLockBadge` and
    // `AccessStatusAction` both refuse to draw. A whole *page* must not do
    // that. `access_gate.dart` says why for the waiting gate — "this route was
    // reached deliberately and an empty one reads as broken" — and
    // `first_user.dart`'s `_loading` says the same thing for a page that is
    // still resolving its database handle. Both are this page's case.
    if (!storeAsync.hasValue && !storeAsync.hasError) {
      return const Center(
        child: CircularProgressIndicator(key: kAccessAdminLoadingKey),
      );
    }

    // Deliberately **not** branched past this point. The store's error state
    // and its null state are each rendered by both sections, in their own
    // words, with their own keys. A third message at page level would be a
    // fourth thing that can contradict the other two, and the first time one
    // wording changed it would be the one nobody updated.
    //
    // Both sections are `const`: a page rebuild — and the store provider
    // resolving is one — then does not rebuild either subtree.
    const content = Padding(
      padding: _kPagePadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Nothing at all until an agent has proposed something, so the
          // measured heights below still hold on every station; with a batch
          // staged it lists what Accept will do, above the sections it will
          // do it to, and carries its own gap.
          AccessAdminProposalsSection(),
          AccessRolesSection(),
          SizedBox(height: _kSectionGap),
          AccessUsersSection(),
          SizedBox(height: _kSectionGap),
          AccessSessionSection(),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // **The scroll view is unconditional, and that is where this page
        // departs from `key_repository.dart`'s otherwise identical fallback.**
        // That page has an `Expanded` key list which absorbs a roster of any
        // size, so it can lay out directly on a tall window. Neither section
        // here is bounded or scrolled — both say so in their own class docs:
        // *"the page composing this section owns the scroll view"* — so a site
        // with thirty accounts overflows a 1080p panel without one.
        //
        // What the measured minimum then buys is the short window: below it,
        // the content is given the height it was measured at instead of the
        // window's, so the page a cabinet-door panel scrolls is the same page
        // a station shows rather than a differently wrapped one.
        final double floor = constraints.maxHeight >= kAccessAdminMinContentHeight
            ? 0
            : kAccessAdminMinContentHeight;
        return SingleChildScrollView(
          // Not the primary scroll view: a dialog opened from either section
          // brings its own, and leaving this one primary would hand it the
          // PrimaryScrollController and make the two indistinguishable to a
          // test helper.
          primary: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: floor),
            child: content,
          ),
        );
      },
    );
  }
}
