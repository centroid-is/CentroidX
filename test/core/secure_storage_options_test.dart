/// What the desktop keychain is actually asked for.
///
/// flutter_secure_storage 10 renamed the macOS data-protection switch and
/// flipped its default to `true`. Left to that default, every Mac build we
/// ship — ad-hoc signed, unprovisioned — would move to the data-protection
/// keychain and fail every call with errSecMissingEntitlement (-34018). And a
/// changed `accountName` would orphan every secret the old plugin wrote,
/// because it is the keychain *service* items are found by.
///
/// Asserted on the map the plugin sends to the platform, not on the Dart
/// field, because the map is what the keychain sees.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/secure_storage/other.dart';

void main() {
  final sent = OtherSecureStorage.macOsOptions.toMap();

  test('macOS stays on the file-based login keychain', () {
    expect(sent['usesDataProtectionKeychain'], 'false',
        reason: 'true (the 10.x default) needs provisioned code signing; '
            'our Mac builds are ad-hoc signed and every keychain call would '
            'fail with -34018');
  });

  test('items are still found under the service 9.x wrote them to', () {
    expect(sent['accountName'], 'CentroidX',
        reason: 'accountName is the keychain service; changing it strands '
            'every secret already on a machine');
  });
}
