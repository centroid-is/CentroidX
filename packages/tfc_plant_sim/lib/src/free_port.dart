/// A port the kernel says is free.
///
/// Bound and released, so what comes back is a port nothing held a moment
/// ago rather than a number somebody hoped was free. The gap between the
/// release and the server's bind is a race in principle; in practice it is
/// microseconds on a loopback interface, and the alternative — a fixed port —
/// fails every time two benches or two test files run at once.
library;

import 'dart:io';

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
