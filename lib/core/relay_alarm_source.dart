/// The alarm surface of a gateway-mode panel: told, never computed.
///
/// ## What is deliberately absent
///
/// There is no `Evaluator` in this file, and no subscription to any rule
/// variable. A gateway-mode station is *told* its active set by the backend's
/// alarm engine under `ALARM.active`, including the instant each rule became
/// active and where that instant came from. The panel's job is to render it.
///
/// That is not tidiness. Measured on the SVN rig, 2026-09-06: the station's
/// `alarm_man_config` contains a rule on `__agg_default_connected == false`,
/// and nothing in this repository produces `__agg_default_connected`. In
/// gateway mode `GatewayStateMan.connMetaAliases` is `const []` and
/// `subscribeConnMeta` throws by name, so the variable is unbound, coerces to
/// `false`, and the alarm stands permanently on a healthy plant. A second
/// opinion computed from values the panel cannot see is not a safety net; it
/// is a fault report about the panel, printed in the operator's alarm banner.
///
/// ## The payload is self-sufficient, and is never joined against local config
///
/// Every entry carries its own `level`, `title`, `description` and `group`
/// (`AlarmActiveEntry`, 14-05). They are read straight off the payload and
/// **never** looked up in this station's `alarm_man_config`, because the two
/// copies are not the same age: preferences are re-read on a restart, so a
/// panel that has been up since before the last configuration change would
/// otherwise draw a live alarm it cannot name. An alarm nobody can name is an
/// alarm nobody acts on.
///
/// The same applies, with teeth, to `(uid, ruleIndex)`: they are the identity
/// an acknowledge is sent under. A panel one restart behind that recomputed
/// the index from its own rule list would acknowledge the wrong rule of the
/// right alarm — a silent mis-actuation of the operator's intent, with no
/// error anywhere.
///
/// ## Alarm history comes from the backend too — D-11 is superseded
///
/// **The old text of this section was false, and its falsehood is how the bug
/// survived.** It read: *"Alarm history and alarm configuration (D-11). The
/// panel holds its own Postgres connection in gateway mode —
/// `preferencesProvider` builds it unconditionally — so `getRecentAlarms`
/// reads `alarm_history` exactly as direct mode does."*
///
/// `preferencesProvider` stopped building it unconditionally.
/// `lib/providers/preferences.dart:60` now branches on the transport *before*
/// it reads the config row — deliberately, so a gateway station does not pull
/// a Postgres pool up at boot with no screen asking — and builds
/// `Preferences` with `db: null`. From that commit,
/// `if (preferences.database == null) return []` was the only branch
/// [getRecentAlarms] ever took on a gateway panel: an empty history page, on a
/// plant that has had alarms all week, with no error, no badge and no line on
/// stderr. An empty answer presented as a fact is worse than an error, and it
/// is the failure class this whole milestone exists to remove.
///
/// So history is routed the way every other read is routed: the backend owns
/// `alarm_history`, and [AlarmTransport.recentAlarms] asks it. A failure is
/// **thrown**, never returned as an empty list — see [getRecentAlarms] and
/// [historyError].
///
/// ## Alarm configuration comes from the backend too, now
///
/// This used to say the opposite, and it was describing a bug rather than a
/// design. The alarm editor writes `alarm_man_config` through preferences,
/// and in gateway mode that store *was* this panel's own device-local mirror
/// — so an operator editing a rule here got a successful-looking edit the
/// plant never saw, and two panels held two rule sets with nothing anywhere
/// reporting it. A silently panel-local alarm rule is the same failure class
/// as the silently empty history above, and worse in consequence.
///
/// `RelayedPreferences` (`lib/core/relayed_preferences.dart`) now routes the
/// shared store over the same pipe, so [_saveConfig] reaches the backend's
/// `alarm_man_config` and the write is graded there by the server's own
/// `configure` gate rather than by this panel. What has **not** changed is
/// that the editor is not read-only in gateway mode.
///
/// **The one thing still missing, named rather than implied:** these three
/// mutators return `void` and [_saveConfig] is an un-awaited `async` body, so
/// a write refused or dropped by a downed link cannot reach the editor. The
/// divergence is no longer permanent — the next rebuild reads the backend and
/// the panel converges — but the moment of the edit still looks like success.
/// Making `addAlarm`/`removeAlarm`/`updateAlarm` return futures the editor
/// awaits is the fix, and it touches `AlarmMan` and the editor as well as this
/// class. (A *denial* is already visible: it goes through
/// `GuardedPreferences`' `onDenied` and the shared prompt.)
///
/// ## Why the collaborator is a port and not `RemoteStateMan`
///
/// `RemoteStateMan` is a `final class`: nothing outside its own library may
/// implement it, so no test in this repository can hand this class a double of
/// it. [AlarmTransport] is therefore the three things a gateway-mode alarm
/// source actually needs — the active-set stream, the acknowledge and the
/// history read — and [RemoteAlarmTransport] is the one-line production
/// implementation over the live client.
///
/// The stream is taken from the client **directly** rather than through
/// `GatewayStateMan.subscribe`, which runs `toUaValue` and rebuilds the
/// payload into an `open62541` object graph member by member. That shape has
/// nowhere to put a per-entry instant, which is exactly why D-9 put
/// `activeAtMs` in the payload as data (P-7); decoding `AlarmActiveEntry` back
/// out of it would be lossy on the one field a stop analysis is judged on.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show stderr;

