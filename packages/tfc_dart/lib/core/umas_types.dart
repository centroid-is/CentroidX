import 'dart:convert';
import 'dart:typed_data';

import 'package:tfc_dart/core/modbus_client_wrapper.dart' show ModbusDataType;
import 'package:tfc_dart/core/umas_fb_direction.dart' show UmasFbMemberDirection;

/// Maps a UMAS data type name to the corresponding Modbus data type.
///
/// Uses [byteSize] as a fallback for unknown type names.
ModbusDataType mapUmasDataTypeToModbus(String umasType, int byteSize) {
  switch (umasType.toUpperCase()) {
    case 'BOOL':
      return ModbusDataType.bit;
    case 'INT':
      return ModbusDataType.int16;
    case 'UINT':
      return ModbusDataType.uint16;
    case 'DINT':
      return ModbusDataType.int32;
    case 'UDINT':
      return ModbusDataType.uint32;
    case 'REAL':
      return ModbusDataType.float32;
    case 'LREAL':
      return ModbusDataType.float64;
    case 'LINT':
      return ModbusDataType.int64;
    case 'ULINT':
      return ModbusDataType.uint64;
    default:
      if (byteSize <= 2) return ModbusDataType.uint16;
      if (byteSize <= 4) return ModbusDataType.uint32;
      return ModbusDataType.float64;
  }
}

/// Session state for UMAS client lifecycle.
///
/// Tracks the progression through the UMAS handshake:
/// uninitialized -> identified (after readPlcId) -> paired (after init).
enum UmasSessionState {
  /// No UMAS session. Pairing key is invalid/unknown.
  uninitialized,

  /// readPlcId (0x02) succeeded. Have hardwareId and index.
  identified,

  /// init (0x01) succeeded. Have valid pairing key.
  paired,
}

/// UMAS sub-function codes for Schneider PLC communication via FC90.
enum UmasSubFunction {
  init(0x01),
  readId(0x02),
  readProjectInfo(0x03),
  plcStatus(0x04),
  echo(0x0A),
  takePlcReservation(0x10),
  releasePlcReservation(0x11),
  keepAlive(0x12),
  readVariable(0x22),
  writeVariable(0x23),
  readCoilsRegisters(0x24),
  writeCoilsRegisters(0x25),
  readCardInfo(0x06),
  readMemoryBlock(0x20),
  readDataDictionary(0x26),
  readEthMasterData(0x39),
  monitorPlc(0x50),
  checkPlc(0x58),
  readIoObject(0x70),
  getStatusModule(0x73);

  const UmasSubFunction(this.code);
  final int code;
}

/// A variable discovered from the UMAS data dictionary (0xDD02 records).
class UmasVariable {
  final String name;
  final int blockNo;
  final int offset;
  final int dataTypeId;
  final String? parentPath;

  /// Declaration direction when this variable is a function-block member
  /// (see [UmasFbMemberDirection]). Null for top-level variables and for
  /// non-FB struct members. Populated by [UmasClient] when parsing DD02
  /// member-layout records (Phase 3 of v1.1).
  final UmasFbMemberDirection? direction;

  const UmasVariable({
    required this.name,
    required this.blockNo,
    required this.offset,
    required this.dataTypeId,
    this.parentPath,
    this.direction,
  });

  @override
  String toString() => 'UmasVariable($name, block=$blockNo, offset=$offset, '
      'typeId=$dataTypeId'
      '${direction != null ? ', dir=${direction!.name}' : ''})';
}

/// A data type reference from the UMAS data dictionary (0xDD03 records).
class UmasDataTypeRef {
  final int id;
  final String name;
  final int byteSize;

  /// Class identifier from the PLC4X mspec (0xDD03 record field).
  /// 2 = UDT/struct, 4 = array, other values = elementary.
  final int classIdentifier;

  /// Data type code from the PLC4X mspec (0xDD03 record field).
  final int dataType;

  const UmasDataTypeRef({
    required this.id,
    required this.name,
    required this.byteSize,
    this.classIdentifier = 0,
    this.dataType = 0,
  });

  @override
  String toString() => 'UmasDataTypeRef($id: $name, ${byteSize}B)';
}

/// Inclusive bounds for one array dimension (PLC4X UmasArrayDimension).
class UmasArrayDimension {
  /// Inclusive lower index (e.g. 1 for `ARRAY[1..100]`).
  final int startIndex;

  /// Inclusive upper index (e.g. 100 for `ARRAY[1..100]`).
  final int upperBound;

  const UmasArrayDimension({required this.startIndex, required this.upperBound});

  /// Element count for this dimension = `upperBound - startIndex + 1`.
  int get count => upperBound - startIndex + 1;

  @override
  String toString() => '[$startIndex..$upperBound]';
}

/// Parsed UmasArrayTypeDefinition returned by a DD02 query for an array
/// data-type id (PLC4X mspec).
///
/// Wire format (LE): `classId(1) + elementTypeId(2) + numberOfDimensions(1)
/// + dimensions[N]`, where each [UmasArrayDimension] is `startIndex(4) +
/// upperBound(4)`.
class UmasArrayTypeDefinition {
  /// Always 0x04 for arrays.
  final int classId;

  /// PLC-assigned type id of the element (built-in or custom UDT).
  final int elementTypeId;

  /// Inclusive bounds per dimension (PLC4X observes 1D in production but
  /// the wire format and mspec support N-dimensional definitions).
  final List<UmasArrayDimension> dimensions;

  const UmasArrayTypeDefinition({
    required this.classId,
    required this.elementTypeId,
    required this.dimensions,
  });

  /// Total flattened element count across all dimensions.
  int get totalElementCount {
    if (dimensions.isEmpty) return 0;
    int n = 1;
    for (final d in dimensions) {
      final c = d.count;
      if (c <= 0) return 0;
      n *= c;
    }
    return n;
  }

  /// Parse from raw DD02 response payload bytes (the body returned by
  /// [UmasClient.readDD02Raw] for an array type id).
  ///
  /// Returns null if the buffer is too short or `classId` is not 0x04.
  static UmasArrayTypeDefinition? tryParse(Uint8List bytes) {
    if (bytes.length < 4) return null;
    if (bytes[0] != 0x04) return null;
    final bd = ByteData.sublistView(bytes);
    final elementTypeId = bd.getUint16(1, Endian.little);
    final numberOfDimensions = bd.getUint8(3);
    final dimensions = <UmasArrayDimension>[];
    int pos = 4;
    for (int i = 0; i < numberOfDimensions; i++) {
      if (pos + 8 > bytes.length) return null;
      final startIndex = bd.getUint32(pos, Endian.little);
      final upperBound = bd.getUint32(pos + 4, Endian.little);
      dimensions.add(UmasArrayDimension(
        startIndex: startIndex,
        upperBound: upperBound,
      ));
      pos += 8;
    }
    return UmasArrayTypeDefinition(
      classId: 0x04,
      elementTypeId: elementTypeId,
      dimensions: dimensions,
    );
  }

  @override
  String toString() => 'UmasArrayTypeDefinition(elementTypeId=$elementTypeId, '
      'dims=${dimensions.length})';
}

/// PLC identification data from sub-function 0x02 response.
class UmasPlcIdent {
  /// Hardware identifier (uint32 from ident field).
  final int hardwareId;

  /// Memory block index used for 0x26 data dictionary requests.
  final int index;

  /// Number of memory banks reported by the PLC.
  final int numberOfMemoryBanks;

  const UmasPlcIdent({
    required this.hardwareId,
    required this.index,
    required this.numberOfMemoryBanks,
  });

  @override
  String toString() => 'UmasPlcIdent(hwId=0x${hardwareId.toRadixString(16)}, '
      'index=$index, banks=$numberOfMemoryBanks)';
}

/// A node in the hierarchical variable tree built from data dictionary.
///
/// Phase 5 / FB-05 additions: [direction], [readable], and
/// [unreadableReason] expose IEC 61131-3 FB member metadata so the
/// UI (Phase 4) can render VAR_INPUT / VAR_OUTPUT distinctions and
/// surface unreadable VAR_IN_OUT members with a clear affordance
/// instead of silently dropping them.
///
/// Direction classification belongs to Phase 3 (see
/// `umas_fb_direction.dart`). plc4j (PLC4X) does not surface
/// direction metadata at all; see `umas_var_in_out.dart` for the
/// parity-deviation rationale.
class UmasVariableTreeNode {
  final String name;
  final String path;
  final List<UmasVariableTreeNode> children;
  final UmasVariable? variable;
  final UmasDataTypeRef? dataType;

