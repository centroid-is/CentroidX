import 'dart:async';

import 'package:logger/logger.dart' as log;
import 'package:mcp_dart/mcp_dart.dart';
// Reaching past the barrel on purpose. `JsonSchema.validate` is an extension
// in `json_schema_validator.dart`, which `mcp_dart.dart` does not export even
// though mcp_dart's own `tools/call` handler calls it. This registry has to
// run exactly the validation the client was promised by `tools/list`, so it
// uses the same validator rather than a second, drifting copy of it.
// ignore: implementation_imports
import 'package:mcp_dart/src/shared/json_schema/json_schema_validator.dart';

import '../audit/audit_log_service.dart';
import '../logging/stderr_logger.dart';
import '../safety/proposal_declined_exception.dart';

/// A counting semaphore that limits concurrent async operations.
///
/// When the number of running operations reaches [maxCount], additional
/// callers queue up and are resumed FIFO when a slot frees up.
///
/// Used by [ToolRegistry] to prevent parallel LLM tool calls from
/// overwhelming the remote PostgreSQL connection (which causes
/// SocketException and 300s timeouts under 6+ concurrent queries).
class Semaphore {
  /// Creates a semaphore that allows at most [maxCount] concurrent operations.
  Semaphore(this.maxCount);

  /// Maximum number of concurrent operations.
  final int maxCount;

  int _current = 0;
  final _waiters = <Completer<void>>[];

  /// Execute [fn] when a slot is available.
  ///
  /// If fewer than [maxCount] operations are running, starts immediately.
  /// Otherwise queues until a running operation completes.
  /// The slot is always released, even if [fn] throws.
  Future<T> run<T>(Future<T> Function() fn) async {
    if (_current >= maxCount) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _current++;
    try {
      return await fn();
    } finally {
      _current--;
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      }
    }
  }
}

/// One tool as this registry knows it: the schema the client was shown, and
/// the guarded callback that runs it.
class _RegisteredTool {
  _RegisteredTool({
    required this.name,
    required this.inputSchema,
    required this.invoke,
  });

  final String name;
  final ToolInputSchema? inputSchema;
  final Future<CallToolResult> Function(
      Map<String, dynamic> arguments, RequestHandlerExtra extra) invoke;
}

/// Central tool registration with audit middleware.
///
/// Every tool registered through [ToolRegistry] is automatically wrapped
/// with argument validation, audit trail creation and concurrency limiting.
/// Tool implementations do not need to handle these concerns -- the
/// middleware is transparent.
///
/// Pipeline per tool call:
/// 1. Acquire concurrency slot (max 3 concurrent tool handlers)
/// 2. Log intent via [AuditLogService.executeWithAudit()]
/// 3. Validate the arguments against the tool's advertised input schema
/// 4. Execute the tool handler, under [callTimeout]
/// 5. Update audit outcome (success/failed)
/// 6. Release concurrency slot
///
/// **Nothing in that pipeline is allowed to throw out of the handler**, and
/// that is the load-bearing property rather than a tidiness preference. A
/// handler that throws becomes a JSON-RPC *error* response, and mcp_dart's
/// Streamable HTTP transport only ends the response stream after a JSON-RPC
/// *result* (`StreamableHTTPServerTransport.send`, whose close branch is
/// gated on `_isJsonRpcResponse`). An error is written to the stream and the
/// stream is then held open forever, so the caller sees no answer, no error
/// and no end -- it simply hangs. That is the same transport behaviour the
/// `prompts` capability is conditionally advertised for in `server.dart`;
/// here it is closed for every tool at once, by answering with a
/// [CallToolResult] carrying `isError: true` instead.
///
/// Taking `tools/call` over is the other half: mcp_dart validates arguments
/// itself, *before* the callback, and raises a protocol error when they do
/// not match. That error can never be delivered, so the registry takes
/// `tools/call` over and validates inside the pipeline, where a failure is
/// an ordinary error result naming the offending field.
///
/// Every MCP tool in this package is registered here, so `tools/call` is
/// covered whole. What is **not** covered is the rest of the protocol
/// surface: `resources/read` on a URI no resource claims, `prompts/get` with
/// a missing argument, and any request for a method with no handler still
/// raise protocol errors and still hang a Streamable HTTP client. Those are
/// reads with fixed, short argument lists, which is why they have not been
/// hit; the durable answer is a transport that terminates an error response,
/// and that lives in mcp_dart rather than here.
///
/// **There is no identity step, and its absence is a decision rather than an
/// omission.** Every tool registered here either reads, or returns a proposal
/// that a human must approve in the app through an access-gated store
/// (`lib/src/tools/access_template_tools.dart:28`: "they return a proposal").
/// Authorization and attribution both live at that approval, so a caller
/// identity here would authorize nothing and attribute nothing. The audit row
/// records provenance instead, under [kMcpAuditOperator], whose doc comment
/// carries the full reasoning.
class ToolRegistry {
  /// Creates a [ToolRegistry] that wraps tool registrations on [mcpServer]
  /// with an [auditLogService] audit trail and concurrency limiting.
  ///
  /// The [maxConcurrency] parameter controls how many tool handlers can
  /// execute simultaneously (default 3). This prevents parallel LLM tool
  /// calls from overwhelming the database connection pool.
  ///
  /// [callTimeout] caps how long a metered tool handler may run before the
  /// call is answered with an error result. It is defence in depth, not the
  /// mechanism: it exists so that a handler which does block forever costs
  /// one slow call and leaves a log line and an audit row, instead of
  /// occupying a concurrency slot for the life of the process. Unmetered
  /// tools -- the long polls that park on a human -- are exempt, since
  /// waiting is what they are for.
  ToolRegistry({
    required McpServer mcpServer,
    required AuditLogService auditLogService,
    int maxConcurrency = 3,
    Duration callTimeout = const Duration(minutes: 3),
    log.Logger? logger,
  })  : _mcpServer = mcpServer,
        _auditLogService = auditLogService,
        _semaphore = Semaphore(maxConcurrency),
        _callTimeout = callTimeout,
        _logger = logger ?? createServerLogger();