import 'package:collection/collection.dart';
// No `package:drift` import, and its absence is the point: since history moved
// onto the transport there is no query in this file, and a station that has no
// database cannot be asked one. The old import was `OrderingMode` and
// `OrderingTerm` for a `select(db.alarmHistory)` whose only reachable branch
// on a gateway panel was `return []`.
import 'package:rxdart/rxdart.dart';
import 'package:tfc_dart/core/alarm.dart';
// A prefixed second import of the same library, for one reason: the
// `filterAlarms` member below shadows the top-level `filterAlarms` it has to
// delegate to. The same trick `AlarmMan` uses, for the same reason.
import 'package:tfc_dart/core/alarm.dart' as shared;
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

/// The three things a gateway-mode alarm source needs from the relay client.
///
/// Narrow on purpose. Taking the whole client would make this class untestable
/// (`RemoteStateMan` is `final`) and would also let a later edit reach for
/// `write` or `readFresh` from inside an alarm source, which is how a second
/// evaluation path grows back.
abstract interface class AlarmTransport {
  /// The backend's active set, as it arrives under `ALARM.active`.
  Stream<rp.DynamicValue> activeValues();

  /// Acknowledges one rule of one alarm, by the identity D-4 persists.
  Future<void> ackAlarm(String alarmUid, int ruleIndex);

  /// The backend's `alarm_history` rows overlapping the window, newest first.
  ///
  /// **The third member, and it was added because the second-best answer here
  /// is measurably harmful.** History used to be read from the panel's own
  /// database; a gateway panel has no database, so that read answered an empty
  /// list — every time, silently, on every station. See the library doc.
  ///
  /// An implementation **throws** when the backend could not answer. It must
  /// never return an empty list for a failure: `[]` is what a plant with no
  /// alarms looks like, and the two are indistinguishable on screen.
  Future<List<rp.AlarmHistoryEntry>> recentAlarms({
    required int limit,
    DateTime? from,
    DateTime? to,
  });
}

/// [AlarmTransport] over the live relay client.
class RemoteAlarmTransport implements AlarmTransport {
  const RemoteAlarmTransport(this._remote);

  final RemoteStateMan _remote;

  @override
  Stream<rp.DynamicValue> activeValues() =>
      _remote.subscribe(rp.AlarmKeys.active);