  /// Direction of this node when it is an FB member, or `null` for
  /// non-member nodes (top-level variables, struct members, array
  /// elements, folders). Phase 2's FB expander and Phase 3's
  /// [UmasFbMemberDirection] classifier populate this. Consumed by the
  /// browser-tree UI (Phase 4) and the `--show-direction` CLI flag.
  final UmasFbMemberDirection? direction;

  /// Whether this node is readable through the normal 0x22 / 0x50
  /// read path. Defaults to `true`. Phase 5 sets `false` for
  /// VAR_IN_OUT members per FB-05 path (b).
  final bool readable;

  /// Human-readable reason a node is unreadable (e.g. `"VAR_IN_OUT
  /// (PLC returns 0x94)"`). `null` when [readable] is `true`.
  /// Surfaced by the UI as a tooltip / suffix on unreadable leaves.
  final String? unreadableReason;

  UmasVariableTreeNode({
    required this.name,
    required this.path,
    List<UmasVariableTreeNode>? children,
    this.variable,
    this.dataType,
    this.direction,
    this.readable = true,
    this.unreadableReason,
  }) : children = children ?? [];

  bool get isFolder => children.isNotEmpty && variable == null;

  @override
  String toString() => 'UmasVariableTreeNode($path, '
      '${isFolder ? "folder" : "leaf"}, '
      '${children.length} children'
      '${direction != null ? ", direction=${direction!.name}" : ""}'
      '${!readable ? ", readable=false" : ""})';
}

/// A flattened, resolved view of a UMAS symbol — the minimum tuple
/// needed to issue a [VariableReadRef] / [VariableWriteRef] for a leaf
/// addressed by name.
///
/// Produced by [UmasClient.lookupSymbol]. The fields mirror what the
/// browse tree carries on a leaf node, but with non-nullable types so
/// callers don't need to re-validate.
class ResolvedSymbol {
  /// Full dotted path used to look the symbol up, e.g.
  /// `B_F1_RC_01_Front` or `M_Elevator.speed`.
  final String path;

  /// PLC address (blockNo + offset) and metadata.
  final UmasVariable variable;

  /// Resolved data type (built-in or custom UDT).
  final UmasDataTypeRef dataType;

  /// Whether the underlying tree node was marked readable. VAR_IN_OUT
  /// members are unreadable (PLC returns 0x94).
  final bool readable;

  /// Human-readable explanation when [readable] is `false`.
  final String? unreadableReason;

  const ResolvedSymbol({
    required this.path,
    required this.variable,
    required this.dataType,
    this.readable = true,
    this.unreadableReason,
  });

  @override
  String toString() => 'ResolvedSymbol($path, ${dataType.name}, '
      'block=${variable.blockNo}, offset=${variable.offset}'
      '${!readable ? ", readable=false" : ""})';
}

/// Exception thrown by UMAS operations.
class UmasException implements Exception {
  final int errorCode;
  final String message;

  /// TD-017 (v1.1.x): second byte of the PLC's UMAS error payload,
  /// when present. Schneider M580 firmware emits a 2-byte error marker
  /// `0xA1 0xA1` from sub-function 0x22 (ReadVariable) to signal "use
  /// MonitorPlc (0x50) instead"; the single-byte 0xA1 alone could
  /// plausibly originate from an unrelated firmware path on a different
  /// PLC family, so the auto-fallback heuristic in [UmasClient.readVariables]
  /// requires both bytes to match (pdu[3] == 0xA1 && pdu[4] == 0xA1) to
  /// flip into MonitorPlc mode.
  ///
  /// Null when the PDU did not carry a 5th byte.
  final int? secondaryErrorCode;

  const UmasException({
    required this.errorCode,
    required this.message,
    this.secondaryErrorCode,
  });

  @override
  String toString() {
    if (secondaryErrorCode == null) {
      return 'UmasException($errorCode): $message';
    }
    return 'UmasException($errorCode, sec=$secondaryErrorCode): $message';
  }
}

/// Exception thrown when PLC reservation cannot be acquired (conflict).
///
/// Indicates another client currently holds the exclusive write reservation.
/// The [message] is suitable for user-facing feedback (WRITE-04).
class UmasReservationException extends UmasException {
  const UmasReservationException({
    required super.errorCode,
    required super.message,
    super.secondaryErrorCode,
  });

  @override
  String toString() => 'UmasReservationException($errorCode): $message';
}

/// Exception thrown when [UmasClient.readVariableByName] /
/// [UmasClient.writeVariableByName] is invoked on a non-scalar root such as
/// a Function Block (FB) instance.
///
/// fuzz #7 (v1.1.x): previously the read path silently returned an empty
/// [TypedVariableValue] (FB type, byteSize 0) for FB instances — the
/// `default:` branch of [parseVariableValue] returned a zero-length slice
/// without raising. Operators saw a blank in FB-DynamicValue / Key
/// Repository with no error message, which made the bug invisible.
///
/// The browse tree (UMAS-by-name FB browse / Key Repository member picker)
/// enumerates FB members via its own walk, so it does NOT depend on
/// `readVariableByName(fbRoot)`. The gate that throws this exception only
/// fires for callers that asked for the FB root itself — which is buggy.
///
/// The [message] is operator-facing: it names the path and suggests the
/// `path.<member>` notation so the operator can recover without re-browsing.
class UmasNotScalarException extends UmasException {
  /// Path that the caller tried to read/write as a scalar.
  final String path;

  /// Human-readable kind name from the resolved [UmasDataTypeRef]
  /// (e.g. `FB`, `STRUCT`, `ARRAY`).
  final String typeKind;

  UmasNotScalarException({
    required this.path,
    required this.typeKind,
  }) : super(
          errorCode: 0,
          message: 'UMAS variable "$path" is a $typeKind, not a scalar. '
              'Use "$path.<member>" to read individual members of this '
              '$typeKind.',
        );

  @override
  String toString() => 'UmasNotScalarException: $message';
}

/// Result of UMAS init communication (sub-function 0x01).
class UmasInitResult {
  final int maxFrameSize;
  final String? firmwareVersion;

  const UmasInitResult({required this.maxFrameSize, this.firmwareVersion});

  @override
  String toString() => 'UmasInitResult(maxFrame=$maxFrameSize)';
}

/// Result of PlcStatus (0x04) sub-function call.
///
/// Contains PLC run state and memory block CRC checksums needed by
/// ReadVariable (0x22) and WriteVariable (0x23).
class PlcStatusResult {
  /// Raw status byte from the first byte of payload. PLC run states are vendor-specific.
  final int statusByte;

  /// Number of memory blocks reported by PLC.
  final int numberOfBlocks;

  /// CRC checksums for each memory block (uint32 LE). Required by ReadVariable (0x22).
  final List<int> blockCrcs;

  /// Raw additional data bytes after the block CRCs (M580 has extra status data).
  final Uint8List additionalData;

  /// Whether the CRCs changed compared to the previous poll.
  /// False on the first poll (no previous data to compare).
  /// True when CRC list length or values differ from the previous poll.
  final bool crcChanged;

  const PlcStatusResult({
    required this.statusByte,
    required this.numberOfBlocks,
    required this.blockCrcs,
    required this.additionalData,
    this.crcChanged = false,
  });

  @override
  String toString() => 'PlcStatusResult(status=0x${statusByte.toRadixString(16)}, '
      'blocks=$numberOfBlocks, crcs=$blockCrcs)';
}

/// Result of ProjectInfo (0x03) sub-function call.
///
/// Contains the raw response bytes and a best-effort extracted project name.
class ProjectInfoResult {
  /// Raw response bytes (opaque -- format varies by PLC firmware).
  final Uint8List rawData;

  /// Extracted project name (best-effort: longest printable ASCII run).
  /// Null if no printable ASCII sequence found.
  final String? projectName;

