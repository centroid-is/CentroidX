/// The factory a contract driver calls: a `FakeStateMan` on the far side of a
/// channel, and a `StateManApi` on this one.
///
/// One function, synchronous, with the reference implementation's own
/// constructor arguments on it. All three of those are constraints rather than
/// preferences:
///
///  * **Synchronous**, because `runSubscribeContract` and every other sub-suite
///    take a `StateManApi Function()` and call it inside the case. A factory
///    that returned a future would force every driver to be rewritten, which is
///    the one thing this harness exists to avoid.
///  * **Same arguments as `FakeStateMan`**, because a driver configures the
///    source it is judging — `test/write_contract_test.dart` declares a
///    read-only key, the freshness driver passes a shorter `staleAfter` — and a
///    channel-served source that could not be configured the same way would
///    make the two drivers diverge in exactly the place the harness is claiming
///    they do not.
///  * **Disposal cascades**, because the driver registers `api.dispose` and
///    nothing else. See `ChannelStateMan.dispose`.
///
/// The corruption hook is threaded through from [ChannelPair] so plan 02-10 can
/// point the malformed-peer catalogue at a fully-served source without adding a
/// second factory.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../../testing/fake_access_services.dart';
import '../../testing/fake_data_services.dart';
import '../../testing/fake_state_man.dart';
import 'channel_pair.dart';
import 'channel_state_man.dart';
import 'served_state_man.dart';

/// Both halves of one channel-served source, for a test that needs to reach
/// past the client — to sever the channel, or to compare the two ends.
///
/// Ordinary drivers want [channelServedFake] and never see this.
final class ChannelServedFake {
  /// The reference implementation, on the far side. Real, and driveable
  /// directly — which is what lets the bite-proof apply a lever the client
  /// cannot see the result of.
  final FakeStateMan served;

  /// The implementation under test, on this side.
  final ChannelStateMan api;

  /// The channel between them, and the seam faults are injected at.
  final ChannelPair channel;

  /// The served peer, for a test that wants to close one end explicitly.
  final ServedStateMan session;

  ChannelServedFake._(this.served, this.api, this.channel, this.session);
}

/// A `FakeStateMan` served over a fresh channel, with both ends wired.
///
/// Disposing [ChannelServedFake.api] releases everything, including the served
/// fake's freshness watchdog.
ChannelServedFake serveFakeOverChannel({
  Duration staleAfter = const Duration(milliseconds: 300),
  Set<String> readOnlyKeys = const {},
  Duration writeLatency = Duration.zero,
  FakeBrowse? browse,
  FakeTimeseries? timeseries,
  FakeHistoryViews? historyViews,
  FakePreferences? preferences,
  FakeAccessServices? access,
  String Function(String message)? corruptServerToClient,
}) {
  final served = FakeStateMan(
    staleAfter: staleAfter,
    readOnlyKeys: readOnlyKeys,
    writeLatency: writeLatency,
    browse: browse,
    timeseries: timeseries,
    historyViews: historyViews,
    preferences: preferences,
    access: access,
  );
  final channel = channelPair(corruptServerToClient: corruptServerToClient);
  final session = serveStateMan(served, channel.server);
  final api = ChannelStateMan(
    channel: channel.client,
    observables: served,
    closeServed: () async {
      await session.close();
      await served.dispose();
    },
  );
  return ChannelServedFake._(served, api, channel, session);
}

/// The driver-facing factory: one channel-served `StateManApi`, per case.
///
/// ```dart
/// void main() => runSubscribeContract(channelServedFake);
/// ```
StateManApi channelServedFake({
  Duration staleAfter = const Duration(milliseconds: 300),
  Set<String> readOnlyKeys = const {},
  Duration writeLatency = Duration.zero,
  FakeBrowse? browse,
  FakeTimeseries? timeseries,
  FakeHistoryViews? historyViews,
  FakePreferences? preferences,
  FakeAccessServices? access,
  String Function(String message)? corruptServerToClient,
}) =>
    serveFakeOverChannel(
      staleAfter: staleAfter,
      readOnlyKeys: readOnlyKeys,
      writeLatency: writeLatency,
      browse: browse,
      timeseries: timeseries,
      historyViews: historyViews,
      preferences: preferences,
      access: access,
      corruptServerToClient: corruptServerToClient,
    ).api;
