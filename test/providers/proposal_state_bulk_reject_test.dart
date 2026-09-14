/// Rejecting a restored queue in one press.
///
/// The failure this pins down: a station restarted with fifteen undecided
/// proposals in the device-local mirror, restored them, and the operator
/// pressed the banner's Reject all. The banner takes a queue down one proposal
/// at a time, and every removal used to be mirrored on its own — so one press
/// rewrote the whole preferences file once per proposal. That file is about a
/// megabyte on a configured station and it is rewritten whole for any key, on
/// the UI isolate, which on Windows is the platform thread: the one that pumps
/// the message loop and services the compositor. The measured stall was 945 ms
/// against 1 ms for every other sample in that process, and the process did not
/// come back from it.
///
/// So these tests count writes. The queue emptying correctly was never in
/// doubt — what the fix has to hold is that one decision costs one write,
/// whatever it decided, and that the mirror still ends up telling the truth.
library;

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_dart/core/preferences.dart';

import 'package:tfc/core/pending_proposals_store.dart';
import 'package:tfc/providers/proposal_state.dart';

void main() {
  /// The blob a previous engine generation left behind: [keyMappings] key
  /// mapping proposals and [reports] report proposals, all raised just now.
  ///
  /// More than one type on purpose. A single-type queue can be taken down by
  /// [ProposalStateNotifier.rejectAllOfType] in one state change; a mixed one
  /// is what forces the banner onto its per-proposal loop, which is the path
  /// that failed.
  String persistedBlob({required int keyMappings, required int reports}) {
    final now = clock.now().toUtc().toIso8601String();
    Map<String, Object?> entry(String type, String title, String json) =>
        <String, Object?>{
          'type': type,
          'title': title,
          'json': json,
          'operator': 'local',
          'createdAt': now,
          'viewed': false,
        };
    return jsonEncode(<String, Object?>{
      'v': pendingProposalsFormatVersion,
      'proposals': <Map<String, Object?>>[
        for (var i = 0; i < keyMappings; i++)
          entry(
            'key_mapping',
            'line1/motor$i/run',
            jsonEncode(<String, Object?>{
              '_proposal_type': 'key_mapping',
              '_op': 'create',
              'key': 'line1/motor$i/run',
              'node': 'ns=2;s=line1.motor$i.run',
            }),
          ),
        for (var i = 0; i < reports; i++)
          entry(
            'report',
            'Shift summary $i',
            jsonEncode(<String, Object?>{
              '_proposal_type': 'report',
              '_op': 'create',
              'id': 'shift_summary_$i',
              'title': 'Shift summary $i',
            }),
          ),
      ],
    });
  }

  /// A notifier over [prefs] whose restore has settled, as the next engine
  /// generation's would have by the time anyone can press a button.
  Future<ProposalStateNotifier> restart(
    PreferencesApi prefs, {
    StreamController<ProposalFeedback>? feedback,
  }) async {
    final notifier = ProposalStateNotifier(
      feedback: feedback,
      store: PendingProposalStore(prefs),
    );
    addTearDown(notifier.dispose);
    await pumpEventQueue();
    return notifier;
  }

  /// Everything the mirror owes, written.
  Future<void> settle(ProposalStateNotifier notifier) async {
    await pumpEventQueue();
    await notifier.pendingWrites;
    await pumpEventQueue();
  }

  test('rejecting a restored multi-type queue writes the mirror once',
      () async {
    final prefs = _CountingPreferences();
    await prefs.setString(
        pendingProposalsPrefsKey, persistedBlob(keyMappings: 12, reports: 3));

    final feedback = StreamController<ProposalFeedback>.broadcast();
    addTearDown(feedback.close);
    final rejected = <String>[];
    feedback.stream.listen((f) {
      if (f.action == 'rejected') rejected.addAll(f.proposals.map((p) => p.title));
    });

    final notifier = await restart(prefs, feedback: feedback);
    expect(notifier.state.pendingCount, 15,
        reason: 'the whole queue must come back, both types');
    expect(
      notifier.state.proposals.map((p) => p.proposalType).toSet(),
      {'key_mapping', 'report'},
    );

    await settle(notifier);
    prefs.resetCounts();

    // Exactly what the banner's Reject all does: one synchronous loop over the
    // queue it is showing, one rejectProposal per row.
    for (final proposal in notifier.state.proposals.toList()) {
      notifier.rejectProposal(proposal.id);
    }
    await settle(notifier);

    // The notifier is still usable — nothing about emptying it in one step
    // leaves it in a state a later proposal cannot be added to.
    expect(notifier.mounted, isTrue);
    expect(notifier.state.proposals, isEmpty);
    expect(rejected, hasLength(15));

    // The mirror tells the truth: nothing pending, and the key gone rather
    // than left holding an empty queue.
    expect(await prefs.containsKey(pendingProposalsPrefsKey), isFalse);

    // The point of the fix. One press, one write — not one per proposal.
    expect(prefs.writes, 1,
        reason: 'a bulk decision must cost one mirror write, not fifteen: '
            'each one rewrites the whole device-local preferences file on the '
            'UI isolate');
  });

  test('a decision made while a write is in flight still reaches the mirror',
      () async {
    final prefs = _CountingPreferences();
    await prefs.setString(
        pendingProposalsPrefsKey, persistedBlob(keyMappings: 2, reports: 1));

    final notifier = await restart(prefs);
    await settle(notifier);

    // Coalescing must not be able to swallow the last decision of a turn.
    // Reject two rows, let the write start, then reject the third.
    final ids = notifier.state.proposals.map((p) => p.id).toList();
    notifier.rejectProposal(ids[0]);
    notifier.rejectProposal(ids[1]);
    await pumpEventQueue();
    notifier.rejectProposal(ids[2]);
    await settle(notifier);

    expect(notifier.state.proposals, isEmpty);
    expect(await prefs.containsKey(pendingProposalsPrefsKey), isFalse);
  });

  test('a restored queue rejected down to one still mirrors what is left',
      () async {
    final prefs = _CountingPreferences();
    await prefs.setString(
        pendingProposalsPrefsKey, persistedBlob(keyMappings: 4, reports: 1));

    final first = await restart(prefs);
    await settle(first);

    // Reject the four key mappings in one press, leave the report pending.
    for (final p in first.state.ofType('key_mapping').toList()) {
      first.rejectProposal(p.id);
    }
    await settle(first);
    expect(first.state.proposals.single.proposalType, 'report');

    // The next generation must see exactly the one that was left.
    final second = await restart(prefs);
    expect(second.state.proposals.map((p) => p.title), ['Shift summary 0']);
  });
}

/// [InMemoryPreferences] that counts what actually reaches the store.
///
/// A write is a write whether it sets or removes: both re-encode and rewrite
/// the whole preferences file on the real device-local store, which is the
/// cost these tests exist to bound.
class _CountingPreferences extends InMemoryPreferences {
  int writes = 0;

  void resetCounts() => writes = 0;

  @override
  Future<void> setString(String key, String value) {
    writes++;
    return super.setString(key, value);
  }

  @override
  Future<void> remove(String key) {
    writes++;
    return super.remove(key);
  }
}