  const ProjectInfoResult({required this.rawData, this.projectName});

  @override
  String toString() => 'ProjectInfoResult(${rawData.length} bytes, '
      'name=${projectName ?? "unknown"})';
}

/// Result of an Echo/Repeat (0x0A) sub-function call.
class UmasEchoResult {
  /// The payload bytes echoed back by the PLC.
  final Uint8List payload;

  /// Round-trip latency measured via [Stopwatch].
  final Duration latency;

  const UmasEchoResult({required this.payload, required this.latency});

  @override
  String toString() =>
      'UmasEchoResult(${payload.length} bytes, ${latency.inMilliseconds}ms)';
}

/// UMAS data type lookup table (from PLC4X).
/// Maps UMAS data type IDs to their standard names and byte sizes.
class UmasDataTypes {
  // Per the PLC4X UmasDataType enum (protocols/umas/.../umas.mspec). The
  // Schneider PLC's `dataType` byte uses these values, NOT the contiguous
  // 1..14 mapping we previously assumed. dataType=1 is BOOL (1 byte), not
  // INT — getting this wrong causes 0x94 read errors when an INT-sized
  // request hits a BOOL-sized member.
  static const Map<int, UmasDataTypeRef> builtIn = {
    1: UmasDataTypeRef(id: 1, name: 'BOOL', byteSize: 1),
    // Schneider also uses 2 and 3 for BOOL-like fields per PLC4X (UNKNOWN2,
    // UNKNOWN3 in mspec) — both 1 byte.
    2: UmasDataTypeRef(id: 2, name: 'BOOL', byteSize: 1),
    3: UmasDataTypeRef(id: 3, name: 'BOOL', byteSize: 1),
    4: UmasDataTypeRef(id: 4, name: 'INT', byteSize: 2),
    5: UmasDataTypeRef(id: 5, name: 'UINT', byteSize: 2),
    6: UmasDataTypeRef(id: 6, name: 'DINT', byteSize: 4),
    7: UmasDataTypeRef(id: 7, name: 'UDINT', byteSize: 4),
    8: UmasDataTypeRef(id: 8, name: 'REAL', byteSize: 4),
    9: UmasDataTypeRef(id: 9, name: 'STRING', byteSize: 256),
    10: UmasDataTypeRef(id: 10, name: 'TIME', byteSize: 4),
    14: UmasDataTypeRef(id: 14, name: 'DATE', byteSize: 4),
    15: UmasDataTypeRef(id: 15, name: 'TIME_OF_DAY', byteSize: 4),
    16: UmasDataTypeRef(id: 16, name: 'DATE_AND_TIME', byteSize: 8),
    21: UmasDataTypeRef(id: 21, name: 'BYTE', byteSize: 1),
    22: UmasDataTypeRef(id: 22, name: 'WORD', byteSize: 2),
    23: UmasDataTypeRef(id: 23, name: 'DWORD', byteSize: 4),
    25: UmasDataTypeRef(id: 25, name: 'EBOOL', byteSize: 1),
    // Extended/non-mspec entries kept for parser tests; not emitted by the
    // Schneider PLCs we've observed but supported for completeness.
    12: UmasDataTypeRef(id: 12, name: 'LREAL', byteSize: 8),
    13: UmasDataTypeRef(id: 13, name: 'LINT', byteSize: 8),
    24: UmasDataTypeRef(id: 24, name: 'ULINT', byteSize: 8),
  };

  /// Resolve a data type ID, first checking custom types then built-in.
  static UmasDataTypeRef? resolve(
      int id, List<UmasDataTypeRef> customTypes) {
    for (final t in customTypes) {
      if (t.id == id) return t;
    }
    return builtIn[id];
  }
}

/// Maps a data type byte size to the UMAS dataSizeIndex used in ReadVariable (0x22) requests.
///
/// Per PLC4X: 1B->1 (BOOL), 2B->2 (INT/UINT/WORD), 4B->3 (DINT/UDINT/REAL/
/// TIME/DWORD). The PLC rejects (0x86) any dsi outside this set, so for
/// types larger than 4 bytes (e.g. TON, struct instances) we clamp to 3
/// and return only the first 4 bytes — matching plc4j's behavior.
/// STRING (256 bytes) is a special case returning 17 per PLC4X table.
int dataSizeIndexFromByteSize(int byteSize) {
  if (byteSize >= 256) return 17; // STRING special case
  if (byteSize > 4) return 3; // clamp wide types to 4 bytes (PLC4X behaviour)
  int index = 1;
  int size = 1;
  while (size < byteSize && index < 16) {
    size *= 2;
    index++;
  }
  return index;
}

/// Canonical Schneider array name pattern: `ARRAY[..] OF <ELEM>` or
/// `ARRAY[..,..] OF <ELEM>` (multi-dim). Captures the element type name.
final RegExp _arrayElementTypeNameRe =
    RegExp(r'\bARRAY\s*\[.*?\]\s+OF\s+([A-Z_][A-Z0-9_]*)', caseSensitive: false);

/// Recover the byte size of an array's element type from a
/// [UmasDataTypeRef] whose `classIdentifier == 4`.
///
/// **Why this exists (DROP_HEALTH underflow, v1.1.x):** The live M580
/// DD03 emits ARRAY records whose `dataType` byte equals the array's
/// OWN type id, NOT the element type id. For `ARRAY[1..31] OF BOOL`
/// the record is `id=0x1F, dataType=0x1F, byteSize=31, classId=4`.
/// Looking up `builtIn[0x1F]` returns null and the legacy fallback
/// (`dataType.byteSize`) clamps to dsi=3 (4 bytes/element) -- which
/// asks the PLC for 7x4 = 28 bytes and silently drops the last 3
/// BOOLs. plc4j hits the same wire shape and recovers from the DD02
/// `UmasArrayTypeDefinition.elementTypeId`; the tree builder here
/// already does that for per-element children but the whole-array
/// read path goes straight through the encoder with the raw DD03
/// shape.
///
/// Strategy (in order of trust):
///   1. `builtIn[dataType.dataType]` -- the path that works when the
///      tree builder / speculative-resolve branch has already
///      rewritten `dataType` to the real element type id (e.g. for
///      arrays of UDT or arrays surfaced via the DD02-keyed path).
///   2. If `dataType.dataType` == `dataType.id` (self-referencing,
///      the live-M580 DD03 shape), parse the canonical Schneider
///      type name `ARRAY[..] OF <ELEM>` and look the element up in
///      `builtIn` by name. Schneider firmware emits these names
///      consistently for built-in element types -- we observe BOOL,
///      INT, UINT, WORD, DINT, UDINT, REAL, BYTE, DATE, TIME,
///      TIME_OF_DAY, DATE_AND_TIME, STRING on M580 / M340.
///   3. Fall back to `dataType.byteSize` (the legacy behaviour).
///      Worst case the caller asks the PLC for a wide read and gets
///      a clamped response -- noisy but at least no underflow.
int _arrayElementByteSize(UmasDataTypeRef dataType) {
  final byId = UmasDataTypes.builtIn[dataType.dataType];
  if (byId != null) return byId.byteSize;
  // (2) Name parse for the DD03 self-referencing shape.
  if (dataType.dataType == dataType.id) {
    final m = _arrayElementTypeNameRe.firstMatch(dataType.name);
    if (m != null) {
      final elemName = m.group(1)!.toUpperCase();
      for (final t in UmasDataTypes.builtIn.values) {
        if (t.name.toUpperCase() == elemName) return t.byteSize;
      }
    }
  }
  return dataType.byteSize;
}

/// A reference to a variable for ReadVariable (0x22) requests.
///
/// Encodes the wire format: isArray:4bits + dataSizeIndex:4bits (1 byte)
/// + block(2 LE) + 0x01(1) + baseOffset(2 LE) + offset(1)
/// + [arrayLength(2 LE) if isArray]
class VariableReadRef {
  final int blockNo;
  final int baseOffset;
  final int offset;
  final int dataSizeIndex;
  final bool isArray;
  final int arrayLength;

  const VariableReadRef({
    required this.blockNo,
    required this.baseOffset,
    required this.offset,
    required this.dataSizeIndex,
    this.isArray = false,
    this.arrayLength = 0,
  });

