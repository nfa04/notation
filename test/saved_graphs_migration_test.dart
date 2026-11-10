import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/knowledge_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('the one graph per kind that the version before kept becomes a kept graph each (a tab), and the old table goes', () async {
    final dir = await Directory.systemTemp.createTemp('graphs_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/n.db';
    final old = await databaseFactory.openDatabase(path, options: OpenDatabaseOptions(version: 50, onCreate: (db, _) async {
      await db.execute('CREATE TABLE sync_tombstones (kind TEXT NOT NULL, id TEXT NOT NULL, deleted_at INTEGER NOT NULL, PRIMARY KEY (kind, id))');
      await db.execute('CREATE TABLE graph_snapshots (mode TEXT PRIMARY KEY, built_at INTEGER NOT NULL, payload TEXT NOT NULL)');
      await db.insert('graph_snapshots', {'mode': 'facts', 'built_at': 1700000000000, 'payload': 'F'});
      await db.insert('graph_snapshots', {'mode': 'notes', 'built_at': 1700000001000, 'payload': 'N'});
    }));
    await old.close();

    final db = await AppDatabase.open(path: path);
    final repo = KnowledgeRepository(db);
    final graphs = await repo.listGraphs();
    expect(graphs.map((g) => (g.name, g.mode, g.folderId, g.uid)), [('Facts', 'facts', null, 'first-facts'), ('Notes', 'notes', null, 'first-notes')]);
    expect(graphs.first.builtAt.millisecondsSinceEpoch, 1700000000000);
    expect(await repo.loadGraph(graphs.last.id), 'N');
    expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE name = 'graph_snapshots'"), isEmpty);

    // a kept graph is replaced in place (name kept), renamed and deleted
    final id = await repo.saveGraph(name: 'x', mode: 'facts', folderId: 'f1', payload: 'F2', replace: graphs.first.id);
    expect(id, graphs.first.id);
    await repo.renameGraph(id, 'Mine');
    final after = (await repo.listGraphs()).first;
    expect((after.name, after.folderId), ('Mine', 'f1'));
    expect(await repo.loadGraph(id), 'F2');
    await repo.deleteGraph(id);
    expect(await repo.listGraphs(), hasLength(1));
    expect((await db.query('sync_tombstones')).single['id'], 'first-facts', reason: 'the other devices are told');
    await db.close();
  });

  test('a database that the first build of version 51 made (graphs without ids) gets them, and keeps its graphs', () async {
    final dir = await Directory.systemTemp.createTemp('graphs_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/n.db';
    final old = await databaseFactory.openDatabase(path, options: OpenDatabaseOptions(version: 51, onCreate: (db, _) async {
      await db.execute('CREATE TABLE sync_tombstones (kind TEXT NOT NULL, id TEXT NOT NULL, deleted_at INTEGER NOT NULL, PRIMARY KEY (kind, id))');
      await db.execute('CREATE TABLE saved_graphs (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, mode TEXT NOT NULL, folder_id TEXT, built_at INTEGER NOT NULL, payload TEXT NOT NULL)');
      await db.insert('saved_graphs', {'name': 'Facts', 'mode': 'facts', 'built_at': 1700000000000, 'payload': 'F'});
      await db.insert('saved_graphs', {'name': 'Notes', 'mode': 'notes', 'built_at': 1700000001000, 'payload': 'N'});
    }));
    await old.close();

    final db = await AppDatabase.open(path: path);
    final repo = KnowledgeRepository(db);
    final graphs = await repo.listGraphs();
    expect(graphs.map((g) => g.name), ['Facts', 'Notes']);
    expect(graphs.map((g) => g.uid).toSet(), hasLength(2));
    expect(graphs.every((g) => g.uid.isNotEmpty), isTrue);
    expect(graphs.map((g) => g.updatedAt), [1700000000000, 1700000001000]);
    expect(await repo.loadGraph(graphs.first.id), 'F');
    // and it takes new ones, with ids that are different
    final id = await repo.saveGraph(name: 'New', mode: 'facts', folderId: null, payload: 'X');
    expect((await repo.listGraphs()).map((g) => g.uid).toSet(), hasLength(3));
    expect(id, greaterThan(graphs.last.id));
    await db.close();
  });
}
