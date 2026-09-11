/// Minimal round trips for the three data services: timeseries, history views
/// and preferences.
///
/// ## SCOPE BOUNDARY — read before adding a case here
///
/// **Behavior beyond round-tripping belongs to Phase 10 (DB-01..DB-04) and must
/// not be added to this file.** CONTEXT `<deferred>` defers deep timeseries,
/// history-view and preferences semantics deliberately: the interface methods
/// are frozen now so the wire surface can be closed (a method that does not
/// exist cannot be invoked by a client), but what the database does behind them
/// is a Phase 10 question and answering it here would freeze guesses as
/// contract.
///
/// What belongs here: the method exists, it carries its arguments, it returns
/// its declared type, and the value comes back. What does not: query planning,
/// downsampling *accuracy* (as opposed to the point count and the window),
/// retention behavior, bucket-boundary semantics, index selection, cross-client
/// preference propagation over a real pipe, and anything requiring a real
/// database to be true. Each of those is a real property and each has a Phase
/// 10 requirement waiting for it; asserting a weaker version of it here would
/// mean Phase 10 inherits a contract that is already almost right, which is
/// harder to correct than one that is honestly silent.
///
/// The one apparent exception is not one. [checkDownsampledRespectsMaxPoints]
/// asserts a bound and a span, not a sampling strategy: "no more than
/// `maxPoints` came back and they still reach both ends of the window" is a
/// shape promise every downsampler must keep, where "which points" is exactly
/// the Phase 10 question. It is here because an unbounded downsample is a
/// denial of service — a month of one-second samples is millions of points on
/// a link that exists to avoid exactly that.
///
/// ## Shape
///
/// Follows `write_contract.dart`: no implementation is imported, every case is
/// a named top-level function, every await is wrapped in [within] so silence
/// fails by name instead of hanging. Two of the three services can be seeded
/// through their own API — a history view is created by creating one, a
/// preference is set by setting one — which is why only timeseries needs a
/// harness: there is no `insert` on [TimeseriesApi] and there must not be, so
/// samples have to arrive from outside the wire surface.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'check.dart';
import 'harness.dart';

/// The budget every check in this file waits on, and why it is not `within`'s
/// default.
///
/// 200 ms is a sensible default for a contract check that crosses an in-process
/// seam. **Every check in this file crosses a data store** — timeseries reads,
/// downsamples, history views — and one of the legs it runs on is a real
/// TimescaleDB. There a single downsample over 500 points is a query plan, a
/// connection and a round trip, which is a different order of magnitude from a
/// map lookup, and 200 ms was never a claim about it.
///
/// Measured: `tfc-dart-test (windows-latest)` failed
/// `a downsampled series coming back did not happen within 800 ms
/// (200 ms x 4.0 for this runner)` — that is, with the hosted-runner factor
/// already applied. A case that still fails once scaled is not slow, and the
/// honest reading is that the default was wrong for this transport rather than
/// that the runner was too slow for the default.
///
/// Still a liveness bound, and still scaled by `budgetScale` inside [within]:
/// this turns a hung query into a named failure, it does not measure latency.
/// **Bounded above by `suite_integrity_test`'s `_checkBudget` (2 s), and that
/// coupling is load-bearing.** That meta-test runs every check against a source
/// that never answers and requires each to give up inside its budget — "no
/// check can hang" is a property of this suite, and a check that takes longer
/// to fail than the meta-test allows breaks it. Setting this to 2 s put the two
/// numbers on top of each other and turned five integrity cases red. One second
/// leaves a second of margin; anything larger has to raise `_checkBudget` in
/// the same commit, and the file's own 90 s wall-clock budget with it.
const Duration _storeBudget = Duration(seconds: 1);

/// [within] with [_storeBudget], so the 38 call sites in this file read as they
/// did and there is one number to change rather than thirty-eight.
Future<T> _within<T>(Future<T> f, String what) =>
    within(f, what, budget: _storeBudget);


