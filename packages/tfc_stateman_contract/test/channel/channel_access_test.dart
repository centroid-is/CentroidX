/// The access refusal is the *same shape* over the channel as in memory — a
/// claim about the transport, so it lives here and not in `access_contract.dart`.
///
/// D-09: a refusal must come back as one exception type on both legs, so a
/// screen — and a contract case — cannot tell which transport refused it. The
/// harness peer must forward whatever the underlying implementation throws; it
/// must not mint its own `forbidden`. If it did, the channel leg would pass the
/// suite's negative arms against an implementation with no gate at all.
///
/// Two things are asserted:
///
///  * an authorisation refusal that happened server-side arrives on the client
///    as the **same [AccessDenied]** — same item key, same required group,
///    same "definitively no effect" wording — as the in-memory leg throws;
///  * a **domain** refusal (a bound template) arrives as something that is
///    NOT an [AccessDenied], because it is not an authorisation verdict — the
///    same distinction the in-memory leg keeps.
@Tags(['contract'])
library;

import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';
import 'package:test/test.dart';

AccessTemplate _tpl(String name) => AccessTemplate(
    name: name, rules: const {kWholeKeyMember: AccessGroup.setpoints});

/// Runs [body] and returns whatever it threw, or null.
Future<Object?> _thrown(Future<void> Function() body) async {
  try {
    await body();
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  group('a refusal over the channel has the same shape as in memory', () {
    test('an authorisation refusal is the same AccessDenied on both legs',
        () async {
      // In memory.
      final memory = FakeStateMan();
      addTearDown(memory.dispose);
      memory.actAs(AccessSession(groups: {AccessGroup.configure}));
      final memoryRefusal =
          await _thrown(() => memory.accessTemplates.create(_tpl('x')));

      // Over the channel: the same source, the same session, served.
      final served = serveFakeOverChannel();
      addTearDown(served.api.dispose);
      (served.api as StateManAccessHarness)
          .actAs(AccessSession(groups: {AccessGroup.configure}));
      final channelRefusal =
          await _thrown(() => served.api.accessTemplates.create(_tpl('x')));

      expect(memoryRefusal, isA<AccessDenied>(),
          reason: 'the in-memory leg did not refuse a create for a configure '
              'session: $memoryRefusal');
      expect(channelRefusal, isA<AccessDenied>(),
          reason: 'the channel minted a different error type than the '
              'in-memory leg ($channelRefusal). A refusal a screen cannot '
              'match by type is a refusal a caller cannot handle uniformly');

      final m = memoryRefusal as AccessDenied;
      final c = channelRefusal as AccessDenied;
      expect(c.required, m.required,
          reason: 'the channel refusal names a different required group '
              '(${c.required}) than the in-memory one (${m.required})');
      expect(c.itemKey, m.itemKey,
          reason: 'the channel refusal names a different item (${c.itemKey}) '
              'than the in-memory one (${m.itemKey})');
      expect('$c', '$m',
          reason: 'the "definitively no effect" wording differs between the '
              'two legs, so an operator reading a log cannot tell they are the '
              'same refusal');
    });

    test('a domain refusal is NOT dressed up as an AccessDenied over the channel',
        () async {
      final served = serveFakeOverChannel();
      addTearDown(served.api.dispose);
      final h = served.api as StateManAccessHarness;
      h.actAs(AccessSession(groups: AccessGroup.values.toSet()));

      await served.api.accessTemplates.create(_tpl('bound'));
      await served.api.accessTemplates.bind('ST101.CN01.MOT01', 'bound');

      final refusal =
          await _thrown(() => served.api.accessTemplates.delete('bound'));
      expect(refusal, isNotNull,
          reason: 'a bound template was deleted over the channel with no '
              'complaint');
      expect(refusal, isNot(isA<AccessDenied>()),
          reason: 'the domain refusal (a bound template) arrived as an '
              'AccessDenied over the channel ($refusal); the transport dressed '
              'a data rule up as an authorisation verdict, which would write a '
              'false deny row in the trail');
    });

    test('the permitted neighbour still crosses the channel', () async {
      // Anti-vacuity: the refusals above prove nothing if the channel refuses
      // everything. A users session creates a template and reads it back.
      final served = serveFakeOverChannel();
      addTearDown(served.api.dispose);
      (served.api as StateManAccessHarness)
          .actAs(AccessSession(groups: {AccessGroup.users}));
      await served.api.accessTemplates.create(_tpl('ok'));
      // Read back via list(): the access audit cut `template(name)` from the
      // wire, and deriving the row from list() is exactly what a remote does.
      final back = (await served.api.accessTemplates.list())
          .where((t) => t.name == 'ok')
          .firstOrNull;
      expect(back?.name, 'ok',
          reason: 'a permitted create did not survive the channel round trip');
    });
  });
}
