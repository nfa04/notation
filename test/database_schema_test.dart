import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/point_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  setUp(() async => db = await AppDatabase.open(path: inMemoryDatabasePath));
  tearDown(() => db.close());

  Future<void> note(String id, {String? folder}) => db.insert('notes', {
        'id': id,
        'folder_id': folder,
        'created_at': 1,
        'updated_at': 1,
      });

  test('deleting a note deletes its annotations', () async {
    await note('n1');
    await db.insert('strokes', {
      'note_id': 'n1', 'page_index': 0, 'color': 0xFF000000, 'width': 3.0,
      'points': encodePoints(const [Offset(1, 2), Offset(3, 4)]),
    });
    await db.insert('text_boxes', {
      'id': 'b1', 'note_id': 'n1', 'page_index': 0,
      'x': 0, 'y': 0, 'width': 260, 'height': 140,
    });
    await db.delete('notes', where: 'id = ?', whereArgs: ['n1']);
    expect(await db.query('strokes'), isEmpty);
    expect(await db.query('text_boxes'), isEmpty);
  });

  test('deleting a folder keeps its notes, deleting its subfolders', () async {
    await db.insert('folders', {'id': 'a', 'name': 'A', 'created_at': 1, 'updated_at': 1});
    await db.insert('folders', {'id': 'b', 'parent_id': 'a', 'name': 'B', 'created_at': 1, 'updated_at': 1});
    await note('n1', folder: 'a');
    await db.delete('folders', where: 'id = ?', whereArgs: ['a']);
    expect(await db.query('folders'), isEmpty);
    expect((await db.query('notes')).single['folder_id'], isNull);
  });

  test('pdf columns must be set together', () async {
    expect(
      () => db.insert('notes', {'id': 'x', 'pdf_name': 'a.pdf', 'created_at': 1, 'updated_at': 1}),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('points round-trip', () {
    final pts = [const Offset(1.5, -2), const Offset(300, 1129.25)];
    expect(decodePoints(Uint8List.fromList(encodePoints(pts))), pts);
  });

  test('a version 1 database is upgraded with the folder image column', () async {
    final dir = await Directory.systemTemp.createTemp('schema_upgrade_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/old.db';

    final old = await databaseFactory.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (d, _) async {
            await d.execute(
                'CREATE TABLE folders (id TEXT PRIMARY KEY, parent_id TEXT, name TEXT NOT NULL, color INTEGER, '
                'sort_order INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');
            await d.execute('CREATE TABLE notes (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT \'\')');
            await d.execute('CREATE TABLE text_boxes (id TEXT NOT NULL, note_id TEXT NOT NULL, text TEXT NOT NULL DEFAULT \'\')');
            await d.execute('CREATE TABLE highlights (id INTEGER PRIMARY KEY AUTOINCREMENT, note_id TEXT NOT NULL, page_index INTEGER NOT NULL)');
            await d.execute('CREATE TABLE strokes (id INTEGER PRIMARY KEY AUTOINCREMENT, note_id TEXT NOT NULL, page_index INTEGER NOT NULL)');
            await d.insert('text_boxes', {'id': 'b', 'note_id': 'n'});
          },
        ));
    await old.insert('folders', {'id': 'f', 'name': 'Old', 'created_at': 1, 'updated_at': 1});
    await old.close();

    final upgraded = await AppDatabase.open(path: path);
    addTearDown(upgraded.close);
    final row = (await upgraded.query('folders')).single;
    expect(row['name'], 'Old');
    expect(row.containsKey('theme_image'), isTrue);
    expect(row['theme_image'], isNull);
  });

  test('an upgraded note starts upright on A4', () async {
    final dir = await Directory.systemTemp.createTemp('schema_upgrade_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/old.db';
    final old = await databaseFactory.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (d, _) async {
            await d.execute(
                'CREATE TABLE folders (id TEXT PRIMARY KEY, parent_id TEXT, name TEXT NOT NULL, color INTEGER, '
                'sort_order INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');
            await d.execute('CREATE TABLE notes (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT \'\')');
            await d.execute('CREATE TABLE text_boxes (id TEXT NOT NULL, note_id TEXT NOT NULL, text TEXT NOT NULL DEFAULT \'\')');
            await d.execute('CREATE TABLE highlights (id INTEGER PRIMARY KEY AUTOINCREMENT, note_id TEXT NOT NULL, page_index INTEGER NOT NULL)');
            await d.execute('CREATE TABLE strokes (id INTEGER PRIMARY KEY AUTOINCREMENT, note_id TEXT NOT NULL, page_index INTEGER NOT NULL)');
            await d.insert('text_boxes', {'id': 'b', 'note_id': 'n'});
            await d.insert('notes', {'id': 'n'});
          },
        ));
    await old.close();

    final upgraded = await AppDatabase.open(path: path);
    addTearDown(upgraded.close);
    final row = (await upgraded.query('notes')).single;
    expect(row['page_format'], 'a4');
    expect(row['landscape'], 0);
    expect(row['margin_left'], 56);
    expect(row['margin_right'], 56);
    expect(row.containsKey('theme_image'), isTrue);
    expect(row['theme_image'], isNull);
    expect(row.containsKey('last_opened_at'), isTrue); // (for notes not opened for a while)
    expect(row['last_opened_at'], isNull);
    // text boxes made before they had a look keep the default one
    final box = (await upgraded.query('text_boxes')).single;
    expect(box.containsKey('style'), isTrue);
    expect(box['style'], isNull);
  });

  test('a database that was numbered 29 before it had the margin and branch columns gets them', () async {
    final dir = await Directory.systemTemp.createTemp('schema_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/old.db';
    final fresh = await AppDatabase.open(path: path);
    await fresh.close();
    final raw = await databaseFactory.openDatabase(path);
    await raw.execute('ALTER TABLE notes DROP COLUMN margin_top');
    await raw.execute('ALTER TABLE notes DROP COLUMN margin_bottom');
    await raw.execute('ALTER TABLE note_versions DROP COLUMN branch');
    await raw.execute('DROP TABLE note_branches');
    await raw.execute('PRAGMA user_version = 29');
    await raw.close();

    final upgraded = await AppDatabase.open(path: path);
    addTearDown(upgraded.close);
    final notes = (await upgraded.rawQuery('PRAGMA table_info(notes)')).map((c) => c['name']);
    expect(notes, containsAll(['margin_top', 'margin_bottom']));
    expect((await upgraded.rawQuery('PRAGMA table_info(note_versions)')).map((c) => c['name']), contains('branch'));
    expect(await upgraded.query('note_branches'), isEmpty);
  });
}
