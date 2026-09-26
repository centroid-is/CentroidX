/// A stored preference of the wrong type surfaces as the `TypeError`
/// `PreferencesApi` promises — and a pre-handshake refusal does not.
///
/// 10-PATTERNS finding 5, ruled a real bug in 10-CONTEXT amendment 5.
/// `client_sub_apis.dart` checked `-32001`, which is the *contract harness*'s
/// number for a type mismatch (`rpc_names.dart:53`, the kit's own peer). On
/// this wire `-32001` is `ServerErrorCodes.helloRequired` and the gateway's
/// type mismatch is `-32010`. So the check was not a near miss: it could only
/// ever fire on the wrong thing, in both directions at once. A settings page
/// catching `TypeError` around a `getInt` — the code being ported already does
/// — saw a raw `RpcException` instead, and a call that arrived before the
/// handshake was re-raised to it as a type error about a value nobody read.
///
/// Both directions get a named case, because fixing one number can only be
/// proven by the pair.
library;

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_relay_client/src/client_sub_apis.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The two numbers the bug confused. Spelled here rather than imported for the
/// same reason the production file spells its own: `tfc_relay_server` is not a
/// dependency of this package, and the value *is* the contract
/// (`error_codes.dart:43-47, :94-100`).
const int _helloRequired = -32001;
const int _typeMismatch = -32010;

/// A preferences API whose every call comes back as [error].
ClientPreferencesApi _refusing(rpc.RpcException error) =>
    ClientPreferencesApi((method, params) async => throw error);

void main() {
  group('the gateway says the stored value is the wrong type (-32010)', () {
    test('getInt surfaces it as the TypeError the interface promises',
        () async {
      final api = _refusing(rpc.RpcException(_typeMismatch,
          "type 'String' is not a subtype of type 'int' for key ui.scale"));
      addTearDown(api.dispose);

      await expectLater(
          api.getInt('ui.scale'), throwsA(isA<RemoteTypeError>()),
          reason: 'PreferencesApi\'s typed getters "throw a TypeError when the '
              'stored value is of another type" (preferences_api.dart:51-65), '
              'and that is part of the interface being mirrored — a ported '
              'settings page catches TypeError and is entitled to keep doing '
              'so over the pipe');
    });

    test('it is a TypeError, not merely a class named like one', () async {
      final api = _refusing(rpc.RpcException(_typeMismatch, 'wrong type'));
      addTearDown(api.dispose);

      await expectLater(api.getBool('ui.dark'), throwsA(isA<TypeError>()),
          reason: 'the promise is the Dart type, so `on TypeError` in ported '
              'code has to catch it; a lookalike would compile and never fire');
    });

    test('the far side\'s own message survives', () async {
      final api = _refusing(rpc.RpcException(_typeMismatch,
          "type 'String' is not a subtype of type 'int' for key ui.scale"));
      addTearDown(api.dispose);

      await expectLater(
          api.getInt('ui.scale'),
          throwsA(isA<RemoteTypeError>().having((error) => error.message,
              'message', contains('ui.scale'))),
          reason: 'the cast happened where the value is stored, so the useful '
              'half of the answer is the far side\'s description — it names '
              'the key and what was actually in it');
    });

    test('every typed getter carries the same promise', () async {
      final calls = <String, Future<Object?> Function(PreferencesApi)>{
        'getBool': (api) => api.getBool('k'),
        'getInt': (api) => api.getInt('k'),
        'getDouble': (api) => api.getDouble('k'),
        'getString': (api) => api.getString('k'),
        'getStringList': (api) => api.getStringList('k'),
      };
      expect(calls, isNotEmpty,
          reason: 'anti-vacuity: an empty sweep asserts nothing');

      for (final entry in calls.entries) {
        final api = _refusing(rpc.RpcException(_typeMismatch, 'wrong type'));
        addTearDown(api.dispose);
        await expectLater(entry.value(api), throwsA(isA<RemoteTypeError>()),
            reason: '${entry.key} documents the same TypeError as the rest, '
                'and a fix applied to one getter and not the others is the '
                'shape of bug this sweep exists to catch');
      }
    });
  });

  group('the gateway says hello has not happened yet (-32001)', () {
    test('it does not become a TypeError', () async {
      final api = _refusing(rpc.RpcException(
          _helloRequired, 'say hello before calling preferences.getInt'));
      addTearDown(api.dispose);

      await expectLater(api.getInt('ui.scale'), throwsA(isNot(isA<TypeError>())),
          reason: 'on this wire -32001 is helloRequired: the session has not '
              'negotiated and the call has to be re-sent after it does. '
              'Re-raising it as a TypeError tells a settings page the stored '
              'value is the wrong type, which sends somebody looking at a '
              'preference row that is fine');
    });

    test('it stays the RpcException it arrived as', () async {
      final api = _refusing(rpc.RpcException(
          _helloRequired, 'say hello before calling preferences.getInt'));
      addTearDown(api.dispose);

      await expectLater(
          api.getInt('ui.scale'),
          throwsA(isA<rpc.RpcException>()
              .having((error) => error.code, 'code', _helloRequired)),
          reason: 'the code reaches the caller intact, so the failure taxonomy '
              'above can still tell a pre-handshake refusal from anything '
              'else');
    });
  });

  group('everything else passes through', () {
    test('an unrelated error code is rethrown unchanged', () async {
      final api = _refusing(
          rpc.RpcException(ServerCodesUnderTest.handlerFailed, 'it broke'));
      addTearDown(api.dispose);

      await expectLater(
          api.getInt('k'),
          throwsA(isA<rpc.RpcException>().having(
              (error) => error.code, 'code', ServerCodesUnderTest.handlerFailed)),
          reason: 'the translation is one code wide. A handler that failed is '
              'retryable with backoff and a type mismatch is not, and a client '
              'that confused them would either give up on a transient fault or '
              'hammer a permanent one');
    });

    test('a value that is the right type comes back as itself', () async {
      final api = ClientPreferencesApi((method, params) async => 42);
      addTearDown(api.dispose);

      expect(await api.getInt('ui.scale'), 42,
          reason: 'anti-vacuity: if the wrapper threw on everything the cases '
              'above would all pass');
    });
  });
}

/// The one server code this file names beyond the pair under test.
abstract final class ServerCodesUnderTest {
  static const handlerFailed = -32011;
}
