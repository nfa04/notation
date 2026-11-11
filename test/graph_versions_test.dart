import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/knowledge_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _payload(int nodes, [String tag = '']) => jsonEncode({'v': 1, 'mode': 'facts', 'tag': tag, 'nodes': List.generate(nodes, (i) => ['n$i'])});

void main() {
  setUpAll(AppDatabase.initFfi);
  late KnowledgeRepository k;

  setUp(() async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    for (final t in ['saved_graphs', 'graph_versions', 'sync_tombstones']) {
      await db.delete(t); // (the in-memory database is shared by the tests of a file)
    }
    k = NoteRepository(db).knowledge;
  });

  Future<(int, String)> make() async {
    final id = await k.saveGraph(name: 'G', mode: 'facts', folderId: null, payload: _payload(3, 'first'));
    return (id, (await k.listGraphs()).singleWhere((g) => g.id == id).uid);
  }

  test('making a graph again keeps the picture it had', () async {
    final (id, uid) = await make();
    expect(await k.listGraphVersions(uid: uid), isEmpty);
    await k.saveGraph(name: '', mode: 'facts', folderId: null, payload: _payload(5, 'second'), replace: id);
    final versions = await k.listGraphVersions(uid: uid);
    expect(versions, hasLength(1));
    expect(versions.single.nodes, 3);
    expect(jsonDecode((await k.loadGraphVersion(versions.single.id))!)['tag'], 'first');
    expect(jsonDecode((await k.loadGraph(id))!)['tag'], 'second');
  });

  test('a new graph (not made over another) has no earlier pictures, and graphs keep their own', () async {
    final (a, ua) = await make();
    final b = await k.saveGraph(name: 'H', mode: 'notes', folderId: null, payload: _payload(2));
    final ub = (await k.listGraphs()).singleWhere((g) => g.id == b).uid;
    await k.saveGraph(name: '', mode: 'facts', folderId: null, payload: _payload(4), replace: a);
    expect(await k.listGraphVersions(uid: ua), hasLength(1));
    expect(await k.listGraphVersions(uid: ub), isEmpty);
    expect(await k.listGraphVersions(), hasLength(1));
  });

  test('only the newest few are kept', () async {
    final (id, uid) = await make();
    for (var i = 0; i < KnowledgeRepository.keptVersions + 3; i++) {
      await k.saveGraph(name: '', mode: 'facts', folderId: null, payload: _payload(3, 'v$i'), replace: id);
    }
    final versions = await k.listGraphVersions(uid: uid);
    expect(versions, hasLength(KnowledgeRepository.keptVersions));
    // newest first: the one before the current picture comes first
    expect(jsonDecode((await k.loadGraphVersion(versions.first.id))!)['tag'], 'v${KnowledgeRepository.keptVersions + 1}');
  });

  test('an earlier picture can be brought back; the picture that was there takes its place', () async {
    final (id, uid) = await make();
    await k.saveGraph(name: '', mode: 'facts', folderId: null, payload: _payload(5, 'second'), replace: id);
    final old = (await k.listGraphVersions(uid: uid)).single;
    final changes = <String>[];
    k.onChange = changes.add;
    expect(await k.restoreGraphVersion(old.id), id);
    expect(jsonDecode((await k.loadGraph(id))!)['tag'], 'first');
    final now = await k.listGraphVersions(uid: uid);
    expect(now, hasLength(1));
    expect(jsonDecode((await k.loadGraphVersion(now.single.id))!)['tag'], 'second');
    expect(changes, contains('graph:$uid'));
    expect(await k.restoreGraphVersion(99999), isNull);
  });

  test('deleting a graph deletes its earlier pictures; deleting one picture leaves the graph', () async {
    final (id, uid) = await make();
    await k.saveGraph(name: '', mode: 'facts', folderId: null, payload: _payload(4), replace: id);
    await k.saveGraph(name: '', mode: 'facts', folderId: null, payload: _payload(6), replace: id);
    final versions = await k.listGraphVersions(uid: uid);
    expect(versions, hasLength(2));
    await k.deleteGraphVersion(versions.first.id);
    expect(await k.listGraphVersions(uid: uid), hasLength(1));
    expect(await k.loadGraph(id), isNotNull);
    await k.deleteGraph(id);
    expect(await k.listGraphVersions(), isEmpty);
  });

  test('a picture that comes by the sync replaces the one here, which is kept, unless they are the same', () async {
    final (id, uid) = await make();
    final g = (await k.listGraphs()).single;
    await k.applySyncedGraph(g, _payload(3, 'first')); // the same picture: nothing to keep
    expect(await k.listGraphVersions(uid: uid), isEmpty);
    await k.applySyncedGraph(g, _payload(9, 'from elsewhere'));
    final versions = await k.listGraphVersions(uid: uid);
    expect(versions, hasLength(1));
    expect(jsonDecode((await k.loadGraphVersion(versions.single.id))!)['tag'], 'first');
    expect(jsonDecode((await k.loadGraph(id))!)['tag'], 'from elsewhere');
    // a graph that is new here has nothing to keep
    final fresh = SavedGraph(id: 0, uid: 'abc123', name: 'X', mode: 'facts', folderId: null, builtAt: DateTime(2026), updatedAt: 5);
    await k.applySyncedGraph(fresh, _payload(2));
    expect(await k.listGraphVersions(uid: 'abc123'), isEmpty);
  });
}
