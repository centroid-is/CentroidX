// A hand-driven end-to-end probe against a REAL gateway over a REAL wss://
// socket. Not a test: a tool, run by a human against a rig, printing what it
// observed so a person can judge it.
//
// It exists because every automated leg speaks to a gateway the test process
// built. This one speaks to a gateway somebody deployed, on hardware, with a
// token file on a disk and accounts in a database — the arrangement the plant
// actually runs, and the one where a mis-provisioned account or a wire
// disagreement shows up.
//
// Usage:
//   dart run tool/rig_e2e_probe.dart <wss-url> <ca.pem> <eng-token> <view-token>
//
// It never commands the plant. The only refusals it provokes are reads.
import 'dart:async';
import 'dart:io';

import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart' show LinkState;
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// Plant keys this probe is allowed to touch. Temperatures and a scratch
/// register — no command keys, and emphatically nothing under `Door.`.
const Set<String> kSafeProbeKeys = <String>{
  'ElectricalRoom.temp.avg',
  'cooler.temp.avg',
  'cooler.temp.1',
  'data.real.1',
};

int _passed = 0;
int _failed = 0;

void _check(String what, bool ok, String evidence) {
  if (ok) {
    _passed++;
    print('  PASS  $what\n        $evidence');
  } else {
    _failed++;
    print('  FAIL  $what\n        $evidence');
  }
}

Future<RemoteStateMan> _connect(
  String url,
  String caPath,
  String token,
  String label,
) async {
  final man = RemoteStateMan(
    uri: Uri.parse(url),
    config: ClientConfig(
      token: token,
      tls: ClientTlsConfig(rootCertPath: caPath),
    ),
    // Read-only instrument keys, chosen deliberately: `Door.*` is mapped on
    // this rig and the owner's standing rule is that the door is never
    // operated from here. Nothing in this probe writes, but the key set is
    // kept clear of it anyway so a stray subscribe cannot even be misread.
    keys: kSafeProbeKeys,
    client: PeerInfo('rig-probe-$label', '0.1.0'),
  );
  // Up means the hello was answered, not merely that a socket opened.
  await man.linkStates
      .firstWhere((s) => s == LinkState.ready)
      .timeout(const Duration(seconds: 30));
  return man;
}

