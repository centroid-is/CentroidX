/// What a protocol's answer to a write *means*, as pure functions.
///
/// Moved down from `tfc_relay_local/lib/src/write_translation.dart` in Phase 12
/// so `tfc_dart` — which cannot depend on `tfc_relay_local` — holds the single
/// source of truth for the three-state write classifier. relay_local re-exports
/// these symbols so its own call sites keep compiling.
///
/// ## The rule this whole file implements
///
/// **Unknown is the safe default and rejected is the claim that needs
/// evidence.** "Rejected" tells an operator it is safe to press the button
/// again; a rejected that was actually applied is a second start command on a
/// machine somebody is standing next to. So `WriteRejected` is produced only
/// where a device *named* a refusal, and everything else — a timeout, a
/// channel loss, a status code with no ruling behind it, a sentence nobody
/// has taught this file to read — is [WriteUnknown].
///
/// The three states already exist as a sealed type with no throw path
/// (`write_result.dart`), and `state_man_api.dart:118-122` names the two
/// shipped lines this file is here to replace: `StateMan.write`'s
/// `Future<void>` that throws (`state_man.dart:2042-2044`) and
/// `M2400DeviceClientAdapter.write`'s `UnsupportedError` (`:1266-1268`) — a
/// read-only device answering with an exception where the honest answer is a
/// refusal.
///
/// ## Why pure functions over a descriptor, and not methods on the links
///
/// A function that takes what the protocol handed back — a status code, an
/// exception, a timeout marker — and returns a `WriteResult` is testable with
/// no device at all, which is what makes fifteen arms affordable. The adapters
/// in 08-07 and 08-10 describe what happened and ask this file what it means;
/// none of them decides for itself.
///
/// ## Which branch of 08-01 this took: the STRING FALLBACK (assumption A3)
///
/// 08-01 task 1(d) — a numeric StatusCode on the write error path — **did not
/// land**, and deliberately: `client.dart:485-494` completes the write
/// completer with a formatted `String`, and `isolate.dart` marshals every
/// error across the port as `e.toString()` (`:1078`, `:1124`, `:969`), so a
/// typed exception under `useIsolate: true` would be flattened straight back
/// to a String. Both branches are therefore implemented here:
///
///  * [WriteStatusAnswer] translates on the **code**, which is what the
///    adapters should hand over the day the binding carries one; and
///  * [WriteErrorText] parses the formatted string against a small table of
///    known code names, and **every unparsed string is unknown** — never
///    rejected. That is assumption A3's cost, and it is the safe half of it:
///    noisy, not dangerous.
///
/// ## No retry lives here and none can
///
/// These functions map one answer to one outcome. They have no reference to a
/// link, so a retry cannot be written inside them, and the package's single
/// upstream write call site is pinned by `freeze_test.dart`'s freeze 4.
///
/// ## The redaction helper is inlined (Phase 12 move)
///
/// The classifier redacts upstream error prose before it becomes a plant-
/// visible `WriteReason.message` (threat T-08-08). The relay_local original
/// imported `redactUpstreamError` from its `upstream_link.dart`; importing that
/// here would be an illegal UPWARD edge (tfc_dart must not depend on
/// tfc_relay_local). It is therefore inlined below as [_redactUpstreamError].
/// relay_local keeps its own copy for its link/lastError paths; the two must
/// stay in step (see the SUMMARY's deviation note).
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// Which protocol answered. The translation differs between them in exactly
/// one respect — how much an error is evidence of a *refusal* — so the split
/// is an argument rather than a code layout.
enum UpstreamProtocol {
  /// OPC UA. A Bad code may be raised by the service layer *after* the node
  /// was written, so only a named refusal is evidence of one.
  opcUa,

  /// Classic Modbus. An exception PDU is a reply: the slave parsed the request
  /// and declined it, and there is no service layer above the write that could
  /// fail after the register moved.
  modbus,

  /// UMAS by name, over the same transport, with typed exception codes.
  umas,

  /// The M2400 weigher protocol, which has no write at all.
  m2400,
}

/// What a protocol handed back for one write attempt.
///
/// Sealed so [translateWriteAnswer]'s switch is exhaustive: a new way for a
/// write to end is a compile error at the one place that decides what it means
/// to an operator.
sealed class WriteAnswer {
  const WriteAnswer();
}

/// The device acknowledged: OPC UA `Good`, a Modbus function-code echo, a UMAS
/// ack.
final class WriteAcknowledged extends WriteAnswer {
  const WriteAcknowledged({this.readback, this.at});

  /// What the device read back. "Applied" means applied *and* read back —
  /// readback is the only confirmation this system accepts (CLAUDE.md).
  final Object? readback;

