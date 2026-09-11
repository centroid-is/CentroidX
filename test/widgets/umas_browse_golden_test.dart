/// Golden + widget tests for UMAS browse panel integration.
///
/// Uses UmasBrowseDataSource with a mock UmasClient to verify:
/// 1. The browse panel renders the UMAS variable tree correctly
/// 2. Folder expansion works
/// 3. Variable selection and detail strip show correct metadata
/// 4. Golden images capture the visual state for manual review
///
/// To update goldens: flutter test test/widgets/umas_browse_golden_test.dart --update-goldens
@Tags(['golden'])
library;

import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_client/modbus_client.dart';
import 'package:tfc_dart/core/umas_client.dart';
import 'package:tfc_dart/core/umas_types.dart';

import 'package:tfc/widgets/browse_panel.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc/widgets/resizable_overlay_frame.dart';
import 'package:tfc/widgets/umas_browse.dart';

// ---------------------------------------------------------------------------
// Fake UMAS send function — returns canned FC90 responses
// ---------------------------------------------------------------------------

/// Builds a success PDU: `[0x5A, pairingKey, status=0xFE, ...payload]`.
///
/// There is no echoed sub-function byte. `UmasClient._checkStatus` reads the
/// status at `pdu[2]`, and every fake in `packages/tfc_dart/test` frames it
/// the same way. This helper used to insert the sub-function there, which put
/// the status at `pdu[3]` and made the client read the sub-function *as* the
/// status — so `readPlcId` saw `0x02`, threw
/// `UMAS readPlcId failed with status 0x2`, and the browse dialog rendered
/// that exception instead of a tree. Nothing caught it because this file is
/// `@Tags(['golden'])` and CI never ran it.
Uint8List _successPdu(List<int> payload, {int pairingKey = 0x00}) {
  return Uint8List.fromList([0x5A, pairingKey, 0xFE, ...payload]);
}

/// The error counterpart: `[0x5A, pairingKey, status=0xFD, errorCode]`.
Uint8List _errorPdu(int errorCode, {int pairingKey = 0x00}) {
  return Uint8List.fromList([0x5A, pairingKey, 0xFD, errorCode]);
}

/// Little-endian uint16
List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

/// Little-endian uint32
List<int> _le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

/// Build variable names response payload with proper header and record format.
///
/// Header: range(1) + nextAddress(2 LE) + unknown1(2 LE) + noOfRecords(2 LE)
/// Record: dataType(2 LE) + block(2 LE) + offset(4 LE) + flags(1) +
///         unknown4(1) + name + NUL
///
/// The name is **null-terminated**, not length-prefixed. This used to write a
/// `stringLength(2 LE)` and no terminator. The two headers happen to be the
/// same ten bytes, so the first record read plausibly -- and then
/// `_parseVariableRecords` scanned for a NUL that was not there, ran into the
/// next record's `dataType`, and every record after the first landed in the
/// wrong place. The panel showed `GVL` and lost `Motor` and `Counters`.
List<int> _variableNamesPayload() {
  const variables = [
    ('Application.GVL.temperature', 1, 0, 5),
    ('Application.GVL.pressure', 1, 4, 5),
    ('Application.GVL.motor_running', 1, 8, 6),
    ('Application.GVL.setpoint', 1, 9, 1),
    ('Application.GVL.error_code', 1, 11, 2),
    ('Application.Motor.speed', 2, 0, 5),
    ('Application.Motor.torque', 2, 4, 5),
    ('Application.Motor.enabled', 2, 8, 6),
    ('Application.Counters.production', 3, 0, 4),
    ('Application.Counters.runtime_ms', 3, 4, 8),
  ];
  final buf = <int>[];
  // Header: range(1) + nextAddress=0 (2 LE, no more pages) + unknown1(2) + noOfRecords(2 LE)
  buf.add(0x00); // range
  buf.addAll(_le16(0)); // nextAddress = 0 (single page)
  buf.addAll(_le16(0)); // unknown1
  buf.addAll(_le16(variables.length));
  // Records
  for (final (name, blockNo, offset, typeId) in variables) {
    buf.addAll(_le16(typeId)); // dataType
    buf.addAll(_le16(blockNo)); // block
    buf.addAll(_le32(offset)); // offset
    buf.add(0x01); // flags — non-zero marks a top-level variable
    buf.add(0x00); // unknown4
    buf.addAll(name.codeUnits); // name...
    buf.add(0x00); // ...NUL-terminated
  }
  return buf;
}