/// A recorded series on the pre-freezer line, named the way the database names
/// tables rather than the way the key space names tags — the parameter is
/// `tableName` and whether the wire speaks key space or table space is itself a
/// Phase 10 question (`state_man_api.dart:40-44`).
const _table = 'st101_cn01_mot01_setpoint';

/// A second series, deliberately never seeded: the one a multi-series query
/// must still return an entry for.
const _unrecordedTable = 'st201_cn04_mot01_setpoint';

/// Two plotted keys for the history-view cases, in the plant's tag convention.
const _keyA = 'ST101.CN01.MOT01.setpoint';
const _keyB = 'ST301.CN21.SEN01.temp';

/// The preference a change-notification case writes to.
const _prefKey = 'svn.ui.darkMode';

/// The one key [checkPreferenceClearCarriesItsAllowList] names in its allow
/// list. Deliberately a key the round-trip case already uses, so no leg's
/// clean-up list grows.
const _clearedKey = 'svn.chart.maxPoints';

/// The timeseries side of the test-only control surface.
///
/// Declared here, alongside the cases that need it, for the same reason
/// `StateManWriteHarness` is declared in `write_contract.dart`: a lever exists
/// because a case needs it, and putting it on `StateManApi` instead would make
/// it a thing a connected client may invoke, which is an access-control
/// decision and not a testing convenience.
///
/// Deliberately **not** an extension of `StateManHarness`. Nothing in this file
/// makes a plant value arrive — the data services read what was recorded, not
/// what is happening — so requiring `setValue`/`dropKey` of a source that only
/// serves history would be asking for levers no case here pulls.
///
/// There is exactly one lever, and its absence from the wire is the point: a
/// client that could insert samples could forge history, and a chart is
/// evidence. Recording is the gateway's job, upstream of anything a socket can
/// reach.
abstract interface class StateManDataHarness {
  /// Records [points] against [tableName], as the gateway's recorder would.
  void seedTimeseries(String tableName, List<TimeseriesData> points);
}

/// The [StateManDataHarness] side of [api], or a failure saying what is
/// missing.
///
/// Reported through `fail` rather than a cast error for the same reason
/// `harnessOf` does it: an implementation that arrives without a way to be
/// seeded gets a message telling its author what to add, instead of a
/// `_CastError` naming a line in this package.
StateManDataHarness dataHarnessOf(StateManApi api) {
  if (api is StateManDataHarness) return api as StateManDataHarness;
  fail('${api.runtimeType} does not implement StateManDataHarness, so no '
      'timeseries case can put a sample in front of it. An implementation '
      'under test must expose the test-only seeding lever (seedTimeseries) '
      'declared in package:tfc_stateman_contract — there is deliberately no '
      'way to insert a sample through the wire surface, because a client that '
      'could write history could forge it.');
}

/// Seeding, read off the implementation's own control surface.
///
/// The default behind [runDataServicesContract]'s `seedTimeseries` override.
void _seedFromHarness(
        StateManApi api, String tableName, List<TimeseriesData> points) =>
    dataHarnessOf(api).seedTimeseries(tableName, points);

/// A regular series, one sample a minute from [base].
List<TimeseriesData> _minutely(DateTime base, int count) => [
      for (var i = 0; i < count; i++)
        TimeseriesData<num>(1200 + i, base.add(Duration(minutes: i))),
    ];

