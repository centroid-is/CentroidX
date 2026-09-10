/// A stream that tears itself down when the last listener leaves.
///
/// Pure plumbing — a `ReplaySubject`, a listener count and an idle timer — that
/// lived in `state_man.dart` beside the OPC UA client. `collector.dart`
/// constructs one and names nothing else from that library, so this single type
/// tied the collector, and every HMI asset that reaches it, to `dart:ffi`.
///
/// ## Why four fields are public
///
/// `OpcUaStateMan` drives this object's internals directly during a
/// resubscribe: it cancels [rawSub] for every key *before* creating any new
/// monitored item, because after a session loss the server reissues monIds from
/// 1 and an interleaved create/delete can have one key's stale delete destroy
/// another key's fresh item. That ordering is the fix for a real fault and it
/// needs the raw subscription handle, not a stream view.
///
/// While both lived in one library those were private fields and the coupling
/// was invisible. Moving the class makes it explicit rather than new: these are
/// marked [internal] so the analyzer keeps them inside this package, and the
/// only writer outside this file is `state_man.dart`.
library;

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:meta/meta.dart' show internal;
import 'package:rxdart/rxdart.dart';

class AutoDisposingStream<T> {
  final String key;
  @internal
  final ReplaySubject<T> subject;
  final Logger _logger = Logger();
  int _listenerCount = 0;
  @internal
  Timer? idleTimer;
  @internal
  StreamSubscription<T>? rawSub;
  final Function(String key) _onDispose;
  T? _lastValue;

  /// Set once a permanent (BadNodeIdUnknown) error has been reported for this
  /// key, so the same dead mapping is not reprinted on every retry.
  bool _loggedPermanentError = false;

  /// Last error the raw stream reported, so a first-value timeout can name
  /// the server's actual complaint instead of just saying it timed out.
  @internal
  String? lastRawError;

  final Duration idleTimeout;
  AutoDisposingStream(this.key, this._onDispose,
      {this.idleTimeout = const Duration(minutes: 10)})
      : subject = ReplaySubject<T>(maxSize: 1) {
    // Count UI listeners for idle shutdown:
    subject
      ..onListen = _handleListen
      ..onCancel = _handleCancel;
  }

  Stream<T> get stream => subject.stream;

  /// True once the subject is closed and this entry can never deliver again.
  ///
  /// A closed subject hands a new listener the replay buffer and then `done`,
  /// which looks to a widget exactly like a key that has stopped updating.
  /// [StateMan._monitor] checks this before reusing a cached entry.
  bool get isSpent => subject.isClosed;

  void subscribe(Stream<T> raw, T? firstValue) {
    _logger.d('[$key] subscribe() called: '
        'subjectClosed=${subject.isClosed}, '
        'listeners=$_listenerCount, '
        'hadRawSub=${rawSub != null}, '
        'hasFirstValue=${firstValue != null}');
    rawSub?.cancel();
    // wire raw → subject
    rawSub = raw.listen(
      (value) {
        if (subject.isClosed) {
          _logger.e(
              '[$key] RAW STREAM emitted value but subject is CLOSED — data lost!');
          return;
        }
        _lastValue = value;
        subject.add(value);
      },
      onError: (error, stackTrace) {
        // BadNodeIdUnknown is the server's final answer: that node does not
        // exist in its address space, so every retry will get the same reply.
        // Log it once at error level and then stay quiet, rather than
        // reprinting the same dead mapping on every reconnect and burying the
        // faults that are actually actionable.
        lastRawError = '$error';
        final permanent = '$error'.contains('BadNodeIdUnknown');
        if (permanent && _loggedPermanentError) {
          // already reported; swallow the repeat
        } else {
          _logger.e('[$key] raw stream error: $error'
              '${permanent ? " (node does not exist -- fix or remove this key "
                  "mapping; further repeats suppressed)" : ""}');
          if (permanent) _loggedPermanentError = true;
        }
        if (!subject.isClosed) {
          subject.addError(error, stackTrace);
        }
      },
      onDone: () {
        _logger.w('[$key] raw stream DONE — '
            'subject will close! listeners=$_listenerCount, '
            'subjectClosed=${subject.isClosed}');
        // A spent entry must not leave an idle timer armed. _onDispose
        // removes BY KEY, so a timer surviving into the next subscription for
        // this key would evict the live entry that replaced this one, and the
        // subscriber after that would ask the PLC for four more monitored
        // items while the displaced entry kept streaming.
        idleTimer?.cancel();
        idleTimer = null;
        subject.close();
        // Retire the entry as well. The idle path already does both -- it
        // calls _onDispose before closing -- but this one used to close and
        // leave the entry in StateMan._subscriptions, so the next subscriber
        // for this key was handed a closed subject and saw nothing. That is
        // what made a readout stay blank on returning to a page while
        // selecting a different key worked: the different key had no cached
        // entry to inherit.
        _onDispose(key);
      },
    );
    _lastValue = firstValue;
    if (firstValue != null) {
      if (subject.isClosed) {
        _logger.e('[$key] subject is CLOSED, cannot add firstValue!');
      } else {
        subject.add(firstValue);
        _logger.d('[$key] firstValue pushed to subject');
      }
    }
  }

  void _handleListen() {
    _listenerCount++;
    idleTimer?.cancel();
    _logger.d('[$key] listener added (count=$_listenerCount)');
  }

  void _handleCancel() {
    _listenerCount--;
    _logger.d('[$key] listener removed (count=$_listenerCount)');
    // Nothing left to retire, and nothing that may outlive this entry.
    if (subject.isClosed) return;
    if (_listenerCount == 0) {
      _logger.w(
          '[$key] no listeners left, starting ${idleTimeout.inSeconds}s idle timer');
      idleTimer = Timer(idleTimeout, () {
        _logger.w('[$key] idle timer fired — disposing');
        rawSub?.cancel(); // tear down the OPC-UA monitoredItem
        _onDispose(key); // remove from StateMan._subscriptions
        subject.close(); // close the replay buffer
      });
    }
  }

  void resendLastValue() {
    // A spent entry can still be reachable from ClientWrapper.streams; adding
    // to its closed subject throws StateError, which would abort the recovery
    // loop and leave every later key on that server unrefreshed.
    if (subject.isClosed) return;
    if (_lastValue != null) {
      subject.add(_lastValue!);
    }
  }
}