/// Build data types response payload with proper header and record format.
///
/// Header: range(1) + nextAddress(2 LE) + unknown1(1) + noOfRecords(2 LE)
/// Record: dataSize(2 LE) + unknown1(2 LE) + classIdentifier(1) +
///         dataType(1) + stringLength(1) + name
List<int> _dataTypesPayload() {
  const types = [
    ('MY_STRUCT', 16),
    ('ALARM_TYPE', 8),
  ];
  final buf = <int>[];
  // Header: range(1) + nextAddress=0 (2 LE) + unknown1(1) + noOfRecords(2 LE)
  buf.add(0x00); // range
  buf.addAll(_le16(0)); // nextAddress = 0 (single page)
  buf.add(0x00); // unknown1
  buf.addAll(_le16(types.length));
  // Records
  for (final (name, byteSize) in types) {
    final nameBytes = name.codeUnits;
    buf.addAll(_le16(byteSize)); // dataSize
    buf.addAll(_le16(0)); // unknown1
    buf.add(0x00); // classIdentifier
    buf.add(0x00); // dataType
    buf.add(nameBytes.length); // stringLength (1 byte)
    buf.addAll(nameBytes); // name
  }
  return buf;
}

/// Mock send function that mimics the stub server responses
Future<ModbusResponseCode> _fakeSend(ModbusRequest request) async {
  if (request is! UmasRequest) {
    return ModbusResponseCode.requestTimeout;
  }

  final subFunc = request.umasSubFunction;
  Uint8List pdu;

  if (subFunc == 0x02) {
    // ReadPlcId: range(2) + hardwareId(4 LE) + numMemBanks(1) + entry(9)
    pdu = _successPdu([
      0x00, 0x00, // range
      0x01, 0x00, 0x00, 0x00, // hardwareId = 1
      0x01, // numberOfMemoryBanks = 1
      0x00, 0x00, // address = 0 (index)
      0x01, // blockType
      0x00, 0x00, // unknown
      0x00, 0x10, 0x00, 0x00, // memoryLength
    ]);
  } else if (subFunc == 0x01) {
    // Init: max frame size = 1024
    pdu = _successPdu(_le16(1024));
  } else if (subFunc == 0x26) {
    // ReadDataDictionary
    final recordType = request.umasPayload[0] | (request.umasPayload[1] << 8);
    if (recordType == 0xDD02) {
      pdu = _successPdu(_variableNamesPayload());
    } else if (recordType == 0xDD03) {
      pdu = _successPdu(_dataTypesPayload());
    } else {
      pdu = _errorPdu(0x03);
    }
  } else {
    pdu = _errorPdu(0x04);
  }

  request.internalSetFromPduResponse(pdu);
  return ModbusResponseCode.requestSucceed;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// What the goldens frame.
///
/// [ResizableOverlayFrame] has no [RepaintBoundary] of its own — its resize
/// handles are deliberately positioned OUTSIDE its bounds under
/// `Clip.none` — so `matchesGoldenFile` walks up to the nearest boundary and
/// captures the whole surface regardless of what is named here. That is the
/// right image anyway: half of what changed is that this window now FLOATS,
/// and a crop to its own bounds would show neither the page behind it nor
/// where on that page it sits. Named for what it actually captures.
final _browseSurface = find.byType(MaterialApp);

/// Pump a BrowsePanel inside a MaterialApp with Solarized-like dark theme.
///
/// The surface is deliberately larger than the dialog's 920x600 so the
/// goldens show a window FLOATING over the page — at the default 800x600 the
/// shell's `_fit` would clamp it to the full surface and the border, the
/// centring and the corner grip would all be flush against the edge, which is
/// the one thing these images exist to show.
Future<void> _showUmasBrowse(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(1200, 800)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // The registry is static: a dialog left open leaks its id into the next
  // test, where the same alias would be a no-op re-open.
  addTearDown(closeAllFloatingDialogs);

  final client = UmasClient(sendFn: _fakeSend);
  final dataSource = UmasBrowseDataSource(client);

  await tester.pumpWidget(
    MaterialApp(
      // The banner is a rotated ribbon in the top-right corner of the
      // surface, and the surface is what gets captured.
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showBrowseDialog(
                context: context,
                dataSource: dataSource,
                serverAlias: 'Schneider M340',
              ),
              child: const Text('Browse'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('Browse'));
  await tester.pumpAndSettle();

  // A live session starts a periodic keep-alive, and flutter_test checks for
  // pending timers at the end of the test body -- before any addTearDown
  // runs, so that hook is too late. The whole dictionary is already fetched
  // and cached by now (expanding folders walks the tree, it does not go back
  // to the PLC), so the client has nothing left to do.
  //
  // No test ever reached this: the fake's PDU framing meant the session never
  // came up, so the keep-alive never started.
  client.dispose();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('UMAS Browse Panel', () {
    testWidgets('renders root "Application" folder from UMAS browse',
        (tester) async {
      await _showUmasBrowse(tester);

      // Root should show "Application" (may appear in breadcrumb too)
      expect(find.text('Application'), findsWidgets);
    });

    testWidgets('expanding Application shows GVL, Motor, Counters folders',
        (tester) async {
      await _showUmasBrowse(tester);

      // Tap to expand Application (use .first — breadcrumb also shows it)
      // pump(kDoubleTapTimeout) needed to distinguish from double-tap
      await tester.tap(find.text('Application').first);
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      expect(find.text('GVL'), findsWidgets);
      expect(find.text('Motor'), findsWidgets);
      expect(find.text('Counters'), findsWidgets);
    });

    testWidgets('expanding GVL shows 5 variables with correct types',
        (tester) async {
      await _showUmasBrowse(tester);

      // Expand Application
      await tester.tap(find.text('Application').first);
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      // Expand GVL
      await tester.tap(find.text('GVL').first);
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      expect(find.text('temperature'), findsWidgets);
      expect(find.text('pressure'), findsWidgets);
      expect(find.text('motor_running'), findsWidgets);
      expect(find.text('setpoint'), findsWidgets);
      expect(find.text('error_code'), findsWidgets);
    });

    testWidgets('selecting a variable shows detail strip', (tester) async {
      await _showUmasBrowse(tester);

      // Expand Application → GVL
      await tester.tap(find.text('Application').first);
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      await tester.tap(find.text('GVL').first);
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      // Tap temperature to select it
      await tester.tap(find.text('temperature').first);
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      // The detail strip should show path info
      expect(find.text('Application.GVL.temperature'), findsWidgets);
    });

    testWidgets('golden: initial state with Application root',
        (tester) async {
      await _showUmasBrowse(tester);
      await expectLater(
        _browseSurface,
        matchesGoldenFile('goldens/umas_browse_initial.png'),
      );
    });

    testWidgets('golden: expanded tree showing variables', (tester) async {
      await _showUmasBrowse(tester);

      // Expand Application → GVL
      await tester.tap(find.text('Application').first);
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      await tester.tap(find.text('GVL').first);
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      // No "also expand Motor" step. The panel drills down rather than
      // expanding in place -- entering GVL replaces the folder list with
      // GVL's variables, so Motor (a sibling of GVL, one level up) is not on
      // screen and tapping it threw "Bad state: No element". Application >
      // GVL with its five variables is what "showing variables" means here.

      await expectLater(
        _browseSurface,
        matchesGoldenFile('goldens/umas_browse_expanded.png'),
      );
    });

    testWidgets('golden: variable selected with detail strip',
        (tester) async {
      await _showUmasBrowse(tester);

      await tester.tap(find.text('Application').first);
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      await tester.tap(find.text('GVL').first);
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      // Select temperature
      await tester.tap(find.text('temperature').first);
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      await expectLater(
        _browseSurface,
        matchesGoldenFile('goldens/umas_browse_selected.png'),
      );
    });
  });
}
