import 'package:flutter_test/flutter_test.dart';
import 'package:notes/mcp/mcp_protocol.dart';

McpProtocol protocol({bool canChange = true, List<String>? ran}) => McpProtocol(
      canChange: () => canChange,
      instructions: 'Use the tools.',
      tools: () => [
        McpTool(name: 'look', description: 'Looks.', inputSchema: const {'type': 'object'}, run: (a) async => 'saw ${a['what']}'),
        McpTool(
          name: 'change',
          description: 'Changes.',
          inputSchema: const {'type': 'object'},
          changes: true,
          run: (a) async {
            ran?.add('change');
            if (a['fail'] == true) throw McpToolError('no way');
            return 'changed';
          },
        ),
        McpTool(name: 'crash', description: 'Crashes.', inputSchema: const {'type': 'object'}, run: (a) async => throw StateError('boom')),
      ],
    );

const modernMeta = {
  'io.modelcontextprotocol/protocolVersion': mcpModernVersion,
  'io.modelcontextprotocol/clientInfo': {'name': 'test', 'version': '1'},
  'io.modelcontextprotocol/clientCapabilities': <String, Object?>{},
};

Map<String, Object?> request(String method, [Map<String, Object?> params = const {}, Object? id = 1]) => {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params};

Map<String, Object?> result(McpReply? r) => (r!.body['result'] as Map).cast<String, Object?>();
Map<String, Object?> error(McpReply? r) => (r!.body['error'] as Map).cast<String, Object?>();
String text(Map<String, Object?> r) => ((r['content'] as List).single as Map)['text'] as String;

