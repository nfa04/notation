import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/page_background.dart';
import 'package:notes/models/page_format.dart';
import 'package:notes/models/pdf_models.dart';
import 'package:notes/models/rich_text.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late NoteRepository repo;
  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    repo = NoteRepository(db);
  });
  tearDown(() => db.close());

  test('added pen colours are kept', () async {
    expect(await repo.settings.penColors(), isEmpty);
    await repo.settings.setPenColors(const [Color(0xFFFF8800), Color(0xFF123456)]);
    expect(await repo.settings.penColors(), const [Color(0xFFFF8800), Color(0xFF123456)]);
  });

  test('page size and orientation are kept', () async {
    final id = await repo.createNote(title: 'Wide');
    var note = (await repo.loadNote(id))!;
    expect(note.pageFormat, PageFormat.a4);
    expect(note.landscape, isFalse);
    note.pageFormat = PageFormat.letter;
    note.landscape = true;
    await repo.saveNote(note);
    note = (await repo.loadNote(id))!;
    expect(note.pageFormat, PageFormat.letter);
    expect(note.landscape, isTrue);
  });

  test('a note keeps its theme image, which goes with the note', () async {
    final dir = await Directory.systemTemp.createTemp('note_theme_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/banner.png')..writeAsBytesSync([1, 2, 3]);

    final id = await repo.createNote(title: 'Pretty');
    expect((await repo.listNotes()).single.themeImage, isNull);
    await repo.setNoteThemeImage(id, file.path);
    expect((await repo.listNotes()).single.themeImage, file.path);
    expect((await repo.loadNote(id))!.themeImage, file.path);

    // autosaving the note does not drop the banner
    await repo.saveNote((await repo.loadNote(id))!);
    expect((await repo.loadNote(id))!.themeImage, file.path);

    await repo.setNoteThemeImage(id, null);
    expect((await repo.listNotes()).single.themeImage, isNull);

    await repo.setNoteThemeImage(id, file.path);
    await repo.deleteNote(id);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(file.existsSync(), isFalse);
  });

  test('a note without a banner shows the one of its folder', () async {
    final folder = await repo.createFolder('Trip');
    await repo.setFolderThemeImage(folder, '/folder/banner.png');
    final id = await repo.createNote(title: 'Plan', folderId: folder);

    expect((await repo.listNotes()).single.themeImage, '/folder/banner.png');
    var note = (await repo.loadNote(id))!;
    expect(note.themeImage, isNull); // not the note's own
    expect(note.folderThemeImage, '/folder/banner.png');

    await repo.setNoteThemeImage(id, '/own.png');
    expect((await repo.listNotes()).single.themeImage, '/own.png');
    note = (await repo.loadNote(id))!;
    expect(note.themeImage, '/own.png');

    await repo.setNoteThemeImage(id, null);
    expect((await repo.listNotes()).single.themeImage, '/folder/banner.png');
  });

  test('document margins are kept', () async {
    final id = await repo.createNote();
    var note = (await repo.loadNote(id))!;
    expect((note.marginLeft, note.marginRight), (56.0, 56.0));
    note.marginLeft = 90;
    note.marginRight = 30.5;
    await repo.saveNote(note);
    note = (await repo.loadNote(id))!;
    expect((note.marginLeft, note.marginRight), (90.0, 30.5));
  });

  test('landscape turns the aspect ratio around', () {
    expect(PageFormat.a4.aspect(landscape: false), greaterThan(1));
    expect(PageFormat.a4.aspect(landscape: true), closeTo(210 / 297, 1e-9));
    expect(PageFormat.square.aspect(landscape: true), 1);
  });

  test('save and load round-trip', () async {
    final id = await repo.createNote(title: 'Algebra');
    final note = (await repo.loadNote(id))!;
    note.background = PageBackground.grid;
    note.documentText = '# Hi';
    note.documentSpans = [TextSpanAttribute(start: 2, end: 4, type: AttributeType.bold)];
    note.strokes[1] = [
      DrawingStroke(color: const Color(0xFF112233), width: 3, points: const [Offset(1, 2), Offset(3, 4)]),
      DrawingStroke(color: const Color(0xFF112233), width: 3, points: const [Offset(9, 9)]), // dropped
    ];
    final box = TextBoxWidgetModel(
        id: 'b1', position: const Offset(10, 20), initialText: 'hello', fontSize: 18);
    box.controller.attributes.add(TextSpanAttribute(start: 0, end: 2, type: AttributeType.italic));
    note.textBoxes[0] = [box];
    note.highlights[0] = [PdfHighlight(rect: const Rect.fromLTRB(1, 2, 3, 4), color: const Color(0x66FFFF00))];
    await repo.saveNote(note);

    final back = (await repo.loadNote(id))!;
    expect(back.title, 'Algebra');
    expect(back.background, PageBackground.grid);
    expect(back.documentText, '# Hi');
    expect(back.documentSpans.single.type, AttributeType.bold);
    expect(back.strokes[1]!.single.points, const [Offset(1, 2), Offset(3, 4)]);
    expect(back.strokes[1]!.single.color, const Color(0xFF112233));
    final b = back.textBoxes[0]!.single;
    expect([b.id, b.position, b.controller.text, b.fontSize], ['b1', const Offset(10, 20), 'hello', 18.0]);
    expect(b.controller.attributes.single.type, AttributeType.italic);
    expect(back.highlights[0]!.single.rect, const Rect.fromLTRB(1, 2, 3, 4));
    expect(back.highlights[0]!.single.color, const Color(0x66FFFF00));
  });

  test('saving twice does not duplicate, deleted notes stay deleted', () async {
    final id = await repo.createNote();
    final note = (await repo.loadNote(id))!;
    note.strokes[0] = [DrawingStroke(color: const Color(0xFF000000), width: 1, points: const [Offset(0, 0), Offset(1, 1)])];
    await repo.saveNote(note);
    await repo.saveNote(note);
    expect(await db.query('strokes'), hasLength(1));

    await repo.deleteNote(id);
    await repo.saveNote(note);
    expect(await db.query('strokes'), isEmpty);
    expect(await repo.loadNote(id), isNull);
  });

  test('list is newest first', () async {
    final a = await repo.createNote(title: 'a');
    await Future<void>.delayed(const Duration(milliseconds: 3));
    final b = await repo.createNote(title: 'b');
    expect((await repo.listNotes()).map((n) => n.id), [b, a]);
  });

  group('folders', () {
    test('create, nest, count, move notes', () async {
      final a = await repo.createFolder('A');
      final b = await repo.createFolder('B', parentId: a);
      final n = await repo.createNote(folderId: b);
      await repo.createNote(); // unfiled

      final folders = await repo.listFolders();
      expect(folders.map((f) => (f.name, f.parentId, f.noteCount)),
          unorderedEquals([('A', null, 0), ('B', a, 1)]));
      expect((await repo.listNotes()).firstWhere((x) => x.id == n).folderId, b);

      await repo.moveNote(n, a);
      expect((await repo.listFolders()).firstWhere((f) => f.id == a).noteCount, 1);
      await repo.moveNote(n, null);
      expect((await repo.loadNote(n)), isNotNull);
      expect((await repo.listNotes()).firstWhere((x) => x.id == n).folderId, isNull);
    });

    test('theme image is stored and cleared', () async {
      final a = await repo.createFolder('A');
      await repo.setFolderThemeImage(a, '/x/y.png');
      expect((await repo.listFolders()).firstWhere((f) => f.id == a).themeImage, '/x/y.png');
      await repo.setFolderThemeImage(a, null);
      expect((await repo.listFolders()).firstWhere((f) => f.id == a).themeImage, isNull);
    });

    test('rename and sorting', () async {
      final z = await repo.createFolder('zeta');
      await repo.createFolder('Alpha');
      await repo.renameFolder(z, 'Beta');
      expect((await repo.listFolders()).map((f) => f.name), ['Alpha', 'Beta']);
    });

    test('moving a folder into itself or a descendant is refused', () async {
      final a = await repo.createFolder('A');
      final b = await repo.createFolder('B', parentId: a);
      final c = await repo.createFolder('C', parentId: b);
      expect(() => repo.moveFolder(a, a), throwsArgumentError);
      expect(() => repo.moveFolder(a, c), throwsArgumentError);
      await repo.moveFolder(c, null);
      expect((await repo.listFolders()).firstWhere((f) => f.id == c).parentId, isNull);
    });

    test('deleting a folder removes subfolders but keeps notes', () async {
      final a = await repo.createFolder('A');
      final b = await repo.createFolder('B', parentId: a);
      final n = await repo.createNote(folderId: b);
      await repo.deleteFolder(a);
      expect(await repo.listFolders(), isEmpty);
      expect((await repo.listNotes()).single.id, n);
      expect((await repo.listNotes()).single.folderId, isNull);
    });
  });
}
