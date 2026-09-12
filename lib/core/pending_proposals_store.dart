/// Keeps the operator's undecided proposals across an engine restart.
///
/// # Why this exists
///
/// On Windows the runner's GPU watchdog recovers from a lost render context by
/// destroying the `FlutterViewController` and building a new one. That is not
/// a re-render: it shuts the Dart isolate down and runs `main()` again, so
/// every object the app held is gone -- including every proposal an AI client
/// had handed the operator and the operator had not yet decided on. The
/// process is the same, its uptime is unbroken, and the banner is simply
/// empty. Operators reported "there is no proposal"; the work the proposal
/// carried had to be redone.
///
/// So the pending queue is written to the device-local preferences store on
/// every change and read back when the next isolate's
/// `ProposalStateNotifier` is built. The store is the same per-station
/// `shared_preferences` file the startup page lives in: it never goes near
/// the shared database, because a proposal is a conversation between one
/// station's operator and one client, not plant configuration.
///
/// # What is kept, and what is not
///
/// A proposal is kept as the fields the operator sees plus the raw JSON the
/// editor stages from. Its **id is not kept**: ids are minted per isolate by
/// `nextLocalProposalId()` and are only ever handles inside one process, so a
/// restored proposal gets a fresh one. Whether the operator has already
/// **viewed** it is kept, so the AI is not told "viewed" a second time by an
/// isolate that never saw the first look.
///
/// # Expiry and bound
///
/// Entries older than [pendingProposalMaxAge] are dropped on load. A proposal
/// is a live question for the shift it was raised in; a day later the client
/// that asked has long since timed out, the operator who was going to answer
/// has gone home, and the configuration it was proposed against may have
/// moved -- the MCP server already tells clients to re-read before proposing.
/// Restoring a stale one would put a plausible-looking change in front of
/// whoever is at the panel next with no context for it.
///
/// [pendingProposalLimit] and [pendingProposalMaxBytes] bound the blob so the
/// preferences file cannot grow without limit under a client that proposes
/// and never gets an answer. Both drop the oldest first.
///
/// # Failure
///
/// Nothing here throws. A corrupt or missing blob loads as "nothing pending",
/// a store that cannot be written is logged and ignored, and a decode that
/// trips over one entry skips that entry rather than the rest. This runs
/// during startup, and a startup that cannot proceed because a cache is
/// unreadable is worse than the cache being lost.
library;

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:logger/logger.dart';
import 'package:tfc_dart/core/preferences.dart';

/// The device-local preferences key holding the encoded queue.
const String pendingProposalsPrefsKey = 'pending_proposals';

/// Bumped when the encoding changes shape. A blob with another version is
/// ignored rather than guessed at.
const int pendingProposalsFormatVersion = 1;

/// How long an undecided proposal stays restorable.
const Duration pendingProposalMaxAge = Duration(hours: 24);

/// The most proposals restored. A review batch -- a page proposal with its
/// assets, or a sweep of alarms -- is a few dozen at most; this is well above
/// one sitting's worth and still bounds the blob.
const int pendingProposalLimit = 64;

/// The largest encoded blob written. Page proposals carry the whole page, so
/// a count alone does not bound the size.
const int pendingProposalMaxBytes = 2 * 1024 * 1024;

/// One proposal as it is stored: everything `PendingProposal` carries except
/// its process-local id, plus whether it has already been reported as viewed.
class PersistedProposal {
  const PersistedProposal({
    required this.proposalType,
    required this.title,
    required this.proposalJson,
    required this.operatorId,
    required this.createdAt,
    this.viewed = false,
  });

