import 'dart:math';

/// Everything the installer cannot work out for itself.
///
/// Values travel a long way after this screen: into `station.env`, then
/// `/etc/centroid/station.conf`, then `/home/centroid/.env`, then compose
/// interpolation, then a shell inside a privileged container. Escaping
/// correctly at four layers is not worth attempting, so the charset is
/// restricted here instead — the same restriction the shell installer enforces.
const String allowedPasswordChars = r'A-Za-z0-9._@%+:~/-';
final RegExp _passwordShape = RegExp('^[$allowedPasswordChars]+\$');

const int minPasswordLength = 8;

/// Generated rather than typed. Nine fields on a panel with an on-screen
/// keyboard covering half the screen is a lot of glass typing, and most of
/// these are never recited to anyone — the database and keyring passwords in
/// particular are read only by containers on this machine.
String generatePassword({int length = 20}) {
  // Deliberately a subset of [allowedPasswordChars]: no look-alike characters,
  // because a generated value does sometimes get read off a screen and typed
  // somewhere else.
  const alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final rng = Random.secure();
  return List.generate(length, (_) => alphabet[rng.nextInt(alphabet.length)]).join();
}

String? validatePassword(String? value) {
  final v = value ?? '';
  if (v.isEmpty) return 'Required';
  if (v.length < minPasswordLength) return 'At least $minPasswordLength characters';
  if (!_passwordShape.hasMatch(v)) {
    return 'Use letters, digits and . _ @ % + : ~ / - only';
  }
  return null;
}

String? validateStationName(String? value) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return 'Required';
  // It becomes the hostname and a TLS certificate CN, so it has to be a valid
  // DNS label, not just any string the operator likes.
  if (!RegExp(r'^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$').hasMatch(v)) {
    return 'Letters, digits and hyphens; must not start or end with a hyphen';
  }
  return null;
}

/// A disk the image could be written to. Never includes the USB the installer
/// booted from — that exclusion happens before this list is built.
class TargetDisk {
  const TargetDisk({required this.name, required this.size, required this.model});

  /// Kernel name without /dev, e.g. `nvme0n1`.
  final String name;
  final String size;
  final String model;

  String get devicePath => '/dev/$name';

  @override
  String toString() => '$devicePath  $size  $model';
}

class Answers {
  String? targetDisk;
  String stationName = '';
  String centroidPassword = '';
  String rootPassword = '';
  String vncPassword = '';
  String dbPassword = '';

  // Remote access. All empty means the station installs without VPN access,
  // which firstboot reports loudly rather than silently.
  bool vpnWanted = false;
  String vpnEndpoint = '';
  String vpnObfuscatorKey = '';
  String vpnServerPublicKey = '';
  String vpnAddress = '';
  String vpnAllowedIps = '10.13.1.0/24';

  bool get vpnComplete =>
      vpnEndpoint.isNotEmpty &&
      vpnObfuscatorKey.isNotEmpty &&
      vpnServerPublicKey.isNotEmpty &&
      vpnAddress.isNotEmpty;

  /// The seed file the shell installer reads. Deliberately the same key=value
  /// format it already parses (never sources), so the graphical and text paths
  /// share one interface and one set of validation rules.
  String toStationEnv() {
    final lines = <String>[
      '# Written by the CentroidX setup app. Parsed as key=value, never sourced.',
      'STATION_NAME=$stationName',
      'CENTROID_PASSWORD=$centroidPassword',
      'ROOT_PASSWORD=$rootPassword',
      'VNC_PASSWORD=$vncPassword',
      'DB_PASSWORD=$dbPassword',
    ];
    if (vpnWanted && vpnComplete) {
      lines.addAll([
        'VPN_ENDPOINT=$vpnEndpoint',
        'VPN_OBFUSCATOR_KEY=$vpnObfuscatorKey',
        'VPN_SERVER_PUBKEY=$vpnServerPublicKey',
        'VPN_ADDRESS=$vpnAddress',
        'VPN_ALLOWED_IPS=$vpnAllowedIps',
      ]);
    }
    return '${lines.join('\n')}\n';
  }
}