  @override
  Future<void> ackAlarm(String alarmUid, int ruleIndex) =>
      _remote.ackAlarm(alarmUid, ruleIndex);

  @override
  Future<List<rp.AlarmHistoryEntry>> recentAlarms({
    required int limit,
    DateTime? from,
    DateTime? to,
  }) =>
      _remote.recentAlarms(limit: limit, from: from, to: to);
}

/// The gateway-mode [AlarmSource].
class RelayAlarmSource implements AlarmSource {
  RelayAlarmSource._({
    required AlarmTransport transport,
    required this.preferences,
    required this.config,
  })  : _transport = transport,
        alarms = config.alarms.map((e) => Alarm(config: e)).toSet(),
        _activeAlarms = BehaviorSubject<Set<AlarmActive>>.seeded(const {}),
        _historyController = BehaviorSubject<List<AlarmActive?>>.seeded([]);

  /// Loads the local configuration, subscribes to `ALARM.active` and primes
  /// history.
  ///
  /// The subscription is opened here and **not** in an `onListen` body. The
  /// panel-side gate is being retired, not relocated: a source that only
  /// starts listening when a widget appears is a source whose first payload
  /// depends on which page happened to be open.
  static Future<RelayAlarmSource> create({
    required AlarmTransport transport,
    required Preferences preferences,
  }) async {
    final configJson = await preferences.getString('alarm_man_config');
    final config = configJson == null
        ? AlarmManConfig(alarms: [])
        : AlarmManConfig.fromJson(jsonDecode(configJson));

    final source = RelayAlarmSource._(
      transport: transport,
      preferences: preferences,
      config: config,
    );
    source._listen();
    await source._reloadHistory();
    return source;
  }

  final AlarmTransport _transport;
  final Preferences preferences;

  @override
  final AlarmManConfig config;

  @override
  final Set<Alarm> alarms;

  final BehaviorSubject<Set<AlarmActive>> _activeAlarms;
  final BehaviorSubject<List<AlarmActive?>> _historyController;
  StreamSubscription<rp.DynamicValue>? _subscription;

  /// Whether the backend said it had to cut the list it sent.
  ///
  /// Surfaced rather than swallowed: a list that was capped is not the same
  /// fact as a plant with fewer alarms, and presenting a short list as
  /// complete is how an operator stops looking for the alarm that matters.
  bool get activeTruncated => _truncated;
  bool _truncated = false;

  /// How many entries the backend's cap dropped.
  int get activeOmitted => _omitted;
  int _omitted = 0;

  bool _reportedTruncation = false;

  /// Whether `ALARM.active` stopped arriving because the stream **ended**.
  ///
  /// This is CR-01's second half and it is not a nicety. `RemoteStateMan`
  /// closes every stream it handed out when it is disposed
  /// (`remote_state_man.dart:1219-1222`) — it does not error them — so a source
  /// left holding a disposed client goes quiet with `onError` never firing.
  /// The banner then keeps showing whatever it last saw, for as long as the
  /// panel is up, and "we cannot read the alarm list" is indistinguishable from
  /// "the plant is fine". That is the exact silence this milestone exists to
  /// remove, so an ended stream is recorded here, said on `stderr`, and made a
  /// refusal in [ackAlarm].
  ///
  /// False after an ordinary [close]: a source shut down on purpose has not
  /// failed, and a fault line printed on every rebuild is a fault line nobody
  /// reads.
  bool get activeStreamClosed => _activeStreamClosed;
  bool _activeStreamClosed = false;

  /// Set by [close] before the subscription is cancelled, so a deliberate
  /// teardown is not reported as a dead gateway.
  ///
  /// **Inert as this file stands today, and that was measured rather than
  /// assumed.** `close()` reaches `_subscription.cancel()` synchronously — no
  /// await comes before it — and a cancelled subscription is never delivered
  /// the done event a `StreamController.close()` had already scheduled. So
  /// deleting this flag on its own turns nothing red.
  ///
  /// It is kept because it stops being inert the moment anybody puts a single
  /// `await` in front of that cancel, and the mutation matrix says so in both
  /// directions: with the flag present, inserting that await keeps every arm
  /// green; with it absent, the same await turns arm 15f red. What that arm
  /// would then be reporting on a plant is a gateway-is-dead line printed on
  /// **every** key-mappings save — and a fault line that cries wolf on every
  /// save is a fault line nobody reads, which is the same silence by a longer
  /// route.
  bool _closing = false;

