import 'dart:math';

/// Everything the installer cannot work out for itself.
///
/// Values travel a long way after this screen: into `station.env`, then
/// `/etc/centroid/station.conf`, then `/home/centroid/.env`, then compose
/// interpolation, then a shell inside a privileged container. Escaping
/// correctly at four layers is not worth attempting, so the charset is
/// restricted here instead — the same restriction the shell installer enforces
/// in `password_ok`, and the two must agree character for character.
///
/// This is a DENY list. It began as an allow list, which banned every symbol
/// nobody had thought about — `#` among them, which an operator reasonably
/// wants in a password and which is safe at all four layers: compose's dotenv
/// only treats `#` as a comment when whitespace precedes it, and whitespace is
/// refused below. What remains refused is the much shorter set that turns a
/// quoting slip into executed code or a silently truncated value.
const String hazardousPasswordChars = '"\'`\$\\;&|<>()';

/// Printable ASCII, which excludes space, tab, control characters and
/// everything non-ASCII — `chpasswd` and a container's shell do not agree
/// about the last of those.
final RegExp _printableAscii = RegExp(r'^[\x21-\x7E]+$');

/// Human-readable form of the rule, shown under the field. Phrased as what is
/// refused because the permitted set is now most of the keyboard.
const String passwordRule =
    'No spaces, and none of:  " \' ` \$ \\ ; & | < > ( )';

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
  if (!_printableAscii.hasMatch(v)) {
    return 'No spaces or accented characters';
  }
  for (final c in hazardousPasswordChars.split('')) {
    if (v.contains(c)) return 'Cannot contain  $c  — $passwordRule';
  }
  return null;
}

/// Centroid's obfuscator, which is what a station's `wg-obfuscator.conf` points
/// its `target` at. The WireGuard server itself is `wireguard-1.centroid.is`,
/// but a station never addresses it directly: the client obfuscator listens on
/// loopback, `wg0.conf`'s Endpoint is `127.0.0.1`, and this is the only address
/// that goes over the wire. Two hosts, one field, and it is this one.
const String defaultVpnEndpoint = 'wireguard-obf.centroid.is:13256';

/// Every VPN field is required once the operator has chosen to configure one:
/// a half-filled `wg0.conf` is worse than none, because the station comes up
/// looking configured and is unreachable.
String? validateRequired(String? value) =>
    (value ?? '').trim().isEmpty ? 'Required' : null;

/// The layouts a station's keyboards offer -- the panel, VNC and the on-screen
/// keyboard alike -- by the codes docker-compose.yml's KEYBOARD_LAYOUTS uses.
/// The installer asks which one the station STARTS in; the others stay one
/// Alt+Shift, or one globe key, away.
class KeyboardLayout {
  const KeyboardLayout(this.code, this.name);
  final String code;
  final String name;
}

const List<KeyboardLayout> keyboardLayouts = [
  KeyboardLayout('is', 'Icelandic'),
  KeyboardLayout('en', 'English'),
  KeyboardLayout('pl', 'Polish'),
];

String? validateKeyboardLayout(String? value) =>
    keyboardLayouts.any((l) => l.code == value)
        ? null
        : 'One of ${keyboardLayouts.map((l) => l.code).join(', ')}';

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
  // First in the list is the default: the image's own locale is en_US, so
  // without an explicit answer the compose fallback would start an Icelandic
  // plant's panels in English.
  String keyboardLayout = keyboardLayouts.first.code;

  // Remote access. All empty means the station installs without VPN access,
  // which firstboot reports loudly rather than silently.
  bool vpnWanted = false;

  /// Prefilled, unlike the two below it.
  ///
  /// This field is the obfuscator's `target`, not the WireGuard server's
  /// endpoint — the app always configures the obfuscator (the key is a
  /// required field), so `wg` talks to `127.0.0.1` and the only address that
  /// leaves the machine is this one. Centroid runs exactly one, and typing
  /// it on a touchscreen is a transcription error waiting to happen. It is a
  /// default, not a constant: the field stays editable for a site with its
  /// own server.
  String vpnEndpoint = defaultVpnEndpoint;
  String vpnObfuscatorKey = '';
  String vpnServerPublicKey = '';
  String vpnAddress = '';
  // No default. It was a specific RFC 1918 subnet, which reads as one site's
  // topology shipped as a product default; required and empty is honest.
  String vpnAllowedIps = '';

  /// Must agree field-for-field with the validators on the VPN step: this is
  /// what decides whether the VPN block is written to station.env, so a field
  /// the form requires but this ignores would be dropped on the floor.
  bool get vpnComplete =>
      vpnEndpoint.isNotEmpty &&
      vpnObfuscatorKey.isNotEmpty &&
      vpnServerPublicKey.isNotEmpty &&
      vpnAddress.isNotEmpty &&
      vpnAllowedIps.isNotEmpty;

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
      'KEYBOARD_DEFAULT=$keyboardLayout',
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
