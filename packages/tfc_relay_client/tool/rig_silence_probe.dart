// Does a subscribed key that the plant never publishes eventually SAY so, or
// does it stay silent?
//
// The milestone's core value is that a screen never lies. A key whose PLC node
// exists, whose subscription the gateway created successfully, but which has
// never carried a value, is the edge worth knowing about: if the client is
// told "uncertain / not yet known" the pane can render `---` and the operator
// knows the system has nothing. If nothing is ever emitted, the pane renders
// its empty state for the same reason — which looks identical to a pane that
// was never wired up.
//
// This prints what actually happens over 75 seconds, which is past both the
// client's freshness deadline (~3 s) and the server's sweep (~10 s).
import 'dart:async';
import 'dart:io';

import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart' show LinkState;
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

Future<void> main(List<String> args) async {
  final url = args[0];
  final ca = args[1];
  final token = args[2];
  final keys = args.sublist(3).toSet();

  final man = RemoteStateMan(
    uri: Uri.parse(url),
    config: ClientConfig(
      token: token,
      tls: ClientTlsConfig(rootCertPath: ca),
    ),
    keys: keys,
    client: const PeerInfo('rig-silence-probe', '0.1.0'),
  );
  await man.linkStates
      .firstWhere((s) => s == LinkState.ready)
      .timeout(const Duration(seconds: 30));

  final counts = <String, int>{for (final k in keys) k: 0};
  final last = <String, String>{};
  final subs = <StreamSubscription<dynamic>>[];
  final started = DateTime.now();

  for (final k in keys) {
    subs.add(man.subscribe(k).listen((v) {
      counts[k] = counts[k]! + 1;
      final at = DateTime.now().difference(started).inSeconds;
      last[k] = '+${at}s value=${v.value} quality=${v.quality}';
      if (counts[k]! <= 3 || counts[k]! % 25 == 0) {
        print('  $k  #${counts[k]}  ${last[k]}');
      }
    }, onError: (Object e) {
      print('  $k  ERROR $e');
    }));
  }

  print('watching ${keys.length} keys for 75 s...\n');
  await Future<void>.delayed(const Duration(seconds: 75));

  print('\n== after 75 s ==');
  for (final k in keys) {
    final n = counts[k]!;
    print('  $k: $n reading(s)'
        '${n == 0 ? "  <-- SILENT: nothing was ever said about this key" : "  last: ${last[k]}"}');
  }

  for (final s in subs) {
    await s.cancel();
  }
  await man.dispose();
  exit(0);
}
