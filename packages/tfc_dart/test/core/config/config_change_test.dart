/// The history has to be able to put things back.
///
/// The first draft of this design stored payloads only, and Fable's review
/// caught what that costs: moving an asset to another page or changing its
/// paint order alters nothing *inside* the asset, so the change row would have
/// had two identical sides and a restore from it would have put the asset back
/// on the wrong page in the wrong order — silently, and only visible as a
/// mimic that looks subtly wrong weeks later. These tests are the guard on the
/// fix.
library;

import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_item.dart';

ConfigItem _asset({
  String id = 'a1',
  String parent = '/roe',
  int order = 0,
  double x = 0.1,
}) =>
    ConfigItem.of(
      kind: ConfigKind.asset,
      id: id,
      value: {'asset_name': 'LEDConfig', 'x': x},
      parentId: parent,
      sortIndex: order,
    );

ConfigChange _change({ConfigItem? before, ConfigItem? after}) =>
    ConfigChange.of(
      at: DateTime.utc(2026, 9, 6, 21),
      actionId: 'abc123',
      who: 'jon',
      station: 'svn-nes-ot-cl02',
      roleName: 'Engineer',
      before: before,
      after: after,
    );

void main() {
  group('a change carries position, not only payload', () {
    test('moving an asset to another page is a recorded difference', () {
      final change = _change(
        before: _asset(parent: '/roe'),
        after: _asset(parent: '/baader'),
      );

      expect(change.op, ConfigChangeOp.update);
      expect(change.oldValue, isNot(change.newValue),
          reason: 'the payload is identical on both sides — if the row does '
              'not record the page, the move is invisible and unrestorable');
      expect(change.oldItem!.parentId, '/roe');
      expect(change.newItem!.parentId, '/baader');
    });

    test('reordering an asset is a recorded difference', () {
      final change = _change(
        before: _asset(order: 0),
        after: _asset(order: 7),
      );

      expect(change.oldValue, isNot(change.newValue));
      expect(change.oldItem!.sortIndex, 0);
      expect(change.newItem!.sortIndex, 7);
    });

    test('undoing a move restores the page and the order it had', () {
      final before = _asset(parent: '/roe', order: 3, x: 0.1);
      final after = _asset(parent: '/baader', order: 0, x: 0.9);

      final restored = _change(before: before, after: after).oldItem!;

      expect(restored, before,
          reason: 'a restore is writing oldItem — it has to be the whole '
              'entity, or the asset comes back in the wrong place');
    });
  });

  group('the operation is derived, never asserted', () {
    test('no before is an insert, and undoing it means deleting', () {
      final change = _change(after: _asset());
      expect(change.op, ConfigChangeOp.insert);
      expect(change.oldValue, isNull);
      expect(change.oldItem, isNull);
      expect(change.inverseValue, isNull);
    });

    test('no after is a delete that still says what was lost', () {
      final change = _change(before: _asset());
      expect(change.op, ConfigChangeOp.delete);
      expect(change.newValue, isNull);
      expect(change.oldItem!.parentId, '/roe');
    });

    test('both sides is an update', () {
      expect(_change(before: _asset(), after: _asset(x: 0.5)).op,
          ConfigChangeOp.update);
    });

    test('neither side is not a change', () {
      expect(() => _change(), throwsArgumentError);
    });

    test('two different entities is a caller bug, not a change', () {
      // A row whose two sides describe different entities would be a history
      // that claims one thing turned into another. Louder than useful here.
      expect(
        () => _change(before: _asset(id: 'a1'), after: _asset(id: 'a2')),
        throwsArgumentError,
      );
    });
  });

  group('identity travels with the row', () {
    test('kind, id and scope come from the entity', () {
      final change = _change(after: _asset(id: 'deadbeef'));
      expect(change.kind, ConfigKind.asset);
      expect(change.entityId, 'deadbeef');
      expect(change.scope, ConfigScope.shared);
    });

    test('a station-scoped change keeps its scope', () {
      final local = ConfigItem.of(
        kind: ConfigKind.preference,
        id: 'startup_url',
        value: {'value': '/roe'},
        scope: ConfigScope.forStation('svn-nes-ot-cl02'),
      );

      final change = _change(after: local);

      expect(change.scope.isShared, isFalse);
      expect(change.scope.station, 'svn-nes-ot-cl02');
      expect(change.newItem!.scope, local.scope,
          reason: 'a station row restored into the shared scope would '
              'publish this machine own database endpoint to every other');
    });
  });

  group('scope wire form', () {
    test('round-trips', () {
      for (final scope in [
        ConfigScope.shared,
        ConfigScope.forStation('svn-nes-ot-cl02'),
      ]) {
        expect(ConfigScope.byWireName(scope.wireName), scope);
      }
    });

    test('a malformed scope is null, not a silent shared row', () {
      // Answering `shared` for something unparseable is how a station-local
      // secret ends up in Postgres.
      for (final bad in ['', 'station:', 'nonsense', 'Shared']) {
        expect(ConfigScope.byWireName(bad), isNull, reason: 'for "$bad"');
      }
    });
  });
}