  void _listen() {
    _subscription = _transport.activeValues().listen(
      _onValue,
      onError: (Object error, StackTrace stack) {
        // The previous set stands. A decode or transport error must not clear
        // the banner: "we cannot read the alarm list" and "there are no
        // alarms" are opposite facts and look identical on a blank screen.
        stderr.writeln('ALARM.active could not be read: $error');
      },
      onDone: () {
        if (_closing) return;
        _activeStreamClosed = true;
        stderr.writeln(
            'ALARM.active ENDED: the relay client behind this alarm source is '
            'gone, so no further active set will ever arrive and the list on '
            'screen is frozen at whatever it last showed. This is not an '
            'empty plant. The client is disposed when the panel reloads its '
            'key mappings or switches transport; if this line appears without '
            'one of those, the socket died and the panel needs restarting.');
      },
    );
  }

  void _onValue(rp.DynamicValue value) {
    final rp.AlarmActiveList decoded;
    try {
      decoded = rp.AlarmActiveEntry.decodeList(value.toJson(slim: true));
    } catch (error) {
      // `AlarmActiveEntry.fromJson` refuses an unknown `tsSource` by name
      // (T-14-36). Refused, logged, and the previous set left standing.
      stderr.writeln('ALARM.active payload refused: $error');
      return;
    }

    _truncated = decoded.truncated;
    _omitted = decoded.omitted;
    if (_truncated && !_reportedTruncation) {
      _reportedTruncation = true;
      stderr.writeln('ALARM.active was truncated by the backend: '
          '$_omitted further active alarms are not in this list.');
    }

    if (!_activeAlarms.isClosed) {
      _activeAlarms.add({for (final e in decoded.entries) _activeOf(e)});
    }
    // CD-2: re-query history on every active-set change, rather than keeping a
    // ring buffer that appends on an observed deactivation. The rows come from
    // the backend's `alarm_history` — the one table the engine writes — so
    // there is one source of truth and it cannot diverge from itself.
    //
    // No `.catchError` here: [_reloadHistory] absorbs its own failure into
    // [historyError] and a line on stderr, because "the refresh failed" is a
    // fact the object has to keep, not one that scrolls past. A handler here
    // as well would be a second place the same failure is decided about.
    unawaited(_reloadHistory());
  }

  /// One payload entry, as the object the widgets already know.
  ///
  /// Everything here comes from [entry]. Nothing is looked up in [config].
  AlarmActive _activeOf(rp.AlarmActiveEntry entry) {
    final rule = AlarmRule(
      level: _levelOf(entry.level),
      expression:
          ExpressionConfig(value: Expression(formula: entry.expression ?? '')),
      // The payload does not carry the flag, and `pendingAck` is the only
      // evidence in it: the backend keeps a cleared rule in the active set
      // precisely because it requires an acknowledgement. Deriving it from
      // the local config would reintroduce the join this class exists to
      // avoid, and inventing `true` would tell every operator that every
      // alarm needs a click.
      acknowledgeRequired: entry.pendingAck,
    );

    return AlarmActive(
      alarm: Alarm(
        config: AlarmConfig(
          uid: entry.uid,
          title: entry.title,
          description: entry.description,
          group: List<String>.of(entry.group),
          rules: [rule],
        ),
      ),
      notification: AlarmNotification(
        uid: entry.uid,
        // A cleared rule that is still in the set is one waiting on an
        // acknowledgement; anything else in the set is standing.
        active: !entry.pendingAck,
        expression: entry.expression,
        rule: rule,
        // Data, in UTC, to the millisecond the backend stated. Never
        // reconstructed through the local time zone: that is the bug which
        // makes two panels disagree about when the line stopped.
        timestamp: DateTime.fromMillisecondsSinceEpoch(entry.activeAtMs,
            isUtc: true),
        ruleIndex: entry.ruleIndex,
        tsSource: _tsSourceOf(entry.tsSource),
        // The hold badge, straight off the payload: which inputs D-3 is
        // holding this rule on, and since when. Dropping these here would
        // re-blind the panel to exactly the rig-measured defect the fields
        // exist for (a warning held true on a dead sensor, with no visible
        // reason).
        staleInputs: List<String>.of(entry.staleInputs),
        staleSince: entry.staleSince,
      ),
      pendingAck: entry.pendingAck,
    );
  }

