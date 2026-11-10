import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/mcp/mcp_bridge.dart';
import 'package:notes/mcp/mcp_protocol.dart';
import 'package:notes/mcp/mcp_server.dart';

void main() {
  late McpHttpServer server;

  setUp(() async {
    server = McpHttpServer(
      McpProtocol(canChange: () => true, tools: () => [McpTool(name: 'größe', description: '', inputSchema: const {'type': 'object'}, run: (a) async => 'ok ${a['x']}')]),
      token: () => 'tok',
    );
    await server.start(0);
  });

  tearDown(() => server.stop());

  Future<List<Map<String, Object?>>> run(List<Object> messages, {String token = 'tok', int? port}) async {
    final out = <String>[];
    await runMcpBridge(Stream.fromIterable([for (final m in messages) m is String ? m : jsonEncode(m)]), out.add, url: Uri.parse('http://127.0.0.1:${port ?? server.port}/mcp'), token: token);
    return [for (final l in out) (jsonDecode(l) as Map).cast<String, Object?>()];
  }

  const modern = {
    'io.modelcontextprotocol/protocolVersion': mcpModernVersion,
    'io.modelcontextprotocol/clientInfo': {'name': 't', 'version': '1'},
    'io.modelcontextprotocol/clientCapabilities': <String, Object?>{},
  };

  test('the older handshake goes through, and later requests carry the version it settled on', () async {
    final replies = await run([
      {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18'}},
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
    ]);
    expect(replies, hasLength(2), reason: 'a notification gets no reply');
    expect((replies[0]['result'] as Map)['protocolVersion'], '2025-06-18');
    expect(((replies[1]['result'] as Map)['tools'] as List).single, containsPair('name', 'größe'));
  });

  test('the newest revision gets the headers it asks for, with a name that is not ASCII encoded', () async {
    final replies = await run([
      {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': 'größe', 'arguments': {'x': 7}, '_meta': modern}},
    ]);
    expect(replies.single['error'], isNull);
    expect(((replies.single['result'] as Map)['content'] as List).single, containsPair('text', 'ok 7'));
  });

  test('a wrong token, a broken line and an app that is not there each get an answer the agent can show', () async {
    final denied = await run([{'jsonrpc': '2.0', 'id': 5, 'method': 'ping'}], token: 'wrong');
    expect((denied.single['error'] as Map)['message'], contains('token'));
    expect(denied.single['id'], 5);

    final broken = await run(['{nope']);
    expect((broken.single['error'] as Map)['code'], -32700);

    final port = server.port;
    await server.stop();
    final gone = await run([
      {'jsonrpc': '2.0', 'id': 9, 'method': 'ping'},
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
    ], port: port);
    expect(gone, hasLength(1), reason: 'nothing is said about a notification');
    expect((gone.single['error'] as Map)['message'], contains('not running'));
    expect(gone.single['id'], 9);
  });
}