/// Recorded samples come back, inside the window, oldest first.
///
/// The whole of what a chart asks for. Both halves are load-bearing: a source
/// that ignores the window hands a chart a month when it asked for an hour and
/// the chart draws a flat line across the wrong axis; a source that returns the
/// right samples in arrival order rather than time order draws a scribble,
/// because a line chart connects consecutive points and nothing sorts them
/// afterwards.
Future<void> checkTimeseriesQueryReturnsSeededPointsInOrder(
  StateManApi api, {
  void Function(StateManApi api, String tableName, List<TimeseriesData> points)?
      seedTimeseries,
}) async {
  final seed = seedTimeseries ?? _seedFromHarness;
  final base = DateTime.utc(2026, 8, 13, 6);
  seed(api, _table, _minutely(base, 7));

  final from = base.add(const Duration(minutes: 1));
  final to = base.add(const Duration(minutes: 5));
  final got = await _within(
      api.timeseries.queryTimeseriesData(_table, to, from: from),
      'a recorded series coming back');

  expect(got.map((point) => point.time).toList(), [
    for (var i = 1; i <= 5; i++) base.add(Duration(minutes: i)),
  ], reason: 'the window asked for was $from..$to and what came back was '
      '${got.map((p) => p.time.toIso8601String()).toList()}. Samples outside '
      'the window make a chart draw beyond the axis it was given; samples out '
      'of time order make it draw a scribble, because a line chart joins '
      'consecutive points and nothing sorts them on the way to the screen');
  expect(got.map((point) => point.value).toList(), [1201, 1202, 1203, 1204, 1205],
      reason: 'the samples that came back are not the ones that were recorded, '
          'so the chart is showing numbers the plant never produced');
}

/// Every requested series gets an entry, including the ones with no samples.
///
/// A missing key and an empty list are the same fact told two ways, and only
/// one of them is safe. A chart iterating the requested names and reading the
/// map finds null for a silent series and — because null-handling in a chart
/// legend is an afterthought everywhere — drops the series from the legend
/// entirely. The operator then sees a graph of three lines where four were
/// asked for, with nothing saying the fourth is missing rather than flat.
Future<void> checkTimeseriesMultipleReturnsAnEntryPerTable(
  StateManApi api, {
  void Function(StateManApi api, String tableName, List<TimeseriesData> points)?
      seedTimeseries,
}) async {
  final seed = seedTimeseries ?? _seedFromHarness;
  final base = DateTime.utc(2026, 8, 13, 6);
  seed(api, _table, _minutely(base, 5));

  final got = await _within(
      api.timeseries.queryTimeseriesDataMultiple(
          [_table, _unrecordedTable], base.add(const Duration(hours: 1)),
          from: base),
      'two series coming back in one round trip');

  expect(got.keys, containsAll([_table, _unrecordedTable]),
      reason: 'two series were asked for and ${got.keys.toList()} came back; a '
          'name with no entry is a series the chart silently drops from its '
          'legend, which reads as "this tag is flat" rather than as "nothing '
          'was recorded"');
  expect(got[_unrecordedTable], isEmpty,
      reason: 'the unrecorded series came back with samples in it, so the '
          'source is answering for a table it has nothing for');
  expect(got[_table], isNotEmpty,
      reason: 'the recorded series came back empty in a multi-series query '
          'while it has samples, so the batching path is losing what the '
          'single-series path finds');
}

