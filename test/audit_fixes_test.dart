import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/database_schema.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/rich_text.dart';
import 'package:notes/screens/image_item_widget.dart';
import 'package:notes/widgets/bounded_image.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The fixes of the review of 2026-11-16: each test fails on the code as it was before.
void main() {
  setUpAll(AppDatabase.initFfi);

  group('the repository', () {
    late Directory dir;
    late Database db;
    late NoteRepository repo;
    setUp(() async {
      // (a database of its own: the in-memory one is shared between the tests of a file)
      dir = await Directory.systemTemp.createTemp('audit_fixes_');
      db = await AppDatabase.open(path: '${dir.path}/n.db');
      repo = NoteRepository(db);
    });
    tearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });

    Future<int> editedAt(String id) async => (await repo.noteTimes(id))!.edited.millisecondsSinceEpoch;

    test('a text box written straight into a note is an edit the sync hears of', () async {
      final id = await repo.createNote(title: 'n');
      await db.update('notes', {'updated_at': 1}, where: 'id = ?', whereArgs: [id]);
      final changes = <String>[], saves = <String>[];
      repo.changes.listen(changes.add);
      repo.saved.listen(saves.add);
      await repo.putTextBox(id, 0, TextBoxWidgetModel(id: 'b', position: Offset.zero, initialText: 'hello', layer: 'L', group: 'G'));
      await pumpEventQueue();
      expect(await editedAt(id), greaterThan(1));
      expect(changes, [id]);
      expect(saves, isEmpty, reason: 'a save would start the rules that run when a note is left alone, and a rule that writes a box would start itself again');
      final box = (await repo.loadNote(id))!.textBoxes[0]!.single;
      expect((box.text, box.layer, box.group), ('hello', 'L', 'G'));

      await db.update('notes', {'updated_at': 1}, where: 'id = ?', whereArgs: [id]);
      await repo.removeTextBox(id, 0, 'b');
      await pumpEventQueue();
      expect(await editedAt(id), greaterThan(1));
      expect(changes, [id, id]);
    });

    test('a text box for a note that is not there writes nothing', () async {
      await repo.putTextBox('gone', 0, TextBoxWidgetModel(id: 'b', position: Offset.zero, initialText: 'x'));
      expect(await db.query('text_boxes'), isEmpty);
    });

    test('a note and a folder go with their tombstones', () async {
      final f = await repo.createFolder('F');
      final sub = await repo.createFolder('S', parentId: f);
      final n = await repo.createNote(title: 'n');
      await repo.deleteNote(n);
      await repo.deleteFolder(f);
      final tombs = {for (final r in await db.query('sync_tombstones')) '${r['kind']}:${r['id']}'};
      expect(tombs, {'note:$n', 'folder:$f', 'folder:$sub'});
      expect(await repo.loadNote(n), isNull);
    });

    test('text boxes read from the database make no controller until one is asked for', () async {
      final id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: Offset.zero, initialText: 'ab')..attributes.add(TextSpanAttribute(start: 0, end: 1, type: AttributeType.bold))];
      await repo.saveNote(note);
      final box = (await repo.loadNote(id))!.textBoxes[0]!.single;
      expect(box.hasController, isFalse);
      expect(box.attributes.single.type, AttributeType.bold);
      // the editor's controller starts with the text and formatting, and from then on they are its own
      expect(box.controller.text, 'ab');
      expect(box.controller.attributes.single.end, 1);
      box.controller.text = 'abc';
      expect(box.text, 'abc');
      box.dispose();
      expect((box.hasController, box.text, box.attributes.length), (false, 'abc', 1));
    });
  });

  group('the database file', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('audit_db_'));
    tearDown(() => dir.delete(recursive: true));

    test('a database made by a newer build is not opened (its version is left alone)', () async {
      final path = '${dir.path}/n.db';
      final newer = await databaseFactory.openDatabase(path, options: OpenDatabaseOptions(version: schemaVersion + 1, onCreate: (d, _) async {}));
      await newer.close();
      await expectLater(AppDatabase.open(path: path), throwsA(isA<StateError>()));
      expect(await AppDatabase.fileVersion(path), schemaVersion + 1);
    });

    test('a database is copied before it is upgraded, and not otherwise', () async {
      final path = '${dir.path}/n.db';
      final old = await databaseFactory.openDatabase(path, options: OpenDatabaseOptions(version: schemaVersion - 1, onCreate: (d, _) async {
        for (final sql in createStatements) {
          await d.execute(sql);
        }
      }));
      await old.close();
      expect(await AppDatabase.fileVersion(path), schemaVersion - 1);
      final db = await AppDatabase.open(path: path);
      await db.close();
      expect(await AppDatabase.fileVersion('$path.before-upgrade'), schemaVersion - 1);
      expect(await AppDatabase.fileVersion(path), schemaVersion);

      await File('$path.before-upgrade').delete();
      await (await AppDatabase.open(path: path)).close();
      expect(File('$path.before-upgrade').existsSync(), isFalse, reason: 'up to date: nothing to copy');
    });
  });

  group('the stamp of a line', () {
    DrawingStroke line() => DrawingStroke(color: const Color(0xFF000000), width: 2, points: [for (var i = 0; i < 400; i++) Offset(i.toDouble(), 0)]);

    test('sees a change anywhere in the line', () {
      final s = line();
      final before = s.stamp;
      s.points[5] = const Offset(5, 300);
      expect(s.stamp, isNot(before), reason: 'point 5 is not among the sampled ones');
      final after = s.stamp;
      s.points.setRange(130, 132, const [Offset(1, 1), Offset(2, 2)]);
      expect(s.stamp, isNot(after));
    });

    test('is the same while nothing changes, and the points are the list it was made with', () {
      final list = [const Offset(0, 0), const Offset(1, 1)];
      final s = DrawingStroke(color: const Color(0xFF000000), width: 2, points: list);
      expect(s.stamp, s.stamp);
      list.add(const Offset(2, 2)); // (a change to that list itself: the sample sees it)
      expect(s.points.length, 3);
      final copy = DrawingStroke(color: const Color(0xFF000000), width: 2, points: s.points);
      expect(identical(copy.points, s.points), isTrue);
    });
  });

  group('pictures are decoded no larger than they are shown', () {
    test('covering a box keeps the side that fills it', () {
      // a wide picture covering a tall box: its height fills the box, so it is wider than the box
      final t = BoundedImage.target(4000, 1000, 200, 200, cover: true);
      expect((t.width, t.height), (800, 200));
      final fit = BoundedImage.target(4000, 1000, 200, 200, cover: false);
      expect((fit.width, fit.height), (200, 50));
    });

    test('never larger than the picture', () {
      final t = BoundedImage.target(100, 50, 400, 400, cover: true);
      expect((t.width, t.height), (null, null));
    });

    test('a page decodes again only when the size doubles', () {
      expect(ImageItemWidget.decodeSide(const Size(400, 300), 2), 1024);
      expect(ImageItemWidget.decodeSide(const Size(420, 300), 2), 1024);
      expect(ImageItemWidget.decodeSide(const Size(600, 300), 2), 2048);
      expect(ImageItemWidget.decodeSide(const Size(40, 30), 1), 256);
    });

    test('box sizes are rounded up to steps', () {
      expect(roundedPixels(10), 64);
      expect(roundedPixels(1000), 1024);
      expect(roundedPixels(1030), 1152); // (above 1024 the steps are 128)
    });
  });
}