  final String proposalType;
  final String title;
  final String proposalJson;
  final String operatorId;
  final DateTime createdAt;
  final bool viewed;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': proposalType,
        'title': title,
        'json': proposalJson,
        'operator': operatorId,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'viewed': viewed,
      };

  /// Reads one stored entry, or null when it is not shaped like one. A
  /// missing `createdAt` counts as "now" so an entry written by a build that
  /// did not stamp it is kept for the full window rather than dropped.
  static PersistedProposal? tryFromJson(Object? raw, {required DateTime now}) {
    if (raw is! Map) return null;
    final type = raw['type'];
    final title = raw['title'];
    final json = raw['json'];
    final operator = raw['operator'];
    if (type is! String || title is! String || json is! String) return null;
    DateTime createdAt = now;
    final stamp = raw['createdAt'];
    if (stamp is String) {
      createdAt = DateTime.tryParse(stamp)?.toLocal() ?? now;
    }
    return PersistedProposal(
      proposalType: type,
      title: title,
      proposalJson: json,
      operatorId: operator is String ? operator : 'local',
      createdAt: createdAt,
      viewed: raw['viewed'] == true,
    );
  }
}

/// Encodes [proposals] for storage, oldest first.
///
/// Applies the count and byte bounds here rather than only on decode, so a
/// runaway queue is trimmed before it reaches the file, not after it has
/// filled it. Oldest entries go first: they are the ones nearest expiry.
String encodePendingProposals(Iterable<PersistedProposal> proposals) {
  final kept = proposals.toList();
  while (kept.length > pendingProposalLimit) {
    kept.removeAt(0);
  }
  String encoded = _encode(kept);
  while (encoded.length > pendingProposalMaxBytes && kept.length > 1) {
    kept.removeAt(0);
    encoded = _encode(kept);
  }
  return encoded;
}

String _encode(List<PersistedProposal> proposals) => jsonEncode(<String, Object?>{
      'v': pendingProposalsFormatVersion,
      'proposals': [for (final p in proposals) p.toJson()],
    });

/// Decodes a stored blob. Never throws: anything unreadable yields an empty
/// list, and entries older than [pendingProposalMaxAge] as of [now] are
/// dropped. The newest [pendingProposalLimit] survive if there are more.
List<PersistedProposal> decodePendingProposals(String? raw,
    {DateTime? now}) {
  if (raw == null || raw.isEmpty) return const [];
  final at = now ?? clock.now();
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const [];
  }
  if (decoded is! Map || decoded['v'] != pendingProposalsFormatVersion) {
    return const [];
  }
  final entries = decoded['proposals'];
  if (entries is! List) return const [];

  final live = <PersistedProposal>[];
  for (final entry in entries) {
    final proposal = PersistedProposal.tryFromJson(entry, now: at);
    if (proposal == null) continue;
    if (at.difference(proposal.createdAt) > pendingProposalMaxAge) continue;
    live.add(proposal);
  }
  while (live.length > pendingProposalLimit) {
    live.removeAt(0);
  }
  return live;
}

/// The device-local store behind [pendingProposalsPrefsKey].
///
/// Every method swallows its own failures: see the library note on why a
/// cache must never be able to stop the app starting.
class PendingProposalStore {
  PendingProposalStore(this._prefs, {Logger? logger})
      : _logger = logger ?? Logger();

  final PreferencesApi _prefs;
  final Logger _logger;

  /// The restorable queue, oldest first. Empty on any failure.
  Future<List<PersistedProposal>> load() async {
    String? raw;
    try {
      raw = await _prefs.getString(pendingProposalsPrefsKey);
    } catch (error) {
      _logger.w('Pending proposals could not be read from the local store; '
          'starting with none: $error');
      return const [];
    }
    final restored = decodePendingProposals(raw);
    if (raw != null && raw.isNotEmpty && restored.isEmpty) {
      // Either everything expired or the blob was unreadable. Either way
      // the file now holds something no future start will use.
      _logger.i('Pending proposals in the local store were stale or '
          'unreadable; ignoring them');
    }
    return restored;
  }

  /// Writes [proposals], or clears the key when there is nothing pending so
  /// a fresh install and an emptied queue look the same on disk.
  Future<void> save(Iterable<PersistedProposal> proposals) async {
    try {
      if (proposals.isEmpty) {
        await _prefs.remove(pendingProposalsPrefsKey);
      } else {
        await _prefs.setString(
            pendingProposalsPrefsKey, encodePendingProposals(proposals));
      }
    } catch (error) {
      _logger.w('Pending proposals could not be written to the local store; '
          'they will not survive an engine restart: $error');
    }
  }
}
