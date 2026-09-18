/// The two ways a real implementation will lie about freshness, plus the one
/// way it will drown the client while telling the truth.
///
/// `broken_subscribe.dart` covers implementations that lose values. These lose
/// something harder to notice: they deliver values perfectly and are wrong
/// about whether those values mean anything. RESEARCH found that nothing in the
/// current codebase carries a quality or a timestamp on a value, so every case
/// in `freshness_contract.dart` was written from the design document with no
/// working behavior to compare against. These variants are the evidence that
/// those cases would catch anything at all: without them, "the freshness suite
/// bites" is an untested claim about untested code.
///
/// Each class replaces exactly one behavior of [FakeStateMan] and inherits
/// everything else, so `test/sabotage_freshness_test.dart` can assert both
/// halves of a sabotage — the targeted check fails, and an unrelated one still
/// passes. A variant that failed everything would prove only that it was
/// broken.
///
/// None of these is a plausible bug in *this* package. All three have shipped
/// in real state layers, which is why the checks that catch them are worth
/// their runtime forever.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'fake_state_man.dart';

/// Never ages a value: whatever it last heard stays good forever.
///
/// Imitates an upstream subscription that died while the link stayed up. The
/// socket is connected, the gateway answers pings, `PIPE.connected` says true,
/// every box on the mimic shows a number in the normal colour — and not one of
/// those numbers has moved since the subscription lapsed. An operator cannot
/// see this by looking, cannot see it by waiting, and will make a decision on
/// it. It is the failure the whole project is organised around, and the one
/// named in the roadmap's fourth success criterion.
///
/// The sabotage is the absence of a sweep, which is exactly how the real bug
/// arrives: nobody writes code to freeze a value, they write code that forgets
/// to check.
class ServesStaleReads extends FakeStateMan {
  ServesStaleReads({super.staleAfter});

  @override
  void sweepFreshness() {
    // Deliberately nothing. Values age; this source does not notice.
  }
}

/// Keeps reporting good quality for plant keys after the link has dropped.
///
/// Imitates a client that treats "no news" as "good news": it notices the
/// disconnect at the transport layer, updates its own health flag honestly, and
/// never propagates the consequence to the values it is serving. That honest
/// health flag is what makes it realistic — and dangerous. The one indicator
/// that is correct is the one on the diagnostics page nobody has open, while
/// every number on the mimic in front of the operator still claims to be live.
///
/// This is why `checkUpstreamLossDegradesAffectedKeys` asserts on the *values*
/// and not on the health key: a source can be right about the pipe and wrong
/// about everything the pipe carries.
class LiesAboutQuality extends FakeStateMan {
  LiesAboutQuality({super.staleAfter});

  @override
  void applyLinkLoss() {
    // The health key is updated, faithfully. Nothing else is touched, so every
    // plant key keeps whatever quality it had — good, in the normal case.
    applyChanges({
      '${FakeStateMan.healthPrefix}connected': DynamicValue(value: false),
    });
  }
}

/// Announces the link loss once per key instead of once.
///
/// Imitates a naive status fan-out: the degradation is correct, every value
/// ends up with the right quality, and the client is told about it 1500 times
/// in the same instant it is trying to redraw all 1500 boxes. Correct and
/// unusable — the same shape of bug as `NotifiesOnUnchanged`, and the reason
/// the contract asserts a *count* rather than an outcome. Sparkplug sends one
/// NDEATH for a whole node precisely so this cannot happen.
///
/// It overrides only the announcement, so the degradation it fans out is the
/// honest one.
class AnnouncesPerKey extends FakeStateMan {
  AnnouncesPerKey({super.staleAfter});

  @override
  void announceLinkState() {
    for (final _ in keys) {
      super.announceLinkState();
    }
  }
}
