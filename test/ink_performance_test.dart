import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/style/stylus_settings.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Counts what is drawn, leaves everything else alone.
class _CountingCanvas implements Canvas {
  int paths = 0, pictures = 0;

  @override
  void drawPath(Path path, Paint paint) => paths++;

  @override
  void drawPicture(ui.Picture picture) => pictures++;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Notes what is drawn on [real], and draws it there.
class _Kept implements Canvas {
  final Canvas real;
  final drawn = <String>[];
  _Kept(this.real);

  @override
  void drawPicture(ui.Picture picture) {
    drawn.add('picture');
    real.drawPicture(picture);
  }

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    drawn.add('pixels ${image.width}x${image.height}');
    real.drawImageRect(image, src, dst, paint);
  }

  /// (the place drawn line by line over the pixels: only the clip that keeps to it, not the one that leaves it out, is told)
  @override
  void clipRect(Rect rect, {ui.ClipOp clipOp = ui.ClipOp.intersect, bool doAntiAlias = true}) {
    if (clipOp == ui.ClipOp.intersect) drawn.add('lines in ${rect.width.round()}x${rect.height.round()}');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// How far [p] is from the line through [line].
double _off(Offset p, List<Offset> line) {
  var best = double.infinity;
  for (var i = 0; i + 1 < line.length; i++) {
    final a = line[i], ab = line[i + 1] - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    final t = len2 == 0 ? 0.0 : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    best = math.min(best, (p - (a + ab * t)).distance);
  }
  return best;
}

Future<Uint8List> _pixels(void Function(Canvas) draw) async {
  final rec = ui.PictureRecorder();
  draw(Canvas(rec));
  final img = await rec.endRecording().toImage(300, 200);
  return (await img.toByteData())!.buffer.asUint8List();
}

DrawingStroke _word(double x, double y, {Color color = Colors.black, bool pressure = false}) {
  final pts = [for (var i = 0; i <= 120; i++) Offset(x + i * 0.3, y + 8 * math.sin(i / 8))];
  return DrawingStroke(color: color, width: 2.5, points: pts, pressures: pressure ? [for (var i = 0; i <= 120; i++) 80 + (i * 3) % 150] : null);
}

void main() {
  group('a line keeps only the points one can see', () {
    test('a dense line keeps a fraction of its points and stays within the tolerance of where it went', () {
      final pts = [for (var i = 0; i <= 600; i++) Offset(10 + i * 0.25, 50 + 20 * math.sin(i / 40))];
      final s = DrawingStroke(color: Colors.black, width: 2, points: List.of(pts));
      s.simplify(0.2);
      expect(s.points.length, lessThan(pts.length ~/ 4));
      expect(s.points.first, pts.first);
      expect(s.points.last, pts.last);
      for (final p in pts) {
        expect(_off(p, s.points), lessThanOrEqualTo(0.2 + 1e-9));
      }
    });

    test('the pressure stays with its points, and a change of pressure along a straight line is kept', () {
      final pts = [for (var i = 0; i <= 100; i++) Offset(10.0 + i, 50)];
      final pr = [for (var i = 0; i <= 100; i++) i < 50 ? 40 : 220];
      final s = DrawingStroke(color: Colors.black, width: 2, points: List.of(pts), pressures: List.of(pr));
      s.simplify(0.3);
      expect(s.pressures!.length, s.points.length);
      expect(s.points.length, lessThan(20)); // (straight: the ends, and a few around where the pressure jumps)
      for (var i = 0; i < s.points.length; i++) {
        expect(s.pressures![i], pr[pts.indexOf(s.points[i])]);
      }
      expect(s.pressures!.toSet(), containsAll([40, 220]));
    });
  });

  group('drawing a page', () {
    test('lines of the same look that follow each other are drawn at once; see-through ones each on their own, in order', () {
      final c = _CountingCanvas();
      paintStrokes(c, [for (var i = 0; i < 200; i++) _word(10.0 + i, 40, pressure: i.isEven)..pressures = null], 0.6);
      expect(c.paths, 1);

      final d = _CountingCanvas();
      paintStrokes(d, [
        for (var i = 0; i < 50; i++) _word(10.0 + i, 40),
        for (var i = 0; i < 50; i++) _word(10.0 + i, 80, color: Colors.blue),
        for (var i = 0; i < 5; i++) _word(10.0 + i, 120, color: Colors.yellow.withValues(alpha: 0.4)),
        _word(10, 160),
      ], 0.6);
      expect(d.paths, 1 + 1 + 5 + 1);
    });

    testWidgets('the kept picture looks the same as drawing every line, also after a line was added to it', (tester) async {
      final strokes = [for (var i = 0; i < 30; i++) _word(10.0 + (i % 6) * 45, 20.0 + (i ~/ 6) * 35, pressure: i % 3 == 0, color: i % 4 == 0 ? Colors.red : Colors.black)];
      Future<Uint8List> layer() => _pixels((c) => InkLayerPainter(strokes: strokes).paint(c, const Size(300, 200)));
      Future<Uint8List> every() => _pixels((c) => UnifiedInkPainter(strokes: strokes).paint(c, const Size(300, 200)));
      expect(await tester.runAsync(layer), await tester.runAsync(every));
      strokes.add(_word(200, 170, color: Colors.green));
      expect(await tester.runAsync(layer), await tester.runAsync(every));
      strokes.first.points.add(const Offset(290, 190)); // (a line that changed: the whole picture is made again)
      expect(await tester.runAsync(layer), await tester.runAsync(every));
    });

    testWidgets('a page of many lines (kept in chunks) looks the same as drawing every line, also after lines were erased and added', (tester) async {
      // (small lines that do not touch, many more than fit in one chunk)
      DrawingStroke dash(int i) => DrawingStroke(color: i % 7 == 0 ? Colors.red : Colors.black, width: 1.5, points: [for (var k = 0; k < 5; k++) Offset(4.0 + (i % 36) * 8 + k, 4.0 + (i ~/ 36) * 9 + (k.isEven ? 0 : 2))]);
      final strokes = [for (var i = 0; i < 700; i++) dash(i)];
      Future<Uint8List> layer() => _pixels((c) => InkLayerPainter(strokes: strokes).paint(c, const Size(300, 200)));
      Future<Uint8List> every() => _pixels((c) => UnifiedInkPainter(strokes: strokes).paint(c, const Size(300, 200)));
      expect(await tester.runAsync(layer), await tester.runAsync(every));
      for (final i in [350, 0, 650, 120]) {
        strokes.removeAt(i);
        expect(await tester.runAsync(layer), await tester.runAsync(every), reason: 'after erasing line $i');
      }
      strokes.add(dash(701));
      expect(await tester.runAsync(layer), await tester.runAsync(every));
    });

    test('putting the pen down changes nothing about the kept picture, and a page that did not change is not drawn again', () {
      final strokes = [for (var i = 0; i < 10; i++) _word(10.0 + i * 20, 40)];
      final before = InkLayerPainter(strokes: strokes);
      final drawing = _word(30, 100);
      strokes.add(drawing);
      final during = InkLayerPainter(strokes: strokes, skip: drawing);
      expect(during.shouldRepaint(before), isFalse);
      expect(InkLayerPainter(strokes: strokes).shouldRepaint(during), isTrue); // (the pen came up: the line is part of it now)

      final c = _CountingCanvas();
      during.paint(c, const Size(300, 200));
      during.paint(c, const Size(300, 200));
      expect(c.paths, 0); // (into the picture, not onto this canvas)
      expect(c.pictures, 2);
    });
  });

  group('finding lines', () {
    // what isNear and mostlyInside were before they looked at boxes first: they must say the same
    bool nearBefore(DrawingStroke s, Offset p, double radius) {
      final reach = radius + s.width / 2;
      for (var i = 0; i < s.points.length; i++) {
        final a = s.points[i];
        final b = i + 1 < s.points.length ? s.points[i + 1] : a;
        final ab = b - a;
        final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
        final t = len2 == 0 ? 0.0 : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
        if ((p - (a + ab * t)).distance <= reach) return true;
      }
      return false;
    }

    bool insideBefore(DrawingStroke s, List<Offset> lasso) {
      if (lasso.length < 3 || s.points.isEmpty) return false;
      var inside = 0, total = 0;
      void count(Offset p) {
        total++;
        if (pointInPolygon(p, lasso)) inside++;
      }

      count(s.points.first);
      for (var i = 1; i < s.points.length; i++) {
        final a = s.points[i - 1], b = s.points[i];
        final steps = ((b - a).distance / 3).ceil();
        for (var k = 1; k <= steps; k++) {
          count(Offset.lerp(a, b, k / steps)!);
        }
      }
      return inside * 2 >= total;
    }

    final r = math.Random(3);
    DrawingStroke scribble() {
      var p = Offset(r.nextDouble() * 300, r.nextDouble() * 200);
      return DrawingStroke(color: Colors.black, width: 1 + r.nextDouble() * 4, points: [
        for (var k = 0; k < 1 + r.nextInt(30); k++) p += Offset(r.nextDouble() * 16 - 8, r.nextDouble() * 16 - 8),
      ]);
    }

    test('the eraser and a tap find the same lines as measuring every piece of them', () {
      var near = 0;
      for (var i = 0; i < 400; i++) {
        final s = scribble();
        for (var k = 0; k < 20; k++) {
          final p = Offset(r.nextDouble() * 300, r.nextDouble() * 200), radius = r.nextDouble() * 30;
          expect(s.isNear(p, radius), nearBefore(s, p, radius));
          if (nearBefore(s, p, radius)) near++;
        }
      }
      expect(near, greaterThan(100)); // (the cases where it is near were tried too)
    });

    test('a sweep of the eraser finds the lines that stepping along it in fine steps finds', () {
      bool sampledNear(DrawingStroke s, Offset from, Offset to, double radius) {
        final steps = math.max(1, ((to - from).distance / 0.25).ceil());
        for (var k = 0; k <= steps; k++) {
          if (nearBefore(s, Offset.lerp(from, to, k / steps)!, radius)) return true;
        }
        return false;
      }

      var near = 0, onlyBetween = 0;
      for (var i = 0; i < 300; i++) {
        final s = scribble();
        for (var k = 0; k < 15; k++) {
          final from = Offset(r.nextDouble() * 300, r.nextDouble() * 200);
          final to = from + Offset(r.nextDouble() * 120 - 60, r.nextDouble() * 120 - 60);
          final radius = r.nextDouble() * 12;
          final swept = s.isNear(to, radius, from: from);
          if (sampledNear(s, from, to, radius)) expect(swept, isTrue);
          if (swept) {
            expect(sampledNear(s, from, to, radius + 0.3), isTrue); // (the steps are 0.25 apart: none is further than 0.125 from the way)
            near++;
            if (!s.isNear(to, radius) && !s.isNear(from, radius)) onlyBetween++;
          }
        }
      }
      expect(near, greaterThan(100));
      expect(onlyBetween, greaterThan(20)); // (lines met only between the two ends were tried)
    });

    test('the box of a line follows every change of its points', () {
      final s = DrawingStroke(color: Colors.black, width: 2, points: const [Offset(0, 0), Offset(10, 0)]);
      expect(s.isNear(const Offset(200, 0), 3), isFalse);
      s.points.add(const Offset(200, 0));
      expect(s.isNear(const Offset(200, 0), 3), isTrue);
      s.points[2] = const Offset(10, 300);
      expect(s.isNear(const Offset(200, 0), 3), isFalse);
      expect(s.isNear(const Offset(10, 299), 3), isTrue);
      s.points.clear();
      expect(s.isNear(const Offset(0, 0), 3), isFalse);
    });

    test('the lasso takes the same lines as testing every sample of them', () {
      var taken = 0;
      for (var i = 0; i < 60; i++) {
        final c = Offset(r.nextDouble() * 300, r.nextDouble() * 200), size = 20 + r.nextDouble() * 120;
        final lasso = [for (var k = 0; k < 40; k++) c + Offset.fromDirection(k / 40 * 2 * math.pi, size * (0.6 + 0.4 * r.nextDouble()))];
        for (var j = 0; j < 40; j++) {
          final s = scribble();
          expect(s.mostlyInside(lasso), insideBefore(s, lasso));
          if (insideBefore(s, lasso)) taken++;
        }
      }
      expect(taken, greaterThan(50));
    });
  });

  group('a page with many lines is shown as pixels', () {
    List<DrawingStroke> lines(int n, {double shift = 0}) => [for (var i = 0; i < n; i++) _word(10 + shift + (i % 30) * 9.0, 10 + (i % 17) * 11.0)];
    // (a word has 121 points: the fewest words that are shown as pixels)
    final enough = (InkLayerPainter.pixelsFrom / 121).ceil();
    const dense = 1500;

    /// What the painter draws, as one line each: a picture, or pixels of that size.
    Future<List<String>> paint(InkLayerPainter painter) async {
      final rec = ui.PictureRecorder();
      final canvas = _Kept(Canvas(rec));
      painter.paint(canvas, const Size(300, 200));
      rec.endRecording();
      return canvas.drawn;
    }

    Future<void> made() => Future<void>.delayed(const Duration(milliseconds: 400));

    test('not below the limit, and not without a size on the screen', () async {
      final few = lines(enough - 1), many = lines(enough);
      await paint(InkLayerPainter(strokes: few, pixelScale: 1));
      await paint(InkLayerPainter(strokes: many));
      await made();
      expect(await paint(InkLayerPainter(strokes: few, pixelScale: 1)), ['picture']);
      expect(await paint(InkLayerPainter(strokes: many)), ['picture']);
    });

    test('it looks as the lines do', () async {
      final many = lines(dense);
      Future<Uint8List> shown() async {
        final rec = ui.PictureRecorder();
        InkLayerPainter(strokes: many, pixelScale: 1).paint(Canvas(rec), const Size(300, 200));
        final image = await rec.endRecording().toImage(300, 200);
        return (await image.toByteData())!.buffer.asUint8List();
      }

      final lines0 = await shown();
      await made();
      expect(await paint(InkLayerPainter(strokes: many, pixelScale: 1)), ['pixels 300x200']);
      expect(await shown(), lines0);
    });

    test('a line added is drawn over the pixels there are (not the whole page line by line); another zoom shows the lines at once; pixels again a moment later', () async {
      final many = lines(dense);
      await paint(InkLayerPainter(strokes: many, pixelScale: 1));
      await made();
      expect(await paint(InkLayerPainter(strokes: many, pixelScale: 1)), ['pixels 300x200']);
      many.add(_word(50, 50));
      expect(await paint(InkLayerPainter(strokes: many, pixelScale: 1)), ['pixels 300x200']); // (and the new line, as lines)
      await made();
      expect(await paint(InkLayerPainter(strokes: many, pixelScale: 1)), ['pixels 300x200']);
      expect(await paint(InkLayerPainter(strokes: many, pixelScale: 2)), ['picture']);
      await made();
      expect(await paint(InkLayerPainter(strokes: many, pixelScale: 2)), ['pixels 600x400']);
    });

    /// What [strokes] look like through the painter, as pixels of the screen.
    Future<Uint8List> shownOf(List<DrawingStroke> strokes) async {
      final rec = ui.PictureRecorder();
      InkLayerPainter(strokes: strokes, pixelScale: 1).paint(Canvas(rec), const Size(300, 200));
      final image = await rec.endRecording().toImage(300, 200);
      return (await image.toByteData())!.buffer.asUint8List();
    }

    test('pixels made from the pixels there were and the lines written since look as pixels made of all the lines', () async {
      final r = math.Random(3);
      final page = lines(dense, shift: 0.5);
      await paint(InkLayerPainter(strokes: page, pixelScale: 1));
      await made();
      // written on in three goes, the pixels made again after each (lines here and there, some over others, some in colour)
      for (var go = 0; go < 3; go++) {
        for (var i = 0; i < 1 + go * 40; i++) {
          page.add(_word(r.nextDouble() * 260, r.nextDouble() * 180, color: Color(0xFF000000 | r.nextInt(0xFFFFFF)), pressure: r.nextBool()));
        }
        expect(await paint(InkLayerPainter(strokes: page, pixelScale: 1)), ['pixels 300x200']);
        expect(await shownOf(page), isNot(isEmpty));
        await made();
      }
      expect(await paint(InkLayerPainter(strokes: page, pixelScale: 1)), ['pixels 300x200']);
      final grown = await shownOf(page);
      // the same lines in a list of their own: its pixels are made of all of them at once. (The same lines, not copies: lines of one look
      // that follow each other are drawn as one path, whose edges where they cross are soft once, not twice, so where a run of them is cut -
      // between chunks, which go by which lines they are - shows at those edges. The lines written here are each in a colour of its own.)
      final fresh = List.of(page);
      await paint(InkLayerPainter(strokes: fresh, pixelScale: 1));
      await made();
      expect(await paint(InkLayerPainter(strokes: fresh, pixelScale: 1)), ['pixels 300x200']);
      // (to the bit but for the soft edges of the lines, which pass through pixels of 8 bits once more: one step of 255 at most there)
      final whole = await shownOf(fresh);
      expect(grown.length, whole.length);
      var most = 0, differ = 0;
      for (var i = 0; i < whole.length; i++) {
        final d = (grown[i] - whole[i]).abs();
        if (d > 0) differ++;
        most = math.max(most, d);
      }
      expect(most, lessThanOrEqualTo(2));
      expect(differ, lessThan(whole.length ~/ 200));
    });

    /// The place drawn line by line over the pixels, in square units, from what the painter drew; null if it drew none.
    int? redrawn(List<String> drawn) {
      final m = drawn.map(RegExp(r'^lines in (\d+)x(\d+)$').firstMatch).nonNulls.firstOrNull;
      return m == null ? null : int.parse(m[1]!) * int.parse(m[2]!);
    }

    test('a line erased, changed or put among the others is drawn over the pixels, line by line only where it was (the line of writing it is in); the pixels made from that are those of all the lines', () async {
      final r = math.Random(5);
      // six lines of writing of six words, each of three strokes that cross; each stroke in a colour of its own (strokes of one look are
      // drawn as one path, see above)
      final page = [
        for (var i = 0; i < 36; i++)
          for (var k = 0; k < 3; k++) _word(10 + (i % 6) * 48.0 + k * 3, 14 + (i ~/ 6) * 30.0 + k * 2, color: Color(0xFF000000 | r.nextInt(0xFFFFFF)), pressure: k.isEven),
      ];
      await paint(InkLayerPainter(strokes: page, pixelScale: 1));
      await made();
      Future<void> changed(String what) async {
        final drawn = await paint(InkLayerPainter(strokes: page, pixelScale: 1));
        expect(drawn.first, 'pixels 300x200', reason: what);
        expect(redrawn(drawn), lessThan(300 * 200 ~/ 3), reason: what);
        await made();
        expect(await paint(InkLayerPainter(strokes: page, pixelScale: 1)), ['pixels 300x200'], reason: what);
      }

      page.removeAt(40);
      await changed('erased');
      page[3].color = Colors.red;
      page.add(_word(150, 120, color: Colors.blue));
      await changed('restyled, and one added on top');
      page.insert(10, _word(100, 46, color: Colors.green));
      await changed('put among the others');
      page.first.points[0] += const Offset(5, 5);
      await changed('moved');
      // the eraser swept through a row: each move erased what it touched, and the pixels were made only when it rested
      for (var x = 20.0; x < 200; x += 12) {
        page.removeWhere((s) => s.points.any((p) => (p - Offset(x, 76)).distance < 4));
        final drawn = await paint(InkLayerPainter(strokes: page, pixelScale: 1));
        expect(drawn.first, 'pixels 300x200');
        expect(redrawn(drawn), lessThan(300 * 200 ~/ 3));
      }
      expect(page.length, lessThan(3 * 36 - 6), reason: 'the sweep erased something');
      await made();
      expect(await paint(InkLayerPainter(strokes: page, pixelScale: 1)), ['pixels 300x200']);
      final changedPixels = await shownOf(page);
      final fresh = List.of(page);
      await paint(InkLayerPainter(strokes: fresh, pixelScale: 1));
      await made();
      expect(await paint(InkLayerPainter(strokes: fresh, pixelScale: 1)), ['pixels 300x200']);
      final whole = await shownOf(fresh);
      // (to the bit but for the soft edges of the lines added on top, which pass through pixels of 8 bits once more)
      var most = 0, differ = 0;
      for (var i = 0; i < whole.length; i++) {
        final d = (changedPixels[i] - whole[i]).abs();
        if (d > 2) differ++;
        most = math.max(most, d);
      }
      expect(most, lessThanOrEqualTo(2));
      expect(differ, lessThan(whole.length ~/ 200));
    });

    test('lines put in another order, or half the page changed, are drawn as lines until the pixels are made again; on a page where all lines touch, only around a change', () async {
      final page = lines(dense + 10);
      await paint(InkLayerPainter(strokes: page, pixelScale: 1));
      await made();
      // (every line here touches others all across the page: the place drawn again is not grown to whole lines, only to the change)
      page.removeAt(700);
      final drawn = await paint(InkLayerPainter(strokes: page, pixelScale: 1));
      expect(drawn.first, 'pixels 300x200');
      expect(redrawn(drawn), lessThan(300 * 200 ~/ 10));
      await made();
      page.insert(0, page.removeAt(500));
      expect(await paint(InkLayerPainter(strokes: page, pixelScale: 1)), ['picture']);
      await made();
      expect(await paint(InkLayerPainter(strokes: page, pixelScale: 1)), ['pixels 300x200']);
      page.removeRange(0, page.length ~/ 2);
      expect(await paint(InkLayerPainter(strokes: page, pixelScale: 1)), ['picture']);
      await made();
      expect(await paint(InkLayerPainter(strokes: page, pixelScale: 1)), ['pixels 300x200']);
    });

    test('pages keep theirs while they fit in the budget, and a page that lost them is still drawn; pages on the screen do not take each other\'s', () async {
      final budget = InkLayerPainter.pixelsBudget;
      addTearDown(() => InkLayerPainter.pixelsBudget = budget);
      InkLayerPainter.forgetPixels();
      InkLayerPainter.pixelsBudget = 4 * 300 * 200 * 4;
      final pages = [for (var p = 0; p < 7; p++) lines(dense, shift: p.toDouble())];
      for (final page in pages) {
        await paint(InkLayerPainter(strokes: page, pixelScale: 1));
        await made();
      }
      expect(await paint(InkLayerPainter(strokes: pages.first, pixelScale: 1)), ['picture']);
      await made();
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      for (final page in pages) {
        InkLayerPainter(strokes: page, pixelScale: 1).paint(canvas, const Size(300, 200));
      }
      final image = await rec.endRecording().toImage(300, 200); // (with an image that was let go of, this fails)
      expect(image.width, 300);
      await made();
      // all seven on the screen at once (each painted after every change): four have pixels, and the same four keep them
      Future<List<bool>> shown() async => [for (final page in pages) (await paint(InkLayerPainter(strokes: page, pixelScale: 1))).first != 'picture'];
      await shown();
      await made();
      final again = await shown();
      await made();
      expect(again.where((p) => p), hasLength(4));
      expect(await shown(), again);
      await made();
    });

    test('an infinite canvas is too big for it', () async {
      final many = lines(dense);
      for (var i = 0; i < 2; i++) {
        final rec = ui.PictureRecorder();
        final canvas = _Kept(Canvas(rec));
        InkLayerPainter(strokes: many, pixelScale: 1).paint(canvas, const Size(200000, 200000));
        rec.endRecording();
        expect(canvas.drawn, ['picture']);
        await made();
      }
    });
  });

  group('writing in the editor', () {
    setUpAll(AppDatabase.initFfi);

    testWidgets('the pen going down, moving and lifting builds nothing but the lines of the page, and the line that is saved has far fewer points than the pen sent', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote();
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, stylus: StylusSettings.inMemory())));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Draw'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));

      final layer = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      final active = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is ActiveInkPainter);
      final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + const Offset(150, 200);
      const p = 7;
      // (the first line on a page brings an empty page after it, which does build the editor: the line looked at is the second)
      await tester.sendEventToBinding(PointerDownEvent(pointer: 6, position: origin + const Offset(0, 300), kind: PointerDeviceKind.stylus, buttons: kPrimaryButton));
      for (var i = 1; i <= 20; i++) {
        await tester.sendEventToBinding(PointerMoveEvent(pointer: 6, position: origin + Offset(i * 4.0, 300 + i.toDouble()), kind: PointerDeviceKind.stylus, buttons: kPrimaryButton));
      }
      await tester.sendEventToBinding(PointerUpEvent(pointer: 6, position: origin + const Offset(80, 320), kind: PointerDeviceKind.stylus));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
      // (the bar of the editor is made anew at every build of it)
      final bar = tester.widget(find.byType(AppBar));
      DrawingStroke? drawn() => (tester.widget<CustomPaint>(active.first).painter! as ActiveInkPainter).stroke();
      expect(drawn(), isNull);
      await tester.sendEventToBinding(PointerDownEvent(pointer: p, position: origin, kind: PointerDeviceKind.stylus, buttons: kPrimaryButton));
      await tester.pump();
      expect(drawn(), isNotNull);
      expect(identical(tester.widget(find.byType(AppBar)), bar), isTrue, reason: 'the editor was built when the pen went down');
      final painter = tester.widget<CustomPaint>(layer.first).painter;
      const moves = 300;
      for (var i = 1; i <= moves; i++) {
        await tester.sendEventToBinding(PointerMoveEvent(pointer: p, position: origin + Offset(i * 0.8, 30 * math.sin(i / 30)), kind: PointerDeviceKind.stylus, buttons: kPrimaryButton));
        await tester.pump();
      }
      expect(identical(tester.widget<CustomPaint>(layer.first).painter, painter), isTrue, reason: 'the page was built again while the pen moved');
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
      await tester.sendEventToBinding(PointerUpEvent(pointer: p, position: origin + Offset(moves * 0.8, 30 * math.sin(moves / 30)), kind: PointerDeviceKind.stylus));
      // (the layer of the line being drawn paints again: else its last picture of the line stays on the screen over the finished one,
      // and stays there when the line is erased)
      expect(tester.renderObject<RenderCustomPaint>(active.first).debugNeedsPaint, isTrue, reason: 'the line being drawn is still shown');
      await tester.pump();
      expect(drawn(), isNull);
      expect(identical(tester.widget(find.byType(AppBar)), bar), isTrue, reason: 'the editor was built when the pen lifted');
      // the lines of the page were built again, with the line among them
      final after = tester.widget<CustomPaint>(layer.first).painter! as InkLayerPainter;
      expect(identical(after, painter), isFalse);
      expect(after.skip, isNull);
      expect(after.strokes, hasLength(2));
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('undo-any'))).onPressed, isNotNull);

      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
      final saved = (await tester.runAsync(() => repo.loadNote(id)))!.strokes[0]!;
      expect(saved, hasLength(2));
      expect(saved.last.points.length, lessThan(moves ~/ 3));
      expect(saved.last.points.length, greaterThan(4)); // (still a curve)
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    });

    testWidgets('the eraser builds nothing but the lines of the page, and what it erased is one step to take back', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote();
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, stylus: StylusSettings.inMemory())));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Draw'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));

      final layer = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      InkLayerPainter ink() => tester.widget<CustomPaint>(layer.first).painter! as InkLayerPainter;
      final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + const Offset(150, 200);
      // three lines, one under the other
      for (var n = 0; n < 3; n++) {
        await tester.sendEventToBinding(PointerDownEvent(pointer: 10 + n, position: origin + Offset(0, n * 60.0), kind: PointerDeviceKind.stylus, buttons: kPrimaryButton));
        for (var i = 1; i <= 20; i++) {
          await tester.sendEventToBinding(PointerMoveEvent(pointer: 10 + n, position: origin + Offset(i * 5.0, n * 60.0 + (i.isEven ? 3 : -3)), kind: PointerDeviceKind.stylus, buttons: kPrimaryButton));
        }
        await tester.sendEventToBinding(PointerUpEvent(pointer: 10 + n, position: origin + Offset(100, n * 60.0), kind: PointerDeviceKind.stylus));
        await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
      }
      expect(ink().strokes, hasLength(3));
      final bar = tester.widget(find.byType(AppBar));
      // the eraser end of the pen, down across the last two
      await tester.sendEventToBinding(PointerDownEvent(pointer: 20, position: origin + const Offset(50, 40), kind: PointerDeviceKind.invertedStylus, buttons: kPrimaryButton));
      await tester.pump();
      expect(identical(tester.widget(find.byType(AppBar)), bar), isTrue, reason: 'the editor was built when the eraser went down');
      for (var i = 1; i <= 20; i++) {
        await tester.sendEventToBinding(PointerMoveEvent(pointer: 20, position: origin + Offset(50, 40 + i * 4.0), kind: PointerDeviceKind.invertedStylus, buttons: kPrimaryButton));
        await tester.pump();
      }
      expect(ink().strokes, hasLength(1));
      expect(identical(tester.widget(find.byType(AppBar)), bar), isTrue, reason: 'the editor was built while the eraser erased');
      await tester.sendEventToBinding(PointerUpEvent(pointer: 20, position: origin + const Offset(50, 120), kind: PointerDeviceKind.invertedStylus));
      await tester.pump();
      expect(identical(tester.widget(find.byType(AppBar)), bar), isTrue, reason: 'the editor was built when the eraser lifted');
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('undo-any'))).onPressed, isNotNull);

      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
      expect((await tester.runAsync(() => repo.loadNote(id)))!.strokes[0], hasLength(1));
      await tester.tap(find.byKey(const ValueKey('undo-any')));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
      expect(ink().strokes, hasLength(3), reason: 'both lines the one sweep erased come back with one step');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    });
  });
}
