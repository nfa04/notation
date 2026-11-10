import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'support/fake_file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/markdown/markdown_view.dart';
import 'package:notes/markdown/math_images.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/rich_text.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  Future<void> show(WidgetTester tester, String markdown) async {
    final controller = RichInlineTextController()..text = markdown;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MarkdownView(controller: controller, fontSize: 16))));
  }

  testWidgets('an inline formula is typeset inside the line', (tester) async {
    await show(tester, r'the area is $\pi r^2$ here');
    expect(find.byType(Math), findsOneWidget);
    expect(find.textContaining('the area is', findRichText: true), findsOneWidget);
  });

  testWidgets('a display formula is typeset on its own', (tester) async {
    await show(tester, r'$$\frac{a}{b}$$');
    expect(find.byType(Math), findsOneWidget);
  });

  testWidgets('a formula that cannot be read shows its source', (tester) async {
    await show(tester, r'broken $\notacommand{x$ here');
    expect(find.byType(Math), findsOneWidget);
    expect(find.textContaining(r'\notacommand', findRichText: true), findsWidgets);
  });

  testWidgets('money stays text', (tester) async {
    await show(tester, r'it costs $5 and then $6 more');
    expect(find.byType(Math), findsNothing);
  });

  test('the formulas of a text are found once each', () {
    expect(mathIn([r'$a$ and $a$ and $b$', r'$$c$$']), {('a', false), ('b', false), ('c', true)});
  });

  testWidgets('formulas are drawn as pictures for the PDF', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      context = c;
      return const SizedBox();
    })));

    MathImages? images;
    final done = renderMathImages(context, [(r'\frac{a}{b}', false), (r'x^2', true), (r'\notacommand{', false)], fontSize: 16)
        .then((v) => images = v);
    for (var i = 0; i < 20 && images == null; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    await done;

    final fraction = images!.of(r'\frac{a}{b}')!;
    expect(fraction.png.sublist(1, 4), [0x50, 0x4E, 0x47]); // "PNG"
    expect(fraction.width, greaterThan(5));
    expect(fraction.height, greaterThan(fraction.width)); // a fraction is taller than wide
    expect(images!.of('x^2', display: true), isNotNull);
    expect(images!.of('x^2'), isNull); // asked for as a display formula only
    expect(images!.of(r'\notacommand{'), isNull); // cannot be read: no picture
  });

  testWidgets('a formula in a text box is a picture in the exported PDF', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<String> export(String boxText) async {
      late NoteRepository repo;
      late String id;
      late Directory dir;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('math_pdf_');
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        repo = NoteRepository(db);
        id = await repo.createNote();
        final note = (await repo.loadNote(id))!;
        note.textBoxes[0] = [
          TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: boxText),
        ];
        await repo.saveNote(note);
      });
      final out = '${dir.path}/out.pdf';
      FilePickerPlatform.instance = FakeFilePicker(savePath: out);
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Export PDF')); // the toolbar scrolls sideways
      await tester.tap(find.text('Export PDF'));
      for (var i = 0; i < 150 && !File(out).existsSync(); i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      final pdf = String.fromCharCodes(await tester.runAsync(() => File(out).readAsBytes()) as List<int>);
      await tester.runAsync(() => dir.delete(recursive: true));
      return pdf;
    }

    final withFormula = await export(r'Area: $\frac{a}{b}$');
    expect(withFormula, startsWith('%PDF'));
    int images(String pdf) => '/Subtype/Image'.allMatches(pdf).length;
    final without = await export('Area: none');
    expect(images(withFormula), greaterThan(images(without))); // the formula is an extra picture
  });
}
