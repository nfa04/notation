import 'dart:async';
import 'dart:convert';

/// The revision of the Model Context Protocol that has no `initialize` handshake: every request says what it speaks.
const mcpModernVersion = '2026-07-28';

/// The revisions that begin with an `initialize` request, newest first. (Most clients still speak these.)
const mcpLegacyVersions = ['2025-11-25', '2025-06-18', '2025-03-26'];

const _versionKey = 'io.modelcontextprotocol/protocolVersion';
const _serverInfoKey = 'io.modelcontextprotocol/serverInfo';

/// An answer to a tool call that is a failure the agent can read and act on (not found, not allowed, not valid), as opposed to a
/// request that is broken.
class McpToolError implements Exception {
  final String message;
  McpToolError(this.message);
  @override
  String toString() => message;
}

/// Something an agent can call: a name, how it is described to the model, the arguments it takes, and what it does.
class McpTool {
  final String name;
  final String description;

  /// A JSON schema of the arguments.
  final Map<String, Object?> inputSchema;

  /// Changes something (a note, a folder, a task); it is off while the person allows reading only.
  final bool changes;

  /// Cannot be taken back by the person with the version history or the trash.
  final bool destructive;

  /// Does it; the result is the text the agent reads. Fails with [McpToolError].
  final Future<String> Function(Map<String, Object?> args) run;

  const McpTool({required this.name, required this.description, required this.inputSchema, this.changes = false, this.destructive = false, required this.run});

  Map<String, Object?> toJson() => {
        'name': name,
        'title': name.replaceAll('_', ' '),
        'description': description,
        'inputSchema': inputSchema,
        'annotations': {
          'readOnlyHint': !changes,
          if (changes) 'destructiveHint': destructive,
          if (changes) 'idempotentHint': false,
          'openWorldHint': false,
        },
      };
}

/// The headers of a request that mirror its body (see [McpProtocol.handle]); null where there was none.
class McpHeaders {
  final String? version, method, name;
  const McpHeaders({this.version, this.method, this.name});
}

/// What goes back: the JSON-RPC message and the HTTP status that carries it.
class McpReply {
  final int status;
  final Map<String, Object?> body;
  const McpReply(this.body, [this.status = 200]);
}

/// The Model Context Protocol for a list of tools, apart from any transport: it takes a decoded JSON-RPC message (and the headers of
/// the HTTP request it came in, if it did) and gives the reply. It speaks the stateless revision ([mcpModernVersion]) and the ones
/// that begin with `initialize` ([mcpLegacyVersions]), told apart by how a request begins; it keeps no session.
class McpProtocol {
  final String name, version;

  /// How the agent is told to use the server.
  final String instructions;

  /// The tools there are, and whether the person allows changes (tools that change something are not offered, and refuse, when not).
  final List<McpTool> Function() tools;
  final bool Function() canChange;

  /// Told when a tool that changes something has done it: the tool, the arguments it was given and what it answered (so that the
  /// person can be shown what an agent is doing).
  final void Function(McpTool tool, Map<String, Object?> args, String result)? onChanged;

  McpProtocol({required this.tools, required this.canChange, this.name = 'Notation', this.version = '0.0.1', this.instructions = '', this.onChanged});

  Future<void> _tail = Future.value();

