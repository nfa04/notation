import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_protocol.dart';

/// For an agent that can only start a program and talk to it (the stdio transport of the Model Context Protocol): reads one JSON-RPC
/// message per line from [input], sends each to the app's endpoint [url] with the [token], and writes each reply as a line to
/// [output]. It adds what the HTTP transport asks of a request (the headers that repeat the version, the method and the tool), which a
/// program talking in lines has no place for. When the app is not there, the agent is told so in a reply it can show.
Future<void> runMcpBridge(Stream<String> input, void Function(String line) output, {required Uri url, required String token, HttpClient? client}) async {
  final http = client ?? HttpClient();
  final pending = <Future<void>>[];
  // the version a handshake settled on (the older revisions say it once, and the HTTP transport wants it with every request)
  String? negotiated;

  Future<void> forward(String line) async {
    Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      output(jsonEncode({'jsonrpc': '2.0', 'id': null, 'error': {'code': -32700, 'message': 'Parse error'}}));
      return;
    }
    final id = message is Map ? message['id'] : null;
    try {
      final request = await http.postUrl(url);
      request.headers
        ..set('Authorization', 'Bearer $token')
        ..set('Accept', 'application/json, text/event-stream')
        ..contentType = ContentType.json;
      if (message is Map && message['method'] is String) {
        final params = message['params'] is Map ? message['params'] as Map : const {};
        final asked = params['_meta'] is Map ? (params['_meta'] as Map)['io.modelcontextprotocol/protocolVersion'] : null;
        final version = asked ?? negotiated;
        if (version is String && message['method'] != 'initialize') {
          request.headers.set('MCP-Protocol-Version', version);
          if (asked != null) {
            request.headers.set('Mcp-Method', message['method'] as String);
            final name = params['name'];
            if (message['method'] == 'tools/call' && name is String) {
              final plain = RegExp(r'^[\x21-\x7e]+$').hasMatch(name) && !name.startsWith('=?base64?');
              request.headers.set('Mcp-Name', plain ? name : '=?base64?${base64.encode(utf8.encode(name))}?=');
            }
          }
        }
      }
      request.add(utf8.encode(line));
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      if (response.statusCode == HttpStatus.unauthorized) {
        // (the app's own answer has no id: the agent could not tell which request it was for)
        if (id != null) output(jsonEncode({'jsonrpc': '2.0', 'id': id, 'error': {'code': -32000, 'message': 'Notation did not accept the token. Copy it again from Connect an AI agent in its settings.'}}));
        return;
      }
      if (response.statusCode == HttpStatus.accepted || body.trim().isEmpty) return;
      final reply = jsonDecode(body);
      if (message is Map && message['method'] == 'initialize' && reply is Map && reply['result'] is Map) {
        final v = (reply['result'] as Map)['protocolVersion'];
        if (mcpLegacyVersions.contains(v)) negotiated = v as String;
      }
      output(jsonEncode(reply));
    } on SocketException {
      if (id != null) {
        output(jsonEncode({'jsonrpc': '2.0', 'id': id, 'error': {'code': -32000, 'message': 'Notation is not running, or "Let an agent use my notes" is off in its settings.'}}));
      }
    } on FormatException {
      if (id != null) output(jsonEncode({'jsonrpc': '2.0', 'id': id, 'error': {'code': -32603, 'message': 'Notation answered with something that is not JSON.'}}));
    }
  }

  await for (final line in input) {
    if (line.trim().isNotEmpty) pending.add(forward(line));
  }
  await Future.wait(pending);
  if (client == null) http.close(force: true);
}
