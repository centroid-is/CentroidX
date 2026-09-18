/// The three-state write outcome — the safety-critical type in this
/// package, designed before the serialization (the RPC-layer research
/// hedge): a sealed hierarchy with NO throw on the unknown path, so client
/// code physically cannot collapse "unknown" into "failed".
///
/// JSON-RPC `error` on a write means "definitively no effect" (unauthorized,
/// malformed, unroutable) and is the ONLY retry-safe case. Everything the
/// PLC may have seen arrives here as a successful result.
library;

/// Why a write was rejected or is unknown.
final class WriteReason {
  /// Stable, greppable kind: `interlocked`, `out_of_range`, `wrong_mode`,
  /// `plc_timeout`, `link_lost`, …
  final String kind;
  final String? message;

  /// Upstream status if available (e.g. OPC UA `Bad_NotWritable`).
  final String? status;

  const WriteReason(this.kind, {this.message, this.status});

  /// Tolerant: a peer that omits `kind`, or sends it as something other than
  /// a string, still produces a reason. The alternative is a throw on the
  /// write path, and a throw there reads to the operator as "the write
  /// failed" — the one thing a malformed answer does not prove.
  factory WriteReason.fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    final message = json['message'];
    final status = json['status'];
    return WriteReason(
      kind is String && kind.isNotEmpty ? kind : unspecified,
      message: message is String ? message : null,
      status: status is String ? status : null,
    );
  }

  /// The kind used when a peer gave no usable one.
  static const String unspecified = 'unspecified';

  Map<String, Object?> toJson() => {
        'kind': kind,
        if (message != null) 'message': message,
        if (status != null) 'status': status,
      };
}

/// Result of `write` and of each entry in `writeStatus`.
sealed class WriteResult {
  /// The client-minted idempotency id (ULID), created when the operator
  /// acted — not at send time — so a re-send carries the same id.
  final String cmd;

  const WriteResult(this.cmd);

  /// Total over every payload that carries a usable [cmd]. A truncated or
  /// version-skewed answer is a write whose fate this side cannot establish,
  /// which is precisely [WriteUnknown] — decoding it must never throw, or the
  /// operator is told the write failed and re-sends it.
  factory WriteResult.fromJson(Map<String, Object?> json) {
    final cmd = json['cmd'];
    if (cmd is! String || cmd.isEmpty) {
      // No id means nothing can be reconciled through `writeStatus` later.
      // That is a protocol error, not a write outcome.
      throw FormatException('write result without a cmd: $json');
    }
    final at = json['at'];
    return switch (json['outcome']) {
      'applied' when at is num => WriteApplied(
          cmd,
          readback: json['readback'],
          at: at.toInt(),
        ),
      // "Applied" without the instant it happened at is not an audit record,
      // and half of one is not proof of application.
      'applied' =>
        WriteUnknown(cmd, const WriteReason('malformed_result:applied')),
      'rejected' => WriteRejected(
          cmd,
          _reasonOf(json['reason']),
          at: at is num ? at.toInt() : null,
        ),
      'unknown' => WriteUnknown(cmd, _reasonOf(json['reason'])),
      'not_received' => WriteNotReceived(cmd),
      // Forward compatibility: an outcome this client doesn't know is by
      // definition not proof of application — treat as unknown, never
      // throw on the write path.
      final other => WriteUnknown(cmd, WriteReason('unrecognized_outcome:$other')),
    };
  }

  /// A reason a peer omitted, or sent as something other than an object,
  /// still has to produce one — see [WriteReason.fromJson].
  static WriteReason _reasonOf(Object? raw) => raw is Map
      ? WriteReason.fromJson(raw.cast<String, Object?>())
      : const WriteReason(WriteReason.unspecified);

  /// Whether re-sending this command is definitively safe.
  ///
  /// True for [WriteNotReceived] and nothing else — an outcome the gateway
  /// could only reach with positive evidence (`write_outcome_log.dart`: the
  /// cmd is datable, was minted after the log started, is not in the future,
  /// and is still inside the dedup TTL). Every other outcome either landed at
  /// the plant or may have.
  ///
  /// It says a re-send *may be offered*, never that one should happen. No
  /// code path in this system re-sends a write by itself; re-send is always
  /// an operator decision, on this outcome as much as any other.
  ///
  /// The default is `false` so that an outcome nobody has thought about is
  /// never the one that invites a second movement of the machine.
  bool get isSafeToResend => false;

  Map<String, Object?> toJson();
}

/// The PLC applied the write and the gateway read the value back.
/// "Applied" always means "applied and read back" — the UI displays
/// [readback], never the locally-typed value.
final class WriteApplied extends WriteResult {
  final Object? readback;
  final int at;

  const WriteApplied(super.cmd, {required this.readback, required this.at});

  @override
  Map<String, Object?> toJson() =>
      {'cmd': cmd, 'outcome': 'applied', 'readback': readback, 'at': at};
}

/// The device said no (interlock, range, mode). A successful RPC carrying
/// bad news — NOT an error, NOT retry-safe by machine; show the reason.
final class WriteRejected extends WriteResult {
  final WriteReason reason;
  final int? at;

  const WriteRejected(super.cmd, this.reason, {this.at});

  @override
  Map<String, Object?> toJson() => {
        'cmd': cmd,
        'outcome': 'rejected',
        'reason': reason.toJson(),
        if (at != null) 'at': at,
      };
}

/// The gateway lost track (PLC timeout, link dropped mid-write). The write
/// may or may not have landed — surface "outcome unknown — verify" to the
/// operator; re-query via `writeStatus`; never auto-retry.
final class WriteUnknown extends WriteResult {
  final WriteReason reason;

  const WriteUnknown(super.cmd, this.reason);

  @override
  Map<String, Object?> toJson() =>
      {'cmd': cmd, 'outcome': 'unknown', 'reason': reason.toJson()};
}

/// `writeStatus` only: the gateway never received this cmd and its dedup
/// TTL has not expired — the one outcome that is definitively safe to
/// re-send (and even then, re-sending is an operator decision).
final class WriteNotReceived extends WriteResult {
  const WriteNotReceived(super.cmd);

  /// The one arm where this is true. See [WriteResult.isSafeToResend].
  @override
  bool get isSafeToResend => true;

  @override
  Map<String, Object?> toJson() => {'cmd': cmd, 'outcome': 'not_received'};
}
