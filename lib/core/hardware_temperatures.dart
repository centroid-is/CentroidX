/// The host's temperature sensors, read straight out of sysfs.
///
/// No mount is needed for this. Docker gives every container a read-only
/// `/sys`, and hwmon is not namespaced, so the HMI container already sees the
/// host's `coretemp`, `acpitz`, `nvme` and friends at the same paths the host
/// does. Off Linux (a developer's Windows or macOS build) the directories do
/// not exist and every reader here returns an empty list, which the page
/// answers by not drawing the section at all.
library;

import 'dart:io';

/// One temperature, already in °C.
class TemperatureReading {
  /// What an operator would call it: `CPU package`, `NVMe`, `Board (ACPI)`.
  final String label;

  final double celsius;

  /// The lowest [celsius] in a collapsed group — the CPU cores row shows a
  /// range rather than a dozen rows. Null for a single sensor.
  final double? minCelsius;

  /// How many sensors this row stands for. 1 unless collapsed.
  final int count;

  /// The driver's `tempN_max` — where it starts throttling on most chips.
  final double? high;

  /// The driver's `tempN_crit` — where the hardware shuts itself off.
  final double? critical;

  const TemperatureReading({
    required this.label,
    required this.celsius,
    this.minCelsius,
    this.count = 1,
    this.high,
    this.critical,
  });

  @override
  bool operator ==(Object other) =>
      other is TemperatureReading &&
      other.label == label &&
      other.celsius == celsius &&
      other.minCelsius == minCelsius &&
      other.count == count &&
      other.high == high &&
      other.critical == critical;

  @override
  int get hashCode =>
      Object.hash(label, celsius, minCelsius, count, high, critical);

  @override
  String toString() => 'TemperatureReading($label, $celsius'
      '${minCelsius == null ? '' : ' min $minCelsius'} x$count'
      ' high $high crit $critical)';
}

/// How hot a reading is against its own driver's limits.
enum TemperatureLevel { normal, high, critical }

/// A reading within this many degrees of its critical limit counts as
/// [TemperatureLevel.high] even when the driver publishes no `max` — a lot of
/// them (acpitz, nvme on some firmware) publish only `crit`.
const double temperatureCriticalMargin = 10;

TemperatureLevel temperatureLevel(TemperatureReading r) {
  final crit = r.critical;
  if (crit != null && r.celsius >= crit) return TemperatureLevel.critical;
  final high = r.high;
  // A driver's max equal to its crit (coretemp does this) is not a separate
  // warning threshold; the margin below crit is the useful one then.
  if (high != null && (crit == null || high < crit) && r.celsius >= high) {
    return TemperatureLevel.high;
  }
  if (crit != null && r.celsius >= crit - temperatureCriticalMargin) {
    return TemperatureLevel.high;
  }
  return TemperatureLevel.normal;
}

/// One `tempN_*` group as found on disk, before any presentation decisions.
class RawHwmonSensor {
  /// The hwmon device's `name` file: `coretemp`, `acpitz`, `nvme`.
  final String chip;

  /// The sensor's `tempN_label`, or null when the driver gives none.
  final String? label;
  final double celsius;
  final double? high;
  final double? critical;

  const RawHwmonSensor({
    required this.chip,
    required this.label,
    required this.celsius,
    this.high,
    this.critical,
  });
}

/// Reads every `temp*_input` under [root] (`/sys/class/hwmon`), falling back
/// to [thermalRoot] (`/sys/class/thermal`) on a board that only exposes
/// thermal zones. Never throws: a sensor that cannot be read is skipped, and
/// a missing tree is an empty list.
Future<List<TemperatureReading>> readHostTemperatures({
  String root = '/sys/class/hwmon',
  String thermalRoot = '/sys/class/thermal',
}) async {
  final raw = await readHwmonSensors(root);
  if (raw.isNotEmpty) return summarizeHwmon(raw);
  return readThermalZones(thermalRoot);
}

Future<List<RawHwmonSensor>> readHwmonSensors(String root) async {
  final dir = Directory(root);
  final sensors = <RawHwmonSensor>[];
  try {
    if (!await dir.exists()) return sensors;
    final devices = await dir.list(followLinks: false).toList()
      ..sort((a, b) => _naturalCompare(a.path, b.path));
    for (final device in devices) {
      final base = device.path;
      final chip = (await _readString('$base/name')) ?? _basename(base);
      final inputs = <String>[];
      try {
        await for (final f in Directory(base).list(followLinks: true)) {
          final name = _basename(f.path);
          if (name.startsWith('temp') && name.endsWith('_input')) {
            inputs.add(name);
          }
        }
      } catch (_) {
        continue;
      }
      inputs.sort(_naturalCompare);
      for (final input in inputs) {
        final prefix = '$base/${input.substring(0, input.length - 6)}';
        final value = await _readMilli('${prefix}_input');
        if (value == null) continue;
        sensors.add(RawHwmonSensor(
          chip: chip,
          label: await _readString('${prefix}_label'),
          celsius: value,
          high: await _readMilli('${prefix}_max'),
          critical: await _readMilli('${prefix}_crit'),
        ));
      }
    }
  } catch (_) {
    // A tree that vanished mid-walk: report what was read.
  }
  return sensors;
}