/// A downsampled query is bounded, and still reaches both ends of the window.
///
/// The denial-of-service case (T-09-04). A month of one-second samples is
/// millions of points, a chart has hundreds of pixels, and the link between
/// them exists precisely to avoid sending the difference — so the bound is not
/// an optimisation, it is the reason the method exists separately at all.
///
/// The span half stops the bound being satisfied dishonestly. Returning the
/// first `maxPoints` samples respects the count and truncates the chart to the
/// first minute of the window, which draws a line that stops in mid-air; the
/// newest sample in particular is the one an operator reads as "now".
///
/// Which samples are chosen between the ends is Phase 10's question, and this
/// case deliberately does not ask it.
Future<void> checkDownsampledRespectsMaxPoints(
  StateManApi api, {
  void Function(StateManApi api, String tableName, List<TimeseriesData> points)?
      seedTimeseries,
}) async {
  final seed = seedTimeseries ?? _seedFromHarness;
  final base = DateTime.utc(2026, 8, 13, 6);
  final points = [
    for (var i = 0; i < 500; i++)
      TimeseriesData<num>(i, base.add(Duration(seconds: i))),
  ];
  seed(api, _table, points);

  final to = base.add(const Duration(seconds: 499));
  const maxPoints = 50;
  final got = await _within(
      api.timeseries
          .queryTimeseriesDataDownsampled(_table, base, to, maxPoints: maxPoints),
      'a downsampled series coming back');

  expect(got.length, lessThanOrEqualTo(maxPoints),
      reason: '${points.length} samples were downsampled to $maxPoints and '
          '${got.length} came back. Downsampling happens where the data is, '
          'and a bound that is not kept means a year of one-second samples '
          'crosses the link the moment somebody widens a chart');
  expect(got, isNotEmpty,
      reason: 'a window with 500 samples in it downsampled to nothing');
  expect(got.first.time, base,
      reason: 'the downsampled series starts at ${got.first.time} where the '
          'window starts at $base; the chart then draws a line that begins '
          'after its own axis does');
  expect(got.last.time, to,
      reason: 'the downsampled series ends at ${got.last.time} where the '
          'window ends at $to. The newest sample is the one an operator reads '
          'as the current value, and a downsample that drops it shows the '
          'plant as it was, with no indication of when');
}

/// A history view survives being created, listed, read back and deleted.
///
/// One round trip through the whole lifecycle of the thing the history page is
/// built on. The keys come back as records rather than as the untyped bags the
/// database layer produces today (`database_drift.dart:493-509`), which is what
/// lets the legend render an alias and the chart place a series on the right
/// axis without every call site knowing the shape of a map.
///
/// Delete must take the keys with it. A view whose rows outlive it is how a
/// deleted view reappears as a partial one after the next restart.
Future<void> checkHistoryViewCreateSelectDeleteRoundTrips(
    StateManApi api) async {
  final views = api.historyViews;

  final id = await _within(
      views.createHistoryView(
        'Frystir — vakt 1',
        [_keyA, _keyB],
        {
          _keyA: const HistoryViewKeyRecord(
              key: _keyA,
              alias: 'Færiband 1',
              useSecondYAxis: true,
              graphIndex: 1),
        },
        {1: const HistoryViewGraphRecord(graphIndex: 1, name: 'Frystir', yAxisUnit: '°C')},
      ),
      'creating a history view');

  expect(id, greaterThan(0),
      reason: 'creating a view returned $id; the id is what every later call '
          'addresses the view by, so a view without one cannot be opened, '
          'edited or deleted');

  final saved = await _within(views.selectHistoryViews(), 'the saved views');
  expect(saved.map((view) => view.id), contains(id),
      reason: 'a view was created and does not appear in the view picker, so '
          'the only way back to it is the id the caller happened to keep');
  expect(saved.firstWhere((view) => view.id == id).name, 'Frystir — vakt 1',
      reason: 'the view came back under a different name than it was saved '
          'with');

  final keys = await _within(views.getHistoryViewKeys(id), 'the view\'s keys');
  expect(keys.keys, containsAll([_keyA, _keyB]),
      reason: 'the view was saved plotting [$_keyA, $_keyB] and came back '
          'plotting ${keys.keys.toList()}');
  expect(keys[_keyA]?.alias, 'Færiband 1',
      reason: 'the legend label the engineer typed did not survive the round '
          'trip');
  expect(keys[_keyA]?.useSecondYAxis, isTrue,
      reason: 'a series saved against the second Y axis came back on the '
          'first, where a temperature and a motor speed share one scale and '
          'the temperature becomes a flat line at the bottom');
  expect(keys[_keyB]?.alias, _keyB,
      reason: 'a key saved with no alias came back with none either; the '
          'legend needs something to render, and the key\'s own name is it');

  final graphs = await _within(views.getHistoryViewGraphs(id), 'the view\'s graphs');
  expect(graphs[1]?.yAxisUnit, '°C',
      reason: 'the axis unit did not survive the round trip, so the chart '
          'draws numbers with nothing saying what they are');

  final names =
      await _within(views.getHistoryViewKeyNames(id), 'the view\'s key names');
  expect(names, containsAll([_keyA, _keyB]),
      reason: 'the name-only accessor disagrees with the record accessor about '
          'what this view plots');

  await _within(views.deleteHistoryView(id), 'deleting the view');
  final after = await _within(views.selectHistoryViews(), 'the views after the delete');
  expect(after.map((view) => view.id), isNot(contains(id)),
      reason: 'the deleted view is still in the picker');
  expect(await _within(views.getHistoryViewKeys(id), 'the deleted view\'s keys'),
      isEmpty,
      reason: 'the view was deleted and its plotted keys outlived it; those '
          'rows are what make a deleted view come back as a partial one after '
          'the next restart');
}

