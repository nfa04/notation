import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/history/note_history.dart';
import 'package:notes/mcp/mcp_bridge.dart';
import 'package:notes/mcp/mcp_protocol.dart';

import 'support/mcp_fixture.dart';
import 'support/mcp_test_client.dart';

/// The whole stack, as an agent meets it: real HTTP to the real service, tools and repositories over a made-up library (see
/// `support/mcp_fixture.dart`), with a real note history. What the single parts do is tested beside this; this is for "does it hang
/// together", and the first thing to run after a change to anything in `lib/mcp/`.
void main() {
  setUpAll(AppDatabase.initFfi);

  for (final modern in [false, true]) {
    group(modern ? 'an agent on the revision without a handshake' : 'an agent on the revisions that begin with initialize', () {
      late McpFixture f;
      late McpTestClient agent;

      setUp(() async {
        f = await startMcpFixture();
        agent = McpTestClient(f.url, f.token, modern: modern);
      });

      tearDown(() async {
        await agent.close();
        await f.close();
      });

      test('connects, is told what the server is, and is offered the tools with their schemas', () async {
        final about = await agent.describe();
        expect(about['instructions'], contains('Notation'));
        expect(about['capabilities'], containsPair('tools', isA<Map>()));
        final tools = await agent.tools();
        expect(tools.map((t) => t['name']), containsAll(['list_notes', 'search_notes', 'read_note', 'create_note', 'append_to_note', 'replace_in_note', 'format_note_text', 'trash_note']));
        for (final t in tools) {
          expect(t['description'], isNotEmpty, reason: '${t['name']}');
          expect((t['inputSchema'] as Map)['type'], 'object', reason: '${t['name']}');
          expect(t['annotations'], contains('readOnlyHint'), reason: '${t['name']}');
        }
      });

      test('finds a note by what is in it, reads it, and the folder, tags and text are all there', () async {
        final found = await agent.json('search_notes', {'query': 'entropy'});
        final hit = (found['notes'] as List).single as Map;
        expect(hit['id'], f.ids['thermo']);
        expect(hit['title'], 'Thermodynamics');

        final read = await agent.text('read_note', {'note_id': hit['id']});
        expect(read, startsWith('# Thermodynamics'));
        expect(read, contains('folder: School'));
        expect(read, contains('tags: physics, school/physics'));
        expect(read, contains('Heat flows from hot to cold.'));
      });

      test('lists the library: notes by recency, by folder, by tag, the starred ones, the folders, the tags and the trash', () async {
        final all = await agent.json('list_notes');
        expect(all['total'], 3, reason: 'the locked note and the one in the trash are not there');
        expect([for (final n in all['notes'] as List) (n as Map)['title']], unorderedEquals(['Thermodynamics', 'Shopping list', 'Project plan']));
        expect((await agent.json('list_notes', {'folder_id': f.ids['work']}))['total'], 1);
        expect((await agent.json('list_notes', {'tag': 'school'}))['total'], 1, reason: 'found under the tag it is nested in');
        expect((await agent.json('list_notes', {'favorite': true}))['total'], 1);
        expect(((await agent.json('list_folders'))['folders'] as List).map((x) => (x as Map)['path']), containsAll(['School', 'School / Maths', 'Work']));
        expect((await agent.json('list_tags'))['tags'], containsPair('work', 1));
        expect(((await agent.json('list_trash'))['trash'] as List).single, containsPair('title', 'Old draft'));
      });

      test('changes a note from start to finish: append, replace, format, retitle; and the versions before and after are really kept', () async {
        final id = f.ids['plan']!;
        await agent.text('append_to_note', {'note_id': id, 'text': 'Review on Friday.'});
        await agent.text('replace_in_note', {'note_id': id, 'find': 'None yet.', 'replacement': 'Slipping schedule.'});
        await agent.text('append_to_note', {'note_id': id, 'text': 'Kickoff done.', 'after': 'Ship the beta.'});
        await agent.text('format_note_text', {'note_id': id, 'target': 'Slipping schedule.', 'bold': true});
        await agent.text('set_note_title', {'note_id': id, 'title': 'Project plan v2'});

        final read = await agent.text('read_note', {'note_id': id});
        expect(read, startsWith('# Project plan v2'));
        expect(read, contains('Ship the beta.\nKickoff done.'));
        expect(read, contains('**Slipping schedule.**'));
        expect(read, endsWith('Review on Friday.'));

        // every change leaves the note as it was after it; one is kept before only when the note differs from the last version kept
        // (a version equal to the one before it is not kept again)
        final versions = await f.history.list(id);
        final labels = [for (final v in versions) '${v.reason.name}: ${v.label}'];
        for (final what in ['append text', 'replace text', 'format text', 'change the title']) {
          expect(labels, contains('assistant: Agent (MCP): $what'));
        }
        expect(labels, contains('assistantBefore: Agent (MCP): append text'));
        // the "before" is the note as the person left it, the last "after" is the note as it is
        final before = versions.where((v) => v.reason == VersionReason.assistantBefore).last;
        final original = (await f.history.read(before)).note.documentText;
        expect(original, contains('None yet.'));
        expect(original, isNot(contains('Review on Friday.')));
        final after = versions.where((v) => v.reason == VersionReason.assistant).first;
        expect((await f.history.read(after)).note.documentText, contains('Slipping schedule.'));
      });

      test('organises: makes a folder and a tagged note in it, moves, stars, trashes and restores it', () async {
        final folder = await agent.made('create_folder', {'name': 'Ideas', 'parent_id': f.ids['work']});
        final id = await agent.made('create_note', {'title': 'Big idea', 'text': 'What if notes could talk?', 'folder_id': folder, 'tags': ['Brainstorm']});
        expect(((await agent.json('list_notes', {'folder_id': folder}))['notes'] as List).single, containsPair('title', 'Big idea'));
        expect((await agent.json('list_notes', {'tag': 'brainstorm'}))['total'], 1);

        await agent.text('move_note', {'note_id': id, 'folder_id': f.ids['maths']});
        await agent.text('set_note_favorite', {'note_id': id});
        await agent.text('set_note_tags', {'note_id': id, 'tags': ['brainstorm', 'later']});
        final moved = ((await agent.json('list_notes', {'favorite': true}))['notes'] as List).firstWhere((n) => (n as Map)['id'] == id) as Map;
        expect(moved['folder'], 'School / Maths');
        expect(moved['tags'], ['brainstorm', 'later']);

        await agent.text('trash_note', {'note_id': id});
        expect((await agent.json('list_trash'))['trash'], hasLength(2));
        expect((await agent.tool('read_note', {'note_id': id})).failed, isTrue);
        await agent.text('restore_note', {'note_id': id});
        expect(await agent.text('read_note', {'note_id': id}), contains('What if notes could talk?'));

        await agent.text('delete_folder', {'folder_id': folder});
        expect((await agent.json('list_folders'))['folders'], hasLength(3));
        expect(await agent.text('read_note', {'note_id': id}), contains('Big idea'), reason: 'the notes of a deleted folder are kept');
      });

      test('tells the app what it changes (so that the person can be shown), and only when something was changed', () async {
        final seen = <(String, String?)>[];
        final sub = f.service.activity.listen((a) => seen.add((a.tool, a.noteId)));
        await agent.json('list_notes');
        await agent.tool('append_to_note', {'note_id': 'nope', 'text': 'x'}); // fails
        await agent.text('append_to_note', {'note_id': f.ids['plan'], 'text': 'x'});
        final made = await agent.made('create_note', {'title': 'New one'});
        await agent.text('create_folder', {'name': 'F'});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await sub.cancel();
        expect(seen, [('append_to_note', f.ids['plan']), ('create_note', made), ('create_folder', null)]);
      });

      test('works with tasks', () async {
        expect(((await agent.json('list_tasks'))['tasks'] as List).map((t) => (t as Map)['title']), unorderedEquals(['Hand in essay', 'Buy milk']));
        final id = await agent.made('add_task', {'title': 'Call the dentist', 'due': '2026-11-02'});
        await agent.text('set_task_done', {'task_id': id});
        final open = (await agent.json('list_tasks'))['tasks'] as List;
        expect(open.map((t) => (t as Map)['title']), isNot(contains('Call the dentist')));
        expect(((await agent.json('list_tasks', {'include_done': true}))['tasks'] as List), hasLength(4));
        expect((await agent.tool('add_task', {'title': 'x', 'due': 'tomorrow'})).failed, isTrue);
      });

      test('never sees a locked note, and nothing it does can reach one', () async {
        final id = f.ids['diary']!;
        expect((await agent.json('search_notes', {'query': 'swordfish'}))['total_matches'], 0);
        expect(((await agent.json('list_notes'))['notes'] as List).map((n) => (n as Map)['id']), isNot(contains(id)));
        for (final (tool, args) in [
          ('read_note', <String, Object?>{}),
          ('append_to_note', {'text': 'hello'}),
          ('replace_in_note', {'find': 'dear', 'replacement': 'x'}),
          ('set_note_text', {'text': 'x'}),
          ('set_note_title', {'title': 'x'}),
          ('trash_note', <String, Object?>{}),
        ]) {
          final r = await agent.tool(tool, {'note_id': id, ...args});
          expect(r.failed, isTrue, reason: tool);
          expect(r.text, contains('locked'), reason: tool);
        }
        expect((await f.repository.loadNote(id))!.documentText, 'dear diary: the password is swordfish');
      });

      test('says what is wrong in words it can act on', () async {
        for (final (tool, args, says) in [
          ('read_note', <String, Object?>{'note_id': 'nope'}, 'no note'),
          ('read_note', <String, Object?>{}, 'note_id'),
          ('search_notes', <String, Object?>{'query': '(', 'regex': true}, 'not valid'),
          ('replace_in_note', <String, Object?>{'note_id': f.ids['plan'], 'find': 'zebra', 'replacement': 'x'}, 'not in the note'),
          ('format_note_text', <String, Object?>{'note_id': f.ids['plan'], 'target': 'all', 'wobble': true}, 'wobble'),
          ('move_note', <String, Object?>{'note_id': f.ids['plan'], 'folder_id': 'nope'}, 'no folder'),
          ('move_folder', <String, Object?>{'folder_id': f.ids['school'], 'parent_id': f.ids['maths']}, 'itself'),
        ]) {
          final r = await agent.tool(tool, args);
          expect(r.failed, isTrue, reason: '$tool $args');
          expect(r.text.toLowerCase(), contains(says), reason: '$tool: ${r.text}');
        }
        final (status, reply) = await agent.request('tools/call', {'name': 'no_such_tool'});
        expect(status, 200);
        expect((reply['error'] as Map)['code'], -32602);
      });

      test('read only: the tools that change things are not offered and refuse, nothing is changed, and allowing it takes effect at once', () async {
        await f.service.setCanChange(false);
        final names = await agent.toolNames();
        expect(names, containsAll(['list_notes', 'search_notes', 'read_note', 'inspect_note_formatting']));
        for (final n in ['create_note', 'append_to_note', 'trash_note', 'delete_folder', 'add_task']) {
          expect(names, isNot(contains(n)));
        }
        final refused = await agent.tool('append_to_note', {'note_id': f.ids['plan'], 'text': 'x'});
        expect(refused.failed, isTrue);
        expect(refused.text, contains('read only'));
        expect((await f.repository.loadNote(f.ids['plan']!))!.documentText, isNot(contains('x\n')));

        await f.service.setCanChange(true);
        expect(await agent.toolNames(), contains('append_to_note'));
        expect((await agent.tool('append_to_note', {'note_id': f.ids['plan'], 'text': 'Now allowed.'})).failed, isFalse);
      });
    });
  }

  group('the door', () {
    late McpFixture f;
    late McpTestClient agent;

    setUp(() async {
      f = await startMcpFixture();
      agent = McpTestClient(f.url, f.token);
    });

    tearDown(() async {
      await agent.close();
      await f.close();
    });

    const ping = {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'};

    test('only a request with the token, to the loopback name, from no other site, gets in', () async {
      expect((await agent.send(ping)).$1, 200);
      expect((await agent.send(ping, bearer: 'wrong')).$1, 401);
      expect((await agent.send(ping, host: 'evil.example')).$1, 403);
      expect((await agent.send(ping, origin: 'https://evil.example')).$1, 403);
      expect((await agent.send(null, method: 'GET')).$1, 405);
      expect((await agent.send(ping, path: '/elsewhere')).$1, 404);
    });

    test('a new token lets out the agent that had the old one, and the app\'s switch stops the server', () async {
      final old = f.token;
      await f.service.regenerateToken();
      expect((await agent.send(ping, bearer: old)).$1, 401);
      expect((await agent.send(ping, bearer: f.token)).$1, 200);
      await f.service.setEnabled(false);
      await expectLater(agent.send(ping, bearer: f.token), throwsA(anything));
    });

    test('a request on the newest revision whose headers disagree with its body, or that names a version nobody has, is refused', () async {
      Map<String, Object?> body(String version) => {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/list',
            'params': {
              '_meta': {'io.modelcontextprotocol/protocolVersion': version},
            },
          };
      final (mismatch, text) = await agent.send(body(mcpModernVersion), headers: {'MCP-Protocol-Version': mcpModernVersion, 'Mcp-Method': 'tools/call'});
      expect(mismatch, 400);
      expect(((jsonDecode(text) as Map)['error'] as Map)['code'], -32020);

      final (unsupported, said) = await agent.send(body('2099-01-01'), headers: {'MCP-Protocol-Version': '2099-01-01', 'Mcp-Method': 'tools/list'});
      expect(unsupported, 400);
      final error = (jsonDecode(said) as Map)['error'] as Map;
      expect(error['code'], -32022);
      expect((error['data'] as Map)['supported'], contains(mcpModernVersion));
    });

    test('the stdio bridge carries a whole session: handshake, tools, a call that changes a note', () async {
      final lines = [
        jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18'}}),
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
        jsonEncode({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'append_to_note', 'arguments': {'note_id': f.ids['shopping'], 'text': '- [ ] cheese'}}}),
        jsonEncode({'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {'name': 'read_note', 'arguments': {'note_id': f.ids['shopping']}}}),
      ];
      final out = <String>[];
      await runMcpBridge(Stream.fromIterable(lines), out.add, url: Uri.parse(f.url), token: f.token);
      final byId = {for (final l in out) (jsonDecode(l) as Map)['id']: (jsonDecode(l) as Map)['result'] as Map};
      expect(byId.keys, {1, 2, 3, 4}, reason: 'one reply for each request, none for the notification');
      expect(byId[1]!['protocolVersion'], '2025-06-18');
      expect(((byId[2]!['tools'] as List).length), greaterThan(10));
      expect(byId[3]!['isError'], false);
      expect((((byId[4]!['content'] as List).single as Map)['text'] as String), contains('- [ ] cheese'));
    });
  });
}