  final McpServer _mcpServer;
  final AuditLogService _auditLogService;
  final Semaphore _semaphore;
  final Duration _callTimeout;
  final log.Logger _logger;

  /// Every tool registered here, by name. The registry's own copy: mcp_dart
  /// keeps one too, but it is private and its dispatch is the half being
  /// replaced.
  final Map<String, _RegisteredTool> _tools = {};

  /// Register a tool with validation + audit + concurrency middleware.
  ///
  /// The [handler] receives the tool arguments and [RequestHandlerExtra]
  /// from the MCP protocol. It should focus only on business logic --
  /// argument validation, audit logging and concurrency limiting are handled
  /// transparently.
  ///
  /// [metered] puts the tool through the concurrency semaphore (the default).
  /// The semaphore holds its slot for the handler's entire duration, which is
  /// right for a tool that queries the database and wrong for one that parks
  /// waiting on a human: three parked long polls would occupy every slot and
  /// freeze the whole server for a minute at a time. Only turn this off for a
  /// handler that spends its time idle rather than working.
  ///
  /// [audited] skips the audit trail. Off only for tools that are called on a
  /// timer and record no intent -- `await_proposal_feedback` re-arms once a
  /// minute forever, and an audit row per call would bury the rows that
  /// describe something someone actually did.
  void registerTool({
    required String name,
    required String description,
    ToolInputSchema? inputSchema,
    bool metered = true,
    bool audited = true,
    required Future<CallToolResult> Function(
            Map<String, dynamic> arguments, RequestHandlerExtra extra)
        handler,
  }) {
    Future<CallToolResult> guarded(
        Map<String, dynamic> args, RequestHandlerExtra extra) {
      Future<CallToolResult> execute() async {
        try {
          Future<CallToolResult> run() async {
            // Inside the audited region on purpose: a call rejected for bad
            // arguments is a call that happened, and the row saying so is
            // the only durable trace of it on a build with no stderr sink.
            _validateArguments(name, inputSchema, args);
            return handler(args, extra);
          }

          final body = metered
              ? () => run().timeout(
                    _callTimeout,
                    onTimeout: () => throw TimeoutException(
                        'Tool "$name" did not finish within '
                        '${_formatDuration(_callTimeout)} and was abandoned. '
                        'Nothing was written; the call can be retried.',
                        _callTimeout),
                  )
              : run;

          if (!audited) return await body();
          return await _auditLogService.executeWithAudit<CallToolResult>(
            operatorId: kMcpAuditOperator,
            tool: name,
            arguments: args,
            handler: body,
          );
        } on ProposalDeclinedException catch (e) {
          // Decline is not an error -- return the message as a normal tool result.
          // Audit trail was already updated to "declined" by executeWithAudit.
          return CallToolResult(
            content: [TextContent(text: e.message)],
            isError: false,
          );
        } catch (e, stack) {
          // Deliberately `catch`, not `on Exception catch`. An `Error` --
          // a failed cast on a field the schema does not describe, a range
          // error, a null check -- is exactly the kind of bug a tool handler
          // has, and letting one through produces the silent hang this
          // pipeline exists to prevent.
          //
          // The audit trail already recorded the failure in executeWithAudit.
          _logger.e('MCP tool "$name" failed', error: e, stackTrace: stack);
          return CallToolResult(
            content: [TextContent(text: _describeFailure(name, e))],
            isError: true,
          );
        }
      }

      return metered ? _semaphore.run(execute) : execute();
    }

    _mcpServer.registerTool(
      name,
      description: description,
      inputSchema: inputSchema,
      // Still registered on mcp_dart: that is what puts the tool and its
      // schema in `tools/list`. Only the *call* half is taken over below.
      callback: (Map<String, dynamic> args, RequestHandlerExtra extra) =>
          guarded(args, extra),
    );

    _tools[name] = _RegisteredTool(
      name: name,
      inputSchema: inputSchema,
      invoke: guarded,
    );

    // Re-installed after every registration rather than once at the end.
    // mcp_dart puts its own `tools/call` handler in place on the first
    // `registerTool`, so this has to come after at least one of them, and
    // "after each" needs no caller to remember an ordering rule -- a
    // registry built in a test gets the same dispatch as the real server.
    _installCallToolHandler();
  }