  /// When, in epoch milliseconds. Null lets the translator stamp it; an
  /// adapter that knows the device's own instant should pass it.
  final int? at;
}

/// A numeric status: an OPC UA `StatusCode`, a Modbus exception code, a typed
/// UMAS code.
final class WriteStatusAnswer extends WriteAnswer {
  const WriteStatusAnswer(this.code, {this.text});

  final int code;

  /// Any accompanying prose, which is redacted before it becomes a reason.
  final String? text;
}

/// The only thing the protocol gave back is prose — 08-01's fallback branch.
final class WriteErrorText extends WriteAnswer {
  const WriteErrorText(this.text);

  final String text;
}

/// The deadline expired.
///
/// [requestSent] is recorded for diagnostics and **changes no outcome**: a
/// deadline that expired with the request on the wire and one that expired
/// before the link was reachable are both unknown, because the gateway cannot
/// tell them apart and must not guess.
final class WriteDeadlineExpired extends WriteAnswer {
  const WriteDeadlineExpired({this.requestSent = true});

  final bool requestSent;
}

/// The attempt threw: a channel loss, a socket error, an untyped exception.
final class WriteThrew extends WriteAnswer {
  const WriteThrew(this.error);

  final Object error;
}

/// OPC UA `Good`.
const int opcUaStatusGood = 0;

/// The OPC UA status codes that are evidence of a **refusal**.
///
/// Deliberately short. Each of these is the server saying "I will not do this
/// to this node", which is a fact about the request rather than about the
/// session — so re-sending it will fail the same way, and telling the operator
/// they may try again costs nothing. Every other Bad code stays unknown; see
/// the library doc.
const Map<int, String> opcUaWriteRefusals = <int, String>{
  0x801F0000: 'Bad_UserAccessDenied',
  0x803C0000: 'Bad_OutOfRange',
  0x80740000: 'Bad_TypeMismatch',
  0x803B0000: 'Bad_NotWritable',
  0x80340000: 'Bad_NodeIdUnknown',
};

/// The Modbus exception codes with names. An unnamed one is still a refusal —
/// see [UpstreamProtocol.modbus].
const Map<int, String> modbusExceptions = <int, String>{
  0x01: 'Modbus_IllegalFunction',
  0x02: 'Modbus_IllegalDataAddress',
  0x03: 'Modbus_IllegalDataValue',
  0x04: 'Modbus_ServerDeviceFailure',
  0x05: 'Modbus_Acknowledge',
  0x06: 'Modbus_ServerDeviceBusy',
  0x08: 'Modbus_MemoryParityError',
  0x0A: 'Modbus_GatewayPathUnavailable',
  0x0B: 'Modbus_GatewayTargetFailedToRespond',
};

/// The refusal an M2400 gives, in `cert_health_state_man.dart:411-424`'s exact
/// shape.
///
/// One spelling for every read-only answer in the gateway: an operator reading
/// two different refusals from two layers of one process learns nothing from
/// the difference.
const WriteReason notWritableReason = WriteReason(
  'not_writable',
  message: 'this device does not accept writes',
  status: 'Bad_NotWritable',
);

/// Translates one protocol answer into one of the three states.
///
/// Pure: no clock beyond the applied stamp, no link, no I/O. See the library
/// doc for the rule it implements.
WriteResult translateWriteAnswer({
  required UpstreamProtocol protocol,
  required String cmd,
  required WriteAnswer answer,
}) {
  // The M2400 short-circuit comes FIRST and takes precedence over every other
  // shape, including an acknowledgement: a device with no write service cannot
  // have applied one, so an "ack" from that direction is a bug in an adapter
  // and not news about a plant.
  if (protocol == UpstreamProtocol.m2400) {
    return WriteRejected(cmd, notWritableReason,
        at: DateTime.now().millisecondsSinceEpoch);
  }

  switch (answer) {
    case WriteAcknowledged(readback: final readback, at: final at):
      return WriteApplied(cmd,
          readback: readback,
          at: at ?? DateTime.now().millisecondsSinceEpoch);

    case WriteStatusAnswer(code: final code, text: final text):
      return _fromCode(protocol: protocol, cmd: cmd, code: code, text: text);

    case WriteErrorText(text: final text):
      return _fromText(protocol: protocol, cmd: cmd, text: text);

    case WriteDeadlineExpired(requestSent: final sent):
      // Both halves are unknown and the flag only says which story to tell.
      return WriteUnknown(
        cmd,
        WriteReason('plc_timeout',
            message: sent
                ? 'the deadline passed with the request on the wire — read the '
                    'value back before acting'
                : 'the deadline passed before the link answered at all. This '
                    'side cannot tell that from a request that landed, so it '
                    'does not guess'),
      );

    case WriteThrew(error: final error):
      return WriteUnknown(
        cmd,
        WriteReason('link_lost',
            message: _redactUpstreamError(error.toString()),
            status: null),
      );
  }
}

