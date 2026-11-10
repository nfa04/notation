// The whole "convert a drawing to a formula" flow in the real editor, with the
// real model. The model files must be in the app's files folder:
//   flutter test integration_test/math_flow_test.dart -d <device> --no-uninstall
//     --dart-define=MODEL_DIR=/data/user/0/com.example.notes/files

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/ink/ink_recognizer.dart';
import 'package:notes/ink/math_service.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:io';

const dir = String.fromEnvironment('MODEL_DIR');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a drawing becomes a formula in the editor', (tester) async {
    AppDatabase.initFfi();
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    final repo = NoteRepository(db);
    final id = await repo.createNote();
    final note = (await repo.loadNote(id))!;
    // a few strokes that look a bit like "x^2"
    DrawingStroke line(List<Offset> pts) => DrawingStroke(color: const Color(0xFF000000), width: 3, points: pts);
    note.strokes[0] = [
      line([for (var i = 0; i <= 20; i++) Offset(300.0 + i * 3, 300.0 + i * 3)]),
      line([for (var i = 0; i <= 20; i++) Offset(360.0 - i * 3, 300.0 + i * 3)]),
      line([for (var i = 0; i <= 12; i++) Offset(380.0 + i * 3, 290.0 + (i % 3) * 4)]),
      line([for (var i = 0; i <= 12; i++) Offset(380.0 + i * 3, 290.0 + (i < 6 ? 0 : 8) + (i % 3) * 4)]),
    ];
    await repo.saveNote(note);

    final math = MathService(defaultModel: FormulaModel.pix2text, modelDirectory: () async => Directory(dir));
    await math.load();
    expect(math.status, HandwritingStatus.installed, reason: 'the model files are not in $dir');

    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, math: math)));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));

    // pick the drawing with a tap, then convert
    final page = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    final scale = tester.getSize(find.byKey(const ValueKey('page-0'))).width / 800;
    await tester.tapAt(Offset(page.dx + 330 * scale, page.dy + 330 * scale));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('convert-to-math')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('convert-to-math')));
    final watch = Stopwatch()..start();
    while (find.byKey(const ValueKey('recognized-text')).evaluate().isEmpty && watch.elapsed < const Duration(seconds: 90)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    debugPrint('FLOW: dialog after ${watch.elapsedMilliseconds} ms');
    expect(find.byKey(const ValueKey('recognized-text')), findsOneWidget);
    final latex = tester.widget<TextField>(find.byKey(const ValueKey('recognized-text'))).controller!.text;
    debugPrint('FLOW: recognised "$latex"');

    await tester.tap(find.text('Add text box'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recognized-text')), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
