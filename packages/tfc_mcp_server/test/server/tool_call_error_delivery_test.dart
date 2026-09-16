/// A tool call that cannot succeed must be *answered*.
///
/// Reported from a plant: `propose_asset` with a child that omitted the
/// required `key` never returned. Not slowly — never: past 30 s, past 90 s,
/// past 240 s, with nothing staged, nothing logged and no error. The same
/// call with `key` set to an empty string came back in 0.03 s, which is what
/// narrowed it to argument validation rather than to anything the tool does.
///
/// The mechanism is a collaboration between two layers of mcp_dart:
///
///  * `McpServer`'s `tools/call` handler validates the arguments against the
///    tool's advertised input schema and *throws* `McpError` when they do not
///    match, before the tool's callback is ever reached.
///  * `StreamableHTTPServerTransport.send` writes the resulting JSON-RPC
///    error onto the request's SSE stream and then leaves that stream open
///    forever: its close-and-clean-up branch is gated on
///    `_isJsonRpcResponse(message)`, and a `JsonRpcError` is not one.
///
/// So the caller is left holding an HTTP response that never ends. The fix is
/// in `ToolRegistry`: it takes `tools/call` over, validates inside its own
/// pipeline, and answers every failure with an ordinary `CallToolResult`
/// carrying `isError: true` — a JSON-RPC *result*, which the transport does
/// terminate.
///
/// The first group here is the one that actually reproduces the defect: it
/// speaks raw HTTP so it can assert the thing that was wrong, namely that the
/// response *ends*. A client object cannot see that distinction, so the
/// second group covers the message and the audit row instead.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/audit/audit_log_service.dart';
import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/safety/risk_gate.dart';
import 'package:tfc_mcp_server/src/services/proposal_service.dart';
import 'package:tfc_mcp_server/src/tools/asset_write_tools.dart';
import 'package:tfc_mcp_server/src/tools/tool_registry.dart';
import '../helpers/mock_mcp_client.dart';
import '../helpers/test_database.dart';

/// A tool call payload with one child missing the required `key`.
///
/// This is the shape the plant sent: a text label, which has no tag to bind
/// to, so the field that the schema insists on is the one left out.
const _childWithoutKey = {
  'title': 'probe',
  'page_key': '/line1',
  'children': [
    {'asset_type': 'TextAssetConfig', 'title': 'probe', 'x': 0.5, 'y': 0.5},
  ],
};

const _childWithKey = {
  'title': 'probe',
  'page_key': '/line1',
  'children': [
    {
      'asset_type': 'TextAssetConfig',
      'key': 'line1.motor.run',
      'title': 'probe',
      'x': 0.5,
      'y': 0.5,
    },
  ],
};

McpServer _newServer() => McpServer(
      const Implementation(name: 'test-server', version: '0.1.0'),
      options: McpServerOptions(
        capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
      ),
    );

void _registerAssetTools(McpServer server, ServerDatabase db) {
  final registry = ToolRegistry(
    mcpServer: server,
    auditLogService: AuditLogService(db),
  );
  registerAssetWriteTools(
    registry: registry,
    riskGate: NoOpRiskGate(),
    proposalService: ProposalService(),
  );
}