  /// Create a [VariableReadRef] from a [UmasVariable] and its resolved [UmasDataTypeRef].
  ///
  /// Detects array variables via [UmasDataTypeRef.classIdentifier] == 4.
  /// For arrays, computes [arrayLength] as `dataType.byteSize / elementSize`
  /// where `elementSize` is resolved via [_arrayElementByteSize] (which
  /// handles the live-M580 DD03 self-referencing-dataType shape that would
  /// otherwise drop the last 3 BOOLs of `ARRAY[1..31] OF BOOL`).
  factory VariableReadRef.fromVariable(
      UmasVariable variable, UmasDataTypeRef dataType) {
    final isArray = dataType.classIdentifier == 4;
    int arrayLength = 0;
    int sizeForDsi = dataType.byteSize;

    if (isArray) {
      final elementSize = _arrayElementByteSize(dataType);
      arrayLength =
          elementSize > 0 ? dataType.byteSize ~/ elementSize : 1;
      sizeForDsi = elementSize > 0 ? elementSize : dataType.byteSize;
    }

    // Per PLC4X driver, the Schneider VariableReadRef uses a paged byte
    // address: `baseOffset` is the 256-byte page index (address >> 8),
    // `offset` is the low byte (address & 0xFF). BOOL access also
    // requires this split form — putting the byte address directly in
    // baseOffset returns 0x94. Verified against plc4j packet captures
    // (e.g. byte 0x11a0 -> baseOffset=0x11 offset=0xa0).
    final addr = variable.offset;
    return VariableReadRef(
      blockNo: variable.blockNo,
      baseOffset: addr >> 8,
      offset: addr & 0xFF,
      dataSizeIndex: dataSizeIndexFromByteSize(sizeForDsi),
      isArray: isArray,
      arrayLength: arrayLength,
    );
  }

  /// Serialize to wire format bytes for the 0x22 request payload.
  Uint8List toBytes() {
    final length = isArray ? 9 : 7;
    final bytes = Uint8List(length);
    final bd = ByteData.sublistView(bytes);

    // Byte 0: isArray(4 bits) | dataSizeIndex(4 bits)
    bytes[0] = (isArray ? 0x10 : 0x00) | (dataSizeIndex & 0x0F);

    // Block number (2 bytes LE)
    bd.setUint16(1, blockNo, Endian.little);

    // Constant 0x01
    bytes[3] = 0x01;

    // Base offset (2 bytes LE)
    bd.setUint16(4, baseOffset, Endian.little);

    // Offset (1 byte)
    bytes[6] = offset & 0xFF;

    // Array length (2 bytes LE) if isArray
    if (isArray) {
      bd.setUint16(7, arrayLength, Endian.little);
    }

    return bytes;
  }
}

/// Result of a ReadVariable (0x22) call.
///
/// Contains raw response bytes; typed parsing is handled by
/// [parseVariableValue] and [parseVariableValues].
class ReadVariableResult {
  /// Raw concatenated bytes of all requested variable values.
  final Uint8List rawBytes;

  const ReadVariableResult({required this.rawBytes});

  @override
  String toString() => 'ReadVariableResult(${rawBytes.length} bytes)';
}

/// A parsed variable value with its Dart type, type name, and raw bytes.
class TypedVariableValue {
  /// The parsed Dart value: [int], [double], [bool], [String], or [Uint8List].
  final dynamic value;

  /// The UMAS data type name (e.g. 'REAL', 'INT', 'BOOL').
  final String typeName;

  /// The original raw bytes for this value.
  final Uint8List rawBytes;

  const TypedVariableValue({
    required this.value,
    required this.typeName,
    required this.rawBytes,
  });

  @override
  String toString() => 'TypedVariableValue($typeName: $value)';
}

/// Maximum allowed STRING byte size for parsing (T-05-06 mitigation).
const _maxStringByteSize = 1024;

/// Parse a single variable value from [bytes] at [offset] using [dataType] info.
///
/// Returns a [TypedVariableValue] with the correctly typed Dart value.
/// Throws [UmasException] if the buffer is too short for a *fixed-size scalar*
/// (BOOL/INT/REAL/etc.) — T-05-04 mitigation.
///
/// STRING / BYTE_STRING / WSTRING are *never* a throw source: Schneider PLCs
/// return STRING reads clamped to 4 bytes via the M580's 0x50 path and may
/// return 0 bytes for empty strings via 0x22. The parser slices whatever
/// arrived (possibly empty) and decodes it without raising, so the HMI
/// renders a (possibly truncated/empty) string rather than the literal text
/// "Buffer underflow" through `'read error: $e'` (v1.1 JOB-A fix).
/// Elementary types [parseVariableValue] decodes at their full declared width.
///
/// Anything in here is read with an exact-width accessor (`getFloat64`,
/// `getInt64`, …), so a caller walking a multi-variable buffer must advance by
/// the same number of bytes. See [umasOnWireSize].
const Set<String> kUmasKnownScalars = {
  'BOOL', 'EBOOL', 'INT', 'UINT', 'WORD', 'DINT', 'TIME', 'UDINT',
  'DWORD', 'REAL', 'LREAL', 'LINT', 'ULINT', 'BYTE',
  'DATE', 'TIME_OF_DAY', 'DATE_AND_TIME',
};

bool _isStringyName(String name) {
  final u = name.toUpperCase();
  return u == 'STRING' || u == 'BYTE_STRING' || u == 'WSTRING';
}

/// Bytes [parseVariableValue] will consume for [type] out of a buffer with
/// [remaining] bytes left at the current offset.
///
/// The single source of truth for stepping through a concatenated buffer.
/// Getting this out of step with the reader silently misaligns every variable
/// that follows: the 4-byte clamp below exists for wide *aggregates* (struct
/// instances, TON), which the M580 truncates to 4 bytes, but it used to catch
/// the 8-byte elementary scalars too — so an LREAL was read as 8 bytes and
/// stepped over as 4, and everything after it decoded from the wrong offset.
int umasOnWireSize(UmasDataTypeRef type, int remaining) {
  final upper = type.name.toUpperCase();
  // Exact-width scalars: the reader demands all of them or throws underflow.
  if (kUmasKnownScalars.contains(upper)) return type.byteSize;
  final clamped = type.byteSize > 4 ? 4 : type.byteSize;
  // STRING-family may arrive shorter than the clamp; never step past the end.
  if (_isStringyName(upper) && clamped > remaining) {
    return remaining < 0 ? 0 : remaining;
  }
  return clamped;
}

/// What the STRING branch has always done, kept as a named function so the
/// default below is one thing rather than a repeated expression.
String _defaultUmasStringDecode(List<int> bytes) =>
    utf8.decode(bytes, allowMalformed: true);

/// Turns a PLC STRING's bytes into text.
///
/// See [parseVariableValue]'s `decodeString`.
typedef UmasStringDecoder = String Function(List<int> bytes);