  /// Takes `tools/call` over from mcp_dart, so that no tool call can answer
  /// with a JSON-RPC error.
  ///
  /// What mcp_dart's handler raises a protocol error for -- an unknown tool
  /// name, arguments that do not match the advertised schema -- becomes a
  /// [CallToolResult] with `isError: true` here. The difference is not
  /// cosmetic: over Streamable HTTP a protocol error is written to the
  /// response stream and the stream is never closed, so the client waits
  /// forever and is told nothing. See the class doc.
  ///
  /// The request is read from the raw [JsonRpcRequest] rather than parsed
  /// into `JsonRpcCallToolRequest`, because mcp_dart turns a parse failure
  /// in the request factory into the same undeliverable error.
  void _installCallToolHandler() {
    _mcpServer.server.setRequestHandler<JsonRpcRequest>(
      Method.toolsCall,
      (request, extra) async {
        final params = request.params ?? const <String, dynamic>{};
        final name = params['name'];
        if (name is! String || name.isEmpty) {
          return _errorResult(
              'tools/call needs a string "name" naming the tool to run.');
        }
        final tool = _tools[name];
        if (tool == null) {
          return _errorResult(
              'Unknown tool "$name". Call tools/list for what this server '
              'offers.');
        }
        final rawArgs = params['arguments'];
        if (rawArgs != null && rawArgs is! Map) {
          return _errorResult(
              'Invalid arguments for tool "$name": "arguments" must be an '
              'object.');
        }
        final args = rawArgs is Map
            ? Map<String, dynamic>.from(rawArgs)
            : <String, dynamic>{};
        return tool.invoke(args, extra);
      },
      (id, params, meta) => JsonRpcRequest(
        id: id,
        method: Method.toolsCall,
        params: params,
        meta: meta,
      ),
    );
  }

  /// Throws [ToolArgumentException] when [args] do not match [schema].
  ///
  /// The same check mcp_dart performs before dispatch, moved inside the
  /// pipeline so that its failure is an answer rather than a hang.
  void _validateArguments(
    String name,
    ToolInputSchema? schema,
    Map<String, dynamic> args,
  ) {
    if (schema == null) return;
    try {
      schema.validate(args);
    } on JsonSchemaValidationException catch (e) {
      final where = e.path.isEmpty ? '' : ' (at ${e.path.join('/')})';
      throw ToolArgumentException(
        'Invalid arguments for tool "$name": ${e.message}$where. '
        'Check the tool\'s input schema in tools/list and call it again.',
      );
    }
  }

  CallToolResult _errorResult(String message) {
    _logger.w('MCP tools/call rejected: $message');
    return CallToolResult(
      content: [TextContent(text: message)],
      isError: true,
    );
  }

  /// A duration as a caller would say it: "200ms", "180s".
  static String _formatDuration(Duration d) => d.inMilliseconds < 1000
      ? '${d.inMilliseconds}ms'
      : '${d.inSeconds}s';

  /// The text a failed call answers with.
  ///
  /// An [Error] stringifies to something that names the bug but not the tool,
  /// and a client that sees only "type 'Null' is not a subtype of..." cannot
  /// tell which call produced it.
  static String _describeFailure(String name, Object error) {
    if (error is ToolArgumentException) return error.message;
    if (error is TimeoutException) {
      return error.message ?? 'Tool "$name" timed out.';
    }
    if (error is Exception) return error.toString();
    return 'Tool "$name" failed: $error';
  }
}

/// Raised when a tool call's arguments do not match the schema the server
/// advertised for it.
///
/// An [Exception] rather than an [Error]: the caller sent it, so it is an
/// answer to give, not a bug to crash on.
class ToolArgumentException implements Exception {
  ToolArgumentException(this.message);

  /// The message handed back to the client, naming the tool and the field.
  final String message;

  @override
  String toString() => message;
}
