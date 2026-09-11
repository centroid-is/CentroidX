/// Which parameter the ATV320 pane is about to write.
///
/// The pane sends the **whole** parameter struct back, so the member a
/// template's rules are written against is not visible at the write. It is
/// visible at the edit, and [atv320ChangedMember] is what reads it there.
///
/// This matters more than its size: a member name that does not match the
/// struct's key silently means "unrestricted". There is no dropdown in front
/// of this one and no exception if it is wrong — the write simply goes through
/// asking the wrong question. So the answer is pinned here, including both
/// ways it can decline to answer.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/schneider.dart';

/// A parameter struct in the shape `DynamicValueWidget` renders and hands
/// back: an object of named scalars.
DynamicValue _params(Map<String, Object?> members) {
  final v = DynamicValue();
  members.forEach((key, value) => v[key] = value);
  return v;
}

void main() {
  test('names the one parameter that changed', () {
    final before = _params({'ACC': 5.0, 'DEC': 5.0, 'HSP': 50.0});
    final after = _params({'ACC': 5.0, 'DEC': 5.0, 'HSP': 45.0});

    expect(atv320ChangedMember(before, after), 'HSP');
  });

  test('the answer is the struct key, not the label beside it', () {
    // The pane shows `Acceleration (ACC)`; the template's rule is written
    // against `ACC`, which is what the struct is indexed with.
    final before = _params({'ACC': 5.0});
    final after = _params({'ACC': 9.0});

    expect(atv320ChangedMember(before, after), 'ACC');
  });

  test('a structurally identical value is not a change', () {
    // `DynamicValue` defines no `==`, so a comparison by identity would report
    // every member as changed and this would answer null on every edit.
    final before = _params({'ACC': 5.0, 'DEC': 5.0});
    final after = _params({'ACC': 5.0, 'DEC': 5.0});

    expect(atv320ChangedMember(before, after), isNull);
  });

  test('two changed members answer null, which asks about the whole key', () {
    final before = _params({'ACC': 5.0, 'DEC': 5.0});
    final after = _params({'ACC': 9.0, 'DEC': 9.0});

    expect(atv320ChangedMember(before, after), isNull);
  });

  test('a member the rendered value never had answers null', () {
    // A struct that grew between the render and the submit is not something
    // this can name a single member for, and guessing would be worse than the
    // key-level question.
    final before = _params({'ACC': 5.0});
    final after = _params({'ACC': 5.0, 'DEC': 9.0});

    expect(atv320ChangedMember(before, after), isNull);
  });

  test('a nested edit answers with the top-level member containing it', () {
    // `DynamicValueWidget` bubbles a child edit up as the parent struct with
    // one member replaced, and the top level is what a template names.
    final before = DynamicValue()..['MOTOR'] = _params({'NPR': 4.0});
    final after = DynamicValue()..['MOTOR'] = _params({'NPR': 5.5});

    expect(atv320ChangedMember(before, after), 'MOTOR');
  });

  test('a scalar on either side answers null', () {
    expect(
      atv320ChangedMember(DynamicValue(value: 1.0), _params({'ACC': 5.0})),
      isNull,
    );
    expect(
      atv320ChangedMember(_params({'ACC': 5.0}), DynamicValue(value: 1.0)),
      isNull,
    );
  });
}