/// A saved time window survives being added, listed and deleted.
///
/// "Vakt 1", "síðasta keyrsla" — the windows an operator saves so they can come
/// back to the shift where something went wrong. The instants must round-trip
/// exactly: a window that comes back an hour off lands on the wrong shift,
/// which is the failure this being UTC end to end exists to prevent.
Future<void> checkHistoryViewPeriodRoundTrips(StateManApi api) async {
  final views = api.historyViews;
  final viewId = await _within(
      views.createHistoryView('Vaktir', [_keyA]), 'creating a history view');

  final start = DateTime.utc(2026, 8, 12, 6);
  final end = DateTime.utc(2026, 8, 12, 14);
  final periodId = await _within(
      views.addHistoryViewPeriod(viewId, 'Vakt 1', start, end),
      'saving a time window');

  expect(periodId, greaterThan(0),
      reason: 'saving a window returned $periodId; without an id it cannot be '
          'deleted again');

  final periods =
      await _within(views.listHistoryViewPeriods(viewId), 'the saved windows');
  expect(periods, hasLength(1),
      reason: 'one window was saved on this view and ${periods.length} came '
          'back');
  expect(periods.single.id, periodId,
      reason: 'the window came back under an id other than the one adding it '
          'returned, so deleting it would address something else');
  expect(periods.single.viewId, viewId,
      reason: 'the window came back attached to view ${periods.single.viewId} '
          'rather than $viewId');
  expect(periods.single.name, 'Vakt 1',
      reason: 'the window came back under a different name');
  expect(periods.single.startAt, start,
      reason: 'the window starts at ${periods.single.startAt} where it was '
          'saved starting at $start; an operator returning to a saved shift '
          'lands on the wrong one, and every conclusion drawn from the chart '
          'is about the wrong hours');
  expect(periods.single.endAt, end,
      reason: 'the window ends at ${periods.single.endAt} where it was saved '
          'ending at $end');

  await _within(views.deleteHistoryViewPeriod(periodId), 'deleting the window');
  expect(
      await _within(
          views.listHistoryViewPeriods(viewId), 'the windows after the delete'),
      isEmpty,
      reason: 'the deleted window is still listed on the view');
}

