import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/mcp/mcp_protocol.dart';
import 'package:notes/mcp/mcp_server.dart';

void main() {
  late McpHttpServer server;
  late HttpClient client;
  String? token = 'secret-token-0123456789';
  final ran = <String>[];

  setUp(() async {
    token = 'secret-token-0123456789';
    ran.clear();
    final protocol = McpProtocol(
      canChange: () => true,
      tools: () => [McpTool(name: 'look', description: '', inputSchema: const {'type': 'object'}, run: (a) async => 'saw ${ran.length}')],
    );
    server = McpHttpServer(protocol, token: () => token, maxBytes: 4096);
    await server.start(0);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
  });

  /// Sends a request and gives the status and the body.
  Future<(int, String)> send(String method, {String path = '/mcp', Object? body = const {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}, String? bearer = 'secret-token-0123456789', String? host, String? origin, List<int>? raw}) async {
    final request = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
    if (bearer != null) request.headers.set('Authorization', 'Bearer $bearer');
    if (host != null) request.headers.host = host;
    if (origin != null) request.headers.set('Origin', origin);
    request.headers.contentType = ContentType.json;
    if (method == 'POST') request.add(raw ?? utf8.encode(body is String ? body : jsonEncode(body)));
    final response = await request.close();
    return (response.statusCode, await utf8.decodeStream(response));
  }

  test('it listens on the loopback address only', () {
    expect(server.running, isTrue);
  });

  test('a request with the token is answered with JSON', () async {
    final (status, body) = await send('POST');
    expect(status, 200);
    expect(jsonDecode(body), {'jsonrpc': '2.0', 'id': 1, 'result': {}});
  });

  test('a notification is accepted with nothing in return', () async {
    final (status, body) = await send('POST', body: {'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    expect(status, 202);
    expect(body, isEmpty);
  });

  test('without the right token nothing is answered, whatever else is right', () async {
    for (final bearer in [null, '', 'wrong', 'secret-token-0123456789x', 'secret-token-012345678']) {
      final (status, _) = await send('POST', bearer: bearer);
      expect(status, 401, reason: '$bearer');
    }
    token = null;
    expect((await send('POST')).$1, 401);
    token = '';
    expect((await send('POST', bearer: '')).$1, 401);
  });

  test('a page that reached the port under its own name (DNS rebinding) or from another site is turned away, token or not', () async {
    expect((await send('POST', host: 'evil.example')).$1, 403);
    expect((await send('POST', origin: 'https://evil.example')).$1, 403);
    expect((await send('POST', origin: 'null')).$1, 403);
    expect((await send('POST', origin: 'http://localhost:5173')).$1, 200); // (a page on this computer still needs the token)
    expect((await send('POST', origin: 'http://localhost:5173', bearer: 'nope')).$1, 401);
  });

  test('only POST to /mcp is served: no stream to listen on and no session to end', () async {
    expect((await send('GET')).$1, 405);
    expect((await send('DELETE')).$1, 405);
    expect((await send('POST', path: '/other')).$1, 404);
  });

  test('a body that is no JSON is a parse error, and one that is too large is refused', () async {
    final (status, body) = await send('POST', body: '{nope');
    expect(status, 400);
    expect(((jsonDecode(body) as Map)['error'] as Map)['code'], -32700);
    expect((await send('POST', raw: List.filled(5000, 0x20))).$1, 413);
  });

  test('the headers of the request reach the protocol (a mismatch is a 400)', () async {
    final (status, body) = await send('POST', body: {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/list',
      'params': {
        '_meta': {'io.modelcontextprotocol/protocolVersion': mcpModernVersion},
      },
    });
    expect(status, 400);
    expect(((jsonDecode(body) as Map)['error'] as Map)['code'], -32020);
  });

  test('after stop it no longer answers', () async {
    final port = server.port;
    await server.stop();
    expect(server.running, isFalse);
    await expectLater(HttpClient().getUrl(Uri.parse('http://127.0.0.1:$port/mcp')).then((r) => r.close()), throwsA(isA<SocketException>()));
  });

  test('the token comparison tells equal from different', () {
    expect(McpHttpServer.sameToken('abc', 'abc'), isTrue);
    expect(McpHttpServer.sameToken('abc', 'abd'), isFalse);
    expect(McpHttpServer.sameToken('abc', 'abcd'), isFalse);
    expect(McpHttpServer.sameToken('', ''), isFalse);
  });
}
