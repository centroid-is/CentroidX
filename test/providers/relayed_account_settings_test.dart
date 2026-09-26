/// The two per-account settings a gateway panel acts on by itself — the home
/// page and alarm auto-navigation — read from the gateway's roster.
///
/// The wire has no self-read: `accessAdmin.listUsers` is the only method that
/// carries either setting, and the gateway grades it `users`. So a session
/// holding `users` is answered from its own roster row, and one without it is
/// never sent the call (a refused call would write a deny row and raise the
/// denial prompt) and answers as "could not be read".
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/access_authority.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_admin.dart';
import 'package:tfc/providers/alarm_auto_navigation.dart';
import 'package:tfc/providers/home_page.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_admin_store.dart';

/// Answers [listUsers] from a fixed roster and counts the calls; every other
/// member is unreachable in these tests.
final class _RosterStore implements AccessAdminStore {
  _RosterStore(this.users);

  final List<UserSummary> users;
  int listCalls = 0;
  Object? failWith;

  @override
  Future<List<UserSummary>> listUsers() async {
    listCalls++;
    final failure = failWith;
    if (failure != null) throw failure;
    return users;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not part of '
          'this test');
}

AccessSession _signedIn(String username, Set<AccessGroup> groups) =>
    AccessSession(
      user: AuthenticatedUser(username: username, roleName: 'Engineering'),
      groups: groups,
      expiresAt: DateTime.utc(2030),
    );

final _roster = [
  const UserSummary(
      username: 'gudrun',
      roleName: 'Engineering',
      homePage: '/fillet',
      alarmAutoNavigate: true),
  const UserSummary(username: 'jon', roleName: 'Engineering'),
];

ProviderContainer _relayContainer(_RosterStore store) {
  final container = ProviderContainer(overrides: [
    accessAuthorityProvider.overrideWith((ref) async => AccessAuthority.relay),
    accessAdminStoreProvider.overrideWith((ref) async => store),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('a session holding users is answered from its roster row', () {
    test('the home page', () async {
      final store = _RosterStore(_roster);
      final lookup = _relayContainer(store).read(homePageLookupProvider);

      expect(
          await lookup(_signedIn(
              'gudrun', const {AccessGroup.operate, AccessGroup.users})),
          (known: true, page: '/fillet'));
      expect(
          await lookup(
              _signedIn('jon', const {AccessGroup.operate, AccessGroup.users})),
          (known: true, page: null),
          reason: 'no home page set is Home, and it is known');
    });

    test('alarm auto-navigation', () async {
      final store = _RosterStore(_roster);
      final lookup =
          _relayContainer(store).read(alarmAutoNavigateLookupProvider);

      expect(
          await lookup(_signedIn(
              'gudrun', const {AccessGroup.operate, AccessGroup.users})),
          isTrue);
      expect(
          await lookup(
              _signedIn('jon', const {AccessGroup.operate, AccessGroup.users})),
          isFalse);
      expect(
          await lookup(_signedIn(
              'not-on-the-roster', const {AccessGroup.users})),
          isFalse);
    });
  });

  group('a session without users is not sent the call', () {
    test('the home page is known and Home; alarm navigation is off', () async {
      final store = _RosterStore(_roster);
      final container = _relayContainer(store);
      final operator = _signedIn('gudrun', const {AccessGroup.operate});

      expect(await container.read(homePageLookupProvider)(operator),
          (known: true, page: null));
      expect(await container.read(alarmAutoNavigateLookupProvider)(operator),
          isFalse);
      expect(store.listCalls, 0,
          reason: 'the gateway grades listUsers users; asking anyway would '
              'write a deny row on every sign-in and every raising alarm');
    });
  });

  test('a roster that cannot be read answers no, and the home page as not '
      'known', () async {
    final store = _RosterStore(_roster)..failWith = StateError('link lost');
    final container = _relayContainer(store);
    final admin =
        _signedIn('gudrun', const {AccessGroup.operate, AccessGroup.users});

    expect(await container.read(alarmAutoNavigateLookupProvider)(admin),
        isFalse);
    expect(await container.read(homePageLookupProvider)(admin),
        (known: false, page: null));
  });
}