void main() {
  group('the revisions that begin with initialize', () {
    test('initialize answers with a version both sides speak, the tools and the instructions, and keeps no session', () async {
      final r = await protocol().handle(request('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'x', 'version': '1'}}));
      expect(r!.status, 200);
      expect(result(r)['protocolVersion'], '2025-06-18');
      expect(result(r)['capabilities'], {'tools': {'listChanged': false}});
      expect((result(r)['serverInfo'] as Map)['name'], 'Notation');
      expect(result(r)['instructions'], 'Use the tools.');
      expect(result(r).containsKey('resultType'), isFalse);
    });

    test('a version it does not know is answered with the newest it does', () async {
      final r = await protocol().handle(request('initialize', {'protocolVersion': '1999-01-01'}));
      expect(result(r)['protocolVersion'], mcpLegacyVersions.first);
    });

    test('notifications get no reply, and ping is answered', () async {
      expect(await protocol().handle({'jsonrpc': '2.0', 'method': 'notifications/initialized'}), isNull);
      expect(result(await protocol().handle(request('ping'))), isEmpty);
    });

    test('tools/list offers the tools that only look when changes are off, and all of them when on', () async {
      final read = result(await protocol(canChange: false).handle(request('tools/list')));
      expect([for (final t in read['tools'] as List) (t as Map)['name']], ['look', 'crash']);
      final all = result(await protocol().handle(request('tools/list')));
      expect([for (final t in all['tools'] as List) (t as Map)['name']], ['look', 'change', 'crash']);
      final tool = (all['tools'] as List)[1] as Map;
      expect((tool['annotations'] as Map)['readOnlyHint'], isFalse);
      expect(((all['tools'] as List)[0] as Map)['annotations'], containsPair('readOnlyHint', true));
    });

    test('tools/call runs the tool; a failure it explains is a result the agent can read, not a broken request', () async {
      final p = protocol();
      expect(text(result(await p.handle(request('tools/call', {'name': 'look', 'arguments': {'what': 'a cat'}})))), 'saw a cat');
      final failed = result(await p.handle(request('tools/call', {'name': 'change', 'arguments': {'fail': true}})));
      expect(failed['isError'], isTrue);
      expect(text(failed), 'no way');
      final crashed = result(await p.handle(request('tools/call', {'name': 'crash'})));
      expect(crashed['isError'], isTrue);
      expect(text(crashed), contains('boom'));
    });

    test('a tool that changes things refuses, without running, while changes are off', () async {
      final ran = <String>[];
      final r = result(await protocol(canChange: false, ran: ran).handle(request('tools/call', {'name': 'change'})));
      expect(r['isError'], isTrue);
      expect(text(r), contains('read only'));
      expect(ran, isEmpty);
    });

    test('onChanged hears of a tool that changes something and did it, and of nothing else', () async {
      final heard = <String>[];
      final p = McpProtocol(
        canChange: () => true,
        onChanged: (tool, args, result) => heard.add('${tool.name} ${args['n']} $result'),
        tools: () => [
          McpTool(name: 'look', description: '', inputSchema: const {'type': 'object'}, run: (a) async => 'saw'),
          McpTool(name: 'change', description: '', inputSchema: const {'type': 'object'}, changes: true, run: (a) async => a['fail'] == true ? throw McpToolError('no') : 'did'),
        ],
      );
      await p.handle(request('tools/call', {'name': 'look'}));
      await p.handle(request('tools/call', {'name': 'change', 'arguments': {'fail': true}}));
      await p.handle(request('tools/call', {'name': 'change', 'arguments': {'n': 7}}));
      expect(heard, ['change 7 did']);
    });

    test('a listener that fails does not fail the call', () async {
      final p = McpProtocol(
        canChange: () => true,
        onChanged: (tool, args, result) => throw StateError('the notice broke'),
        tools: () => [McpTool(name: 'change', description: '', inputSchema: const {'type': 'object'}, changes: true, run: (a) async => 'did')],
      );
      final r = result(await p.handle(request('tools/call', {'name': 'change'})));
      expect(r['isError'], isFalse);
      expect(text(r), 'did');
    });

    test('an unknown tool and arguments that are no object are errors of the request', () async {
      expect(error(await protocol().handle(request('tools/call', {'name': 'nope'})))['code'], -32602);
      expect(error(await protocol().handle(request('tools/call', {'name': 'look', 'arguments': 'text'})))['code'], -32602);
    });

    test('a method it does not have, and a message that is no request', () async {
      final unknown = await protocol().handle(request('resources/list'));
      expect(unknown!.status, 200);
      expect(error(unknown)['code'], -32601);
      final bad = await protocol().handle('hello');
      expect(bad!.status, 400);
      expect(error(bad)['code'], -32600);
    });

    test('a version in the header that no revision has is refused with the list of those that exist', () async {
      final r = await protocol().handle(request('tools/list'), const McpHeaders(version: '1900-01-01'));
      expect(r!.status, 400);
      expect(error(r)['code'], -32022);
      expect(((error(r)['data'] as Map)['supported'] as List), contains(mcpModernVersion));
    });

    test('two calls at once run one after the other', () async {
      final order = <String>[];
      final p = McpProtocol(canChange: () => true, tools: () => [
            McpTool(
              name: 'slow',
              description: '',
              inputSchema: const {'type': 'object'},
              run: (a) async {
                order.add('start ${a['n']}');
                await Future<void>.delayed(const Duration(milliseconds: 20));
                order.add('end ${a['n']}');
                return '';
              },
            ),
          ]);
      await Future.wait([for (var n = 1; n <= 3; n++) p.handle(request('tools/call', {'name': 'slow', 'arguments': {'n': n}}, n))]);
      expect(order, ['start 1', 'end 1', 'start 2', 'end 2', 'start 3', 'end 3']);
    });
  });

  group('the revision without a handshake', () {
    McpHeaders headers(String method, {String? name, String version = mcpModernVersion}) => McpHeaders(version: version, method: method, name: name);

    test('every request says what it speaks, and a result says it is complete', () async {
      final r = await protocol().handle(request('tools/list', {'_meta': modernMeta}), headers('tools/list'));
      expect(result(r)['resultType'], 'complete');
      expect(result(r)['ttlMs'], 0);
      expect(result(r)['cacheScope'], 'private');
      final c = await protocol().handle(request('tools/call', {'name': 'look', 'arguments': {'what': 'x'}, '_meta': modernMeta}), headers('tools/call', name: 'look'));
      expect(result(c)['resultType'], 'complete');
      expect(text(result(c)), 'saw x');
    });

    test('server/discover names the versions, the tools and the server', () async {
      final r = await protocol().handle(request('server/discover', {'_meta': modernMeta}), headers('server/discover'));
      expect(result(r)['supportedVersions'], [mcpModernVersion, ...mcpLegacyVersions]);
      expect(result(r)['capabilities'], containsPair('tools', isA<Map>()));
      expect((((result(r)['_meta']) as Map)['io.modelcontextprotocol/serverInfo'] as Map)['name'], 'Notation');
    });

    test('a version it does not speak gets the versions it does, with a 400', () async {
      final meta = {...modernMeta, 'io.modelcontextprotocol/protocolVersion': '2099-01-01'};
      final r = await protocol().handle(request('tools/list', {'_meta': meta}), headers('tools/list', version: '2099-01-01'));
      expect(r!.status, 400);
      expect(error(r)['code'], -32022);
      expect(error(r)['data'], containsPair('requested', '2099-01-01'));
    });

    test('headers that are missing or say something else than the body are a header mismatch', () async {
      final p = protocol();
      final body = request('tools/call', {'name': 'look', '_meta': modernMeta});
      for (final h in [
        const McpHeaders(), // none
        headers('tools/call', name: 'look', version: '2025-11-25'), // another version
        headers('tools/list', name: 'look'), // another method
        headers('tools/call'), // no name
        headers('tools/call', name: 'change'), // another tool
      ]) {
        final r = await p.handle(body, h);
        expect(r!.status, 400, reason: '${h.version} ${h.method} ${h.name}');
        expect(error(r)['code'], -32020);
      }
    });

    test('a name that is not plain ASCII comes base64 encoded in the header', () async {
      final p = McpProtocol(canChange: () => true, tools: () => [McpTool(name: 'größe', description: '', inputSchema: const {'type': 'object'}, run: (a) async => 'ok')]);
      final r = await p.handle(request('tools/call', {'name': 'größe', '_meta': modernMeta}), headers('tools/call', name: '=?base64?Z3LDtsOfZQ==?='));
      expect(text(result(r)), 'ok');
    });

    test('a method it does not have is a 404', () async {
      final r = await protocol().handle(request('resources/list', {'_meta': modernMeta}), headers('resources/list'));
      expect(r!.status, 404);
      expect(error(r)['code'], -32601);
    });

    test('initialize is still the old way in, whatever else the request says', () async {
      final r = await protocol().handle(request('initialize', {'protocolVersion': '2025-11-25', '_meta': modernMeta}));
      expect(result(r)['protocolVersion'], '2025-11-25');
    });
  });
}