/// Parse one typed variable value out of [bytes] at [offset].
///
/// [decodeString] decodes the STRING / BYTE_STRING / WSTRING branch.
/// **Optional, and its default is exactly what this function always did** —
/// `utf8.decode(bytes, allowMalformed: true)` — so nothing that does not pass
/// it behaves differently in any way. The NUL-terminator trimming and the
/// [_maxStringByteSize] cap are applied *before* the decoder is called and are
/// unchanged.
///
/// It exists because `allowMalformed` is silently lossy against a Latin-1
/// device: a Schneider or Saia PLC holding `Þorskflök í raspi` sends bytes that
/// become U+FFFD here, under a good quality, with nothing in any log. This
/// function cannot know which server it is decoding for — that is deliberate,
/// and the caller which does know is
/// `packages/tfc_relay_local/lib/src/string_encoding.dart`.
TypedVariableValue parseVariableValue(
    Uint8List bytes, int offset, UmasDataTypeRef dataType,
    {UmasStringDecoder? decodeString}) {
  final declared = dataType.byteSize;
  final available = bytes.length - offset;

  // For wide types (TON, struct instances) the PLC clamps the read to 4
  // bytes — accept what arrived and parse the slice as raw bytes. For
  // known scalar types we still require the declared size to be present.
  // STRING / BYTE_STRING / WSTRING are intentionally NOT in this set: the
  // PLC truncates wide STRING reads, and the parser must gracefully decode
  // whatever bytes arrive even when zero bytes are available.
  final upper = dataType.name.toUpperCase();
  final knownScalar = kUmasKnownScalars.contains(upper);
  final isStringy = _isStringyName(upper);

  if (offset + declared > bytes.length) {
    if (isStringy) {
      // Never throw for STRING-family: clamp `needed` to the available
      // bytes (possibly zero) and let the STRING branch decode an empty
      // or short slice gracefully. JOB-A: a defensive belt-and-braces
      // path for the case where a prior iteration in parseReadAllResponse
      // already advanced `offset` past `bytes.length`.
    } else if (knownScalar || available < 0) {
      throw UmasException(
        errorCode: 0,
        message: 'Buffer underflow: need $declared bytes at offset $offset, '
            'but buffer is ${bytes.length} bytes',
      );
    }
  }

  // Clamp `needed` so it never goes negative and never overruns the buffer,
  // regardless of how `offset` and `declared` line up.
  int needed;
  if (isStringy) {
    needed = available < 0 ? 0 : (declared < available ? declared : available);
  } else {
    needed = (offset + declared > bytes.length) ? available : declared;
  }
  final sliceStart = offset < 0 ? 0 : (offset > bytes.length ? bytes.length : offset);
  final sliceEnd = sliceStart + (needed < 0 ? 0 : needed);
  final clampedEnd = sliceEnd > bytes.length ? bytes.length : sliceEnd;
  final slice = bytes.sublist(sliceStart, clampedEnd);
  final bd = ByteData.sublistView(bytes);
  dynamic value;

  switch (upper) {
    case 'BOOL':
    case 'EBOOL':
      value = bytes[offset] != 0;
    case 'INT':
      value = bd.getInt16(offset, Endian.little);
    case 'UINT':
    case 'WORD':
      value = bd.getUint16(offset, Endian.little);
    case 'DINT':
      value = bd.getInt32(offset, Endian.little);
    case 'TIME':
    case 'UDINT':
    case 'DWORD':
      value = bd.getUint32(offset, Endian.little);
    case 'REAL':
      value = bd.getFloat32(offset, Endian.little);
    case 'LREAL':
      value = bd.getFloat64(offset, Endian.little);
    case 'LINT':
      value = bd.getInt64(offset, Endian.little);
    case 'ULINT':
      value = bd.getUint64(offset, Endian.little);
    case 'BYTE':
      value = bytes[offset];
    case 'STRING':
    case 'BYTE_STRING':
    case 'WSTRING':
      // T-05-06: Cap string read length. JOB-A: also defensively guard
      // against malformed UTF-8 — the PLC's clamped slice can land
      // mid-codepoint, and a hard utf8.decode throw would re-surface
      // as "Buffer underflow"-adjacent garbage in the UI.
      final available0 = slice.length;
      final maxRead =
          available0 > _maxStringByteSize ? _maxStringByteSize : available0;
      final stringBytes = slice.sublist(0, maxRead);
      // Find null terminator
      int nullPos = stringBytes.indexOf(0x00);
      if (nullPos < 0) nullPos = maxRead;
      value = (decodeString ?? _defaultUmasStringDecode)(
          stringBytes.sublist(0, nullPos));
    default:
      // Unknown type: return raw bytes
      value = slice;
  }

  return TypedVariableValue(
    value: value,
    typeName: dataType.name,
    rawBytes: slice,
  );
}

/// Parse multiple variable values from a concatenated byte buffer.
///
/// Walks [rawBytes] sequentially, parsing each variable according to its
/// type's [UmasDataTypeRef.byteSize].
///
/// Throws [UmasException] if:
/// - [types] list exceeds 255 entries (T-05-05 cap)
/// - Total expected bytes exceed [rawBytes] length (T-05-05 validation)
/// [decodeString] is threaded straight through to [parseVariableValue] and
/// defaults the same way: absent means today's behaviour, exactly.
List<TypedVariableValue> parseVariableValues(
    Uint8List rawBytes, List<UmasDataTypeRef> types,
    {UmasStringDecoder? decodeString}) {
  // T-05-05: Cap types list to max variableCount byte (255)
  if (types.length > 255) {
    throw UmasException(
      errorCode: 0,
      message: 'Too many types: ${types.length} exceeds max 255',
    );
  }

  // T-05-05: Validate total expected bytes fit in buffer.
  // Wide types (TON, struct instances) are clamped to 4 bytes per the PLC's
  // dataSizeIndex range, so use the on-wire size (max 4) for the bound
  // check rather than the declared byteSize. STRING / BYTE_STRING / WSTRING
  // are intentionally excluded from the bound check (CRIT-1): the M580 may
  // return as little as 1 byte for empty / narrow STRING reads through the
  // 0x22 path, well below the 4-byte ceiling above. parseVariableValue's
  // graceful slice path handles the under-read.
  bool isStringy(String n) {
    final u = n.toUpperCase();
    return u == 'STRING' || u == 'BYTE_STRING' || u == 'WSTRING';
  }

  int totalExpected = 0;
  for (final type in types) {
    if (isStringy(type.name)) continue;
    totalExpected += umasOnWireSize(type, rawBytes.length);
  }
  if (totalExpected > rawBytes.length) {
    throw UmasException(
      errorCode: 0,
      message: 'Buffer underflow: need $totalExpected bytes '
          'but buffer is ${rawBytes.length} bytes',
    );
  }

  final results = <TypedVariableValue>[];
  int offset = 0;
  for (final type in types) {
    results.add(
        parseVariableValue(rawBytes, offset, type, decodeString: decodeString));
    // Advance by exactly what the reader consumed -- see [umasOnWireSize].
    offset += umasOnWireSize(type, rawBytes.length - offset);
  }
  return results;
}