/// Every typed preference round-trips, and `containsKey` agrees.
///
/// One pair per type, because the types are where a store goes wrong: a double
/// that comes back an int, a string list that comes back a string, a bool that
/// comes back the string "true". [PreferencesApi.containsKey] is asserted
/// alongside them because "absent" and "set to null" are different answers and
/// a settings page renders a default for one and a blank for the other.
///
/// Deliberately no secret material anywhere in this case, and no `secret`
/// parameter to pass one through (SEC-01, T-09-02): the interface has no such
/// parameter and `api_surface_test.dart` fails if one appears.
Future<void> checkPreferenceSetGetRoundTrips(StateManApi api) async {
  final prefs = api.preferences;

  await _within(prefs.setBool(_prefKey, true), 'saving a bool preference');
  expect(await _within(prefs.getBool(_prefKey), 'reading a bool preference'),
      isTrue,
      reason: 'a bool did not survive the round trip');

  await _within(
      prefs.setInt('svn.chart.maxPoints', 800), 'saving an int preference');
  expect(
      await _within(
          prefs.getInt('svn.chart.maxPoints'), 'reading an int preference'),
      800,
      reason: 'an int did not survive the round trip');

  await _within(prefs.setDouble('svn.weigher.tolerance', 0.25),
      'saving a double preference');
  expect(
      await _within(prefs.getDouble('svn.weigher.tolerance'),
          'reading a double preference'),
      0.25,
      reason: 'a double did not survive the round trip; a tolerance that comes '
          'back as an int is a weigher grading to the nearest whole gram');

  await _within(
      prefs.setString('svn.site.name', 'Sæból'), 'saving a string preference');
  expect(
      await _within(
          prefs.getString('svn.site.name'), 'reading a string preference'),
      'Sæból',
      reason: 'a string did not survive the round trip intact; the site names '
          'here carry Icelandic characters and a store that mangles them '
          'renders them mangled on every page header');

  await _within(prefs.setStringList('svn.page.recent', ['frystir', 'pökkun']),
      'saving a string list preference');
  expect(
      await _within(
          prefs.getStringList('svn.page.recent'), 'reading a string list'),
      ['frystir', 'pökkun'],
      reason: 'a string list did not survive the round trip');

  expect(await _within(prefs.containsKey(_prefKey), 'containsKey on a set key'),
      isTrue,
      reason: 'a key that was just set reads as absent');
  expect(
      await _within(
          prefs.containsKey('svn.never.set'), 'containsKey on an unset key'),
      isFalse,
      reason: 'a key that was never set reads as present, so a settings page '
          'shows a blank where it should show the default');

  final keys = await _within(prefs.getKeys(), 'enumerating the stored keys');
  expect(keys, containsAll([_prefKey, 'svn.site.name', 'svn.page.recent']),
      reason: 'keys that were set do not appear in the enumeration');

  await _within(prefs.remove('svn.site.name'), 'removing a preference');
  expect(
      await _within(
          prefs.containsKey('svn.site.name'), 'containsKey after a remove'),
      isFalse,
      reason: 'a removed key still reads as present');
  expect(
      await _within(prefs.getString('svn.site.name'), 'reading a removed key'),
      isNull,
      reason: 'a removed key still has a value behind it');
}

/// `clear` carries its allow list: the named keys go, the others stay.
///
/// **Why this is in scope for a round-trip file.** It is the same question
/// every other case here asks — does the method exist, does it carry its
/// argument, does the effect come back — asked of the one method whose argument
/// is the difference between emptying a page's own section and emptying the
/// gateway. Nothing about *which* keys a deployment considers clearable is
/// asserted; that is policy and lives in `policy_state_man.dart`.
///
/// **Why it was added** (10-REVIEW CR-02). `preferences.clear` is the phase's
/// single most destructive method and **no check on any leg called it**. Its
/// only judge was `preference_store_test.dart`, which is `db`-tagged and
/// therefore *excluded* from the default lane rather than skipped in it — an
/// excluded file reports nothing, so the method was unjudged on four legs and
/// invisible on the fifth. A handler that dropped the allow list on the way
/// down would have turned every "clear my page's settings" into "clear the
/// gateway's routing configuration", and five green legs would have said
/// nothing.
///
/// Both keys are already in the file's fixture set, so a leg that cleans up
/// after itself by name needs no new entry.
Future<void> checkPreferenceClearCarriesItsAllowList(StateManApi api) async {
  final prefs = api.preferences;

  await _within(prefs.setBool(_prefKey, true), 'saving the key that must stay');
  await _within(prefs.setInt(_clearedKey, 800), 'saving the key to be cleared');

  await _within(prefs.clear(allowList: <String>{_clearedKey}),
      'clearing exactly one named key');

  expect(
      await _within(
          prefs.containsKey(_clearedKey), 'containsKey on the cleared key'),
      isFalse,
      reason: 'the key named in the allow list is still stored, so `clear` '
          'either ignored its argument or did nothing at all');
  expect(
      await _within(prefs.getBool(_prefKey), 'reading the key that must stay'),
      isTrue,
      reason: 'a key the allow list did NOT name was removed. This is the '
          'direction that matters: with no allow list `clear` removes every '
          'preference this gateway holds, `key_mappings` — 518 KiB of routing '
          'configuration the whole plant is served through — included, and it '
          'is not restored by reconnecting. A layer that dropped the argument '
          'on the way down would turn a settings page tidying up into that');
}

