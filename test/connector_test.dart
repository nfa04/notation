import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/connector.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'close_editor.dart';

const left = Rect.fromLTWH(100, 100, 120, 40);
const right = Rect.fromLTWH(400, 120, 120, 40);
const below = Rect.fromLTWH(110, 300, 120, 40);

double maxGap(List<Offset> pts) {
  var gap = 0.0;
  for (var i = 1; i < pts.length; i++) {
    gap = math.max(gap, (pts[i] - pts[i - 1]).distance);
  }
  return gap;
}

StrokeLink link({Anchor from = Anchor.auto, Anchor to = Anchor.auto, ConnectorRoute route = ConnectorRoute.straight}) =>
    StrokeLink(from: LinkEnd.to('a', anchor: from), to: LinkEnd.to('b', anchor: to), route: route);

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the sides of a connector', () {
    test('the ends face each other along the axis the items are further apart on', () {
      expect(facingAnchors(left, right), (Anchor.right, Anchor.left));
      expect(facingAnchors(right, left), (Anchor.left, Anchor.right));
      expect(facingAnchors(left, below), (Anchor.bottom, Anchor.top));
      expect(facingAnchors(below, left), (Anchor.top, Anchor.bottom));
    });

    test('a side that is chosen is kept, the other end still faces it', () {
      expect(facingAnchors(left, right, pinnedA: Anchor.top), (Anchor.top, Anchor.left));
      expect(facingAnchors(left, right, pinnedB: Anchor.bottom), (Anchor.right, Anchor.bottom));
    });

    test('the nearest side of an item to a point', () {
      expect(nearestAnchor(left, const Offset(500, 120)), Anchor.right);
      expect(nearestAnchor(left, const Offset(0, 120)), Anchor.left);
      expect(nearestAnchor(left, const Offset(160, 0)), Anchor.top);
      expect(nearestAnchor(left, const Offset(160, 500)), Anchor.bottom);
      // a wide item is not taken for a top or bottom by every point beside it
      expect(nearestAnchor(const Rect.fromLTWH(0, 0, 400, 20), const Offset(450, 30)), Anchor.right);
    });
  });

  group('the line of a connector', () {
    final rects = {'a': left, 'b': right};
    Rect? rectOf(String id) => rects[id];

    test('a straight one runs from the middle of one facing side to the other, and ends in an arrowhead', () {
      final routed = routeLink(link(), rectOf);
      expect(routed.points.first, left.centerRight);
      // the head goes back over the line to the tip: the tip is there twice
      expect(routed.points.where((p) => (p - right.centerLeft).distance < 1e-6).length, 2);
      expect(maxGap(routed.points), lessThanOrEqualTo(5.01)); // the eraser finds it anywhere
      expect(routed.link.from.point, left.centerRight);
      expect(routed.link.to.point, right.centerLeft);
    });

    test('no arrowhead when none is asked for, one at the start when asked', () {
      final plain = routeLink(link().copyWith(arrowAtEnd: false), rectOf).points;
      expect(plain.first, left.centerRight);
      expect(plain.last, right.centerLeft);
      final both = routeLink(link().copyWith(arrowAtStart: true), rectOf).points;
      expect(both.where((p) => (p - left.centerRight).distance < 1e-6).length, greaterThanOrEqualTo(2));
    });

    test('an elbow leaves straight out of its side and only turns at right angles (before the corners are rounded)', () {
      final l = link(route: ConnectorRoute.elbow);
      for (final other in [right, below]) {
        final routed = routeLink(l, (id) => id == 'a' ? left : other, cornerRadius: 0);
        final body = routed.points.take(routed.points.length - 4).toList(); // (without the arrowhead)
        for (var i = 1; i < body.length; i++) {
          final d = body[i] - body[i - 1];
          expect(d.dx.abs() < 1e-6 || d.dy.abs() < 1e-6, isTrue, reason: 'a step that is neither level nor upright at $i: $d');
        }
      }
      // facing sideways: out to the right first
      final sideways = routeLink(l, rectOf, cornerRadius: 0).points;
      expect(sideways[1].dy, closeTo(left.centerRight.dy, 1e-6));
      expect(sideways[1].dx, greaterThan(left.right));
    });

    test('the corners of an elbow are bent smoothly, and it still leaves and arrives straight', () {
      for (final other in [right, below, const Rect.fromLTWH(300, 400, 120, 40)]) {
        final routed = routeLink(link(route: ConnectorRoute.elbow), (id) => id == 'a' ? left : other);
        final body = routed.points.take(routed.points.length - 4).toList();
        var sharpest = 0.0;
        for (var i = 2; i < body.length; i++) {
          final a = body[i - 1] - body[i - 2], b = body[i] - body[i - 1];
          if (a.distance < 1e-9 || b.distance < 1e-9) continue;
          final turn = (math.atan2(b.dy, b.dx) - math.atan2(a.dy, a.dx)).abs();
          sharpest = math.max(sharpest, turn > math.pi ? 2 * math.pi - turn : turn);
        }
        expect(sharpest, lessThan(math.pi / 4), reason: 'a turn of ${sharpest * 180 / math.pi} degrees');
        expect(maxGap(routed.points), lessThanOrEqualTo(5.01));
      }
      // a short stretch between two bends does not make them overlap or leave the area of the corners
      final routed = routeLink(link(route: ConnectorRoute.elbow), (id) => id == 'a' ? left : const Rect.fromLTWH(235, 160, 100, 40));
      final xs = routed.points.map((p) => p.dx), ys = routed.points.map((p) => p.dy);
      expect(xs.reduce(math.max), lessThan(400));
      expect(ys.reduce(math.max), lessThan(300));
    });

    test('an elbow between two sides that face away from each other goes round', () {
      final routed = routeLink(link(from: Anchor.left, to: Anchor.right, route: ConnectorRoute.elbow), rectOf);
      final xs = routed.points.map((p) => p.dx);
      expect(xs.reduce(math.min), lessThan(left.left)); // out to the left of the first item, round to the far side of the other
      expect(routed.points.first, left.centerLeft);
    });

    test('a curve begins and ends at the sides and bends out of them', () {
      final routed = routeLink(link(route: ConnectorRoute.curve, from: Anchor.top, to: Anchor.top), rectOf);
      expect(routed.points.first, left.topCenter);
      expect(routed.points.map((p) => p.dy).reduce(math.min), lessThan(left.top)); // it goes up before it comes down
    });

    test('moving an item moves the end of the line that is fixed to it', () {
      final before = routeLink(link(), rectOf).points;
      rects['b'] = right.shift(const Offset(0, 200));
      final after = routeLink(link(), rectOf).points;
      expect(before.first, after.first);
      expect(after.where((p) => (p - rects['b']!.centerLeft).distance < 1e-6), isNotEmpty);
      rects['b'] = right;
    });

    test('an item that is gone leaves its end where it was; a free end stays where it is', () {
      final first = routeLink(link(), rectOf);
      final gone = routeLink(first.link, (id) => id == 'a' ? left : null);
      expect(gone.points.first, left.centerRight);
      expect(gone.points.where((p) => (p - first.link.to.point).distance < 1e-6), isNotEmpty);
      expect(gone.link.to.item, 'b'); // (it can come back, as with an undo)

      final free = StrokeLink(from: LinkEnd.to('a'), to: const LinkEnd.free(Offset(600, 500)));
      final routed = routeLink(free, rectOf);
      expect(routed.points.first, left.centerRight); // the side that faces the free end
      expect(routed.link.to.isFree, isTrue);
      expect(routed.points.where((p) => (p - const Offset(600, 500)).distance < 1e-6), isNotEmpty);
    });

    test('degenerate lines do not break anything', () {
      for (final route in ConnectorRoute.values) {
        expect(connectorPoints(const Offset(5, 5), Offset.zero, const Offset(5, 5), Offset.zero, route), isNotEmpty);
        expect(connectorPoints(const Offset(5, 5), Anchor.right.direction, const Offset(5.2, 5), Anchor.left.direction, route), isNotEmpty);
      }
    });
  });

  group('the link as saved', () {
    test('it survives JSON, with the choices that were made', () {
      final l = StrokeLink(
        from: const LinkEnd.to('a', anchor: Anchor.bottom, point: Offset(3, 4)),
        to: const LinkEnd.free(Offset(9, 8)),
        route: ConnectorRoute.curve,
        arrowAtEnd: false,
        arrowAtStart: true,
      );
      final back = StrokeLink.decode(l.encode())!;
      expect(back, l);
      expect(back.from.anchor, Anchor.bottom);
      expect(back.from.point, const Offset(3, 4));
      expect(back.to.point, const Offset(9, 8));
      expect((back.route, back.arrowAtEnd, back.arrowAtStart), (ConnectorRoute.curve, false, true));
    });

    test('rubbish gives no link, and unknown names fall back to the plain choices', () {
      expect(StrokeLink.decode(null), isNull);
      expect(StrokeLink.decode(''), isNull);
      expect(StrokeLink.decode('{not json'), isNull);
      expect(StrokeLink.decode('[1,2]'), isNull);
      final l = StrokeLink.fromJson({'f': {'i': 'a', 'a': 'sideways'}, 't': 5, 'r': 'zigzag'})!;
      expect((l.from.item, l.from.anchor, l.to.isFree, l.route), ('a', Anchor.auto, true, ConnectorRoute.straight));
    });

    test('the link is part of what a stroke looks like, so that a change of it is seen', () {
      DrawingStroke make(StrokeLink? l) => DrawingStroke(id: 's', color: Colors.black, width: 2, points: const [Offset(0, 0), Offset(9, 9)], link: l);
      expect(make(link()).stamp, make(link()).stamp);
      expect(make(link()).stamp, isNot(make(null).stamp));
      expect(make(link()).stamp, isNot(make(link(route: ConnectorRoute.elbow)).stamp));
      expect(make(link()).copyAt(const Offset(5, 5)).link, isNull); // a copy is a plain line
    });

    NoteData sample() {
      final n = NoteData(id: 'n1');
      n.strokes[0] = [
        DrawingStroke(id: 'c1', color: Colors.red, width: 2, points: const [Offset(0, 0), Offset(50, 50)], link: link(route: ConnectorRoute.elbow, to: Anchor.top)),
        DrawingStroke(id: 'p1', color: Colors.red, width: 2, points: const [Offset(0, 0), Offset(50, 50)]),
      ];
      return n;
    }

    void expectLink(NoteData n) {
      final c = n.strokes[0]!.firstWhere((s) => s.id == 'c1');
      expect(c.link, link(route: ConnectorRoute.elbow, to: Anchor.top));
      expect(n.strokes[0]!.firstWhere((s) => s.id == 'p1').link, isNull);
    }

    test('a note file keeps it', () {
      expectLink(decodeNoteFile(encodeNoteFile(NoteFileParts(sample()))).note);
    });

    test('the database keeps it', () async {
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final id = await repo.createNote();
      final n = sample();
      final note = (await repo.loadNote(id))!;
      note.strokes = n.strokes;
      await repo.saveNote(note);
      expectLink((await repo.loadNote(id))!);
      // a change of only the link is saved too
      note.strokes[0]!.first.link = link(route: ConnectorRoute.curve);
      await repo.saveNote(note);
      expect((await repo.loadNote(id))!.strokes[0]!.first.link!.route, ConnectorRoute.curve);
    });

    test('the other devices of a shared note get it, and a change of only the link is sent', () {
      final dir = Directory.systemTemp.createTempSync('connector_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = NoteData(id: 'n'), b = NoteData(id: 'n');
      final ra = Replica('a'), rb = Replica('b');
      a.strokes = sample().strokes;
      void send() {
        for (final op in ra.localChanges(a)) {
          rb.apply(b, op,
              makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
              saveImage: (id, bytes, ext) => File('${dir.path}/$id.$ext').path,
              onNoteField: (field, data) {});
        }
      }

      send();
      expectLink(b);
      expect(rb.localChanges(b).where((o) => o.kind == ElementKind.stroke), isEmpty);
      a.strokes[0]!.first.link = link(route: ConnectorRoute.curve);
      send();
      expect(b.strokes[0]!.first.link!.route, ConnectorRoute.curve); // (the change of only the link was sent)
    });
  });

  editorTests();
}

