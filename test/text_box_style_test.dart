import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'support/fake_file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the style', () {
    test('a plain box has the default look and is saved as such', () {
      expect(TextBoxStyle.defaults.isDefault, isTrue);
      expect(TextBoxStyle.defaults.copyWith(opacity: 0.5).isDefault, isFalse);
      expect(TextBoxStyle.defaults.fill.a, closeTo(0.95, 0.01));
    });

    test('it survives being written down; broken parts fall back', () {
      const style = TextBoxStyle(
        background: Color(0xFF123456),
        opacity: 0.4,
        borderColor: Color(0xFFABCDEF),
        borderWidth: 3,
        radius: 20,
        textColor: Color(0xFFFFFFFF),
      );
      expect(TextBoxStyle.fromJson(style.toJson()), style);
      expect(TextBoxStyle.fromJson(null), TextBoxStyle.defaults);
      expect(TextBoxStyle.fromJson({'op': 'lots', 'bw': 99}).borderWidth, 12); // clamped
      expect(TextBoxStyle.fromJson({'op': 7}).opacity, 1);
    });
  });

  test('it is saved with the note and comes back', () async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    final repo = NoteRepository(db);
    final id = await repo.createNote();
    final note = (await repo.loadNote(id))!;
    final styled = TextBoxWidgetModel(
      id: 'a',
      position: const Offset(10, 10),
      style: const TextBoxStyle(background: Color(0xFF00FF00), opacity: 0.3, borderWidth: 0, radius: 0),
    );
    final plain = TextBoxWidgetModel(id: 'b', position: const Offset(10, 200));
    note.textBoxes[0] = [styled, plain];
    await repo.saveNote(note);
    final back = (await repo.loadNote(id))!.textBoxes[0]!;
    expect(back[0].style, styled.style);
    expect(back[1].style.isDefault, isTrue);
  });

  testWidgets('the style dialog changes the box as you go, and it is saved and exported', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('style_');
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: 'hello')];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    BoxDecoration boxLook() {
      final c = find.ancestor(of: find.text('hello'), matching: find.byType(Container)).evaluate().map((e) => e.widget as Container);
      return c.map((w) => w.decoration).whereType<BoxDecoration>().firstWhere((d) => d.borderRadius != null);
    }

    expect(find.byKey(const ValueKey('box-style')), findsNothing); // no box selected yet
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(origin + const Offset(150, 130));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('box-style'))); // the toolbar scrolls sideways
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('box-style')));
    await tester.pumpAndSettle();
    expect(find.text('Text box style'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('fill-${const Color(0xFFFFF59D).toARGB32()}'))); // yellow
    await tester.pump();
    await tester.drag(find.byKey(const ValueKey('style-opacity')), const Offset(-120, 0));
    await tester.pump();
    await tester.drag(find.byKey(const ValueKey('style-radius')), const Offset(200, 0));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('text-${Colors.white.toARGB32()}')));
    await tester.pump();

    // the box behind has changed already
    final look = boxLook();
    expect(look.color!.toARGB32() & 0xFFFFFF, 0xFFF59D);
    expect(look.color!.a, lessThan(0.9));
    expect((look.borderRadius as BorderRadius).topLeft.x, greaterThan(8));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // saved with the note
    await tester.pump(const Duration(seconds: 1)); // the autosave timer
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!.textBoxes[0]!.single;
    expect(saved.style.background.toARGB32(), 0xFFFFF59D);
    expect(saved.style.textColor, Colors.white);
    expect(saved.style.opacity, lessThan(0.9));

    // and the PDF export does not choke on it
    FilePickerPlatform.instance = FakeFilePicker(savePath: '${dir.path}/out.pdf');
    await tester.ensureVisible(find.text('Export PDF')); // the toolbar scrolls sideways
    await tester.tap(find.text('Export PDF'));
    for (var i = 0; i < 120 && !File('${dir.path}/out.pdf').existsSync(); i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    expect(String.fromCharCodes(File('${dir.path}/out.pdf').readAsBytesSync().sublist(0, 4)), '%PDF');
  });
}
