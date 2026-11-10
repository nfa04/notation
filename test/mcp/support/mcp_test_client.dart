import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/mcp/mcp_protocol.dart';

/// What a tool answered: the text, and whether it said it failed.
class McpResult {
  final String text;
  final bool failed;
  const McpResult(this.text, this.failed);
}

/// An agent, as far as the server can tell: it speaks real HTTP to the endpoint, the way the revisions with `initialize` do (a handshake,
/// then the version in a header) or the one without (the version in every request, repeated in headers).
class McpTestClient {
  final String url;
  final String token;

  /// Speaks the revision without a handshake.
  final bool modern;

  late final HttpClient _http;
  String? _negotiated;
  var _id = 0;

  McpTestClient(this.url, this.token, {this.modern = false}) {
    HttpOverrides.global = null; // (the test binding answers every request with a 400, to the client it makes: so before one is made)
    _http = HttpClient();
  }

  Future<void> close() async => _http.close(force: true);

  /// (a plain failure: `expect` is guarded by the test binding, and this is also used while a widget test pumps)
  static void _must(bool ok, String message) {
    if (!ok) throw TestFailure(message);
  }

  static const _modernMeta = {
    'io.modelcontextprotocol/protocolVersion': mcpModernVersion,
    'io.modelcontextprotocol/clientInfo': {'name': 'notation-test', 'version': '1'},
    'io.modelcontextprotocol/clientCapabilities': <String, Object?>{},
  };

  /// One HTTP request, as it is: the status and the body.
  Future<(int, String)> send(Object? body, {String? bearer, Map<String, String> headers = const {}, String method = 'POST', String? host, String? origin, String? path}) async {
    final request = await _http.openUrl(method, Uri.parse(url).replace(path: path ?? Uri.parse(url).path));
    final key = bearer ?? token;
    if (key.isNotEmpty) request.headers.set('Authorization', 'Bearer $key');
    request.headers.set('Accept', 'application/json, text/event-stream');
    if (host != null) request.headers.host = host;
    if (origin != null) request.headers.set('Origin', origin);
    headers.forEach(request.headers.set);
    request.headers.contentType = ContentType.json;
    if (method == 'POST') request.add(utf8.encode(body is String ? body : jsonEncode(body)));
    final response = await request.close();
    return (response.statusCode, await utf8.decodeStream(response));
  }

  /// The handshake of the revisions that have one (the other needs none).
  Future<Map<String, Object?>> initialize() async {
    final (status, body) = await send({
      'jsonrpc': '2.0',
      'id': ++_id,
      'method': 'initialize',
      'params': {'protocolVersion': mcpLegacyVersions.first, 'capabilities': <String, Object?>{}, 'clientInfo': {'name': 'notation-test', 'version': '1'}},
    });
    _must(status == 200, 'initialize: HTTP $status $body');
    final result = ((jsonDecode(body) as Map)['result'] as Map).cast<String, Object?>();
    _negotiated = result['protocolVersion'] as String;
    final (accepted, _) = await send({'jsonrpc': '2.0', 'method': 'notifications/initialized'}, headers: {'MCP-Protocol-Version': _negotiated!});
    _must(accepted == 202, 'initialized: HTTP $accepted');
    return result;
  }

  /// Sends a request and gives its JSON-RPC reply (`result` or `error`) with the HTTP status.
  Future<(int, Map<String, Object?>)> request(String method, [Map<String, Object?> params = const {}]) async {
    if (!modern && _negotiated == null && method != 'initialize') await initialize();
    final headers = <String, String>{};
    final sent = {...params};
    if (modern) {
      sent['_meta'] = _modernMeta;
      headers['MCP-Protocol-Version'] = mcpModernVersion;
      headers['Mcp-Method'] = method;
      if (method == 'tools/call') headers['Mcp-Name'] = params['name'] as String;
    } else if (_negotiated != null) {
      headers['MCP-Protocol-Version'] = _negotiated!;
    }
    final (status, body) = await send({'jsonrpc': '2.0', 'id': ++_id, 'method': method, 'params': sent}, headers: headers);
    return (status, (jsonDecode(body) as Map).cast<String, Object?>());
  }

  /// The result of a request that worked.
  Future<Map<String, Object?>> result(String method, [Map<String, Object?> params = const {}]) async {
    final (status, reply) = await request(method, params);
    _must(status == 200, '$method: HTTP $status $reply');
    _must(reply['error'] == null, '$method: $reply');
    if (modern) _must((reply['result'] as Map)['resultType'] == 'complete', '$method: not a complete result: $reply');
    return (reply['result'] as Map).cast<String, Object?>();
  }

  /// What the server says about itself: `initialize` or `server/discover`, whichever this revision has.
  Future<Map<String, Object?>> describe() => modern ? result('server/discover') : initialize();

  Future<List<Map<String, Object?>>> tools() async => [for (final t in (await result('tools/list'))['tools'] as List) (t as Map).cast<String, Object?>()];

  Future<List<String>> toolNames() async => [for (final t in await tools()) t['name'] as String];

  /// Calls a tool.
  Future<McpResult> tool(String name, [Map<String, Object?> args = const {}]) async {
    final r = await result('tools/call', {'name': name, 'arguments': args});
    return McpResult(((r['content'] as List).single as Map)['text'] as String, r['isError'] == true);
  }

  /// Calls a tool that is expected to work and reads its JSON.
  Future<Map<String, dynamic>> json(String name, [Map<String, Object?> args = const {}]) async {
    final r = await tool(name, args);
    _must(!r.failed, '$name: ${r.text}');
    return jsonDecode(r.text) as Map<String, dynamic>;
  }

  /// Calls a tool that is expected to work and gives its text.
  Future<String> text(String name, [Map<String, Object?> args = const {}]) async {
    final r = await tool(name, args);
    _must(!r.failed, '$name: ${r.text}');
    return r.text;
  }

  /// The id a tool that makes something says ("Its id is ...").
  Future<String> made(String name, Map<String, Object?> args) async {
    final said = await text(name, args);
    final id = RegExp(r'Its id is (\S+)\.').firstMatch(said)?.group(1);
    _must(id != null, '$name: no id in: $said');
    return id!;
  }
}