/// Encode a Dart value to raw bytes matching the given UMAS [dataType].
///
/// Supports: BOOL, EBOOL, INT, UINT, WORD, DINT, UDINT, DWORD, TIME, REAL,
/// LREAL, LINT, ULINT, BYTE, DATE, TIME_OF_DAY, DATE_AND_TIME, STRING,
/// WSTRING, BYTE_STRING.
///
/// Throws [UmasException] for:
///   - Unknown types (T-06-07 mitigation).
///   - Type mismatches (e.g. passing a String to an INT field).
///   - Out-of-range integer values (TD-006 v1.1.x): writing 100000 to an
///     INT silently wrapped to -31072 via setInt16 truncation before.
///     We now refuse with a precise message that names the supplied
///     value, the target type, and its [min..max] range.
///   - Oversize STRING / WSTRING / BYTE_STRING (TD-001).
Uint8List encodeVariableValue(dynamic value, UmasDataTypeRef dataType) {
  // TD-006 (v1.1.x): pre-flight range guard for integer types. Industrial
  // control silent-truncation hazard — Dart's `setIntN` wraps via bit
  // masking without raising, so a setpoint of 100000 to an INT silently
  // becomes -31072. Refuse instead and surface a precise operator-
  // facing message.
  void checkRange(String typeName, int v, int min, int max) {
    if (v < min || v > max) {
      throw UmasException(
        errorCode: 0,
        message: 'Value $v exceeds range of $typeName [$min..$max]',
      );
    }
  }

  switch (dataType.name.toUpperCase()) {
    case 'BOOL':
    case 'EBOOL':
      // TD-002: EBOOL (id=25) parses as 1-byte bool on the read side
      // (parseVariableValue maps both BOOL and EBOOL to `bytes[offset]
      // != 0`). Mirror that on the write side — same 1-byte 0x00/0x01.
      if (value is! bool) {
        throw UmasException(
          errorCode: 0,
          message: 'Expected bool for ${dataType.name}, got ${value.runtimeType}',
        );
      }
      return Uint8List.fromList([value ? 1 : 0]);

    case 'INT':
      if (value is! int) {
        throw UmasException(
          errorCode: 0,
          message: 'Expected int for ${dataType.name}, got ${value.runtimeType}',
        );
      }
      checkRange('INT', value, -0x8000, 0x7FFF);
      final bytes = Uint8List(2);
      ByteData.sublistView(bytes).setInt16(0, value, Endian.little);
      return bytes;

    case 'UINT':
    case 'WORD':
      if (value is! int) {
        throw UmasException(
          errorCode: 0,
          message: 'Expected int for ${dataType.name}, got ${value.runtimeType}',
        );
      }
      checkRange(dataType.name.toUpperCase(), value, 0, 0xFFFF);
      final bytes = Uint8List(2);
      ByteData.sublistView(bytes).setUint16(0, value, Endian.little);
      return bytes;

    case 'DINT':
      if (value is! int) {
        throw UmasException(
          errorCode: 0,
          message: 'Expected int for ${dataType.name}, got ${value.runtimeType}',
        );
      }
      checkRange('DINT', value, -0x80000000, 0x7FFFFFFF);
      final bytes = Uint8List(4);
      ByteData.sublistView(bytes).setInt32(0, value, Endian.little);
      return bytes;

    case 'UDINT':
    case 'DWORD':
    case 'TIME':
      // TIME is the IEC 61131 elapsed-time-in-ms type, 4-byte unsigned.
      if (value is! int) {
        throw UmasException(
          errorCode: 0,
          message: 'Expected int for ${dataType.name}, got ${value.runtimeType}',
        );
      }
      checkRange(dataType.name.toUpperCase(), value, 0, 0xFFFFFFFF);
      final bytes = Uint8List(4);
      ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
      return bytes;

    case 'DATE':
    case 'TIME_OF_DAY':
      // TD-002: DATE / TIME_OF_DAY are 4-byte unsigned IEC types.
      // DATE encodes days-since-epoch (PLC-defined epoch); TIME_OF_DAY
      // encodes ms-since-midnight. Operators write an integer matching
      // the wire format — the same encoding as UDINT. parseVariableValue
      // currently returns these as raw bytes (no high-level decoder), so
      // mirror the write side at the UDINT level.
      if (value is! int) {
        throw UmasException(
          errorCode: 0,
          message: 'Expected int for ${dataType.name}, got ${value.runtimeType}',
        );
      }
      checkRange(dataType.name.toUpperCase(), value, 0, 0xFFFFFFFF);
      final bytes = Uint8List(4);
      ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
      return bytes;

    case 'REAL':
      if (value is! num) {
        throw UmasException(
          errorCode: 0,
          message: 'Expected num for ${dataType.name}, got ${value.runtimeType}',
        );
      }
      final bytes = Uint8List(4);
      ByteData.sublistView(bytes).setFloat32(0, value.toDouble(), Endian.little);
      return bytes;

    case 'LREAL':
      if (value is! num) {
        throw UmasException(
          errorCode: 0,
          message: 'Expected num for ${dataType.name}, got ${value.runtimeType}',
        );
      }
      final bytes = Uint8List(8);
      ByteData.sublistView(bytes).setFloat64(0, value.toDouble(), Endian.little);
      return bytes;

    case 'LINT':
      if (value is! int) {
        throw UmasException(
          errorCode: 0,
          message: 'Expected int for ${dataType.name}, got ${value.runtimeType}',
        );
      }
      // No range check, and there is nothing to check: a Dart int on the VM
      // IS the LINT range, so the bound could never be crossed. It used to be
      // written out anyway, to state the contract — but `0x7FFFFFFFFFFFFFFF`
      // is not representable in JavaScript, and dart2js rejects the literal at
      // compile time, so the always-true assertion was the one thing in this
      // file stopping the web build. The contract is stated here instead,
      // where it costs nothing: LINT is [-2^63, 2^63-1], which is exactly
      // what `setInt64` accepts below.
      final bytes = Uint8List(8);
      ByteData.sublistView(bytes).setInt64(0, value, Endian.little);
      return bytes;

    case 'ULINT':
      if (value is! int) {
        throw UmasException(
          errorCode: 0,
          message: 'Expected int for ${dataType.name}, got ${value.runtimeType}',
        );
      }
      // Dart 64-bit int max is 2^63-1 — values above that cannot be
      // expressed in a Dart int literal. The wire ULINT can hold up to
      // 2^64-1, so accept any non-negative Dart int. setUint64 reads the
      // bottom 64 bits, so negatives would wrap silently — refuse them
      // explicitly.
      if (value < 0) {
        throw UmasException(
          errorCode: 0,
          message: 'Value $value exceeds range of ULINT '
              '[0..2^64-1] (negative)',
        );
      }
      final bytes = Uint8List(8);
      ByteData.sublistView(bytes).setUint64(0, value, Endian.little);
      return bytes;

    case 'DATE_AND_TIME':
      // TD-002: DATE_AND_TIME (id=16) is 8 bytes. Schneider stores it as
      // a packed timestamp; without a high-level decoder on the read
      // side, mirror as raw 64-bit unsigned. Operator-supplied int is
      // emitted as setUint64 LE.
      if (value is! int) {
        throw UmasException(
          errorCode: 0,
          message: 'Expected int for ${dataType.name}, got ${value.runtimeType}',
        );
      }
      if (value < 0) {
        throw UmasException(
          errorCode: 0,
          message: 'Value $value exceeds range of DATE_AND_TIME '
              '[0..2^64-1] (negative)',
        );
      }
      final dtBytes = Uint8List(8);
      ByteData.sublistView(dtBytes).setUint64(0, value, Endian.little);
      return dtBytes;

    case 'BYTE':
      if (value is! int) {
        throw UmasException(
          errorCode: 0,
          message: 'Expected int for ${dataType.name}, got ${value.runtimeType}',
        );
      }
      checkRange('BYTE', value, 0, 0xFF);
      return Uint8List.fromList([value]);

    case 'STRING':
    case 'WSTRING':
    case 'BYTE_STRING':
      if (value is! String) {
        throw UmasException(
          errorCode: 0,
          message: 'Expected String for ${dataType.name}, got ${value.runtimeType}',
        );
      }
      // TD-001 (v1.1.x): the encoder produces exactly `dataType.byteSize`
      // bytes on the wire — that's the declared wire-size resolved from
      // DD02 (so a `STRING(20)` carries `byteSize=22`, NOT the built-in
      // 256). The read path is null-terminated (see [parseVariableValue]
      // STRING branch), so the encoded payload reserves the LAST byte for
      // the null terminator: max writable length = `byteSize - 1`.
      //
      // Refuse oversized values with an explicit error instead of silently
      // truncating — clobbering the trailing PLC memory under a real
      // M580 would corrupt whatever variable lives at the next address.
      final encoded = utf8.encode(value);
      final wireSize = dataType.byteSize;
      if (wireSize <= 0) {
        throw UmasException(
          errorCode: 0,
          message: '${dataType.name} encode: invalid wire size ${wireSize} '
              '(symbol byteSize must be resolved before writing)',
        );
      }
      // STRING is C-style null-terminated on the M580 wire — reserve a
      // byte for the terminator. BYTE_STRING / WSTRING follow the same
      // convention in plc4j's encoder.
      final maxLen = wireSize - 1;
      if (encoded.length > maxLen) {
        throw UmasException(
          errorCode: 0,
          message: '${dataType.name} value too long: '
              '${encoded.length} bytes exceeds declared maximum '
              '$maxLen (wire size $wireSize, reserves 1 byte for '
              'null terminator). Truncating would corrupt adjacent PLC '
              'memory — refusing.',
        );
      }
      final bytes = Uint8List(wireSize);
      bytes.setRange(0, encoded.length, encoded);
      // Remaining bytes are already 0 (null padding + terminator).
      return bytes;

    default:
      throw UmasException(
        errorCode: 0,
        message: 'Unknown data type for encoding: ${dataType.name}',
      );
  }
}

/// A reference to a variable for WriteVariable (0x23) requests.
///
/// Encodes the wire format: isArray:4bits + dataSizeIndex:4bits (1 byte)
/// + block(2 LE) + baseOffset(2 LE) + offset(2 LE)
/// + [arrayLength(2 LE) if isArray] + data[dataSize * arrayLength]
class VariableWriteRef {
  final int blockNo;
  final int baseOffset;
  final int offset;
  final int dataSizeIndex;
  final bool isArray;
  final int arrayLength;