/// A preference change reaches a second listener.
///
/// DB-03's cross-client notification starts as this property. Over a pipe with
/// several clients on one site, two operators have the same settings page open;
/// without a change stream the second one's form holds stale values until they
/// reopen it, and saving from there quietly overwrites the first one's edit.
///
/// The stream must be broadcast, which is why the case takes a *second*
/// listener rather than one: a settings page and a chart legend both want this,
/// and a single-subscription stream gives the second an exception instead of
/// the news.
///
/// Both awaits are bounded by [within] deliberately. A change stream that was
/// never wired emits nothing at all, and nothing at all is precisely the shape
/// of failure that hangs a suite to the runner's timeout and then reports a
/// file name instead of a property.
Future<void> checkPreferenceChangeNotifiesASecondListener(
    StateManApi api) async {
  final prefs = api.preferences;

  /// Subscribes now and reports the outcome later, without ever erroring.
  ///
  /// Two deadlines run at once in this case, and against a source that emits
  /// nothing they expire together. A [within] that expires on a future nobody
  /// is awaiting *yet* becomes an unhandled async error — which the runner
  /// attributes to whatever test is in progress rather than to this case, and
  /// which `expectContractViolation` therefore cannot catch, so the sabotage
  /// suite would report a zone error instead of the promise that was broken.
  /// Converting each listener into an outcome that never errors lets both be
  /// collected first and the failure raised deliberately, in the order this
  /// case is named for.
  Future<Object?> nextChange(String what) {
    try {
      return within(prefs.onPreferencesChanged.first, what)
          .then<Object?>((key) => key, onError: (Object error) => error);
    } catch (error) {
      fail('$what could not even be waited for: taking a listener threw '
          '${error.runtimeType} ($error). onPreferencesChanged must be a '
          'broadcast stream — a settings page and a chart legend both listen '
          'to it, and on a site with two clients the second listener getting '
          'an exception instead of the news is how one operator\'s edit '
          'silently overwrites another\'s');
    }
  }

  final first = nextChange('the first listener hearing the change');
  final second = nextChange('a second listener hearing the same change');

  await _within(prefs.setBool(_prefKey, true), 'the preference write completing');

  final heardSecond = await second;
  final heardFirst = await first;

  // The second listener's failure is raised first: it is the one this property
  // is about, and a source that notifies only whoever subscribed first is
  // exactly the shape of bug DB-03 is written against.
  if (heardSecond is! String) throw heardSecond as Object;
  if (heardFirst is! String) throw heardFirst as Object;

  expect(heardSecond, _prefKey,
      reason: 'the second listener was told about a different key than the one '
          'that changed');
  expect(heardFirst, _prefKey,
      reason: 'the first listener was told about a different key than the one '
          'that changed');
}

/// The case names, declared once so [runDataServicesContract] can override a
/// case by name without the string appearing twice.
const _seriesCase = 'a recorded series comes back inside the window, oldest '
    'first';
const _multipleCase =
    'every requested series gets an entry, including the silent ones';
const _downsampleCase =
    'a downsampled series is bounded and still reaches both ends of the window';
