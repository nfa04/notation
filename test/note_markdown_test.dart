import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart' show MaterialApp, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/export/note_markdown.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/search/search_query.dart';

TextBoxWidgetModel box(String id, double x, double y, String text) => TextBoxWidgetModel(id: id, position: Offset(x, y), initialText: text);

void main() {
  test('the title, the written document and the pages come in order, a page heading only when there is more than one', () async {
    final note = NoteData(id: 'n', title: 'Trip')
      ..documentText = '{align=center}Plans for the summer.'
      ..textBoxes[0] = [box('a', 40, 300, 'Second box'), box('b', 40, 40, '## Packing\n- tent')]
      ..textBoxes[1] = [box('c', 40, 40, 'On page two')];
    final made = await noteToMarkdown(note);
    expect(made.markdown, '# Trip\n\nPlans for the summer.\n\n## Page 1\n\n## Packing\n- tent\n\nSecond box\n\n## Page 2\n\nOn page two\n');
    expect(made.files, isEmpty);
    expect(made.pack('Trip').extension, 'md');

    final single = await noteToMarkdown(NoteData(id: 'x')..textBoxes[0] = [box('a', 0, 0, 'Only')]);
    expect(single.markdown, 'Only\n'); // no title, one page: no headings
  });

  test('things side by side are read left to right, the rest top to bottom; empty boxes are left out', () async {
    final note = NoteData(id: 'n')
      ..textBoxes[0] = [box('right', 400, 52, 'right'), box('low', 40, 200, 'low'), box('left', 40, 40, 'left'), box('empty', 40, 120, '   ')];
    expect((await noteToMarkdown(note)).markdown, 'left\n\nright\n\nlow\n');
  });

  test('handwriting readings and formulas are in their place, and can be left out', () async {
    final note = NoteData(id: 'n')..textBoxes[0] = [box('a', 40, 40, 'Typed')];
    final ink = [
      InkText(key: 'k', page: 0, text: 'written by hand', bounds: const Rect.fromLTWH(40, 100, 200, 30)),
      InkText(key: 'k2', page: 0, text: '   ', bounds: const Rect.fromLTWH(40, 150, 200, 30)),
    ];
    const formulas = [(page: 0, top: 200.0, left: 40.0, latex: r'\frac{a}{b}')];
    final made = await noteToMarkdown(note, handwriting: ink, formulas: formulas);
    expect(made.markdown, 'Typed\n\nwritten by hand\n\n\$\$\\frac{a}{b}\$\$\n');
    expect(made.handwriting, 1);
    final without = await noteToMarkdown(note, handwriting: ink, formulas: formulas, handwritingAsText: false);
    expect(without.markdown, isNot(contains('by hand')));
    expect(without.handwriting, 0);
  });

  test('pictures become files next to the text, in a ZIP; one that cannot be read is left out', () async {
    final note = NoteData(id: 'n')
      ..textBoxes[0] = [box('a', 40, 40, 'Look:')]
      ..images[0] = [
        ImageItem(id: 'i1', path: '/x/Cat photo.JPG', position: const Offset(40, 100), size: const Size(100, 100)),
        ImageItem(id: 'i2', path: '/x/gone.png', position: const Offset(40, 300), size: const Size(100, 100)),
      ];
    final made = await noteToMarkdown(note, readPicture: (path) async => path.contains('gone') ? null : Uint8List.fromList([1, 2, 3]));
    expect(made.markdown, 'Look:\n\n![Cat photo](images/picture-1.jpg)\n');
    expect(made.files.keys, ['images/picture-1.jpg']);
    final packed = made.pack('My note');
    expect(packed.extension, 'zip');
    final zip = ZipDecoder().decodeBytes(packed.bytes);
    expect(zip.files.map((f) => f.name), ['My note.md', 'images/picture-1.jpg']);
    expect(zip.files.last.content, [1, 2, 3]);
  });

  test('a note with nothing in it gives an empty file, not an error', () async {
    expect((await noteToMarkdown(NoteData(id: 'n'))).markdown.trim(), isEmpty);
  });

  group('from the editor', () {
    setUpAll(AppDatabase.initFfi);
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('md'));
    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('the button is there and the note is written as a Markdown file', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote(title: 'Export me');
        final note = (await repo.loadNote(id))!;
        note.textBoxes[0] = [box('a', 40, 40, '## Heading\nSome *text*')];
        await repo.saveNote(note);
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('export-markdown-button')), findsOneWidget);

      String? problem = 'not run';
      var done = false;
      final state = tester.state(find.byType(FixedPageNoteEditor)) as dynamic;
      (state.exportMarkdownTo('${dir.path}/a.md') as Future<String?>).then((r) {
        problem = r;
        done = true;
      });
      for (var i = 0; i < 400 && !done; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(done, isTrue);
      expect(problem, isNull);
      expect(File('${dir.path}/a.md').readAsStringSync(), '# Export me\n\n## Heading\nSome *text*\n');
    });
  });
}
