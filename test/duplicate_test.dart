import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/authorship.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = Colors.red);
  final image = await recorder.endRecording().toImage(8, 8);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  setUpAll(AppDatabase.initFfi);
  tearDown(() {
    Authorship.set(null);
    Authorship.setId(null);
  });

  late NoteRepository repo;
  late String id;
  late Directory dir;
  late String picture;

  Future<void> open(WidgetTester tester, {void Function(NoteData note)? fill}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('duplicate_');
      picture = '${dir.path}/pic.png';
      await File(picture).writeAsBytes(await _png());
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      fill?.call(note);
      await repo.saveNote(note);
    });
    addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  /// The note as it is saved (the editor saves a moment after a change).
  Future<NoteData> saved(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1300)));
    await tester.pump(const Duration(milliseconds: 1000));
    late NoteData n;
    await tester.runAsync(() async => n = (await repo.loadNote(id))!);
    return n;
  }

  testWidgets('a drawing the lasso selected is duplicated: shifted, selected, with the name of who made it, and one step to take back', (tester) async {
    Authorship.set('Noel');
    await open(tester, fill: (n) {
      n.strokes[0] = [
        DrawingStroke(id: 'orig', color: const Color(0xFFD32F2F), width: 6, author: 'Anna', points: [for (var i = 0; i < 20; i++) Offset(300.0 + i * 4, 300.0 + (i.isEven ? 0 : 10))]),
      ];
    });
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();
    final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
    final left = (1600 - 57 - 800) / 2;
    Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
    final g = await tester.startGesture(at(280, 280), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    for (final p in [at(280, 280), at(400, 280), at(400, 340), at(280, 340), at(280, 285)]) {
      await g.moveTo(p);
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('duplicate-selection')), findsOneWidget, reason: 'next to the trash button');
    expect(find.byTooltip('Duplicate drawing'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('duplicate-selection')));
    await tester.pump();
    var note = await saved(tester);
    expect(note.strokes[0], hasLength(2));
    final copy = note.strokes[0]!.firstWhere((s) => s.id != 'orig');
    final orig = note.strokes[0]!.firstWhere((s) => s.id == 'orig');
    expect(copy.color, orig.color);
    expect(copy.width, orig.width);
    expect(copy.points.length, orig.points.length);
    expect(copy.points.first - orig.points.first, const Offset(24, 24));
    expect(copy.points.last - orig.points.last, const Offset(24, 24));
    expect(copy.author, 'Noel', reason: 'made by the person who copied it, not by the one who drew the original');
    expect(orig.author, 'Anna');
    expect(orig.points.first, const Offset(300, 300), reason: 'the original did not move');

    // the copy is the selection now: duplicating again copies the copy, and it lands further on
    await tester.tap(find.byKey(const ValueKey('duplicate-selection')));
    await tester.pump();
    note = await saved(tester);
    expect(note.strokes[0], hasLength(3));
    expect(note.strokes[0]!.last.points.first - orig.points.first, const Offset(48, 48));

    // one step to take back each
    await tester.tap(find.byKey(const ValueKey('undo-button')));
    await tester.pump();
    note = await saved(tester);
    expect(note.strokes[0], hasLength(2));
    await tester.tap(find.byKey(const ValueKey('undo-button')));
    await tester.pump();
    note = await saved(tester);
    expect(note.strokes[0]!.map((s) => s.id), ['orig']);
    await tester.tap(find.byKey(const ValueKey('redo-button')));
    await tester.pump();
    note = await saved(tester);
    expect(note.strokes[0], hasLength(2));
  });

  testWidgets('near the right and the bottom edge the copy goes up and left instead of off the page', (tester) async {
    await open(tester, fill: (n) {
      n.strokes[0] = [
        DrawingStroke(id: 'edge', color: Colors.black, width: 3, points: [for (var i = 0; i < 20; i++) Offset(740.0 + i * 2, 300.0 + (i.isEven ? 0 : 10))]),
      ];
    });
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();
    final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
    final left = (1600 - 57 - 800) / 2;
    Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
    final g = await tester.startGesture(at(720, 280), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    for (final p in [at(720, 280), at(795, 280), at(795, 340), at(720, 340), at(720, 285)]) {
      await g.moveTo(p);
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('duplicate-selection')));
    await tester.pump();
    final note = await saved(tester);
    final copy = note.strokes[0]!.firstWhere((s) => s.id != 'edge');
    expect(copy.points.first.dx, lessThan(740), reason: 'moved left, not off the page');
    expect(copy.points.last.dx, lessThanOrEqualTo(800));
    expect(copy.points.first.dy, greaterThan(300), reason: 'there is room below');
  });

  testWidgets('a picture is duplicated with a file of its own, next to the trash button, and the copy is selected', (tester) async {
    Authorship.set('Noel');
    await open(tester, fill: (n) {
      n.images[0] = [ImageItem(id: 'p', path: picture, position: const Offset(60, 100), size: const Size(200, 100), author: 'Anna')];
    });
    await tester.tap(find.byKey(const ValueKey('image-ctl-p')));
    await tester.pump();
    expect(find.byKey(const ValueKey('image-delete')), findsOneWidget);
    expect(find.byKey(const ValueKey('image-duplicate')), findsOneWidget);
    expect(find.byTooltip('Duplicate picture'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('image-duplicate')));
    await tester.pump();
    final note = await saved(tester);
    expect(note.images[0], hasLength(2));
    final copy = note.images[0]!.firstWhere((m) => m.id != 'p');
    final orig = note.images[0]!.firstWhere((m) => m.id == 'p');
    expect(copy.position - orig.position, const Offset(24, 24));
    expect(copy.size, orig.size);
    expect(copy.path, isNot(orig.path));
    expect(copy.author, 'Noel');
    expect(orig.author, 'Anna');
    late bool both;
    late List<int> a, b;
    await tester.runAsync(() async {
      both = File(copy.path).existsSync() && File(orig.path).existsSync();
      a = await File(copy.path).readAsBytes();
      b = await File(orig.path).readAsBytes();
    });
    expect(both, isTrue, reason: 'the copy has a file of its own');
    expect(a, b);

    // the copy is the selected picture: its own buttons are on screen
    expect(find.byKey(const ValueKey('image-duplicate')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('image-delete')));
    await tester.pump();
    final after = await saved(tester);
    expect(after.images[0]!.map((m) => m.id), ['p'], reason: 'the copy was the one deleted');
    expect(File(orig.path).existsSync(), isTrue);
  });

  testWidgets('a text box is duplicated with its text, look and size, under a new id', (tester) async {
    Authorship.set('Noel');
    await open(tester, fill: (n) {
      n.textBoxes[0] = [
        TextBoxWidgetModel(
          id: 'tb',
          position: const Offset(100, 200),
          size: const Size(300, 0),
          initialText: 'Entropy never **decreases**',
          fontSize: 20,
          style: const TextBoxStyle(background: Color(0xFFFFF8E1), borderWidth: 0),
          author: 'Anna',
        ),
      ];
    });
    // a tap on the text selects the box
    final box = find.textContaining('Entropy');
    await tester.tap(box.first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('duplicate-text-box')), findsOneWidget);
    expect(find.byKey(const ValueKey('delete-text-box')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('duplicate-text-box')));
    await tester.pump();
    final note = await saved(tester);
    expect(note.textBoxes[0], hasLength(2));
    final copy = note.textBoxes[0]!.firstWhere((b) => b.id != 'tb');
    final orig = note.textBoxes[0]!.firstWhere((b) => b.id == 'tb');
    expect(copy.controller.text, 'Entropy never **decreases**');
    expect(copy.fontSize, 20);
    expect(copy.size.width, 300);
    expect(copy.style, orig.style);
    expect(copy.position - orig.position, const Offset(24, 24));
    expect(copy.author, 'Noel');
    expect(orig.author, 'Anna');
    expect(orig.position, const Offset(100, 200));
  });
}
