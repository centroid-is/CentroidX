import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/hardware_temperatures.dart';

/// Builds a fake `/sys/class` with an Intel panel PC's sensors: acpitz with
/// only a crit, and coretemp with a package sensor and cores whose indices
/// skip (temp2, temp6, temp10 …) the way hybrid CPUs number them.
Future<Directory> _fakeSys() async {
  final sys = await Directory.systemTemp.createTemp('hwmon_test');
  Future<void> put(String path, String value) async {
    final f = File('${sys.path}/$path');
    await f.parent.create(recursive: true);
    await f.writeAsString('$value\n');
  }

  await put('hwmon/hwmon0/name', 'acpitz');
  await put('hwmon/hwmon0/temp1_input', '27800');
  await put('hwmon/hwmon0/temp1_crit', '105000');

  await put('hwmon/hwmon1/name', 'coretemp');
  await put('hwmon/hwmon1/temp1_label', 'Package id 0');
  await put('hwmon/hwmon1/temp1_input', '51000');
  await put('hwmon/hwmon1/temp1_max', '100000');
  await put('hwmon/hwmon1/temp1_crit', '100000');
  for (final (i, core, v) in [(2, 0, 51000), (6, 4, 53000), (10, 8, 44000)]) {
    await put('hwmon/hwmon1/temp${i}_label', 'Core $core');
    await put('hwmon/hwmon1/temp${i}_input', '$v');
    await put('hwmon/hwmon1/temp${i}_max', '100000');
    await put('hwmon/hwmon1/temp${i}_crit', '100000');
  }

  await put('hwmon/hwmon2/name', 'nvme');
  await put('hwmon/hwmon2/temp1_label', 'Composite');
  await put('hwmon/hwmon2/temp1_input', '38850');
  await put('hwmon/hwmon2/temp1_max', '84850');
  await put('hwmon/hwmon2/temp1_crit', '89850');

  await put('thermal/thermal_zone0/type', 'acpitz');
  await put('thermal/thermal_zone0/temp', '27800');
  return sys;
}

void main() {
  late Directory sys;
  setUp(() async => sys = await _fakeSys());
  tearDown(() => sys.delete(recursive: true));

  test('reads hwmon and collapses the cores into one row', () async {
    final rows = await readHostTemperatures(
      root: '${sys.path}/hwmon',
      thermalRoot: '${sys.path}/thermal',
    );
    expect(rows, const [
      TemperatureReading(label: 'Board (ACPI)', celsius: 27.8, critical: 105),
      TemperatureReading(
          label: 'CPU package', celsius: 51, high: 100, critical: 100),
      TemperatureReading(
          label: 'CPU cores',
          celsius: 53,
          minCelsius: 44,
          count: 3,
          high: 100,
          critical: 100),
      TemperatureReading(
          label: 'NVMe',
          celsius: 38.85,
          high: 84.85,
          critical: 89.85),
    ]);
  });

  test('falls back to thermal zones when hwmon has no temperatures', () async {
    final rows = await readHostTemperatures(
      root: '${sys.path}/nope',
      thermalRoot: '${sys.path}/thermal',
    );
    expect(rows, const [TemperatureReading(label: 'Board (ACPI)', celsius: 27.8)]);
  });

  test('a host with no sensors at all is an empty list, not a throw', () async {
    expect(
      await readHostTemperatures(
          root: '${sys.path}/nope', thermalRoot: '${sys.path}/nope'),
      isEmpty,
    );
  });

  group('temperatureLevel', () {
    test('coretemp max equal to crit is not a warning threshold of its own',
        () {
      expect(
          temperatureLevel(const TemperatureReading(
              label: 'x', celsius: 60, high: 100, critical: 100)),
          TemperatureLevel.normal);
      expect(
          temperatureLevel(const TemperatureReading(
              label: 'x', celsius: 92, high: 100, critical: 100)),
          TemperatureLevel.high);
    });

    test('a distinct max warns, crit is critical', () {
      const nvme = (high: 84.85, crit: 89.85);
      expect(
          temperatureLevel(TemperatureReading(
              label: 'x', celsius: 70, high: nvme.high, critical: nvme.crit)),
          TemperatureLevel.normal);
      expect(
          temperatureLevel(TemperatureReading(
              label: 'x', celsius: 85, high: nvme.high, critical: nvme.crit)),
          TemperatureLevel.high);
      expect(
          temperatureLevel(TemperatureReading(
              label: 'x', celsius: 90, high: nvme.high, critical: nvme.crit)),
          TemperatureLevel.critical);
    });

    test('no limits at all is always normal', () {
      expect(temperatureLevel(const TemperatureReading(label: 'x', celsius: 120)),
          TemperatureLevel.normal);
    });
  });
}
