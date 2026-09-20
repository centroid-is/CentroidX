/// A port the kernel is not using right now.
///
/// `packages/tfc_relay_local/test/support/free_port.dart`, copied rather than
/// imported: that file lives under another package's `test/`, which no
/// `package:` URI reaches, and the root package's `flutter test` cannot see
/// it. Kept identical on purpose so a fix there is a fix here by diff.
///
/// The gap between `close()` and whoever binds next is real and is why the
/// Compose stack in [postgres_fixture.dart] is the only thing that asks for
/// one: every socket this lane binds itself is bound at port 0 and asked
/// afterwards, which has no gap at all.
library;

import 'dart:io';

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final assigned = socket.port;
  await socket.close();
  return assigned;
}