  /// The payload's level, or the loudest one when it names something this
  /// build has never heard of.
  ///
  /// A newer backend with a fourth level must not make an alarm invisible;
  /// showing it too loudly is the failure an operator can act on.
  static AlarmLevel _levelOf(String wire) =>
      AlarmLevel.values.firstWhereOrNull((l) => l.name == wire) ??
      AlarmLevel.error;

  static AlarmTsSource? _tsSourceOf(String wire) =>
      wire == rp.AlarmActiveEntry.tsSourcePlant
          ? AlarmTsSource.plant
          : AlarmTsSource.backendReceipt;

  @override
  Stream<Set<AlarmActive>> activeAlarms() => _activeAlarms.stream;

  @override
  Stream<List<AlarmActive?>> history() => _historyController.stream;

  /// Acknowledges [alarm] by sending it to the backend, and does nothing else.
  ///
  /// **Q-1, ruled by Jón on 2026-09-06:** *"The acknowledge is not used
  /// anywhere yet. So let's relay it."* Any earlier document saying this member
  /// refuses by name, or that the control is disabled in gateway mode, is
  /// superseded.
  ///
  /// It does not touch the active set. The backend owns that set, so a local
  /// removal would be undone by the next `ALARM.active` and the operator would
  /// watch the alarm vanish and come back — and an operator who has seen that
  /// once stops believing the screen. The confirmation is therefore the
  /// readback, which is PROJECT.md's rule applied without an exception for the
  /// case where the exception would feel nicer.
  ///
  /// It does not catch, either. A refusal the operator cannot see is the
  /// silent loss this project exists to prevent, so the throw is the caller's
  /// to show. And it is sent **once**: no retry, no `unawaited`, no
  /// `.catchError` — an acknowledge that reached the backend and lost its
  /// answer must not be sent twice.
  @override
  Future<void> ackAlarm(AlarmActive alarm) async {
    if (_activeStreamClosed) {
      // The alarm the operator is acknowledging is one this source stopped
      // being told about. Sending it would reach a disposed client and come
      // back as `RemoteStateMan was asked for "ackAlarm" after it was
      // disposed` — a sentence about an object, from a package an operator has
      // never heard of, that does not say the alarm list stopped arriving.
      throw StateError(
          'This panel cannot acknowledge "${alarm.notification.uid}": '
          '${rp.AlarmKeys.active} ended, so the relay client behind this alarm '
          'source is gone and the list on screen is frozen at whatever it last '
          'showed. Nothing was sent. Restart the panel, or reload its key '
          'mappings, to get a live client.');
    }
    final ruleIndex = alarm.notification.ruleIndex;
    if (ruleIndex == null) {
      // Only reachable with an AlarmActive that did not come from
      // `ALARM.active` — a pre-v7 history row, say. Guessing 0 would
      // acknowledge whichever rule happens to be first.
      throw ArgumentError.value(alarm, 'alarm',
          'cannot be acknowledged: it states no rule index, so there is no '
          'identity to send. Only alarms from the backend\'s active set carry '
          'one.');
    }
    await _transport.ackAlarm(alarm.notification.uid, ruleIndex);
  }