class _EditorFixture {
  late NoteRepository repo;
  late String id;
}

void editorTests() {
  testWidgets('the connector tool joins two boxes with a line that follows them, and a tap on a side grows a new box', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final f = _EditorFixture();
    await tester.runAsync(() async {
      f.repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      f.id = await f.repo.createNote();
      final note = (await f.repo.loadNote(f.id))!;
      note.textBoxes[0] = [
        TextBoxWidgetModel(id: 'A', position: const Offset(100, 100), size: const Size(200, 0), initialText: 'Start'),
        TextBoxWidgetModel(id: 'B', position: const Offset(500, 300), size: const Size(200, 0), initialText: 'End'),
      ];
      await f.repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(f.id), noteId: f.id, repository: f.repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();

    List<DrawingStroke> strokes() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
    }

    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    Future<void> drag(Offset from, Offset to) async {
      final g = await tester.createGesture();
      await g.down(origin + from);
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(origin + Offset.lerp(from, to, i / 10)!);
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    await tester.ensureVisible(find.byKey(const ValueKey('shape-tool')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shape-tool')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shape-connector')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('connector-route')), findsOneWidget);

    // from the middle of the first box (not on a dot) to the second: the line is fixed to both
    await drag(const Offset(200, 120), const Offset(600, 320));
    final line = strokes().single;
    expect(line.link, isNotNull);
    expect(line.link!.from.item, 'A');
    expect(line.link!.to.item, 'B');
    expect(line.link!.route, ConnectorRoute.elbow);
    expect(line.points.first.dx, closeTo(300, 0.01)); // it leaves the side of the first box that faces the second
    expect(line.link!.from.anchor, Anchor.auto);

    // the line is one step to take back
    final before = List.of(line.points);
    final endBefore = line.link!.to.point;
    await tester.drag(find.byKey(const ValueKey('shape-tool')), const Offset(0, 900)); // (the drawing bar back to its top)
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('undo-button')));
    await tester.pumpAndSettle();
    expect(strokes(), isEmpty);
    await tester.tap(find.byKey(const ValueKey('redo-button')));
    await tester.pumpAndSettle();
    expect(strokes().single.points, before);

    // a box that is dragged away (with the pen's own tool, which leaves the boxes to be moved) takes the end of the line along
    await tester.tap(find.byKey(const ValueKey('shape-tool')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shape-freehand')));
    await tester.pumpAndSettle();
    final grab = await tester.startGesture(tester.getCenter(find.text('End')), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    for (var i = 1; i <= 10; i++) {
      await grab.moveBy(const Offset(0, 20));
    }
    await grab.up();
    await tester.pumpAndSettle();
    final moved = strokes().single;
    expect(moved.points, isNot(before));
    expect(moved.link!.to.item, 'B');
    expect(moved.link!.to.point.dy, greaterThan(endBefore.dy + 100)); // the end is on the second box, which is lower now
    expect(moved.points.last.dy, greaterThan(before.last.dy));

    // a tap on the dot of a side of a box: a new box grows out of it, joined to it
    await tester.tap(find.byKey(const ValueKey('shape-tool')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shape-connector')));
    await tester.pumpAndSettle();
    final bottom = moved.link!.from.point; // (the line leaves the bottom of the first box now that the second is far below)
    expect(bottom.dx, 200);
    final dot = Offset(300, 100 + (bottom.dy - 100) / 2); // the dot on the right side of the first box
    final tap = await tester.startGesture(origin + dot, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tap.up();
    await tester.pumpAndSettle();
    final all = strokes();
    expect(all.length, 2);
    expect(all.last.link!.from.item, 'A');
    expect(all.last.link!.from.anchor, Anchor.right);
    expect(all.last.link!.to.item, isNotNull);
    final typing = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Type text...');
    expect(typing, findsOneWidget); // (the new box is typed in at once)
    expect(find.text('Start'), findsOneWidget);

    // taking that back removes the box and the line together
    await tester.tap(find.byKey(const ValueKey('undo-button')));
    await tester.pumpAndSettle();
    expect(strokes().length, 1);
    expect(typing, findsNothing);
    final note = await tester.runAsync(() => f.repo.loadNote(f.id));
    expect(note, isNotNull);
  });

  testWidgets('an end of a selected connector can be pulled to another box or let go, and is one step to take back', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final f = _EditorFixture();
    await tester.runAsync(() async {
      f.repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      f.id = await f.repo.createNote();
      final note = (await f.repo.loadNote(f.id))!;
      note.textBoxes[0] = [
        TextBoxWidgetModel(id: 'A', position: const Offset(100, 100), size: const Size(200, 0), initialText: 'Start'),
        TextBoxWidgetModel(id: 'B', position: const Offset(500, 100), size: const Size(200, 0), initialText: 'End'),
        TextBoxWidgetModel(id: 'C', position: const Offset(500, 400), size: const Size(200, 0), initialText: 'Other'),
      ];
      await f.repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(f.id), noteId: f.id, repository: f.repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();

    List<DrawingStroke> strokes() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
    }

    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    Future<void> drag(Offset from, Offset to) async {
      final g = await tester.startGesture(origin + from, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(origin + Offset.lerp(from, to, i / 10)!);
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    await tester.ensureVisible(find.byKey(const ValueKey('shape-tool')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shape-tool')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shape-connector')));
    await tester.pumpAndSettle();
    await drag(const Offset(200, 120), const Offset(600, 120)); // A to B
    expect(strokes().single.link!.to.item, 'B');

    // select it with a tap of the pen's own tool
    await tester.tap(find.byKey(const ValueKey('shape-tool')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shape-freehand')));
    await tester.pumpAndSettle();
    final line = strokes().single;
    final onLine = line.points[line.points.length ~/ 2];
    final tap = await tester.startGesture(origin + onLine, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tap.up();
    await tester.pumpAndSettle();

    // its end (on the left side of B) is pulled into the third box
    final end = line.link!.to.point;
    final pointsOnB = List.of(line.points);
    await drag(end, const Offset(600, 420));
    final moved = strokes().single;
    expect(moved.link!.from.item, 'A');
    expect(moved.link!.to.item, 'C');
    expect(moved.points.last.dy, greaterThan(350));

    // taking that back puts it on the second box again
    await tester.tap(find.byKey(const ValueKey('undo-button')));
    await tester.pumpAndSettle();
    expect(strokes().single.link!.to.item, 'B');
    expect(strokes().single.points, pointsOnB);
    expect(strokes().single.link!.to.point, end);
    await tester.tap(find.byKey(const ValueKey('redo-button')));
    await tester.pumpAndSettle();
    expect(strokes().single.link!.to.item, 'C');

    // let go over empty paper (the undo let go of the selection: select it again)
    final again = strokes().single;
    final tap2 = await tester.startGesture(origin + again.points[again.points.length ~/ 3], kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await tap2.up();
    await tester.pumpAndSettle();
    // the end is free there, the start is still fixed
    await drag(strokes().single.link!.to.point, const Offset(900, 700));
    final freed = strokes().single;
    expect(freed.link!.to.isFree, isTrue);
    expect(freed.link!.from.item, 'A');
    await closeEditor(tester);
  });
}