  /// Runs [job] after the ones before it: two agents (or one that does not wait) must not change a note at the same time.
  Future<T> _serially<T>(Future<T> Function() job) {
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await job());
      } catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  static McpReply _error(Object? id, int code, String message, {int status = 200, Object? data}) =>
      McpReply({'jsonrpc': '2.0', 'id': id, 'error': {'code': code, 'message': message, 'data': ?data}}, status);

  static const _supported = [mcpModernVersion, ...mcpLegacyVersions];

  /// Decodes `=?base64?...?=`, how a header carries a value that is not plain ASCII.
  static String _headerValue(String v) {
    if (v.startsWith('=?base64?') && v.endsWith('?=') && v.length >= 11) {
      try {
        return utf8.decode(base64.decode(v.substring(9, v.length - 2)));
      } on FormatException {
        return v;
      }
    }
    return v;
  }

  /// The reply to one message, or null when it needs none (a notification).
  Future<McpReply?> handle(Object? message, [McpHeaders headers = const McpHeaders()]) async {
    if (message is! Map || message['method'] is! String) return _error(null, -32600, 'Invalid request', status: 400);
    final id = message['id'];
    final method = message['method'] as String;
    final notification = !message.containsKey('id');
    final params = message['params'] is Map ? (message['params'] as Map).cast<String, Object?>() : <String, Object?>{};
    final meta = params['_meta'] is Map ? (params['_meta'] as Map).cast<String, Object?>() : const <String, Object?>{};
    final asked = meta[_versionKey];
    final modern = method != 'initialize' && asked != null;

    if (modern) {
      if (asked != mcpModernVersion) {
        return _error(id, -32022, 'Unsupported protocol version', status: 400, data: {'supported': _supported, 'requested': asked});
      }
      String? mismatch;
      if (headers.version != mcpModernVersion) {
        mismatch = 'MCP-Protocol-Version has to be $mcpModernVersion, as in the body';
      } else if (headers.method != method) {
        mismatch = 'Mcp-Method has to be $method, as in the body';
      } else if (method == 'tools/call' && (headers.name == null || _headerValue(headers.name!) != params['name'])) {
        mismatch = 'Mcp-Name has to be the name of the tool, as in the body';
      }
      if (mismatch != null) return _error(id, -32020, 'Header mismatch: $mismatch', status: 400);
    } else if (headers.version != null && !mcpLegacyVersions.contains(headers.version)) {
      return _error(id, -32022, 'Unsupported protocol version', status: 400, data: {'supported': _supported, 'requested': headers.version});
    }

    if (notification) return null;

    Map<String, Object?> result(Map<String, Object?> r, {bool cacheable = false}) =>
        {'jsonrpc': '2.0', 'id': id, 'result': {if (modern) 'resultType': 'complete', ...r, if (modern && cacheable) ...{'ttlMs': 0, 'cacheScope': 'private'}}};

    switch (method) {
      case 'initialize':
        final wanted = params['protocolVersion'];
        final chosen = mcpLegacyVersions.contains(wanted) ? wanted : mcpLegacyVersions.first;
        return McpReply(result({
          'protocolVersion': chosen,
          'capabilities': _capabilities,
          'serverInfo': {'name': name, 'version': version},
          if (instructions.isNotEmpty) 'instructions': instructions,
        }));
      case 'ping':
        return McpReply(result({}));
      case 'server/discover':
        return McpReply(result({
          'supportedVersions': _supported,
          'capabilities': _capabilities,
          '_meta': {
            _serverInfoKey: {'name': name, 'version': version},
          },
          if (instructions.isNotEmpty) 'instructions': instructions,
        }, cacheable: true));
      case 'tools/list':
        return McpReply(result({
          'tools': [for (final t in tools()) if (canChange() || !t.changes) t.toJson()],
        }, cacheable: true));
      case 'tools/call':
        return _call(id, params, result);
    }
    return _error(id, -32601, 'Method not found: $method', status: modern ? 404 : 200);
  }

  static const _capabilities = {'tools': {'listChanged': false}};

  Future<McpReply> _call(Object? id, Map<String, Object?> params, Map<String, Object?> Function(Map<String, Object?>, {bool cacheable}) result) async {
    final tool = tools().where((t) => t.name == params['name']).firstOrNull;
    if (tool == null) return _error(id, -32602, 'Unknown tool: ${params['name']}');
    final args = params['arguments'];
    if (args != null && args is! Map) return _error(id, -32602, '"arguments" has to be an object');

    Map<String, Object?> done(String text, bool failed) => result({
          'content': [
            {'type': 'text', 'text': text},
          ],
          'isError': failed,
        });

    if (tool.changes && !canChange()) {
      return McpReply(done('Changes are switched off in Notation (Settings, Connect an AI agent): this tool is read only for now.', true));
    }
    try {
      final given = (args as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
      final text = await _serially(() => tool.run(given));
      if (tool.changes) {
        try {
          onChanged?.call(tool, given, text);
        } catch (_) {
          // (what the person is shown never fails the call)
        }
      }
      return McpReply(done(text, false));
    } on McpToolError catch (e) {
      return McpReply(done(e.message, true));
    } catch (e) {
      return McpReply(done('That did not work: $e', true));
    }
  }
}
