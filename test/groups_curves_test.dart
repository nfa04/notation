import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/images/picture_edit.dart';
import 'package:notes/models/bezier.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

CurvedPath curve() => CurvedPath([
      PathNode(const Offset(100, 100))..pullOut(const Offset(160, 40)),
      PathNode(const Offset(300, 120))..pullIn(const Offset(240, 200)),
      PathNode(const Offset(420, 90)),
    ]);

DrawingStroke curved({String group = noGroup}) => DrawingStroke(color: Colors.red, width: 3, points: curve().points(), curve: curve(), group: group);

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('the points of a curve', () {
    test('are written and read again, and what cannot be read is no curve', () {
      final back = CurvedPath.decode(curve().encode())!;
      expect(back.nodes.length, 3);
      expect(back.nodes[0].out, const Offset(160, 40));
      expect(back.nodes[0].inn, const Offset(40, 160), reason: 'the other handle goes the other way');
      expect(back.nodes[2].smooth, isFalse);
      expect(back.closed, isFalse);
      expect(CurvedPath.decode(CurvedPath([PathNode(Offset.zero), PathNode(const Offset(5, 5))], true).encode())!.closed, isTrue);
      for (final bad in [null, '', 'x', '{}', '{"n":[[1,2]]}', '{"n":[[1,2],[3]]}', '{"n":[[1,2],["a",4]]}', '[1]']) {
        expect(CurvedPath.decode(bad), isNull, reason: '$bad');
      }
    });

    test('follow a line that was moved or made bigger, and let go of one that was changed some other way', () {
      final c = curve();
      final line = c.points();
      final moved = c.fittedTo([for (final p in line) p + const Offset(40, 25)])!;
      expect(moved.nodes[1].at, c.nodes[1].at + const Offset(40, 25));
      expect(moved.nodes[0].out, c.nodes[0].out! + const Offset(40, 25));
      final box = Rect.fromPoints(line.first, line.last);
      // twice as wide, from the left edge of the line
      final left = line.map((p) => p.dx).reduce((a, b) => a < b ? a : b), top = line.map((p) => p.dy).reduce((a, b) => a < b ? a : b);
      final wide = c.fittedTo([for (final p in line) Offset(left + (p.dx - left) * 2, p.dy)])!;
      expect(wide.nodes[2].at.dx, closeTo(left + (c.nodes[2].at.dx - left) * 2, 1e-6));
      expect(wide.nodes[2].at.dy, closeTo(c.nodes[2].at.dy, 1e-6));
      expect(box, isNotNull);
      expect(top, isNotNull);
      expect(c.fittedTo([for (final p in line) p + Offset(0, p.dx / 10)]), isNull, reason: 'sheared: not the same line');
      expect(c.fittedTo(line.take(line.length - 3).toList()), isNull, reason: 'cut short');
    });
  });

  group('kept with the note', () {
    test('groups and curves are saved and come back, from the database and from a note file', () async {
      final dir = await Directory.systemTemp.createTemp('groupcurve');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/p.png')..writeAsBytesSync(encodePicture(RgbaPicture.filled(4, 4, 1, 2, 3)));
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final files = NoteFileService(repo, supportDirectory: () async => dir);
      final id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [curved(group: 'g1'), DrawingStroke(color: Colors.blue, width: 2, points: const [Offset(0, 0), Offset(50, 50)])];
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(10, 300), initialText: 'in the group', group: 'g1')];
      note.images[0] = [ImageItem(id: 'p', path: file.path, position: Offset.zero, size: const Size(10, 10), group: 'g1')];
      await repo.saveNote(note);

      void check(NoteData n) {
        final s = n.strokes[0]!;
        expect(s.first.group, 'g1');
        expect(s.first.curve!.nodes.length, 3);
        expect(s.first.curve!.nodes[1].inn, const Offset(240, 200));
        expect(s.last.group, noGroup);
        expect(s.last.curve, isNull);
        expect(n.textBoxes[0]!.single.group, 'g1');
        expect(n.images[0]!.single.group, 'g1');
      }

      check((await repo.loadNote(id))!);
      check((await repo.loadNote((await files.importBytes((await files.exportBytes(id))!)).noteId))!);
    });

    test('devices share them: a change of group is a change to send', () {
      final a = Replica('a'), b = Replica('b');
      final na = NoteData(id: 'n'), nb = NoteData(id: 'n');
      na.strokes[0] = [curved(group: 'g1')];
      na.textBoxes[0] = [TextBoxWidgetModel(id: 'x', position: Offset.zero, initialText: 'hi', group: 'g1')];
      void send(Replica from, NoteData of, Replica to, NoteData into) {
        for (final op in from.localChanges(of)) {
          to.apply(into, op, makeBox: (i) => TextBoxWidgetModel(id: i, position: Offset.zero), saveImage: (i, bytes, e) => '', onNoteField: (f, d) => Replica.applyNoteField(into, f, d));
        }
      }

      send(a, na, b, nb);
      expect(nb.strokes[0]!.single.group, 'g1');
      expect(nb.strokes[0]!.single.curve!.nodes.length, 3);
      expect(nb.textBoxes[0]!.single.group, 'g1');
      na.strokes[0]!.single.group = noGroup;
      na.textBoxes[0]!.single.group = noGroup;
      send(a, na, b, nb);
      expect(nb.strokes[0]!.single.group, noGroup);
      expect(nb.textBoxes[0]!.single.group, noGroup);
    });
  });

  group('in the editor', () {
    late NoteRepository repo;
    late String id;

    Future<void> open(WidgetTester tester, void Function(NoteData) fill) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote();
        final note = (await repo.loadNote(id))!;
        fill(note);
        await repo.saveNote(note);
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    List<DrawingStroke> strokes() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
    }

    Future<void> lassoAround(WidgetTester tester, Rect page) async {
      final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
      // (the drawing tools take a column of 56 pixels, or more of them when they do not fit the height)
      final barLeft = tester.getCenter(find.byKey(const ValueKey('undo-button'))).dx - 28;
      final left = (barLeft - 1 - 800) / 2;
      Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
      final g = await tester.startGesture(at(page.left, page.top), kind: PointerDeviceKind.touch);
      for (final p in [at(page.left, page.top), at(page.right, page.top), at(page.right, page.bottom), at(page.left, page.bottom), at(page.left, page.top + 5)]) {
        await g.moveTo(p);
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pumpAndSettle();
    }

    testWidgets('two things are grouped, then selecting one takes the other with it, and ungrouping lets them go; each is a step to take back', (tester) async {
      await open(tester, (n) {
        n.strokes[0] = [DrawingStroke(id: 'far', color: Colors.red, width: 3, points: const [Offset(100, 100), Offset(180, 140)])];
        n.textBoxes[0] = [
          TextBoxWidgetModel(id: 'near', position: const Offset(100, 500), size: const Size(200, 40), initialText: 'Partner'),
          TextBoxWidgetModel(id: 'other', position: const Offset(400, 500), size: const Size(200, 40), initialText: 'Loner'),
        ];
      });
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
      await tester.pumpAndSettle();
      await lassoAround(tester, const Rect.fromLTRB(60, 60, 330, 580)); // the line and "Partner"
      expect(find.byKey(const ValueKey('group-selection')), findsOneWidget);
      expect(find.byKey(const ValueKey('ungroup-selection')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('group-selection')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('group-selection')), findsNothing, reason: 'they are a group now');
      expect(find.byKey(const ValueKey('ungroup-selection')), findsOneWidget);

      // a lasso round the box alone takes the line as well: the frame covers both
      await tester.tapAt(const Offset(1300, 900)); // nothing: lets go of the selection
      await lassoAround(tester, const Rect.fromLTRB(60, 480, 330, 580));
      expect(find.byKey(const ValueKey('ungroup-selection')), findsOneWidget);
      final frame = tester.getRect(find.byKey(const ValueKey('ungroup-selection')));
      expect(frame, isNotNull);
      // delete takes both
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(strokes(), isEmpty, reason: 'the line was in the group');
      expect(find.text('Partner'), findsNothing);
      expect(find.text('Loner'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('undo-any')));
      await tester.pumpAndSettle();
      expect(strokes().length, 1);
      expect(find.text('Partner'), findsOneWidget);

      // ungroup, and the lasso round the box takes only the box
      await lassoAround(tester, const Rect.fromLTRB(60, 480, 330, 580));
      await tester.tap(find.byKey(const ValueKey('ungroup-selection')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(1300, 900));
      await lassoAround(tester, const Rect.fromLTRB(60, 480, 330, 580));
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(strokes().length, 1, reason: 'the line is on its own again');
      expect(find.text('Partner'), findsNothing);
      await settle(tester);
      final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
      expect(saved.strokes[0]!.single.group, noGroup);
    });

    testWidgets('pulling a text box that is in a group moves the others with it, and a box in none moves alone', (tester) async {
      await open(tester, (n) {
        n.strokes[0] = [DrawingStroke(id: 'line', color: Colors.red, width: 3, points: const [Offset(100, 100), Offset(180, 140)], group: 'g')];
        n.textBoxes[0] = [
          TextBoxWidgetModel(id: 'in', position: const Offset(100, 400), size: const Size(200, 40), initialText: 'Grouped', group: 'g'),
          TextBoxWidgetModel(id: 'out', position: const Offset(400, 400), size: const Size(200, 40), initialText: 'Single'),
        ];
      });
      final line = strokes().single;
      final start = line.points.first;
      await tester.drag(find.text('Single'), const Offset(60, 40));
      await tester.pumpAndSettle();
      expect(line.points.first, start, reason: 'a box in no group moves alone');
      final box = tester.getTopLeft(find.text('Grouped'));
      final g = await tester.startGesture(box + const Offset(20, 10));
      await tester.pump();
      for (var i = 1; i <= 10; i++) {
        await g.moveBy(const Offset(10, 6));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();
      final moved = tester.getTopLeft(find.text('Grouped')) - box;
      expect(moved.dx, greaterThan(60)); // (the first step of a pull is the slop of the gesture)
      expect(line.points.first - start, moved, reason: 'the line in the group went along, as far');
      await tester.tap(find.byKey(const ValueKey('undo-any')));
      await tester.pumpAndSettle();
      await settle(tester);
    });

    testWidgets('a copy of a whole group is a new group', (tester) async {
      await open(tester, (n) {
        n.strokes[0] = [
          DrawingStroke(id: 'a', color: Colors.red, width: 3, points: const [Offset(100, 100), Offset(180, 140)], group: 'g'),
          DrawingStroke(id: 'b', color: Colors.red, width: 3, points: const [Offset(100, 200), Offset(180, 240)], group: 'g'),
          DrawingStroke(id: 'c', color: Colors.red, width: 3, points: const [Offset(100, 400), Offset(180, 440)], group: 'h'),
        ];
      });
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
      await tester.pumpAndSettle();
      await lassoAround(tester, const Rect.fromLTRB(60, 60, 260, 160)); // only "a": "b" comes with it
      await tester.tap(find.byKey(const ValueKey('duplicate-selection')));
      await tester.pumpAndSettle();
      final all = strokes();
      expect(all.length, 5, reason: 'both members of the group were copied');
      final copies = all.where((s) => !{'a', 'b', 'c'}.contains(s.id)).toList();
      expect(copies.map((s) => s.group).toSet().length, 1);
      expect(copies.first.group, allOf(isNot(noGroup), isNot('g'), isNot('h')));
      await settle(tester);
    });

    testWidgets('a line of the pen for curves shows its points again, they are pulled, and the line follows; it is one step to take back', (tester) async {
      await open(tester, (n) {
        n.strokes[0] = [DrawingStroke(id: 'curve', color: Colors.red, width: 3, points: curve().points(), curve: curve())];
      });
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
      await tester.pumpAndSettle();
      await lassoAround(tester, const Rect.fromLTRB(60, 20, 460, 260));
      await tester.tap(find.byKey(const ValueKey('edit-points')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pen-path')), findsOneWidget);
      expect(find.byKey(const ValueKey('pen-done')), findsOneWidget);

      final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
      final before = List.of(strokes().single.points);
      // pull the middle point down by 80
      final g = await tester.createGesture();
      await g.down(origin + const Offset(300, 120));
      await tester.pump();
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(origin + Offset(300, 120.0 + 10 * i));
      }
      await g.up();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pen-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pen-path')), findsNothing);
      final after = strokes().single;
      expect(after.id, 'curve', reason: 'the same line');
      expect((after.points.first - before.first).distance, lessThan(0.01), reason: 'the ends did not move');
      expect(after.points[after.points.length ~/ 2].dy, greaterThan(before[before.length ~/ 2].dy + 20));
      expect((after.curve!.nodes[1].at - const Offset(300, 200)).distance, lessThan(0.5));

      await tester.tap(find.byKey(const ValueKey('undo-any')));
      await tester.pumpAndSettle();
      expect(strokes().single.points, before);
      expect((strokes().single.curve!.nodes[1].at - const Offset(300, 120)).distance, lessThan(0.5));
      await settle(tester);
    });
  });
}
