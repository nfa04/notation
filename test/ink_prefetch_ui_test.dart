import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'ink_prefetch_test.dart' show FakeReader, word;

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late String id;

  Future<void> open(WidgetTester tester, {required FakeReader? text, FakeReader? math}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      await repo.settings.set('index_handwriting', '0'); // (reading for the search is not what these tests are about)
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = word('w', 300, 300);
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(
      home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, handwriting: text, math: math, inkIdle: const Duration(milliseconds: 40)),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  Future<void> selectWriting(WidgetTester tester) async {
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();
    final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
    // (the drawing tools take a column of 56 pixels, or more of them when they do not fit the height)
    final barLeft = tester.getCenter(find.byKey(const ValueKey('undo-button'))).dx - 28;
    final left = (barLeft - 1 - 800) / 2;
    Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
    final g = await tester.startGesture(at(280, 280), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    for (final p in [at(280, 280), at(400, 280), at(400, 345), at(280, 345), at(280, 285)]) {
      await g.moveTo(p);
      await tester.pump();
    }
    await g.up();
    await tester.pump();
  }

  testWidgets('with the automation on, the writing is read in the background and converting it needs no waiting', (tester) async {
    final text = FakeReader((s) => 'ready text');
    await open(tester, text: text);
    final editor = tester.state(find.byType(FixedPageNoteEditor)) as InkPreparer;
    expect(text.calls, isEmpty, reason: 'nothing is read unless the automation asked for it');

    late String said;
    await tester.runAsync(() async => said = await editor.prepareInk(text: true, math: false));
    expect(said, contains('ahead of time'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    expect(text.calls, hasLength(1), reason: 'read while the person did nothing');
    expect(text.calls.single, ['w0', 'w1', 'w2', 'w3']);

    await selectWriting(tester);
    expect(find.byKey(const ValueKey('ink-ready-text-true')), findsOneWidget, reason: 'a green dot: it is ready');
    await tester.tap(find.byKey(const ValueKey('convert-to-text')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Recognized text'), findsOneWidget);
    expect(find.text('Reading the handwriting...'), findsNothing, reason: 'no waiting');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('recognized-text'))).controller!.text, 'ready text');
    expect(text.calls, hasLength(1), reason: 'the reader was not asked again');
  });

  testWidgets('without the automation, converting reads the writing then, as it always did', (tester) async {
    final text = FakeReader((s) => 'read just now');
    await open(tester, text: text);
    await selectWriting(tester);
    expect(find.byKey(const ValueKey('ink-ready-text-false')), findsOneWidget, reason: 'no dot');
    await tester.tap(find.byKey(const ValueKey('convert-to-text')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(text.calls, hasLength(1));
    expect(tester.widget<TextField>(find.byKey(const ValueKey('recognized-text'))).controller!.text, 'read just now');
  });

  testWidgets('the formula too, when it looks like one; and writing added later is read again', (tester) async {
    final text = FakeReader((s) => 'x^2 = 4');
    final math = FakeReader((s) => 'x^{2}=4');
    await open(tester, text: text, math: math);
    final editor = tester.state(find.byType(FixedPageNoteEditor)) as InkPreparer;
    await tester.runAsync(() => editor.prepareInk(text: true, math: true));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    expect(math.calls, hasLength(1), reason: 'the text had a sign of maths in it');

    await selectWriting(tester);
    expect(find.byKey(const ValueKey('ink-ready-math-true')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('convert-to-math')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Recognized formula (LaTeX)'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('recognized-text'))).controller!.text, 'x^{2}=4');
    expect(math.calls, hasLength(1));
  });

  testWidgets('the editor says why it cannot read ahead when there are no readers or no models', (tester) async {
    await open(tester, text: null);
    final editor = tester.state(find.byType(FixedPageNoteEditor)) as InkPreparer;
    late String a, b;
    await tester.runAsync(() async => a = await editor.prepareInk(text: true, math: true));
    expect(a, contains('switched off'));
    final off = FakeReader((s) => '', installed: false);
    await open(tester, text: off);
    final editor2 = tester.state(find.byType(FixedPageNoteEditor)) as InkPreparer;
    await tester.runAsync(() async => b = await editor2.prepareInk(text: true, math: false));
    expect(b, contains('not installed'));
    expect(off.calls, isEmpty);
  });
}
