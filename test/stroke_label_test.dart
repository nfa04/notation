import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryMouseButton;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:notes/collab/replica.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/layers.dart';
import 'package:notes/models/shapes.dart';
import 'package:notes/models/stroke_label.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/label_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Every letter is as wide as half its size: easy to count with.
double half(String text, double size, bool bold) => text.characters.length * size / 2;

const red = Color(0xFFFF0000);

DrawingStroke boxShape({StrokeLabel? label, Color? fill, Offset from = const Offset(0, 0)}) => DrawingStroke(
      id: 'box',
      color: Colors.black,
      width: 2,
      points: shapePoints(ShapeTool.rectangle, from, from + const Offset(200, 100)),
      fill: fill,
      label: label,
    );

/// What the streams of a PDF say, deflated (the text of a page is in them).
String pdfContent(List<int> bytes) {
  final raw = String.fromCharCodes(bytes);
  final out = StringBuffer(raw);
  final start = RegExp(r'stream\r?\n');
  var at = 0;
  while (true) {
    final m = start.firstMatch(raw.substring(at));
    if (m == null) break;
    final from = at + m.end;
    final to = raw.indexOf('endstream', from);
    if (to < 0) break;
    try {
      out.writeln(String.fromCharCodes(ZLibDecoder().convert(bytes.sublist(from, to))));
    } on Exception {
      // (not deflated: a picture, a font)
    }
    at = to + 9;
  }
  return out.toString();
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('a label', () {
    test('is written and read again, and what cannot be read is none', () {
      const l = StrokeLabel(text: 'Ünï', size: 33, place: LabelPlace.inside, align: LabelAlign.end, side: LabelSide.below, turned: true, bold: true, color: red);
      expect(StrokeLabel.decode(l.encode()), l);
      const plain = StrokeLabel(text: 'a');
      expect(StrokeLabel.decode(plain.encode()), plain);
      for (final bad in [null, '', 'x', '{}', '[1]', '{"t":5}', '{"t":"  "}']) {
        expect(StrokeLabel.decode(bad), isNull, reason: '$bad');
      }
      expect(StrokeLabel.decode('{"t":"a","p":"nonsense","s":99999}')!.place, LabelPlace.along, reason: 'an unknown kind is the usual one');
      expect(StrokeLabel.decode('{"t":"a","s":99999}')!.size, 400, reason: 'and a silly size is held in');
    });

    test('is part of the stamp of the line, so that a change is saved, and a copy keeps it', () {
      final s = boxShape();
      final before = s.stamp;
      s.label = const StrokeLabel(text: 'one');
      expect(s.stamp, isNot(before));
      final withIt = s.stamp;
      s.label = const StrokeLabel(text: 'one', size: 30);
      expect(s.stamp, isNot(withIt));
      expect(s.copyAt(const Offset(5, 5)).label, s.label);
    });

    test('has the colour of the line along it, and inside a shape the one that shows on the fill', () {
      const along = StrokeLabel(text: 'a');
      expect(along.colorFor(red, null), red);
      const inside = StrokeLabel(text: 'a', place: LabelPlace.inside);
      expect(inside.colorFor(red, null), const Color(0xFF000000));
      expect(inside.colorFor(red, Colors.white), const Color(0xFF000000));
      expect(inside.colorFor(red, Colors.indigo), const Color(0xFFFFFFFF));
      expect(inside.colorFor(red, Colors.indigo.withValues(alpha: 0.05)), const Color(0xFF000000), reason: 'a faint fill is mostly the white paper');
      expect(inside.copyWith(color: Colors.green).colorFor(red, Colors.indigo), Colors.green);
      expect(inside.copyWith(color: Colors.green).copyWith(noColor: true).color, isNull);
    });

    test('is as faint as its layer', () {
      final s = boxShape(label: const StrokeLabel(text: 'a', color: red))..layer = 'a';
      final out = LayerStack(const [NoteLayer('a', 'A', opacity: 0.5)]).forExport([s]).single;
      expect(out.label!.text, 'a');
      expect(out.label!.color!.a, closeTo(0.5, 0.01));
    });
  });

  group('along a line', () {
    const line = [Offset(0, 100), Offset(200, 100)];
    List<LabelRun> along(String text, {List<Offset> pts = line, bool closed = false, double width = 2, StrokeLabel? base, LabelAlign align = LabelAlign.middle, LabelSide side = LabelSide.above, bool turned = false, double size = 20}) =>
        layoutLabel(pts, closed, width, StrokeLabel(text: text, size: size, align: align, side: side, turned: turned), half);

    test('puts a letter after the other, centred, just above the line', () {
      final runs = along('Hello');
      expect(runs.map((r) => r.text).join(), 'Hello');
      // 5 letters of 10 = 50 wide, centred on 200: from 75
      expect(runs.first.origin.dx, closeTo(75, 1e-6));
      expect(runs.last.origin.dx, closeTo(115, 1e-6));
      for (final r in runs) {
        expect(r.angle, closeTo(0, 1e-9));
        expect(r.origin.dy, lessThan(100), reason: 'above');
        expect(r.origin.dy, greaterThan(94));
        expect(r.size, 20);
      }
    });

    test('starts or ends at the end of the line, and is below or on the line', () {
      expect(along('abcd', align: LabelAlign.start).first.origin.dx, closeTo(0, 1e-6));
      expect(along('abcd', align: LabelAlign.end).last.origin.dx + 10, closeTo(200, 1e-6));
      final above = along('a').single.origin.dy, on = along('a', side: LabelSide.on).single.origin.dy, below = along('a', side: LabelSide.below).single.origin.dy;
      expect(above, lessThan(on));
      expect(on, greaterThan(100), reason: 'the middle of the letters is on the line, so their baseline is under it');
      expect(below, greaterThan(on), reason: 'the letters hang under the line');
    });

    test('keeps the space between words but writes no letter for it', () {
      final runs = along('a b', align: LabelAlign.start);
      expect(runs.map((r) => r.text), ['a', 'b']);
      expect(runs[1].origin.dx, closeTo(20, 1e-6), reason: 'a, a space, then b');
    });

    test('is made smaller when it is too long for the line', () {
      final runs = along('x' * 100);
      expect(runs.first.size, lessThan(20));
      expect(runs.last.origin.dx + runs.last.size / 2, lessThanOrEqualTo(200.5));
      expect(runs.first.origin.dx, closeTo(0, 4), reason: 'it fills the line');
    });

    test('turns with the line: down a vertical line the letters are turned a quarter', () {
      final runs = along('abc', pts: const [Offset(50, 0), Offset(50, 200)], align: LabelAlign.start);
      for (final r in runs) {
        expect(r.angle, closeTo(math.pi / 2, 1e-9));
      }
      expect(runs.first.origin.dx, greaterThan(50), reason: 'above is to the right of a line that goes down');
      expect(runs[1].origin.dy, closeTo(10, 1e-6));
    });

    test('follows a bend: letters round a corner point their own ways', () {
      final runs = along('abcdefghij', pts: const [Offset(0, 0), Offset(50, 0), Offset(50, 100)], align: LabelAlign.start, size: 20);
      expect(runs.first.angle, closeTo(0, 1e-9));
      expect(runs.last.angle, closeTo(math.pi / 2, 1e-6));
    });

    test('reads a line drawn from right to left the right way round, unless turned', () {
      final back = along('abc', pts: const [Offset(200, 100), Offset(0, 100)], align: LabelAlign.start);
      expect(back.map((r) => r.text).join(), 'abc');
      expect(back.first.origin.dx, closeTo(0, 1e-6));
      expect(back.first.angle, closeTo(0, 1e-9));
      final turned = along('abc', pts: const [Offset(200, 100), Offset(0, 100)], align: LabelAlign.start, turned: true);
      expect(turned.first.origin.dx, closeTo(200, 1e-6));
      expect(turned.first.angle.abs(), closeTo(math.pi, 1e-9));
    });

    test('goes round a closed shape from its top, clockwise', () {
      final pts = shapePoints(ShapeTool.rectangle, const Offset(0, 0), const Offset(200, 100));
      final start = along('abcd', pts: pts, closed: true, align: LabelAlign.start);
      expect(start.first.origin.dx, closeTo(0, 1e-6));
      expect(start.first.angle, closeTo(0, 1e-9));
      expect(start.first.origin.dy, lessThan(0), reason: 'above the top edge is outside');
      // in the middle: round the top, so that it is the top that is written on
      final middle = along('abcd', pts: pts, closed: true);
      final onTop = middle.where((r) => r.angle.abs() < 1e-6);
      expect(onTop, isNotEmpty);
      expect(middle.map((r) => r.text).join(), 'abcd');
      // a shape drawn the other way round is written the same way
      final other = along('abcd', pts: pts.reversed.toList(), closed: true, align: LabelAlign.start);
      expect(other.first.origin.dx, closeTo(0, 1e-6));
      expect(other.first.angle, closeTo(0, 1e-9));
    });

    test('a line with no length, or no text, has nothing to write', () {
      expect(along('abc', pts: const [Offset(5, 5), Offset(5, 5)]), isEmpty);
      expect(along('   '), isEmpty);
      expect(along(''), isEmpty);
    });
  });

  group('inside a shape', () {
    final box = shapePoints(ShapeTool.rectangle, const Offset(0, 0), const Offset(200, 100));
    List<LabelRun> inside(String text, {List<Offset>? pts, double size = 20}) => layoutLabel(pts ?? box, true, 2, StrokeLabel(text: text, size: size, place: LabelPlace.inside), half);

    test('is one line in the middle when it fits', () {
      final runs = inside('Hello');
      expect(runs, hasLength(1));
      expect(runs.single.size, 20);
      expect(runs.single.origin.dx + 25, closeTo(100, 1e-6), reason: 'centred across');
      expect(runs.single.origin.dy, inInclusiveRange(40, 70), reason: 'and about halfway down');
    });

    test('is broken into lines at its spaces that fit, each centred', () {
      final runs = inside('one two three four five six seven eight nine ten');
      expect(runs.length, greaterThan(1));
      for (final r in runs) {
        final w = half(r.text, r.size, false);
        expect(w, lessThanOrEqualTo(180 + 0.5), reason: 'inside the shape');
        expect(r.origin.dx + w / 2, closeTo(100, 1e-6));
      }
      expect(runs.map((r) => r.text).join(' '), 'one two three four five six seven eight nine ten');
      for (var i = 1; i < runs.length; i++) {
        expect(runs[i].origin.dy, greaterThan(runs[i - 1].origin.dy));
      }
    });

    test('is made smaller when there is too much of it for the shape', () {
      final runs = inside(List.filled(60, 'word').join(' '));
      expect(runs.first.size, lessThan(20));
      expect(runs.last.origin.dy, lessThanOrEqualTo(100));
      expect(runs.first.origin.dy, greaterThanOrEqualTo(0));
    });

    test('breaks a word that is wider than the shape, and honours a new line', () {
      final runs = inside('x' * 60, size: 20);
      expect(runs.map((r) => r.text).join(), 'x' * 60);
      for (final r in runs) {
        expect(half(r.text, r.size, false), lessThanOrEqualTo(180.5));
      }
      expect(inside('a\nb').map((r) => r.text), ['a', 'b']);
    });

    test('has less room in a round shape than in a box', () {
      final circle = shapePoints(ShapeTool.ellipse, const Offset(0, 0), const Offset(200, 100));
      final text = List.filled(8, 'word').join(' ');
      final inCircle = inside(text, pts: circle), inBox = inside(text);
      expect(inCircle.first.size, lessThanOrEqualTo(inBox.first.size));
      for (final r in inCircle) {
        expect(half(r.text, r.size, false), lessThanOrEqualTo(200 * 0.7));
      }
    });
  });

  group('drawn', () {
    Future<img.Image> draw(List<DrawingStroke> strokes, {int w = 240, int h = 140}) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);
      InkLayerPainter(strokes: strokes).paint(canvas, Size(w.toDouble(), h.toDouble()));
      final image = await recorder.endRecording().toImage(w, h);
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      return img.decodePng(data.buffer.asUint8List())!;
    }

    int dark(img.Image image, Rect area, {bool Function(img.Pixel p)? test}) {
      var n = 0;
      for (var y = area.top.toInt(); y < area.bottom.toInt(); y++) {
        for (var x = area.left.toInt(); x < area.right.toInt(); x++) {
          final p = image.getPixel(x, y);
          if (test != null ? test(p) : p.r < 128) n++;
        }
      }
      return n;
    }

    testWidgets('text along a line is drawn on the page, over the line, where the line goes', (tester) async {
      await tester.runAsync(() async {
        final line = DrawingStroke(
          color: Colors.white, // (the line itself does not show on the white page)
          width: 2,
          points: const [Offset(20, 90), Offset(220, 90)],
          label: const StrokeLabel(text: 'Hello', size: 28, color: Color(0xFF000000)),
        );
        final bare = await draw([DrawingStroke(color: Colors.white, width: 2, points: line.points)]);
        expect(dark(bare, const Rect.fromLTWH(0, 0, 240, 140)), 0);
        final image = await draw([line]);
        expect(dark(image, const Rect.fromLTWH(20, 50, 200, 40)), greaterThan(60), reason: 'letters sit just above the line');
        expect(dark(image, const Rect.fromLTWH(0, 100, 240, 40)), 0, reason: 'and nothing is below');
      });
    });

    testWidgets('text inside a shape is drawn in the middle of it, and shows on a dark fill', (tester) async {
      await tester.runAsync(() async {
        final shape = DrawingStroke(
          color: Colors.black,
          width: 2,
          points: shapePoints(ShapeTool.rectangle, const Offset(20, 20), const Offset(220, 120)),
          fill: Colors.indigo,
          label: const StrokeLabel(text: 'Middle', size: 24, place: LabelPlace.inside),
        );
        final image = await draw([shape]);
        final light = dark(image, const Rect.fromLTWH(60, 50, 120, 40), test: (p) => p.r > 200 && p.g > 200 && p.b > 200);
        expect(light, greaterThan(40), reason: 'white letters on the indigo (the automatic colour)');
        expect(dark(image, const Rect.fromLTWH(0, 0, 240, 18), test: (p) => p.r > 200 && p.g > 200 && p.b > 200), greaterThan(0), reason: 'the paper above the shape is white');
      });
    });

    testWidgets('a label is over its own line and under the lines drawn after it', (tester) async {
      await tester.runAsync(() async {
        final first = DrawingStroke(
          color: Colors.white,
          width: 2,
          points: const [Offset(20, 90), Offset(220, 90)],
          label: const StrokeLabel(text: 'Under', size: 28, color: Color(0xFF000000)),
        );
        // a wide white line drawn later covers the text
        final cover = DrawingStroke(color: Colors.white, width: 60, points: const [Offset(0, 70), Offset(240, 70)]);
        final image = await draw([first, cover]);
        expect(dark(image, const Rect.fromLTWH(20, 50, 200, 40)), lessThan(20), reason: 'the later line is over it');
      });
    });
  });

  group('kept with the note', () {
    test('in the database, in a note file and with the others working on it', () async {
      final dir = await Directory.systemTemp.createTemp('label');
      addTearDown(() => dir.delete(recursive: true));
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final files = NoteFileService(repo, supportDirectory: () async => dir);
      final id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      const label = StrokeLabel(text: 'Door', size: 26, align: LabelAlign.start, bold: true, color: red);
      note.strokes[0] = [boxShape(label: label), DrawingStroke(color: Colors.blue, width: 2, points: const [Offset(0, 0), Offset(50, 50)])];
      await repo.saveNote(note);

      void check(NoteData n) {
        final s = n.strokes[0]!;
        expect(s.first.label, label);
        expect(s.last.label, isNull);
      }

      check((await repo.loadNote(id))!);
      check((await repo.loadNote((await files.importBytes((await files.exportBytes(id))!)).noteId))!);

      // a change of the text alone is saved
      final back = (await repo.loadNote(id))!;
      back.strokes[0]!.first.label = label.copyWith(text: 'Window');
      await repo.saveNote(back);
      expect((await repo.loadNote(id))!.strokes[0]!.first.label!.text, 'Window');
      final gone = (await repo.loadNote(id))!;
      gone.strokes[0]!.first.label = null;
      await repo.saveNote(gone);
      expect((await repo.loadNote(id))!.strokes[0]!.first.label, isNull);

      final a = Replica('a'), b = Replica('b');
      final na = NoteData(id: 'n'), nb = NoteData(id: 'n');
      na.strokes[0] = [boxShape(label: label)];
      for (final op in a.localChanges(na)) {
        b.apply(nb, op, makeBox: (i) => TextBoxWidgetModel(id: i, position: Offset.zero), saveImage: (i, bytes, e) => '', onNoteField: (f, d) => Replica.applyNoteField(nb, f, d));
      }
      expect(nb.strokes[0]!.single.label, label);
    });
  });

  group('the dialog', () {
    Future<LabelEdit?> ask(WidgetTester tester, Future<void> Function() act, {StrokeLabel? initial, bool closed = false}) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      LabelEdit? got;
      var done = false;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              got = await showLabelDialog(context, initial: initial, lineColor: Colors.black, closed: closed);
              done = true;
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await act();
      expect(done, isTrue);
      return got;
    }

    Future<void> tap(WidgetTester tester, Key key) async {
      await tester.ensureVisible(find.byKey(key));
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
    }

    testWidgets('takes the words and how they are set', (tester) async {
      final got = await ask(tester, () async {
        expect(tester.widget<FilledButton>(find.byKey(const ValueKey('label-apply'))).onPressed, isNull, reason: 'no words yet');
        await tester.enterText(find.byKey(const ValueKey('label-text')), 'Main road');
        await tester.pump();
        await tap(tester, const ValueKey('label-align'));
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('label-align')), matching: find.text('End')));
        await tester.pump();
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('label-side')), matching: find.text('Below')));
        await tester.pump();
        await tap(tester, const ValueKey('label-bold'));
        await tap(tester, ValueKey('label-color-${Colors.green.toARGB32().toRadixString(16)}'));
        await tap(tester, const ValueKey('label-apply'));
      });
      final l = got!.label!;
      expect(l.text, 'Main road');
      expect(l.place, LabelPlace.along);
      expect(l.align, LabelAlign.end);
      expect(l.side, LabelSide.below);
      expect(l.bold, isTrue);
      expect(l.color, Colors.green);
    });

    testWidgets('a closed shape starts with the text inside, and the colour can be left to itself again', (tester) async {
      final got = await ask(tester, closed: true, () async {
        await tester.enterText(find.byKey(const ValueKey('label-text')), 'Kitchen');
        await tester.pump();
        await tap(tester, ValueKey('label-color-${Colors.green.toARGB32().toRadixString(16)}'));
        await tap(tester, const ValueKey('label-color-auto'));
        await tap(tester, const ValueKey('label-apply'));
      });
      expect(got!.label!.place, LabelPlace.inside);
      expect(got.label!.color, isNull);
    });

    testWidgets('shows the text there is, and can take it off', (tester) async {
      final got = await ask(tester, initial: const StrokeLabel(text: 'Old', size: 30), () async {
        expect(find.widgetWithText(TextField, 'Old'), findsOneWidget);
        await tap(tester, const ValueKey('label-remove'));
      });
      expect(got, isNotNull);
      expect(got!.label, isNull);
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

    testWidgets('a note with text on a line exports to a PDF that has the text, and to a picture that shows it', (tester) async {
      await open(tester, (n) {
        n.strokes[0] = [
          boxShape(from: const Offset(300, 300), label: const StrokeLabel(text: 'Hall', place: LabelPlace.inside, size: 40, color: Color(0xFF000000))),
          DrawingStroke(id: 'l', color: Colors.white, width: 2, points: const [Offset(100, 700), Offset(700, 700)], label: const StrokeLabel(text: 'Corridor', size: 40, color: Color(0xFF000000))),
        ];
      });
      final dir = Directory.systemTemp.createTempSync('labelexport');
      addTearDown(() => dir.deleteSync(recursive: true));
      final state = tester.state(find.byType(FixedPageNoteEditor)) as dynamic;
      String? problem = 'not run';
      var done = false;
      (state.exportPdfTo('${dir.path}/out.pdf') as Future<String?>).then((r) {
        problem = r;
        done = true;
      });
      for (var i = 0; i < 100 && !done; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(problem, isNull);
      final text = pdfContent(File('${dir.path}/out.pdf').readAsBytesSync());
      expect(text, contains('[(Hall)]TJ'), reason: 'inside the shape');
      expect(text, contains('[(C)]TJ'), reason: 'a letter of the one along the line');

      done = false;
      (state.exportImagesTo('${dir.path}/out.png') as Future<String?>).then((r) {
        problem = r;
        done = true;
      });
      for (var i = 0; i < 100 && !done; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(problem, isNull);
      final image = img.decodePng(File('${dir.path}/out.png').readAsBytesSync())!;
      var darkPixels = 0;
      for (var y = (650 * image.width / 800).round(); y < (700 * image.width / 800).round(); y++) {
        for (var x = 0; x < image.width; x++) {
          if (image.getPixel(x, y).r < 100) darkPixels++;
        }
      }
      expect(darkPixels, greaterThan(100), reason: 'the letters above the (white) line are in the picture');
    });

    testWidgets('a selected shape gets text from its button, which is saved with the note', (tester) async {
      await open(tester, (n) => n.strokes[0] = [boxShape(from: const Offset(300, 300))]);
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('label-selection')), findsNothing, reason: 'nothing is selected');
      await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
      await tester.pumpAndSettle();
      final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
      final left = (1600 - 57 - 800) / 2;
      Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
      final g = await tester.startGesture(at(280, 280), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      for (final p in [at(280, 280), at(520, 280), at(520, 420), at(280, 420), at(280, 285)]) {
        await g.moveTo(p);
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      expect(find.byKey(const ValueKey('label-selection')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('label-selection')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('label-text')), 'Hall');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('label-apply')));
      await tester.pumpAndSettle();

      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1300)));
      await tester.pump(const Duration(milliseconds: 1000));
      late NoteData n;
      await tester.runAsync(() async => n = (await repo.loadNote(id))!);
      final label = n.strokes[0]!.single.label;
      expect(label!.text, 'Hall');
      expect(label.place, LabelPlace.inside, reason: 'a closed shape: inside');
      expect(Feature.pathText.group, FeatureGroup.creative);
    });
  });
}