  /// The raw data bytes to write.
  final Uint8List data;

  const VariableWriteRef({
    required this.blockNo,
    required this.baseOffset,
    required this.offset,
    required this.dataSizeIndex,
    required this.data,
    this.isArray = false,
    this.arrayLength = 0,
  });

  /// Create a [VariableWriteRef] from a [UmasVariable], its resolved
  /// [UmasDataTypeRef], and the value to write.
  ///
  /// Detects array variables via [UmasDataTypeRef.classIdentifier] == 4.
  /// Uses [_arrayElementByteSize] so live-M580 DD03 self-referencing
  /// shapes for `ARRAY[..] OF <ELEM>` recover the real element width
  /// instead of clamping to the 4-byte wide read (symmetric with
  /// [VariableReadRef.fromVariable]).
  factory VariableWriteRef.fromVariable(
      UmasVariable variable, UmasDataTypeRef dataType, dynamic value) {
    final isArray = dataType.classIdentifier == 4;
    int arrayLength = 0;
    int sizeForDsi = dataType.byteSize;

    if (isArray) {
      final elementSize = _arrayElementByteSize(dataType);
      arrayLength =
          elementSize > 0 ? dataType.byteSize ~/ elementSize : 1;
      sizeForDsi = elementSize > 0 ? elementSize : dataType.byteSize;
    }

    final encodedData = encodeVariableValue(value, dataType);

    // SCHNEIDER WRITE-PATH ADDRESS SWAP (v1.1.x, M580-verified):
    //
    // For FC 0x22 (read), `baseOffset` carries the high byte of the paged
    // address and `offset` carries the low byte — same convention as
    // `VariableReadRef.fromVariable`. The mspec at
    // `umas-v1.mspec:427-434` matches this layout.
    //
    // For FC 0x23 (write), the live M580 at 192.168.112.159 *rejects*
    // the same paging order with status 0x94 ("address out of range") —
    // even though plc4j's mspec at `umas-v1.mspec:440-449` documents the
    // write reference as if the two fields had the same meaning. The
    // reference Python implementation (`plc4j-sources/UmasVariables.py`
    // lines 108-126) however *swaps* the two fields when building the
    // write reference:
    //
    //   VariableWriteRequestReference(
    //     base_offset=self.offset,     // low byte goes here
    //     offset=self.base_offset,     // high byte goes here
    //     ...)
    //
    // Switching to the swapped layout makes M580 accept the write
    // (verified end-to-end against `FB_S_F2_OrdElev.p_xHmiButton` —
    // block 0xe9, offset 0x38, BOOL — read-after-write reflects the
    // new value). This is the only difference between a write that
    // returns 0xFE 0x01 0x94 0x94 and one that lands.
    final addr = variable.offset;
    return VariableWriteRef(
      blockNo: variable.blockNo,
      baseOffset: addr & 0xFF,
      offset: addr >> 8,
      dataSizeIndex: dataSizeIndexFromByteSize(sizeForDsi),
      isArray: isArray,
      arrayLength: arrayLength,
      data: encodedData,
    );
  }

  /// Serialize to wire format bytes for the 0x23 request payload.
  ///
  /// Returns header bytes + data bytes appended.
  Uint8List toBytes() {
    final headerLength = isArray ? 9 : 7;
    final bytes = Uint8List(headerLength + data.length);
    final bd = ByteData.sublistView(bytes);

    // Byte 0: isArray(4 bits) | dataSizeIndex(4 bits)
    bytes[0] = (isArray ? 0x10 : 0x00) | (dataSizeIndex & 0x0F);

    // Block number (2 bytes LE)
    bd.setUint16(1, blockNo, Endian.little);

    // Base offset (2 bytes LE)
    bd.setUint16(3, baseOffset, Endian.little);

    // Offset (2 bytes LE)
    bd.setUint16(5, offset, Endian.little);

    // Array length (2 bytes LE) if isArray
    if (isArray) {
      bd.setUint16(7, arrayLength, Endian.little);
    }

    // Append data bytes after header
    bytes.setRange(headerLength, headerLength + data.length, data);

    return bytes;
  }
}

/// PLC memory area types for direct register access (0x24/0x25).
///
/// Area codes are best-effort based on Schneider Modbus conventions.
/// May need adjustment when verified against a real PLC.
enum RegisterType {
  coil(0x00),          // %M -- discrete memory bits
  memoryWord(0x04),    // %MW -- 16-bit memory words
  systemBit(0x06),     // %S -- system bits
  systemWord(0x07);    // %SW -- system words

  const RegisterType(this.areaCode);
  final int areaCode;
}

/// A direct register address for ReadCoilsRegisters (0x24) / WriteCoilsRegisters (0x25).
///
/// Wire format: memoryArea(1) + startAddress(2 LE) + quantity(2 LE)
/// NOTE: Wire format is UNVERIFIED (PLC4X marks as opaque bytes).
/// May need adjustment when tested against a real PLC.
class RegisterAddress {
  final RegisterType type;
  final int startAddress;
  final int quantity;

  const RegisterAddress({
    required this.type,
    required this.startAddress,
    required this.quantity,
  });

  Uint8List toBytes() {
    final bytes = Uint8List(5);
    final bd = ByteData.sublistView(bytes);
    bytes[0] = type.areaCode;
    bd.setUint16(1, startAddress, Endian.little);
    bd.setUint16(3, quantity, Endian.little);
    return bytes;
  }

  /// Expected response data size in bytes.
  /// Coils/system bits: ceil(quantity / 8) bytes (bit-packed).
  /// Words/system words: quantity * 2 bytes.
  int get expectedDataBytes {
    switch (type) {
      case RegisterType.coil:
      case RegisterType.systemBit:
        return (quantity + 7) ~/ 8;
      case RegisterType.memoryWord:
      case RegisterType.systemWord:
        return quantity * 2;
    }
  }
}

/// Result of ReadCoilsRegisters (0x24).
class CoilsRegistersResult {
  final Uint8List rawBytes;
  const CoilsRegistersResult({required this.rawBytes});
}

// ---------------------------------------------------------------------------
// Diagnostic result types (0x06, 0x20, 0x39, 0x58, 0x70, 0x73)
// ---------------------------------------------------------------------------

/// Result of ReadCardInfo (0x06) -- SD card status.
class CardInfoResult {
  final Uint8List rawData;
  const CardInfoResult({required this.rawData});

  @override
  String toString() => 'CardInfoResult(${rawData.length} bytes)';
}

/// Request payload for ReadMemoryBlock (0x20).
///
/// Wire format (9 bytes LE):
/// range(1) + blockNumber(2) + offset(2) + unknownObj(2) + numberOfBytes(2)
class ReadMemoryBlockRequest {
  final int range;
  final int blockNumber;
  final int offset;
  final int numberOfBytes;
  final int unknownObj;

  const ReadMemoryBlockRequest({
    required this.range,
    required this.blockNumber,
    required this.offset,
    required this.numberOfBytes,
    this.unknownObj = 0,
  });

  /// Serialize to 9-byte LE wire payload.
  Uint8List toBytes() {
    final bytes = Uint8List(9);
    final bd = ByteData.sublistView(bytes);
    bytes[0] = range & 0xFF;
    bd.setUint16(1, blockNumber, Endian.little);
    bd.setUint16(3, offset, Endian.little);
    bd.setUint16(5, unknownObj, Endian.little);
    bd.setUint16(7, numberOfBytes, Endian.little);
    return bytes;
  }
}

/// Result of ReadMemoryBlock (0x20).
///
/// Response format: range(1) + numberOfBytes(2 LE) + data[numberOfBytes]
class ReadMemoryBlockResult {
  final int range;
  final int numberOfBytes;
  final Uint8List data;

  const ReadMemoryBlockResult({
    required this.range,
    required this.numberOfBytes,
    required this.data,
  });

