@TestOn('vm')

/// The audit trail's `station` column for a person's session is where the
/// gateway saw the socket come from — never a label the client typed.
///
/// `SessionLoginParams.station` used to be copied into every row the session
/// left. A laptop on the plant LAN could sign in claiming to be
/// `ST101-PANEL-07` and have its writes attributed to that panel's station.
/// Found where it would be seen: `test/e2e_pages/pages/audit_trail.dart`.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/relay_session.dart';

SessionLoginParams _login({String? station}) => SessionLoginParams(
    username: 'jon', password: 'not-checked-here', station: station);

void main() {
  const peer = '10.50.10.11';
  const claimed = 'ST101-PANEL-07';

  test('the socket address leads, and the claim rides behind it, marked',
      () {
    expect(RelaySession.stationColumnFor(_login(station: claimed), peer: peer),
        '$peer (says $claimed)');
  });

  test('no claim: the address alone', () {
    expect(RelaySession.stationColumnFor(_login(), peer: peer), peer);
    expect(RelaySession.stationColumnFor(_login(station: '   '), peer: peer),
        peer,
        reason: 'whitespace is no claim');
  });

  test('a session over no socket is unlabelled, and still marks the claim',
      () {
    expect(RelaySession.stationColumnFor(_login(station: claimed), peer: null),
        '${RelaySession.unlabelledStation} (says $claimed)');
    expect(RelaySession.stationColumnFor(_login(), peer: null),
        RelaySession.unlabelledStation);
  });

  test('the column is never the bare claim, whatever the client sends', () {
    for (final claim in [claimed, peer, RelaySession.unlabelledStation, 'x']) {
      for (final socket in [peer, null]) {
        expect(
            RelaySession.stationColumnFor(_login(station: claim),
                peer: socket),
            isNot(claim),
            reason: 'claim "$claim" over ${socket ?? 'no socket'}');
      }
    }
  });

  test('a pasted megabyte is capped at the close-reason clamp, address '
      'intact', () {
    final column = RelaySession.stationColumnFor(
        _login(station: 'A' * (1 << 20)),
        peer: peer);
    expect(column.length, 63);
    expect(column, startsWith('$peer (says '));
  });
}
