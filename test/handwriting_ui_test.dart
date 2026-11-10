import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/ink/glm_ocr_service.dart';
import 'package:notes/ink/handwriting_service.dart';
import 'package:notes/ink/math_decoder.dart';
import 'package:notes/ink/math_service.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

HandwritingService fakeService(Directory dir, {bool installed = true, List<List<int>>? tokens}) {
  if (installed) {
    Directory('${dir.path}/m').createSync(recursive: true);
    for (final f in ['vision.onnx', 'text.onnx', 'embeddings.bin']) {
      File('${dir.path}/m/$f').writeAsBytesSync([1]);
    }
  }
  return HandwritingService(
    glm: GlmOcrService(
      modelDirectory: () async => Directory('${dir.path}/m'),
      checksums: const {},
      // "hello world."
      loadVocab: () async => 'hello\nĠworld\n.\n',
      read: (_, _, _, pictures) async => [for (final _ in pictures) tokens?.first ?? [0, 1, 2]],
      download: (_, _, _) async {},
    ),
    removeOldFiles: () async {},
  );
}

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('settings show the model and let it be removed', (tester) async {
    late Directory dir;
    await tester.runAsync(() async => dir = await Directory.systemTemp.createTemp('hw_ui_'));
    addTearDown(() => dir.delete(recursive: true));
    final service = fakeService(dir);
    await tester.runAsync(service.load);

    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), handwriting: service)));
    await tester.tap(find.byKey(const ValueKey('settings-tab-AI and models')));
    await tester.pumpAndSettle();
    expect(find.text('Model installed'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.ensureVisible(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('Model not installed'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('settings let the person choose how carefully GLM-OCR looks, down to the light mode', (tester) async {
    late Directory dir;
    await tester.runAsync(() async => dir = await Directory.systemTemp.createTemp('hw_ui_q_'));
    addTearDown(() => dir.delete(recursive: true));
    final service = fakeService(dir);
    await tester.runAsync(service.load);
    expect(service.quality, GlmQuality.standard);

    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), handwriting: service)));
    await tester.tap(find.byKey(const ValueKey('settings-tab-AI and models')));
    await tester.pumpAndSettle();
    for (final q in GlmQuality.values) {
      expect(find.byKey(ValueKey('handwriting-quality-${q.name}')), findsOneWidget);
    }
    await tester.ensureVisible(find.byKey(const ValueKey('handwriting-quality-light')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('handwriting-quality-light')));
    await tester.pumpAndSettle();
    expect(service.quality, GlmQuality.light);
  });

  testWidgets('a selected drawing is converted to a text box', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late Directory dir;
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('hw_ui_');
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      await repo.settings.set('index_handwriting', '0'); // (reading for the search is not what these tests are about)
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [
        DrawingStroke(color: const Color(0xFF000000), width: 3, points: [
          for (var i = 0; i < 30; i++) Offset(200.0 + i * 4, 300 + (i.isEven ? 0 : 20)),
        ]),
      ];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    final service = fakeService(dir);
    await tester.runAsync(service.load);

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, handwriting: service)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    // tap on the writing to select it (select mode), then convert
    final page = tester.getTopLeft(find.byType(CustomScrollView));
    final pageLeft = (1600 - 800) / 2;
    await tester.tapAt(Offset(pageLeft + 230, page.dy + 16 + 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('convert-to-text')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('convert-to-text')));
    // reading happens in real time (rendering the picture, the fake model)
    for (var i = 0; i < 40 && find.byKey(const ValueKey('recognized-text')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('recognized-text')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('recognized-text'))).controller!.text, 'hello world.');

    await tester.tap(find.text('Add text box'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recognized-text')), findsNothing);
    expect(find.textContaining('hello world.'), findsWidgets); // the new text box
  });

  testWidgets('a selected formula becomes LaTeX in a text box', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late Directory dir;
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('math_ui_');
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      await repo.settings.set('index_handwriting', '0'); // (reading for the search is not what these tests are about)
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [
        DrawingStroke(color: const Color(0xFF000000), width: 3, points: [
          for (var i = 0; i < 30; i++) Offset(200.0 + i * 4, 300 + (i.isEven ? 0 : 20)),
        ]),
      ];
      await repo.saveNote(note);
      Directory('${dir.path}/m').createSync(recursive: true);
      File('${dir.path}/m/encoder_model.onnx').writeAsBytesSync([1]);
      File('${dir.path}/m/decoder_model.onnx').writeAsBytesSync([1]);
    });
    addTearDown(() => dir.delete(recursive: true));
    final math = MathService(
      defaultModel: FormulaModel.pix2text,
      modelDirectory: () async => Directory('${dir.path}/m'),
      loadVocab: () async => File('assets/math/vocab.txt').readAsStringSync(),
      open: (_, _) async => _FormulaModel(),
    );
    await tester.runAsync(math.load);

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, math: math)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final page = tester.getTopLeft(find.byType(CustomScrollView));
    await tester.tapAt(Offset((1600 - 800) / 2 + 230, page.dy + 16 + 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('convert-to-text')), findsNothing); // no text reader in this test
    expect(find.byKey(const ValueKey('convert-to-math')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('convert-to-math')));
    for (var i = 0; i < 40 && find.byKey(const ValueKey('recognized-text')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.widget<TextField>(find.byKey(const ValueKey('recognized-text'))).controller!.text, 'E=mc^{2}');
    await tester.tap(find.text('Add text box'));
    await tester.pumpAndSettle();
    expect(find.textContaining('E=mc'), findsWidgets); // in the dollar signs of a text box
  });

  testWidgets('a recognized equation can be solved for a letter', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late Directory dir;
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('math_ui_');
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      await repo.settings.set('index_handwriting', '0'); // (reading for the search is not what these tests are about)
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [
        DrawingStroke(color: const Color(0xFF000000), width: 3, points: [
          for (var i = 0; i < 30; i++) Offset(200.0 + i * 4, 300 + (i.isEven ? 0 : 20)),
        ]),
      ];
      await repo.saveNote(note);
      Directory('${dir.path}/m').createSync(recursive: true);
      File('${dir.path}/m/encoder_model.onnx').writeAsBytesSync([1]);
      File('${dir.path}/m/decoder_model.onnx').writeAsBytesSync([1]);
    });
    addTearDown(() => dir.delete(recursive: true));
    final math = MathService(
      defaultModel: FormulaModel.pix2text,
      modelDirectory: () async => Directory('${dir.path}/m'),
      loadVocab: () async => File('assets/math/vocab.txt').readAsStringSync(),
      open: (_, _) async => _FormulaModel(),
    );
    await tester.runAsync(math.load);

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, math: math)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final page = tester.getTopLeft(find.byType(CustomScrollView));
    await tester.tapAt(Offset((1600 - 800) / 2 + 230, page.dy + 16 + 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('convert-to-text')), findsNothing); // no text reader in this test
    expect(find.byKey(const ValueKey('convert-to-math')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('convert-to-math')));
    for (var i = 0; i < 40 && find.byKey(const ValueKey('recognized-text')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.widget<TextField>(find.byKey(const ValueKey('recognized-text'))).controller!.text, 'E=mc^{2}');
    await tester.tap(find.byKey(const ValueKey('solve-equation')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('solve-for-m')));
    await tester.pumpAndSettle();
    expect(find.text('Solution'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-solution')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recognized-text')), findsNothing);
    expect(find.textContaining(r'm = \frac{E}{c^{2}}'), findsWidgets);
  });

  testWidgets('a tap on nothing lets go of the selected drawing, beside the page or with a finger after the pen', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late Directory dir;
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('math_ui_');
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      await repo.settings.set('index_handwriting', '0'); // (reading for the search is not what these tests are about)
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [
        DrawingStroke(color: const Color(0xFF000000), width: 3, points: [
          for (var i = 0; i < 30; i++) Offset(200.0 + i * 4, 300 + (i.isEven ? 0 : 20)),
        ]),
      ];
      await repo.saveNote(note);
      Directory('${dir.path}/m').createSync(recursive: true);
      File('${dir.path}/m/encoder_model.onnx').writeAsBytesSync([1]);
      File('${dir.path}/m/decoder_model.onnx').writeAsBytesSync([1]);
    });
    addTearDown(() => dir.delete(recursive: true));
    final math = MathService(
      defaultModel: FormulaModel.pix2text,
      modelDirectory: () async => Directory('${dir.path}/m'),
      loadVocab: () async => File('assets/math/vocab.txt').readAsStringSync(),
      open: (_, _) async => _FormulaModel(),
    );
    await tester.runAsync(math.load);

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, math: math)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final page = tester.getTopLeft(find.byType(CustomScrollView));
    await tester.tapAt(Offset((1600 - 800) / 2 + 230, page.dy + 16 + 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('convert-to-text')), findsNothing); // no text reader in this test
    expect(find.byKey(const ValueKey('convert-to-math')), findsOneWidget);

    // beside the page
    await tester.tapAt(const Offset(100, 500));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('convert-to-math')), findsNothing);

    // select again (not as a second tap of a double tap, which would make a text box), then a finger taps an empty spot of the page
    // after the pen was used
    await tester.pump(const Duration(seconds: 1));
    await tester.tapAt(Offset((1600 - 800) / 2 + 230, page.dy + 16 + 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('convert-to-math')), findsOneWidget);
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.down(Offset((1600 - 800) / 2 + 600, page.dy + 16 + 700));
    await pen.up();
    await tester.pumpAndSettle();
    final finger = await tester.createGesture(kind: PointerDeviceKind.touch);
    await finger.down(Offset((1600 - 800) / 2 + 600, page.dy + 16 + 800));
    await finger.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('convert-to-math')), findsNothing);
  });
}

/// Says "E = m c ^ { 2 }".
class _FormulaModel implements MathOcrModel {
  int calls = 0;
  @override
  Future<Object> encode(Float32List pixels) async => 'x';
  @override
  Future<int> nextToken(Object encoded, List<int> ids) async => const [41, 270, 305, 318, 265, 262, 269, 261, mathEosToken][calls++];
  @override
  Future<void> release(Object encoded) async {}
  @override
  Future<void> close() async {}
}