  /// Parse from response payload bytes.
  ///
  /// Validates header length (>= 3 bytes) and that numberOfBytes
  /// does not exceed available data (T-09-01 mitigation).
  factory ReadMemoryBlockResult.fromPayload(Uint8List payload) {
    if (payload.length < 3) {
      throw UmasException(
        errorCode: 0,
        message: 'ReadMemoryBlock response too short: ${payload.length} bytes',
      );
    }
    final range = payload[0];
    final bd = ByteData.sublistView(payload);
    final numBytes = bd.getUint16(1, Endian.little);

    if (3 + numBytes > payload.length) {
      throw UmasException(
        errorCode: 0,
        message: 'ReadMemoryBlock numberOfBytes ($numBytes) exceeds '
            'available data (${payload.length - 3} bytes)',
      );
    }

    return ReadMemoryBlockResult(
      range: range,
      numberOfBytes: numBytes,
      data: payload.sublist(3, 3 + numBytes),
    );
  }

  @override
  String toString() =>
      'ReadMemoryBlockResult(range=$range, ${data.length} bytes)';
}

/// Result of ReadEthMasterData (0x39) -- network topology.
class EthMasterDataResult {
  final Uint8List rawData;
  const EthMasterDataResult({required this.rawData});

  @override
  String toString() => 'EthMasterDataResult(${rawData.length} bytes)';
}

/// Result of CheckPlc (0x58) -- PLC health verification.
class CheckPlcResult {
  final Uint8List rawData;
  const CheckPlcResult({required this.rawData});

  @override
  String toString() => 'CheckPlcResult(${rawData.length} bytes)';
}

/// Result of ReadIoObject (0x70) -- I/O module data.
class IoObjectResult {
  final Uint8List rawData;
  const IoObjectResult({required this.rawData});

  @override
  String toString() => 'IoObjectResult(${rawData.length} bytes)';
}

/// Result of GetStatusModule (0x73) -- per-module status.
class StatusModuleResult {
  final Uint8List rawData;
  const StatusModuleResult({required this.rawData});

  @override
  String toString() => 'StatusModuleResult(${rawData.length} bytes)';
}

// ---------------------------------------------------------------------------
// MonitorPlc (0x50) types
// ---------------------------------------------------------------------------

/// A reference to a variable for MonitorPlc (0x50) sub-operations.
///
/// Used to build Register (0x05) and RegisterAndRead (0x09) wire payloads.
class MonitorPlcRef {
  final int variableIndex;
  final int blockNo;
  final int offset;

  const MonitorPlcRef({
    required this.variableIndex,
    required this.blockNo,
    required this.offset,
  });

  /// Create from a [UmasVariable] with a given [variableIndex].
  factory MonitorPlcRef.fromVariable(int variableIndex, UmasVariable variable) {
    return MonitorPlcRef(
      variableIndex: variableIndex,
      blockNo: variable.blockNo,
      offset: variable.offset,
    );
  }

  /// Serialize to Register (0x05) sub-operation wire format (7 bytes).
  ///
  /// Per PLC4X mspec, every MonitorPlcSubOperation in the array begins with
  /// its own operationType discriminator byte, even when it duplicates the
  /// outer subCommand. Format:
  ///   operationType(0x05) + variableIndex(1) + block(2 LE) + offset(2 LE)
  ///                       + action(1)
  /// Action: 0x02 = register, 0x01 = deregister.
  Uint8List toRegisterBytes({bool register = true}) {
    final bytes = Uint8List(7);
    final bd = ByteData.sublistView(bytes);
    bytes[0] = 0x05;
    bytes[1] = variableIndex & 0xFF;
    bd.setUint16(2, blockNo, Endian.little);
    bd.setUint16(4, offset, Endian.little);
    bytes[6] = register ? 0x02 : 0x01;
    return bytes;
  }

  /// Serialize to RegisterAndRead (0x09) sub-operation wire format (6 bytes).
  ///
  /// Per PLC4X mspec, every MonitorPlcSubOperation begins with its own
  /// operationType discriminator byte. Format:
  ///   operationType(0x09) + variableIndex(1) + block(2 LE) + offset(2 LE)
  Uint8List toRegisterAndReadBytes() {
    final bytes = Uint8List(6);
    final bd = ByteData.sublistView(bytes);
    bytes[0] = 0x09;
    bytes[1] = variableIndex & 0xFF;
    bd.setUint16(2, blockNo, Endian.little);
    bd.setUint16(4, offset, Endian.little);
    return bytes;
  }
}

/// Client-side registration table for MonitorPlc (0x50).
///
/// Maps variable indices to their data types so that the concatenated
/// ReadAll (0x07) response bytes can be parsed into typed values.
/// Variable index is 1 byte, so max registrations is 255 (T-08-01).
class MonitorPlcRegistrationTable {
  /// Maximum number of registrations (variableIndex is 1 byte).
  static const maxRegistrations = 255;

  final Map<int, UmasDataTypeRef> _types = {};

  /// Auto-incrementing counter for assigning variable indices.
  int _nextIndex = 0;

  /// TD-020 (v1.1.x): cached sort of [_types.keys]. Recomputed lazily
  /// from a dirty flag on next read after any register/deregister/
  /// reset. parseReadAllResponse runs every poll cycle once B-4 ships
  /// (sub-second cadence with up to 255 entries); doing the O(N log N)
  /// sort each call was wasted CPU.
  List<int>? _sortedIndicesCache;

  /// Register a variable index with its data type.
  void register(int variableIndex, UmasDataTypeRef type) {
    if (_types.length >= maxRegistrations && !_types.containsKey(variableIndex)) {
      throw UmasException(
        errorCode: 0,
        message: 'MonitorPlc registration table full (max $maxRegistrations)',
      );
    }
    _types[variableIndex] = type;
    if (variableIndex >= _nextIndex) {
      _nextIndex = variableIndex + 1;
    }
    _sortedIndicesCache = null; // invalidate
  }

  /// Remove a variable index registration.
  void deregister(int variableIndex) {
    final removed = _types.remove(variableIndex);
    if (removed != null) {
      _sortedIndicesCache = null; // invalidate
    }
  }

  /// Clear all registrations.
  void reset() {
    _types.clear();
    _nextIndex = 0;
    _sortedIndicesCache = null; // invalidate
  }

  /// Get the data type for a registered variable index.
  UmasDataTypeRef? getType(int variableIndex) => _types[variableIndex];

  /// All registered variable indices, sorted ascending.
  ///
  /// TD-020 (v1.1.x): result is memoized between mutation calls.
  /// Mutators (register / deregister / reset) clear the cache.
  List<int> get registeredIndices {
    return _sortedIndicesCache ??= (_types.keys.toList()..sort());
  }

  /// Whether the table has no registrations.
  bool get isEmpty => _types.isEmpty;

  /// The next auto-assigned variable index.
  int get nextIndex => _nextIndex;

  /// Allocate the next variable index and return it.
  int allocateIndex() {
    final idx = _nextIndex;
    _nextIndex++;
    return idx;
  }

  /// Parse a ReadAll (0x07) response by walking bytes in registration order.
  ///
  /// Iterates sorted registered indices, parsing each variable's bytes
  /// using [parseVariableValue]. Throws [UmasException] on buffer underflow
  /// for fixed-size scalars; STRING-family values decode gracefully even
  /// from a zero-byte slice (JOB-A v1.1: see parseVariableValue comments).
  /// [decodeString] is threaded to [parseVariableValue] for the same reason
  /// the ReadVariable path threads it: this is the *other* road a STRING takes
  /// out of a PLC (MonitorPlc, 0x50, which the M580 prefers), and a decoder
  /// wired into only one of the two is a per-server encoding that works until
  /// somebody's controller picks the other path.
  List<TypedVariableValue> parseReadAllResponse(Uint8List rawBytes,
      {UmasStringDecoder? decodeString}) {
    final indices = registeredIndices;
    if (indices.isEmpty) return [];

    final results = <TypedVariableValue>[];
    int offset = 0;

    for (final idx in indices) {
      final type = _types[idx]!;
      results.add(parseVariableValue(rawBytes, offset, type,
          decodeString: decodeString));
      // Advance by exactly what the reader consumed. [umasOnWireSize] also
      // clamps STRING-family at the remaining bytes, so a PLC that returned
      // fewer-than-clamped bytes (e.g. 1 byte for an empty STRING via 0x22,
      // or none at all) cannot push `offset` past the end.
      offset += umasOnWireSize(type, rawBytes.length - offset);
    }

    return results;
  }
}