const _viewCase = 'a history view survives create, list, read back and delete';
const _periodCase = 'a saved time window survives add, list and delete';
const _prefRoundTripCase = 'every typed preference round-trips and containsKey '
    'agrees';
const _prefNotifyCase = 'a preference change reaches a second listener';
const _prefClearCase = 'clear removes the keys its allow list names and no '
    'others';

/// Every data-service property, keyed by the sentence it asserts.
///
/// Eight round trips and not one semantic beyond them — see the scope boundary
/// at the top of this file before adding a ninth.
///
/// **Seven became eight in the 10-REVIEW fix cycle** (CR-02): `clear` had no
/// judge on any leg, which is how the widest method on this interface reached
/// the wire ungated by anything but the role that sets a theme. See
/// [checkPreferenceClearCarriesItsAllowList].
const dataServicesChecks = <String, Check<StateManApi>>{
  _seriesCase: checkTimeseriesQueryReturnsSeededPointsInOrder,
  _multipleCase: checkTimeseriesMultipleReturnsAnEntryPerTable,
  _downsampleCase: checkDownsampledRespectsMaxPoints,
  _viewCase: checkHistoryViewCreateSelectDeleteRoundTrips,
  _periodCase: checkHistoryViewPeriodRoundTrips,
  _prefRoundTripCase: checkPreferenceSetGetRoundTrips,
  _prefNotifyCase: checkPreferenceChangeNotifiesASecondListener,
  _prefClearCase: checkPreferenceClearCarriesItsAllowList,
};

/// Registers the data-service contract against implementations from [make].
///
/// [supportsDataServices] `false` skips the group with a reason on the record
/// rather than passing it vacuously — a source with no database behind it is
/// then visible in the run report instead of absent from it.
///
/// [seedTimeseries] overrides where recorded samples come from, for an
/// implementation whose recorder is not in the same process as the test — a
/// remote source seeds through the gateway, not through its own memory. Left
/// null, the three timeseries cases read the lever off [StateManDataHarness],
/// which is what every in-memory implementation does. The history-view and
/// preference cases need no hook: they seed through their own API, because
/// creating a view *is* the round trip under test.
///
/// One fresh instance per case, disposed by `addTearDown`: the view ids and the
/// preference store are only meaningful when nothing from a previous case has
/// touched them.
void runDataServicesContract(
  StateManApi Function() make, {
  bool supportsDataServices = true,
  void Function(StateManApi api, String tableName, List<TimeseriesData> points)?
      seedTimeseries,
  Set<String> expectUnreachable = const {},
}) {
  final cases = <String, Check<StateManApi>>{
    ...dataServicesChecks,
    if (seedTimeseries != null) ...{
      _seriesCase: (api) => checkTimeseriesQueryReturnsSeededPointsInOrder(api,
          seedTimeseries: seedTimeseries),
      _multipleCase: (api) => checkTimeseriesMultipleReturnsAnEntryPerTable(api,
          seedTimeseries: seedTimeseries),
      _downsampleCase: (api) =>
          checkDownsampledRespectsMaxPoints(api, seedTimeseries: seedTimeseries),
    },
  };

  group('data services', () {
    cases.forEach((property, check) {
      test(property, () async {
        final api = make();
        addTearDown(api.dispose);
        // The link, before the property. On an in-process source this is a
        // synchronous read and nothing more; behind a socket it is where the
        // connect, the handshake and the first subscribe come due, and leaving
        // them inside the case's own budget made the first check in this suite
        // a measurement of the transport (`harness.dart`'s [linkUp]).
        await linkUp(api);
        if (expectUnreachable.contains(property)) {
          await expectUnreachableMethod(property, () => check(api));
          return;
        }
        await check(api);
      });
    });
  },
      skip: supportsDataServices
          ? null
          : 'this implementation declares no data services; the contract is '
              'skipped rather than passed, so the capability is visible in '
              'the run report instead of absent from it');
}
