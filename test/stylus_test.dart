import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/style/stylus_settings.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  test('pressure makes a line thicker or thinner than its width, as much as the sensitivity says', () {
    expect(pressureFactor(0.5, 0), 1);
    expect(pressureFactor(1, 0), 1);
    expect(pressureFactor(0.5, 1), closeTo(1.0, 1e-9));
    expect(pressureFactor(0, 1), lessThan(0.4));
    expect(pressureFactor(1, 1), greaterThan(1.6));
    expect(pressureFactor(0, 0.5), closeTo(0.675, 1e-9));
  });

  test('the settings are kept', () async {
    final repo = SettingsRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    final a = StylusSettings(repo);
    await a.setPressure(false);
    await a.setBarrel(BarrelAction.lasso);
    await a.setFingers(FingerMode.scroll);
    await a.setSensitivity(0.9);
    await a.setHoverRing(false);
    final b = StylusSettings(repo);
    await b.load();
    expect(b.pressure, isFalse);
    expect(b.effectiveSensitivity, 0);
    expect(b.barrel, BarrelAction.lasso);
    expect(b.fingers, FingerMode.scroll);
    expect(b.sensitivity, 0.9);
    expect(b.hoverRing, isFalse);
  });

  test('pressure travels: in the database, in note files and to the others', () async {
    DrawingStroke pressed() => DrawingStroke(id: 'p1', color: Colors.black, width: 4, points: [for (var i = 0; i < 5; i++) Offset(i * 10.0, i * 3.0)], pressures: [10, 80, 200, 255, 30]);

    final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
    final id = await repo.createNote();
    final n = (await repo.loadNote(id))!;
    n.strokes = {0: [pressed()]};
    await repo.saveNote(n);
    expect((await repo.loadNote(id))!.strokes[0]!.single.pressures, [10, 80, 200, 255, 30]);

    final back = decodeStrokes(encodeStrokes({0: [pressed(), DrawingStroke(id: 'q', color: Colors.red, width: 2, points: [Offset.zero, const Offset(5, 5)])]}));
    expect(back[0]![0].pressures, [10, 80, 200, 255, 30]);
    expect(back[0]![1].pressures, isNull);

    final note = NoteData(id: 'n', strokes: {0: [pressed()]});
    final sender = Replica('a'), receiver = Replica('b');
    final theirs = NoteData(id: 'n');
    for (final op in sender.localChanges(note)) {
      receiver.apply(theirs, op, makeBox: (_) => throw UnimplementedError(), saveImage: (_, _, _) => '', onNoteField: (_, _) {});
    }
    expect(theirs.strokes[0]!.single.pressures, [10, 80, 200, 255, 30]);
  });

  Future<(NoteRepository, String)> note(WidgetTester tester) async {
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
    });
    return (repo, id);
  }

  Future<void> openInDraw(WidgetTester tester, NoteRepository repo, String id, StylusSettings stylus) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, stylus: stylus)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
  }

  int pointer = 100;
  Future<void> stroke(WidgetTester tester, Offset from, List<double> pressures, {PointerDeviceKind kind = PointerDeviceKind.stylus, int buttons = 0}) async {
    final p = pointer++;
    PointerEvent ev(Offset at, double pressure, {bool down = false, bool up = false}) {
      final common = (at, p, kind, buttons, pressure);
      if (down) return PointerDownEvent(pointer: p, position: at, kind: kind, buttons: buttons == 0 ? kPrimaryButton : buttons, pressure: pressure, pressureMin: 0, pressureMax: 1);
      if (up) return PointerUpEvent(pointer: p, position: at, kind: kind, pressure: pressure, pressureMin: 0, pressureMax: 1);
      return PointerMoveEvent(pointer: p, position: at, kind: kind, buttons: common.$4 == 0 ? kPrimaryButton : common.$4, pressure: pressure, pressureMin: 0, pressureMax: 1);
    }

    await tester.sendEventToBinding(ev(from, pressures.first, down: true));
    await tester.pump();
    for (var i = 1; i < pressures.length; i++) {
      await tester.sendEventToBinding(ev(from + Offset(i * 12.0, (i % 3) * 7.0), pressures[i]));
      await tester.pump();
    }
    await tester.sendEventToBinding(ev(from + Offset(pressures.length * 12.0, 0), pressures.last, up: true));
    await tester.pump();
  }

  testWidgets('a pen that presses differently draws a line with pressure, one that does not draws a plain line', (tester) async {
    final (repo, id) = await note(tester);
    await openInDraw(tester, repo, id, StylusSettings.inMemory());
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + const Offset(150, 200);

    await stroke(tester, origin, [0.1, 0.3, 0.6, 0.9, 0.9, 0.5, 0.2]);
    await stroke(tester, origin + const Offset(0, 80), [0.8, 0.8, 0.8, 0.8, 0.8, 0.8]); // always the same
    await stroke(tester, origin + const Offset(0, 160), [0.1, 0.9, 0.5, 0.2, 0.9], kind: PointerDeviceKind.touch); // a finger has no pressure
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!.strokes[0]!;
    expect(saved.length, greaterThanOrEqualTo(2));
    final first = saved.first;
    expect(first.pressures, isNotNull);
    expect(first.pressures!.length, first.points.length);
    expect(first.pressures!.first, lessThan(first.pressures![3]));
    expect(saved[1].pressures, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });

  testWidgets('a tap with the pen, quick or slow, leaves a dot (the dot of an i)', (tester) async {
    final (repo, id) = await note(tester);
    await openInDraw(tester, repo, id, StylusSettings.inMemory());
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + const Offset(150, 200);
    for (final (i, wait) in [(0, 0), (1, 600)]) {
      final at = origin + Offset(i * 60.0, 0);
      await tester.sendEventToBinding(PointerDownEvent(pointer: 900 + i, position: at, kind: PointerDeviceKind.stylus, buttons: kPrimaryButton, pressure: 0.5, pressureMin: 0, pressureMax: 1));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: wait)));
      await tester.sendEventToBinding(PointerUpEvent(pointer: 900 + i, position: at + const Offset(1, 1), kind: PointerDeviceKind.stylus, pressure: 0.5, pressureMin: 0, pressureMax: 1));
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 3));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!.strokes[0]!;
    expect(saved, hasLength(2));
    expect(saved.every((s) => s.points.length >= 2), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });

  testWidgets('with pressure switched off the line has none', (tester) async {
    final (repo, id) = await note(tester);
    await openInDraw(tester, repo, id, StylusSettings.inMemory(pressure: false));
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + const Offset(150, 200);
    await stroke(tester, origin, [0.1, 0.3, 0.6, 0.9, 0.9, 0.5, 0.2]);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!.strokes[0]!;
    expect(saved.single.pressures, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });

  testWidgets('a finger that is set only to scroll does not write, even before any pen was used', (tester) async {
    final (repo, id) = await note(tester);
    await openInDraw(tester, repo, id, StylusSettings.inMemory(fingers: FingerMode.scroll));
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + const Offset(150, 200);
    await stroke(tester, origin, [0.5, 0.5, 0.5, 0.5, 0.5, 0.5], kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
    expect((await tester.runAsync(() => repo.loadNote(id)))!.strokes[0] ?? const [], isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
  });
}