/// Turns raw sensors into rows an operator can read.
///
/// The one real decision is `coretemp`: it publishes a sensor per physical
/// core, which on a 16-thread panel PC is a dozen rows saying 45 °C. Those
/// collapse into one `CPU cores` row carrying the hottest core and the range,
/// under the package row that is the number anyone actually watches.
List<TemperatureReading> summarizeHwmon(List<RawHwmonSensor> sensors) {
  final rows = <TemperatureReading>[];
  final byChip = <String, List<RawHwmonSensor>>{};
  for (final s in sensors) {
    byChip.putIfAbsent(s.chip, () => []).add(s);
  }

  for (final MapEntry(key: chip, value: group) in byChip.entries) {
    final cores = group
        .where((s) => s.label != null && s.label!.startsWith('Core '))
        .toList();
    final packages = group
        .where((s) => s.label != null && s.label!.startsWith('Package id '))
        .toList();

    for (final p in packages) {
      rows.add(TemperatureReading(
        label: packages.length == 1
            ? 'CPU package'
            : 'CPU package ${p.label!.substring('Package id '.length)}',
        celsius: p.celsius,
        high: p.high,
        critical: p.critical,
      ));
    }
    if (cores.isNotEmpty) {
      final hottest = cores.reduce((a, b) => b.celsius > a.celsius ? b : a);
      final coolest = cores.map((c) => c.celsius).reduce((a, b) => a < b ? a : b);
      rows.add(TemperatureReading(
        label: 'CPU cores',
        celsius: hottest.celsius,
        minCelsius: cores.length > 1 ? coolest : null,
        count: cores.length,
        high: hottest.high,
        critical: hottest.critical,
      ));
    }

    final rest =
        group.where((s) => !cores.contains(s) && !packages.contains(s)).toList();
    for (final s in rest) {
      final name = _chipName(chip);
      final label = s.label?.trim();
      rows.add(TemperatureReading(
        // A lone unlabelled sensor is named after its chip; a labelled one
        // keeps its driver's label, prefixed when that label alone would not
        // say which device it is.
        // NVMe's "Composite" is the drive's own summary sensor — the drive
        // temperature, so it is just "NVMe".
        label: label == null || label.isEmpty || label == 'Composite'
            ? (rest.length == 1 ? name : '$name ${rest.indexOf(s) + 1}')
            : (_selfDescribing(chip) ? label : '$name $label'),
        celsius: s.celsius,
        high: s.high,
        critical: s.critical,
      ));
    }
  }
  return rows;
}

/// Thermal zones, for a board with no hwmon temperatures. Zones carry a type
/// and a temperature and nothing else; their trip points are not a stable
/// "critical" (a passive trip is where the fan starts), so none are reported.
Future<List<TemperatureReading>> readThermalZones(String root) async {
  final rows = <TemperatureReading>[];
  try {
    final dir = Directory(root);
    if (!await dir.exists()) return rows;
    final zones = (await dir.list(followLinks: false).toList())
        .where((e) => _basename(e.path).startsWith('thermal_zone'))
        .toList()
      ..sort((a, b) => _naturalCompare(a.path, b.path));
    for (final z in zones) {
      final value = await _readMilli('${z.path}/temp');
      if (value == null) continue;
      final type = await _readString('${z.path}/type');
      rows.add(TemperatureReading(
        label: _chipName(type ?? _basename(z.path)),
        celsius: value,
      ));
    }
  } catch (_) {}
  return rows;
}

/// Drivers whose sensor labels already name the device.
bool _selfDescribing(String chip) =>
    chip == 'coretemp' || chip == 'k10temp' || chip == 'zenpower';

String _chipName(String chip) {
  if (chip.startsWith('nvme')) return 'NVMe';
  if (chip.startsWith('pch_')) return 'Chipset';
  if (chip.startsWith('iwlwifi')) return 'Wi-Fi';
  return switch (chip) {
    'acpitz' => 'Board (ACPI)',
    'x86_pkg_temp' => 'CPU package',
    'coretemp' || 'k10temp' || 'zenpower' || 'cpu_thermal' => 'CPU',
    'drivetemp' => 'Disk',
    'amdgpu' || 'radeon' || 'nouveau' || 'i915' || 'xe' => 'GPU',
    'r8169' || 'igc' || 'igb' || 'e1000e' => 'Ethernet',
    _ => chip,
  };
}

Future<String?> _readString(String path) async {
  try {
    final s = (await File(path).readAsString()).trim();
    return s.isEmpty ? null : s;
  } catch (_) {
    return null;
  }
}

/// sysfs temperatures are integer millidegrees Celsius.
Future<double?> _readMilli(String path) async {
  final s = await _readString(path);
  if (s == null) return null;
  final v = int.tryParse(s);
  return v == null ? null : v / 1000.0;
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

/// `temp10` after `temp2`, `hwmon10` after `hwmon2`.
int _naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final pa = re.allMatches(a).map((m) => m[0]!).toList();
  final pb = re.allMatches(b).map((m) => m[0]!).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final na = int.tryParse(pa[i]);
    final nb = int.tryParse(pb[i]);
    final c = (na != null && nb != null) ? na.compareTo(nb) : pa[i].compareTo(pb[i]);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}
