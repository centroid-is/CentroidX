// Throwaway probe: pinned open62541 binding vs an asyncua server.
// Run: dart run test/support/bench_probe.dart <endpoint> <ns>
import 'dart:async';
import 'package:open62541/open62541.dart' as ua;

Future<void> main(List<String> args) async {
  final endpoint = args[0];
  final ns = int.parse(args.length > 1 ? args[1] : '2');
  final client = ua.Client(logLevel: ua.LogLevel.UA_LOGLEVEL_INFO);
  final driver = Timer.periodic(const Duration(milliseconds: 10),
      (_) => client.runIterate(const Duration(milliseconds: 10)));
  print('connecting to $endpoint ...');
  await client.connect(endpoint).timeout(const Duration(seconds: 15));
  print('connected');

  Future<void> probe(String label, Future<Object?> Function() f) async {
    try {
      final v = await f().timeout(const Duration(seconds: 5));
      print('OK   $label -> ${v.toString().substring(0, v.toString().length > 120 ? 120 : v.toString().length)}');
    } catch (e) {
      print('FAIL $label -> $e');
    }
  }

  await probe('read i=2257 StartTime',
      () => client.read(ua.NodeId.fromNumeric(0, 2257)));
  await probe('read i=2255 NamespaceArray',
      () => client.read(ua.NodeId.fromNumeric(0, 2255)));
  for (final node in [
    'Counter', 'Bool', 'Int16', 'Int64', 'UInt32', 'Float', 'Double',
    'DoubleHazard', 'StringUtf8', 'StringLatin1', 'DateTimeNode', 'GuidNode',
    'ByteStringNode', 'LocalizedTextNode', 'EnumNode', 'AbstractNode',
    'ArrayDouble', 'ArrayString', 'ArrayEmpty', 'StructRange', 'StructCustom',
    'Dead', 'Constant', 'Fast',
  ]) {
    await probe('read $node',
        () => client.read(ua.NodeId.fromString(ns, 'ua00.$node')));
  }
  driver.cancel();
  client.disconnect();
  client.delete();
  print('PROBE DONE');
}