Future<void> main(List<String> args) async {
  if (args.length < 4) {
    stderr.writeln(
        'usage: rig_e2e_probe <wss-url> <ca.pem> <eng-token> <view-token>');
    exit(64);
  }
  final url = args[0];
  final ca = args[1];
  final engToken = args[2];
  final viewToken = args[3];

  print('== rig probe against $url ==\n');

  // ---------------------------------------------------------------- 1. hello
  print('1. an authorised station completes a hello over TLS');
  late RemoteStateMan eng;
  try {
    eng = await _connect(url, ca, engToken, 'eng');
    _check('hello accepted, link reaches ready', true,
        'the Engineering station holds a live session');
  } catch (e) {
    _check('hello accepted, link reaches ready', false, '$e');
    exit(1);
  }

  // ------------------------------------------------------------- 2. browsing
  print('\n2. the plant address space is visible through the socket');
  List<BrowseNode> roots = const [];
  try {
    roots = await eng.browse.fetchRoots().timeout(const Duration(seconds: 25));
    _check('browse returns roots from the real PLCs', roots.isNotEmpty,
        '${roots.length} roots: ${roots.take(4).map((r) => r.displayName).join(", ")}');
  } catch (e) {
    _check('browse returns roots from the real PLCs', false, '$e');
  }

  // ----------------------------------------------------------- 3. live value
  //
  // Grades are the point, not arrival. A reading that turns up carrying
  // `badStale` is the freshness system telling the truth about a key nothing
  // is publishing — the panel renders `---` for it — and counting that as a
  // live value would be exactly the "silence is not success" mistake.
  print('\n3. live plant values arrive, and their GRADES are honest');
  final grades = <String, Quality>{};
  for (final key in kSafeProbeKeys) {
    try {
      final first =
          await eng.subscribe(key).first.timeout(const Duration(seconds: 20));
      grades[key] = first.quality;
      print('        $key => value=${first.value} quality=${first.quality} '
          '(${first.quality == Quality.good ? "GOOD" : "not good"})');
    } catch (e) {
      print('        $key => no reading within 20s: $e');
    }
  }
  final good = grades.entries.where((e) => e.value == Quality.good).toList();
  final stale = grades.entries.where((e) => e.value != Quality.good).toList();
  _check('at least one real plant key is delivering GOOD data', good.isNotEmpty,
      '${good.length} good, ${stale.length} not good '
      '(${stale.map((e) => "${e.key}=${e.value}").join(", ")})');
  _check('every key reported SOME grade — none silently absent',
      grades.length == kSafeProbeKeys.length,
      '${grades.length} of ${kSafeProbeKeys.length} keys answered');

  // ------------------------------------------------ 4. access, both polarities
  print('\n4. access control is enforced by the SERVER, both polarities');
  RemoteStateMan? view;
  try {
    view = await _connect(url, ca, viewToken, 'view');
    _check('the Operator station also completes a hello', true,
        'both stations hold live sessions — so a refusal below is a verdict, '
        'not a failure to connect');
  } catch (e) {
    _check('the Operator station also completes a hello', false, '$e');
  }

  // The permitted half. Without it a refusal proves nothing.
  try {
    final users =
        await eng.accessAdmin.listUsers().timeout(const Duration(seconds: 25));
    _check('LIVE CONTROL: the Engineering station MAY list accounts',
        users.isNotEmpty, '${users.length} accounts');
  } catch (e) {
    _check(
        'LIVE CONTROL: the Engineering station MAY list accounts', false, '$e');
  }

  // The refused half: the same call, a weaker account. `listUsers` is the
  // member the owner ruling gated; `roles()` is deliberately an OPEN read
  // (a role's name and group set is what the templates screen renders before
  // anyone signs in), so it is reported below rather than asserted as a
  // refusal.
  if (view != null) {
    try {
      final users = await view.accessAdmin
          .listUsers()
          .timeout(const Duration(seconds: 25));
      _check('the Operator station is REFUSED the account list', false,
          'it was ANSWERED instead: ${users.length} accounts');
    } catch (e) {
      _check('the Operator station is REFUSED the account list', true,
          'refused by the server: ${e.runtimeType}');
    }
    try {
      final roles =
          await view.accessAdmin.roles().timeout(const Duration(seconds: 25));
      print('  NOTE  roles() is an open read by design — the Operator station '
          'sees ${roles.length} role names. Deliberate '
          '(policy_state_man.dart), flagged here so it stays a decision.');
    } catch (_) {}
  }

  // ------------------------------------------- 5. backend config over the wire
  print("\n5. the backend's own config is readable over the socket");
  try {
    final doc =
        await eng.backendConfig.read().timeout(const Duration(seconds: 25));
    final text = doc.configJson;
    _check('config read answers the real document', text.contains('opcua'),
        'configJson length ${text.length}, read-only sections '
        '${doc.readOnlySections}');
    // 17-10: a secret must never come back down the wire.
    final leaked = text.contains('Centroid.221#');
    _check('NO plaintext OPC UA password on the wire', !leaked,
        leaked ? 'LEAK — the password appeared in the payload' : 'redacted');
  } catch (e) {
    _check('config read answers the real document', false, '$e');
  }

  if (view != null) {
    try {
      await view.backendConfig.read().timeout(const Duration(seconds: 25));
      _check('the Operator station is REFUSED the backend config', false,
          'it was ANSWERED instead');
    } catch (e) {
      _check('the Operator station is REFUSED the backend config', true,
          'refused by the server: ${e.runtimeType}');
    }
  }

  // ------------------------------------------------------------ 6. audit trail
  print('\n6. the decisions above reached the audit trail');
  try {
    final entries = await eng.audit
        .entries(const AuditQueryParams(limit: 40))
        .timeout(const Duration(seconds: 25));
    _check('audit entries are readable over the socket', entries.isNotEmpty,
        '${entries.length} entries returned');
    final who = await eng.audit.distinctWho();
    _check('the audit trail names the station accounts',
        who.any((w) => w.contains('rig-panel')),
        'who values: ${who.take(8).join(", ")}');
  } catch (e) {
    _check('audit entries are readable over the socket', false, '$e');
  }

  print('\n== $_passed passed, $_failed failed ==');
  await eng.dispose();
  await view?.dispose();
  exit(_failed == 0 ? 0 : 1);
}