  @override
  void addAlarm(AlarmConfig alarm) {
    config.alarms.add(alarm);
    _saveConfig();
    alarms.add(Alarm(config: alarm));
  }

  @override
  void removeAlarm(AlarmConfig alarm) {
    config.alarms.removeWhere((e) => e.uid == alarm.uid);
    _saveConfig();
    alarms.removeWhere((e) => e.config.uid == alarm.uid);
  }

  @override
  void updateAlarm(AlarmConfig alarm) {
    config.alarms.removeWhere((e) => e.uid == alarm.uid);
    config.alarms.add(alarm);
    _saveConfig();
    alarms.removeWhere((e) => e.config.uid == alarm.uid);
    alarms.add(Alarm(config: alarm));
  }

  void _saveConfig() async {
    await preferences.setString(
        'alarm_man_config', jsonEncode(config.toJson()));
  }

  /// See the top-level [filterAlarms] — the behaviour lives there so a
  /// gateway-mode panel cannot answer the same question differently from a
  /// direct-mode one on the same screen.
  @override
  List<AlarmActive> filterAlarms(
          List<AlarmActive> alarms, String searchQuery) =>
      shared.filterAlarms(alarms, searchQuery);

  /// Why the last history refresh failed, or null when the last one worked.
  ///
  /// **Not a log line.** The banner's equivalent of this is
  /// [activeStreamClosed], and it exists for the same measured reason: a fault
  /// that only reaches `stderr` is a fault nobody on a plant floor ever sees.
  /// A history page showing an empty list is indistinguishable from a factory
  /// that has never had an alarm, so when the refresh behind it failed there
  /// has to be something on the object saying so.
  ///
  /// Cleared by the next refresh that succeeds — a stale fault line is a fault
  /// line nobody reads.
  String? get historyError => _historyError;
  String? _historyError;

  /// Re-reads the history rows and republishes them.
  ///
  /// A plain list rather than `AlarmMan`'s `RingBuffer.buffer`: that buffer
  /// exists because the direct-mode panel accumulates deactivations as it
  /// observes them, and it has no `clear`, so re-querying into one would leave
  /// the previous answer's rows behind it. This side re-reads the whole window
  /// each time, so the query result *is* the history. Consumers already handle
  /// nulls in this list, because `RingBuffer.buffer` is padded with them.
  ///
  /// **A failure leaves the previous list standing** and records
  /// [historyError]. Publishing an empty list instead would blank the page and
  /// present that as the plant's history, which is the same lie by a shorter
  /// route; erroring the subject instead would put a permanent spinner on
  /// `alarm.dart:855`'s `StreamBuilder`, which says even less.
  ///
  /// It does not rethrow, and that is why [create] can await it: a gateway
  /// that cannot answer history is still a gateway with a working active set,
  /// and refusing to build the whole alarm surface over it would take the
  /// banner down as well as the page.
  Future<void> _reloadHistory() async {
    final List<AlarmActive> rows;
    try {
      rows = await getRecentAlarms();
    } catch (error) {
      _historyError = '$error';
      stderr.writeln(
          'Alarm history could not be read from the backend: $error. The list '
          'on the history page is whatever it last showed and is NOT this '
          'plant\'s history. Nothing here says the plant has had no alarms.');
      return;
    }
    _historyError = null;
    if (!_historyController.isClosed) {
      _historyController.add(List<AlarmActive?>.of(rows));
    }
  }