WriteResult _fromCode({
  required UpstreamProtocol protocol,
  required String cmd,
  required int code,
  required String? text,
}) {
  final message = _redactUpstreamError(text);
  switch (protocol) {
    case UpstreamProtocol.opcUa:
      if (code == opcUaStatusGood) {
        return WriteApplied(cmd,
            readback: null, at: DateTime.now().millisecondsSinceEpoch);
      }
      final named = opcUaWriteRefusals[code];
      if (named != null) {
        return WriteRejected(
          cmd,
          WriteReason('device_refused', message: message, status: named),
          at: DateTime.now().millisecondsSinceEpoch,
        );
      }
      // The whole point of the short table above: an unruled Bad code is not
      // evidence of a refusal, and this side has no way to establish whether
      // the node moved before the service gave up.
      return WriteUnknown(
        cmd,
        WriteReason('unruled_status',
            message: message ??
                'the server answered with a status this gateway has no ruling '
                    'for. Read the value back before acting',
            status: '0x${code.toRadixString(16)}'),
      );

    case UpstreamProtocol.modbus:
      if (code == 0) {
        return WriteApplied(cmd,
            readback: null, at: DateTime.now().millisecondsSinceEpoch);
      }
      return WriteRejected(
        cmd,
        WriteReason('device_refused',
            message: message,
            status: modbusExceptions[code] ??
                'Modbus_Exception_0x${code.toRadixString(16)}'),
        at: DateTime.now().millisecondsSinceEpoch,
      );

    case UpstreamProtocol.umas:
      if (code == 0) {
        return WriteApplied(cmd,
            readback: null, at: DateTime.now().millisecondsSinceEpoch);
      }
      // A typed UMAS code is the device declining by name, the same as a
      // Modbus exception PDU — the adapter wraps both directions symmetrically
      // (`state_man.dart:2005-2018`) and that symmetry must not change.
      return WriteRejected(
        cmd,
        WriteReason('device_refused',
            message: message,
            status: 'Umas_0x${code.toRadixString(16).padLeft(2, '0')}'),
        at: DateTime.now().millisecondsSinceEpoch,
      );

    case UpstreamProtocol.m2400:
      // Unreachable: handled at the top of [translateWriteAnswer].
      return WriteRejected(cmd, notWritableReason);
  }
}

/// The code names this file can find inside a formatted error string.
///
/// Two spellings each, because both appear in the shipped code: the binding
/// formats `BadNotWritable` and the cert overlay writes `Bad_NotWritable`.
/// They are one code and must translate to one status.
final Map<RegExp, String> _textualRefusals = <RegExp, String>{
  for (final name in opcUaWriteRefusals.values)
    RegExp(name.replaceAll('_', '_?'), caseSensitive: false): name,
};

WriteResult _fromText({
  required UpstreamProtocol protocol,
  required String cmd,
  required String text,
}) {
  final message = _redactUpstreamError(text);
  for (final entry in _textualRefusals.entries) {
    if (entry.key.hasMatch(text)) {
      return WriteRejected(
        cmd,
        WriteReason('device_refused', message: message, status: entry.value),
        at: DateTime.now().millisecondsSinceEpoch,
      );
    }
  }
  // Assumption A3, and the safe half of it. A sentence this file cannot read
  // is not evidence of a refusal — and "rejected" is the one answer that
  // invites a second press of the button.
  return WriteUnknown(
    cmd,
    WriteReason('unparsed_upstream_error',
        message: message ??
            'the upstream answered with something this gateway cannot read as '
                'a refusal. Read the value back before acting'),
  );
}

/// Forces `writeStatus`'s positional promise: element *i* answers `cmds[i]`.
///
/// A mismatched entry is substituted **in place** as
/// `WriteUnknown(misaligned_result)` and everything after it keeps its own
/// answer. It is never shifted, and the difference is not cosmetic: a shifted
/// list tells an operator about a different machine, confidently and in the
/// right shape. A short list is padded the same way rather than truncating the
/// question.
///
/// Written as a pure function over both lists so the guard is testable with a
/// deliberately misaligned input — a defence that can only be exercised
/// through the thing it defends is a defence nobody has seen work.
List<WriteResult> alignWriteStatusAnswers(
  List<String> cmds,
  List<WriteResult> answers,
) =>
    <WriteResult>[
      for (var i = 0; i < cmds.length; i++)
        if (i < answers.length && answers[i].cmd == cmds[i])
          answers[i]
        else
          WriteUnknown(
            cmds[i],
            const WriteReason('misaligned_result',
                message: 'the answer in this position was for a different '
                    'command, so this one\'s outcome is not established. Read '
                    'the value back before acting'),
          ),
    ];

