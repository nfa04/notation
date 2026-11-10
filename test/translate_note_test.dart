import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/pdf/pdf_content_editor.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// "Translates" by a small dictionary, and leaves the marks as they are.
class _Translator extends ChangeNotifier implements TextModelProvider {
  final prompts = <AiPrompt>[];

  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  String get description => '';
  @override
  ProviderState get state => ProviderState.ready;
  @override
  String? get reason => null;
  @override
  Future<void> prepare() async {}
  @override
  Future<String> complete(AiPrompt prompt, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async {
    prompts.add(prompt);
    return prompt.user.replaceAll('Hello', 'Hallo').replaceAll('good morning', 'guten Morgen').replaceAll('The area', 'Die Fläche').replaceAll('Goodbye', 'Auf Wiedersehen');
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);
  pdfTests();

  testWidgets('a note is translated in place, formulas and links kept, and the change is taken back with Undo', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    final provider = _Translator();
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [
        TextBoxWidgetModel(id: 'a', position: const Offset(60, 60), initialText: 'Hello'),
        TextBoxWidgetModel(id: 'b', position: const Offset(60, 200), initialText: r'The area is $\pi r^2$ (see [Circles](note:xyz))'),
        TextBoxWidgetModel(id: 'c', position: const Offset(60, 400), initialText: '42'),
      ];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, ai: AiService(providers: [provider]))));
    Future<void> settle([int ms = 300]) async {
      await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
      await tester.pumpAndSettle();
    }

    await settle();
    await tester.tap(find.byKey(const ValueKey('translate-note')));
    await tester.pumpAndSettle();
    expect(find.textContaining('The 2 texts'), findsOneWidget); // "42" has no words
    await tester.tap(find.byKey(const ValueKey('translate-start')));
    await tester.pump();
    await settle();

    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Translated into German'), findsOneWidget);
    expect(provider.prompts.length, 2);
    expect(provider.prompts.every((p) => p.system.contains('German')), isTrue);
    // the formula and the link address were hidden from the model
    expect(provider.prompts.last.user, contains('§1§'));
    expect(provider.prompts.last.user, isNot(contains(r'\pi')));

    final after = (await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      return (await repo.loadNote(id))!;
    }))!;
    await tester.pump(const Duration(seconds: 2));
    final byId = {for (final b in after.textBoxes[0]!) b.id: b.controller.text};
    expect(byId['a'], 'Hallo');
    expect(byId['b'], r'Die Fläche is $\pi r^2$ (see [Circles](note:xyz))');
    expect(byId['c'], '42');

    // taking it back
    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    final undone = (await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      return (await repo.loadNote(id))!;
    }))!;
    await tester.pump(const Duration(seconds: 2));
    expect({for (final b in undone.textBoxes[0]!) b.id: b.controller.text}['a'], 'Hello');
  });

  testWidgets('without a ready model the dialog says so and cannot start', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'a', position: const Offset(60, 60), initialText: 'Hello')];
      await repo.saveNote(note);
    });
    final provider = _NotReady();
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, ai: AiService(providers: [provider]))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('translate-note')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('translate-not-ready')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('translate-start'))).onPressed, isNull);
  });
}

class _NotReady extends _Translator {
  @override
  ProviderState get state => ProviderState.needsDownload;
}

void pdfTests() {
  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  testWidgets('the text of an imported PDF is rewritten in its translation, and Undo brings the old PDF back', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id;
    late Directory dir;
    final provider = _Translator();
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('tp_');
      final doc = pw.Document();
      doc.addPage(pw.Page(
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('Hello world', style: const pw.TextStyle(fontSize: 30)),
          pw.SizedBox(height: 30),
          pw.Text('good morning', style: const pw.TextStyle(fontSize: 20)),
        ]),
      ));
      final file = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.pdfName = 'a.pdf';
      note.pdfPath = file.path;
      note.pdfPageCount = 1;
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, ai: AiService(providers: [provider]))));
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<List<String>> pdfLines() async => (await tester.runAsync(() async {
          final note = (await repo.loadNote(id))!;
          final e = await PdfContentEditor.open(await File(note.pdfPath!).readAsBytes(), modulePath: pdfium.absolute.path);
          try {
            return [for (final o in await e.objects(0)) if (o.kind == PdfObjectKind.text) o.text!];
          } finally {
            await e.close();
          }
        }))!;

    await settle(() => find.byKey(const ValueKey('translate-note')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('translate-note')));
    await settle(() => find.byKey(const ValueKey('translate-pdf-note')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('translate-pdf-note')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('translate-start')));
    await settle(() => find.textContaining('Translated into German').evaluate().isNotEmpty);
    expect(find.textContaining('Translated into German'), findsOneWidget);
    expect(provider.prompts.single.user, '1| Hello world\n2| good morning');

    // the PDF of the note is now the translated one
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
    await tester.pump(const Duration(seconds: 2));
    expect(await pdfLines(), ['Hallo world', 'guten Morgen']);

    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await settle(() => false);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
    await tester.pump(const Duration(seconds: 2));
    expect(await pdfLines(), ['Hello world', 'good morning']);
  });
}