  /// Closed and open activations from `alarm_history`, newest first.
  ///
  /// **Read from the backend over [AlarmTransport.recentAlarms], not from this
  /// panel's database.** See the library doc: the D-11 ruling that put this
  /// read on a local database rested on a premise that stopped being true, and
  /// from that moment this method's only reachable branch was `return []`.
  ///
  /// The three arguments are `AlarmMan.getRecentAlarms`' three arguments and
  /// they mean what they mean there — [limit] a row ceiling, [from] and [to] a
  /// window bounded by **overlap** rather than by start, ordering newest
  /// first. A divergence between the transports here is the bug this class
  /// exists to prevent, so the semantics are stated in one place
  /// (`AlarmHistorySource.recentAlarms`) and both ends are held to it.
  ///
  /// **It does not catch.** A backend that could not answer is the caller's to
  /// show; converting that into an empty list would report a fact about the
  /// wire as a fact about the factory, which is precisely the defect this
  /// method was rewritten to end. [_reloadHistory] is the one caller that
  /// absorbs the throw, and it records [historyError] rather than swallowing
  /// it.
  @override
  Future<List<AlarmActive>> getRecentAlarms({
    int limit = 1000,
    DateTime? from,
    DateTime? to,
  }) async {
    final entries =
        await _transport.recentAlarms(limit: limit, from: from, to: to);
    return entries.map(_historyOf).toList();
  }

  /// One history row, as the object the widgets already know.
  ///
  /// **Everything here comes from [entry]. Nothing is looked up in [config]**,
  /// which is the same rule [_activeOf] follows and it binds harder here.
  /// `AlarmMan.getRecentAlarms` resolves each row against the local
  /// configuration and returns `null` — dropped by `whereType`, silently — for
  /// a uid it cannot find. On a direct station the configuration and the rows
  /// are one file on one machine. In gateway mode they are a backend that
  /// evaluated the rules and a panel holding a device-local mirror of a
  /// preference, so the moment they disagree that join makes an alarm renamed
  /// last week erase its own history, with no error anywhere.
  AlarmActive _historyOf(rp.AlarmHistoryEntry entry) {
    final rule = AlarmRule(
      level: _levelOf(entry.level),
      expression:
          ExpressionConfig(value: Expression(formula: entry.expression ?? '')),
      // Resolved by the backend against the configuration its engine actually
      // ran — including its refusal to guess: a row that names no rule, or one
      // whose rule has since been deleted, arrives as false rather than as
      // rule 0's answer.
      acknowledgeRequired: entry.acknowledgeRequired,
    );

    return AlarmActive(
      alarm: Alarm(
        config: AlarmConfig(
          uid: entry.uid,
          title: entry.title,
          description: entry.description,
          group: List<String>.of(entry.group),
          rules: [rule],
        ),
      ),
      notification: AlarmNotification(
        uid: entry.uid,
        active: entry.active,
        expression: entry.expression,
        rule: rule,
        // The backend's instant, in UTC. Never reconstructed through this
        // machine's time zone: that is the bug which makes two panels disagree
        // about when the line stopped.
        timestamp: entry.createdAt,
        ruleIndex: entry.ruleIndex,
        // Three states, and the null is load-bearing: a pre-v7 row recorded no
        // provenance at all, which is a different fact from a row that
        // positively records that the backend guessed.
        tsSource:
            entry.tsSource == null ? null : _tsSourceOf(entry.tsSource!),
      ),
      pendingAck: entry.pendingAck,
      deactivated: entry.deactivatedAt,
    );
  }

  /// Drops the subscription and the two observation surfaces.
  ///
  /// Called from `alarmManProvider`'s `onDispose` (CR-01). Before this it had
  /// no caller anywhere, so every gateway-mode rebuild left a subscription,
  /// two [BehaviorSubject]s and a `_reloadHistory` chain behind on a client
  /// that no longer existed.
  ///
  /// [_closing] is set **first**, so the deliberate teardown does not go out
  /// as [activeStreamClosed]. Cancelling a subscription does not fire `onDone`
  /// on its own, but the flag makes that a decision rather than a dependency
  /// on stream ordering.
  Future<void> close() async {
    _closing = true;
    await _subscription?.cancel();
    await _activeAlarms.close();
    await _historyController.close();
  }
}
