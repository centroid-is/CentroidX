import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

void main() {
  const runMode = TypeDescriptor(
    ua: 'ns=4;i=3001',
    enumFields: {
      0: EnumField(value: 0, name: 'stopped'),
      2: EnumField(
          value: 2, name: 'auto', displayName: LocalizedText('Auto', locale: 'en')),
    },
  );
  const fd = TypeDescriptor(
    ua: 'ns=4;i=3012',
    displayName: LocalizedText('Frequency drive'),
    members: {
      'p_stat_RunMode': runMode,
      'p_stat_Speed': TypeDescriptor(ua: 'ns=0;i=11'),
    },
  );

  test('round-trips through JSON, members and enum tables included', () {
    final back = TypeDescriptor.fromJson(fd.toJson());
    expect(back.ua, 'ns=4;i=3012');
    expect(back.displayName?.value, 'Frequency drive');
    final mode = back.members['p_stat_RunMode']!;
    expect(mode.enumFields![2]!.name, 'auto',
        reason: 'this is the name readDriveState switches on');
    expect(mode.enumFields![2]!.displayName?.locale, 'en');
    expect(back.members['p_stat_Speed']!.enumFields, isNull);
  });

  test('hasEnum finds a table anywhere in the tree, and only then is a type '
      'worth describing', () {
    expect(fd.hasEnum, isTrue);
    expect(const TypeDescriptor(ua: 'ns=0;i=11').hasEnum, isFalse);
    expect(const TypeDescriptor(element: runMode).hasEnum, isTrue);
  });

  test('decoding is forgiving: not a map, a bad enum entry, a bad member', () {
    expect(TypeDescriptor.fromJson(null).members, isEmpty);
    expect(TypeDescriptor.fromJson('x').ua, isNull);
    final back = TypeDescriptor.fromJson({
      'ua': 'ns=4;i=3001',
      'enum': {'2': {'value': 2, 'name': 'auto'}, 'x': 'not a field', '3': 7},
      'members': {'ok': {'ua': 'ns=0;i=1'}, 'odd': 42},
      'later': 'a field a newer gateway added',
    });
    expect(back.enumFields, {2: const EnumField(value: 2, name: 'auto')},
        reason: 'one bad entry costs one name, not the table');
    expect(back.members.keys, containsAll(['ok', 'odd']),
        reason: 'a malformed member decodes empty rather than dropping the '
            'type');
  });

  test('SubscribeResult carries the dictionary once, and omits it when empty',
      () {
    final withTypes = SubscribeResult(
      sub: 's', epoch: 'e', seq: 0, handles: const {'k': 1},
      snapshot: const {}, types: {'ns=4;i=3012': fd.toJson()},
    ).toJson();
    expect(withTypes['types'], isA<Map>());
    expect(SubscribeResult.fromJson(withTypes).types.keys, ['ns=4;i=3012']);
    final without = const SubscribeResult(
        sub: 's', epoch: 'e', seq: 0, handles: {}, snapshot: {}).toJson();
    expect(without.containsKey('types'), isFalse,
        reason: 'a gateway with nothing to say adds no field');
  });
}