/// The array-element ruling: refuse a compare-and-set-less element write.
///
/// Returns the refusal, or **null** when the write may proceed.
///
/// `state_man.dart:2033-2039` reads the whole array, replaces one element and
/// writes it back — with the author's own "not sure I like this" comment on
/// it. The read and the write are not atomic, so a concurrent change between
/// them is silently overwritten. On a gateway serving thirty panels that is a
/// race somebody meets, not a theoretical one, and the thing it destroys is
/// another operator's setpoint.
///
/// So an array-element write without an `expect` is refused **by name**. With
/// an `expect` present the read-modify-write may run, with the comparison as
/// its guard. A named refusal is a page-editor bug report; a silent overwrite
/// is a plant incident, and this project exists to prevent the second one.
WriteResult? guardArrayElementWrite({
  required String cmd,
  required bool hasExpect,
}) {
  if (hasExpect) return null;
  return WriteRejected(
    cmd,
    const WriteReason(
      'array_element_requires_expect',
      message: 'writing one element of an array is a read-modify-write on this '
          'protocol and is not atomic. Pass expect (compare-and-set) so a '
          'concurrent change is refused rather than overwritten',
    ),
    at: DateTime.now().millisecondsSinceEpoch,
  );
}

// --------------------------------------------------------------- redaction
//
// Inlined from tfc_relay_local's `upstream_link.dart` during the Phase 12 move
// (see the library doc). Kept behaviour-verbatim with that copy; the two must
// stay in step. It strips credentials, endpoints and filesystem paths out of an
// upstream error before it can become a plant-visible `WriteReason.message`
// (threat T-08-08). Deliberately over-broad: redacting a version string that
// looks like an address costs a diagnostic detail; missing a password costs a
// credential.

/// How much of an upstream error survives redaction.
const int _maxRedactedErrorLength = 200;

String? _redactUpstreamError(String? raw) {
  if (raw == null) return null;
  var out = raw;

  // Any scheme://… — this is the one that carries userinfo, so it goes first
  // and takes the credentials with it.
  out = out.replaceAll(
      RegExp(r'\b[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s,;)"' "'" r']+'), '<endpoint>');

  // Windows paths (certificate stores, key files).
  out = out.replaceAll(
      RegExp(r'[a-zA-Z]:\\[^\s,;)"' "'" r']*'), '<path>');

  // Absolute POSIX paths. Two segments minimum, so ordinary prose containing
  // "and/or" survives and "/etc/ssl/private/client.pem" does not.
  out = out.replaceAll(
      RegExp(r'/(?:[A-Za-z0-9._@\-]+/)+[A-Za-z0-9._@\-]*'), '<path>');

  // key=value credentials that never had a scheme in front of them.
  out = out.replaceAllMapped(
      RegExp(
          r'\b(user|username|uid|login|password|passwd|pwd|token|secret|api[_-]?key)'
          r'\s*[=:]\s*\S+',
          caseSensitive: false),
      (m) => '${m[1]}=<redacted>');

  // The shapes `dart:io` writes a peer in: `address = <token>`,
  // `host = <token>`. This one comes BEFORE the literal patterns below because
  // it is the only one that can catch a DNS hostname.
  out = out.replaceAllMapped(
      RegExp(r'\b(address|host|hostname|remoteAddress|peer)\s*[=:]\s*([^\s,;)]+)',
          caseSensitive: false),
      (m) => '${m[1]} = <host>');

  // Bare hosts: an IPv4 literal with an optional port.
  out = out.replaceAll(
      RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b'), '<host>');

  // IPv6 literals, bracketed form first (it carries the port inside a
  // structure the bare patterns would only half-eat).
  out = out.replaceAll(
      RegExp(r'\[[0-9A-Fa-f:]{2,}\](?::\d+)?'), '<host>');

  // Then the two bare forms. A compressed address is recognised by its `::`,
  // an uncompressed one by having at least three colons (two colons is a
  // timestamp `09:49:57`, which must survive).
  out = out.replaceAll(
      RegExp(r'(?<![\w:])[0-9A-Fa-f]{0,4}::[0-9A-Fa-f:]*[0-9A-Fa-f](?::\d+)?'),
      '<host>');
  out = out.replaceAll(
      RegExp(r'(?<![\w:])[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){3,}(?![\w:])'),
      '<host>');

  // A key value is read on a screen. An unbounded error string is also an
  // unbounded thing to fan out to every subscriber of that key.
  return out.length <= _maxRedactedErrorLength
      ? out
      : '${out.substring(0, _maxRedactedErrorLength)}…';
}