void main() {
  group('over Streamable HTTP, the transport the plant uses', () {
    late ServerDatabase db;
    late StreamableMcpServer server;
    late HttpClient http;
    late Uri endpoint;

    setUp(() async {
      db = createTestDatabase();
      await db.customStatement('SELECT 1');

      // Ask the OS for a free port, then hand it to the server: mcp_dart
      // binds eagerly and exposes no bound-port getter.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      server = StreamableMcpServer(
        serverFactory: (_) {
          final s = _newServer();
          _registerAssetTools(s, db);
          return s;
        },
        host: '127.0.0.1',
        port: port,
        path: '/mcp',
      );
      await server.start();
      endpoint = Uri.parse('http://127.0.0.1:$port/mcp');
      http = HttpClient();
    });

    tearDown(() async {
      http.close(force: true);
      await server.stop();
      await db.close();
    });

    /// POSTs [body] and reads the response to completion.
    ///
    /// Returns the body and whether the stream actually *ended* within
    /// [wait]. That flag is the whole test: an undelivered error leaves a
    /// well-formed SSE event on a stream that is never closed, so a reader
    /// that waits for the end of the response waits forever.
    Future<({String body, bool ended, String? session})> post(
      Map<String, dynamic> body, {
      String? session,
      Duration wait = const Duration(seconds: 10),
    }) async {
      final req = await http.postUrl(endpoint);
      req.headers.set('content-type', 'application/json');
      req.headers.set('accept', 'application/json, text/event-stream');
      if (session != null) req.headers.set('mcp-session-id', session);
      req.write(jsonEncode(body));
      final res = await req.close();
      final buffer = StringBuffer();
      final done = Completer<void>();
      final sub = res.transform(utf8.decoder).listen(
            buffer.write,
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
          );
      var ended = true;
      try {
        await done.future.timeout(wait);
      } on TimeoutException {
        ended = false;
      }
      await sub.cancel();
      return (
        body: buffer.toString(),
        ended: ended,
        session: res.headers.value('mcp-session-id'),
      );
    }

    Future<String> handshake() async {
      final init = await post({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': <String, dynamic>{},
          'clientInfo': {'name': 'test-client', 'version': '1'},
        },
      });
      expect(init.ended, isTrue, reason: 'initialize must answer');
      final session = init.session;
      expect(session, isNotNull);
      await post({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }, session: session);
      return session!;
    }

    Map<String, dynamic> callBody(int id, Map<String, dynamic> arguments) => {
          'jsonrpc': '2.0',
          'id': id,
          'method': 'tools/call',
          'params': {'name': 'propose_asset', 'arguments': arguments},
        };

    test('a child missing the required key is answered, not left hanging',
        () async {
      final session = await handshake();

      final result = await post(
        callBody(2, Map<String, dynamic>.from(_childWithoutKey)),
        session: session,
      );

      expect(
        result.ended,
        isTrue,
        reason: 'the response stream must close. Before the fix mcp_dart '
            'wrote a JSON-RPC error onto it and never closed it, so the '
            'caller waited forever and was told nothing.',
      );
      // A result, not a protocol error -- that is what lets the stream end.
      expect(result.body, contains('"result"'));
      expect(result.body, isNot(contains('"error":{"code"')));
      // And it says which field, so the caller can fix the call.
      expect(result.body, contains('key'));
      expect(result.body, contains('propose_asset'));
    });

    test('a well-formed call still answers with its proposal', () async {
      final session = await handshake();

      final result = await post(
        callBody(2, Map<String, dynamic>.from(_childWithKey)),
        session: session,
      );

      expect(result.ended, isTrue);
      expect(result.body, contains('_proposal_type'));
    });

    test('an unknown tool name is answered too', () async {
      final session = await handshake();

      final result = await post({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {'name': 'no_such_tool', 'arguments': <String, dynamic>{}},
      }, session: session);

      expect(result.ended, isTrue,
          reason: 'mcp_dart raises a protocol error for an unknown tool, and '
              'that error cannot be delivered on this transport either');
      expect(result.body, contains('no_such_tool'));
    });
  });

  group('what the caller is told', () {
    late ServerDatabase db;
    late McpServer server;
    late MockMcpClient client;

    setUp(() async {
      db = createTestDatabase();
      await db.customStatement('SELECT 1');
      server = _newServer();
      _registerAssetTools(server, db);
      client = await MockMcpClient.connect(server);
    });

    tearDown(() async {
      await client.close();
      await db.close();
    });

    String textOf(CallToolResult result) =>
        (result.content.single as TextContent).text;

    test('a missing required field names the tool and the field', () async {
      final result = await client.callTool(
          'propose_asset', Map<String, dynamic>.from(_childWithoutKey));

      expect(result.isError, isTrue);
      final text = textOf(result);
      expect(text, contains('propose_asset'));
      expect(text, contains('key'));
      expect(text, contains('children/0'),
          reason: 'which child, not just which field');
    });

    test('a rejected call still leaves an audit row saying so', () async {
      await client.callTool(
          'propose_asset', Map<String, dynamic>.from(_childWithoutKey));

      final rows = await db.select(db.auditLog).get();
      expect(rows, hasLength(1));
      expect(rows.single.tool, 'propose_asset');
      expect(rows.single.status, AuditStatus.failed.name,
          reason: 'on a build with no stderr sink this row is the only '
              'durable trace that the call was made at all');
      expect(rows.single.error, contains('key'));
    });

    test('a minimal single-child proposal against a page still works',
        () async {
      final result = await client.callTool(
          'propose_asset', Map<String, dynamic>.from(_childWithKey));

      expect(result.isError, isNot(isTrue), reason: textOf(result));
      final wrapped = jsonDecode(textOf(result)) as Map<String, dynamic>;
      expect(wrapped['_proposal_type'], 'asset');
      expect(wrapped['page_key'], '/line1');
      expect((wrapped['children'] as List), hasLength(1));
    });

    test('an unknown tool is an error result, not a protocol error', () async {
      final result = await client.callTool('no_such_tool', {});

      expect(result.isError, isTrue);
      expect(textOf(result), contains('no_such_tool'));
    });
  });

  group('a handler that throws', () {
    late ServerDatabase db;
    late McpServer server;
    late ToolRegistry registry;
    late MockMcpClient client;

    setUp(() async {
      db = createTestDatabase();
      await db.customStatement('SELECT 1');
      server = _newServer();
      registry = ToolRegistry(
        mcpServer: server,
        auditLogService: AuditLogService(db),
      );
    });

    tearDown(() async {
      await client.close();
      await db.close();
    });

    test('an Error, not just an Exception, is caught and answered', () async {
      registry.registerTool(
        name: 'bad_cast_tool',
        description: 'Throws an Error the way a real handler bug does',
        inputSchema: JsonSchema.object(properties: {}),
        handler: (args, extra) async {
          // The shape of a handler bug: a field the schema does not describe,
          // read at the wrong type.
          final n = args['count'] as int;
          return CallToolResult(content: [TextContent(text: '$n')]);
        },
      );
      client = await MockMcpClient.connect(server);

      final result = await client.callTool('bad_cast_tool', {});

      expect(result.isError, isTrue,
          reason: 'an uncaught Error became a JSON-RPC error, and over '
              'Streamable HTTP that is a hang');
      expect((result.content.single as TextContent).text,
          contains('bad_cast_tool'));

      final rows = await db.select(db.auditLog).get();
      expect(rows.single.status, AuditStatus.failed.name,
          reason: 'an Error used to slip past the audit wrapper and leave '
              'the row pending forever');
    });

    test('a handler that never finishes is abandoned, not left holding a slot',
        () async {
      registry = ToolRegistry(
        mcpServer: server,
        auditLogService: AuditLogService(db),
        callTimeout: const Duration(milliseconds: 200),
      );
      registry.registerTool(
        name: 'never_returns',
        description: 'Parks forever',
        inputSchema: JsonSchema.object(properties: {}),
        handler: (args, extra) => Completer<CallToolResult>().future,
      );
      client = await MockMcpClient.connect(server);

      final result = await client.callTool('never_returns', {});

      expect(result.isError, isTrue);
      expect((result.content.single as TextContent).text,
          contains('never_returns'));
      final rows = await db.select(db.auditLog).get();
      expect(rows.single.status, AuditStatus.failed.name);
    });
  });
}
