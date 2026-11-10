import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/models/page_format.dart';
import 'package:notes/models/pdf_models.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:notes/export/image_export.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/layers.dart';
import 'package:notes/models/page_background.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/image_export_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DrawingStroke line({String id = 'l', Color color = const Color(0xFFFF0000), String? layer, double y = 200}) => DrawingStroke(
      id: id,
      color: color,
      width: 20,
      points: [Offset(100, y), Offset(700, y)],
      layer: layer ?? baseLayerId,
    );

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const a4 = Size(800, 800 * 297 / 210);

  group('the sizes', () {
    test('web and screen are that many pixels across, with the shape of the page', () {
      final web = planImage(ImagePreset.web, a4);
      expect((web.width, web.height), (1000, 1414));
      expect(web.page, const Rect.fromLTWH(0, 0, 1000, 1414));
      expect(web.scale, closeTo(1.25, 1e-9));
      expect(planImage(ImagePreset.screen, a4).width, 1600);
    });

    test('print is 300 dots to the inch: an A4 sheet is 2480 pixels across', () {
      final plan = planImage(ImagePreset.print, a4);
      expect(plan.width, 2480);
      expect(plan.height, closeTo(3508, 1));
      // a sheet twice as wide is twice the pixels
      expect(planImage(ImagePreset.print, const Size(1600, 800)).width, closeTo(4961, 1));
    });

    test('a picture of too many pixels is made smaller, with the same shape', () {
      final a3 = planImage(ImagePreset.print, const Size(1131, 1600)); // A3: 3508 × 4961 would be 17 million
      expect(a3.width * a3.height, lessThanOrEqualTo(maxImagePixels));
      expect(a3.height / a3.width, closeTo(1600 / 1131, 0.01));
      final small = planImage(ImagePreset.screen, a4, maxPixels: 100000);
      expect(small.width * small.height, lessThanOrEqualTo(100000));
    });

    test('the fixed sizes put the page in the middle, as big as it goes', () {
      final square = planImage(ImagePreset.square, a4);
      expect((square.width, square.height), (1080, 1080));
      expect(square.page.height, closeTo(1080, 1e-6), reason: 'a tall page fills the height');
      expect(square.page.center.dx, closeTo(540, 1e-6));
      expect(square.page.left, greaterThan(0));
      final slide = planImage(ImagePreset.slide, a4);
      expect((slide.width, slide.height), (1920, 1080));
      expect(slide.page.height, closeTo(1080, 1e-6));
      final tall = planImage(ImagePreset.tall, const Size(800, 400)); // a wide page fills the width
      expect((tall.width, tall.height), (1080, 1920));
      expect(tall.page.width, closeTo(1080, 1e-6));
      expect(tall.page.center.dy, closeTo(960, 1e-6));
    });

    test('a name for a file has nothing a file system refuses', () {
      expect(fileNameOf('Maths: week 3/4?'), 'Maths- week 3-4-');
      expect(fileNameOf('   '), 'Note');
      expect(fileNameOf('..'), 'Note');
      expect(fileNameOf('a  b'), 'a b');
      expect(fileNameOf('x' * 200).length, 80);
    });
  });

  group('drawn', () {
    Future<img.Image> picture(ImagePlan plan, void Function(ui.Canvas) paint, {ui.Color? around}) async {
      final bytes = await drawImage(plan, paint, around: around);
      return img.decodePng(bytes)!;
    }

    test('the picture has the size of the plan and what is drawn lies where the page is', () async {
      final plan = planImage(ImagePreset.square, const Size(100, 50)); // 1080 wide, 540 tall in the middle
      await Future(() {});
      final image = await picture(plan, (c) => c.drawRect(const Rect.fromLTWH(0, 0, 100, 50), ui.Paint()..color = const Color(0xFFFF0000)), around: Colors.white);
      expect((image.width, image.height), (1080, 1080));
      expect(image.getPixel(540, 540).r, 255);
      expect(image.getPixel(540, 540).g, 0, reason: 'red where the page is');
      expect(image.getPixel(540, 100).g, 255, reason: 'white above it');
    });

    test('what is round the page is see-through when it has no colour', () async {
      final plan = planImage(ImagePreset.square, const Size(100, 50));
      final image = await picture(plan, (c) => c.drawRect(const Rect.fromLTWH(0, 0, 100, 50), ui.Paint()..color = const Color(0xFFFF0000)));
      expect(image.getPixel(540, 100).a, 0);
      expect(image.getPixel(540, 540).a, 255);
    });

    test('nothing is drawn outside the page', () async {
      final plan = planImage(ImagePreset.square, const Size(100, 50));
      final image = await picture(plan, (c) => c.drawRect(const Rect.fromLTWH(-500, -500, 2000, 2000), ui.Paint()..color = const Color(0xFFFF0000)));
      expect(image.getPixel(540, 100).a, 0);
    });
  });

  group('the dialog', () {
    Future<ImageExportChoice?> ask(WidgetTester tester, {int pages = 3, Future<void> Function()? act}) async {
      ImageExportChoice? got;
      var done = false;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              got = await showImageExportDialog(context, pageSize: a4, pages: pages);
              done = true;
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await act?.call();
      await tester.ensureVisible(find.byKey(const ValueKey('export-images-go')));
      await tester.tap(find.byKey(const ValueKey('export-images-go')));
      await tester.pumpAndSettle();
      expect(done, isTrue);
      return got;
    }

    testWidgets('offers every size, with the pixels each makes, and starts on the screen size', (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final got = await ask(tester, act: () async {
        for (final p in ImagePreset.values) {
          expect(find.byKey(ValueKey('export-preset-${p.name}')), findsOneWidget);
        }
        expect(find.textContaining('1000 × 1414 px'), findsOneWidget);
        expect(find.textContaining('1080 × 1080 px'), findsWidgets);
      });
      expect(got!.preset, ImagePreset.screen);
      expect(got.allPages, isFalse);
      expect(got.seeThrough, isFalse);
    });

    testWidgets('takes the size, all the pages and a see-through background', (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final got = await ask(tester, act: () async {
        await tester.tap(find.byKey(const ValueKey('export-preset-print')));
        await tester.pump();
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('export-pages')), matching: find.textContaining('All 3')));
        await tester.pump();
        await tester.ensureVisible(find.byKey(const ValueKey('export-see-through')));
        await tester.tap(find.byKey(const ValueKey('export-see-through')));
        await tester.pump();
      });
      expect(got!.preset, ImagePreset.print);
      expect(got.allPages, isTrue);
      expect(got.seeThrough, isTrue);
    });

    testWidgets('a note of one page does not ask which pages', (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await ask(tester, pages: 1, act: () async {
        expect(find.byKey(const ValueKey('export-pages')), findsNothing);
      });
    });
  });

  group('in the editor', () {
    late NoteRepository repo;
    late String id;

    Future<void> open(WidgetTester tester, void Function(NoteData) fill, {bool settle = true}) async {
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
      // (a PDF keeps drawing its pages: there is no settling)
      settle ? await tester.pumpAndSettle() : await tester.pump(const Duration(milliseconds: 100));
    }

    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('imageexport'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<String?> export(WidgetTester tester, String name, {ImagePreset preset = ImagePreset.web, bool all = false, bool seeThrough = false}) async {
      String? problem = 'not run';
      var done = false;
      // (the pictures are drawn out of sight over a few frames: they have to be given)
      final state = tester.state(find.byType(FixedPageNoteEditor)) as dynamic;
      (state.exportImagesTo('${dir.path}/$name', preset: preset, allPages: all, seeThrough: seeThrough) as Future<String?>).then((r) {
        problem = r;
        done = true;
      });
      for (var i = 0; i < 200 && !done; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(done, isTrue, reason: 'the export finished');
      return problem;
    }

    img.Image read(String name) => img.decodePng(File('${dir.path}/$name').readAsBytesSync())!;

    testWidgets('an automation has every page saved as a picture in a folder, named after the note', (tester) async {
      await open(tester, (n) {
        n.title = 'Heaps: part 1';
        n.strokes[0] = [line()];
        n.strokes[1] = [line()];
      });
      String? said;
      final state = tester.state(find.byType(FixedPageNoteEditor)) as dynamic;
      (state.exportImagesInto(dir.path, ImagePreset.web) as Future<String>).then((r) => said = r);
      for (var i = 0; i < 200 && said == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(said, contains('Saved 2 pictures'));
      final names = dir.listSync().map((f) => f.path.split('/').last).toList()..sort();
      expect(names, ['Heaps- part 1-1.png', 'Heaps- part 1-2.png']);
      expect(read(names.first).width, 1000);
    });

    testWidgets('a page becomes a picture of the size: white paper, with its lines and the drawing on it', (tester) async {
      await open(tester, (n) {
        n.background = PageBackground.lines;
        n.strokes[0] = [line()];
      });
      expect(await export(tester, 'a.png'), isNull);
      final image = read('a.png');
      expect((image.width, image.height), (1000, 1414));
      // the line: red, 20 thick, at 200 units down = 250 pixels
      final on = image.getPixel(500, 250);
      expect((on.r, on.g, on.b, on.a), (255, 0, 0, 255));
      expect(image.getPixel(500, 300).r, greaterThan(240), reason: 'paper beside it');
      expect(image.getPixel(500, 300).g, greaterThan(240));
      expect(image.getPixel(500, 300).a, 255);
    });

    testWidgets('see-through leaves the paper and its lines out, and the drawing stays', (tester) async {
      await open(tester, (n) {
        n.background = PageBackground.lines;
        n.strokes[0] = [line()];
      });
      expect(await export(tester, 'b.png', seeThrough: true), isNull);
      final image = read('b.png');
      expect(image.getPixel(5, 5).a, 0);
      var ruled = 0;
      for (var y = 0; y < image.height; y++) {
        if (image.getPixel(30, y).a != 0) ruled++;
      }
      expect(ruled, 0, reason: 'no lines of the paper');
      expect(image.getPixel(500, 250).a, 255);
      expect(image.getPixel(500, 250).r, 255);
    });

    testWidgets('text boxes are drawn where they are, and a hidden layer is left out', (tester) async {
      await open(tester, (n) {
        n.layers = LayerStack(const [NoteLayer(baseLayerId, 'Base'), NoteLayer('h', 'Hidden', visible: false)]);
        n.strokes[0] = [line(), line(id: 'x', color: const Color(0xFF0000FF), layer: 'h', y: 600)];
        n.textBoxes[0] = [TextBoxWidgetModel(id: 't', position: const Offset(100, 400), initialText: 'Hello **world**')];
      });
      expect(await export(tester, 'c.png'), isNull);
      final image = read('c.png');
      // somewhere in the box (at 125..450 across, 500..560 down in pixels) there is dark text
      var dark = 0;
      for (var y = 500; y < 560; y++) {
        for (var x = 125; x < 450; x++) {
          if (image.getPixel(x, y).r < 100) dark++;
        }
      }
      expect(dark, greaterThan(20), reason: 'the text is there');
      // the hidden layer's blue line (at 600 units = 750 pixels) is not
      final p = image.getPixel(500, 750);
      expect((p.r, p.g, p.b), (255, 255, 255));
    });

    testWidgets('a picture on the page is drawn where it is, and the hidden layer\'s picture is not', (tester) async {
      final file = File('${dir.path}/green.png')..writeAsBytesSync(img.encodePng(img.fill(img.Image(width: 20, height: 20), color: img.ColorRgb8(0, 200, 0))));
      await open(tester, (n) {
        n.layers = LayerStack(const [NoteLayer(baseLayerId, 'Base'), NoteLayer('h', 'Hidden', visible: false)]);
        n.images[0] = [
          ImageItem(id: 'p', path: file.path, position: const Offset(100, 100), size: const Size(200, 100)),
          ImageItem(id: 'q', path: file.path, position: const Offset(100, 500), size: const Size(200, 100), layer: 'h'),
        ];
      });
      expect(await export(tester, 'e.png'), isNull);
      final image = read('e.png');
      final shown = image.getPixel(250, 190); // (200, 150) units
      expect((shown.r, shown.g, shown.b), (0, 200, 0));
      final hidden = image.getPixel(250, 690); // (200, 550) units
      expect((hidden.r, hidden.g, hidden.b), (255, 255, 255));
    });

    testWidgets('an infinite canvas becomes one picture of the part that has something on it', (tester) async {
      await open(tester, (n) {
        n.pageFormat = PageFormat.infinite;
        n.strokes[0] = [
          DrawingStroke(id: 'a', color: const Color(0xFFFF0000), width: 20, points: const [Offset(5000, 5000), Offset(5400, 5000)]),
        ];
      });
      expect(await export(tester, 'f.png'), isNull);
      final image = read('f.png');
      // the window is the drawing with a margin (and at least 400 × 300 units), 1000 pixels across
      expect(image.width, 1000);
      expect(image.height, inInclusiveRange(500, 900));
      var red = 0;
      for (var x = 0; x < image.width; x += 5) {
        for (var y = 0; y < image.height; y += 5) {
          final p = image.getPixel(x, y);
          if (p.r == 255 && p.g == 0 && p.b == 0) red++;
        }
      }
      expect(red, greaterThan(50), reason: 'the line is in the picture');
    });

    // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
    final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

    testWidgets('the page of an imported PDF is the paper, with the marks and the drawing over it', skip: !pdfium.existsSync(), (tester) async {
      Pdfrx.pdfiumModulePath = pdfium.absolute.path;
      late File pdf;
      await tester.runAsync(() async {
        final doc = pw.Document();
        doc.addPage(pw.Page(build: (_) => pw.Align(alignment: pw.Alignment.topLeft, child: pw.Text('MMMMMMMMMM', style: const pw.TextStyle(fontSize: 60)))));
        pdf = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());
      });
      await open(tester, (n) {
        n.pdfName = 'a.pdf';
        n.pdfPath = pdf.path;
        n.pdfPageCount = 1;
        n.highlights[0] = [PdfHighlight(rect: const Rect.fromLTRB(0, 400, 800, 500), color: const Color(0xFFFFFF00))];
        n.strokes[0] = [line(y: 700)];
      }, settle: false);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
      await tester.pump();
      expect(await export(tester, 'g.png'), isNull);
      final image = read('g.png');
      expect(image.width, 1000);
      var dark = 0;
      for (var y = 0; y < 250; y++) {
        for (var x = 0; x < image.width; x += 2) {
          if (image.getPixel(x, y).r < 80) dark++;
        }
      }
      expect(dark, greaterThan(200), reason: 'the text of the PDF is in the picture');
      final marked = image.getPixel(500, 560); // (400, 450) units: yellow over the white page
      expect((marked.r, marked.g, marked.b), (255, 255, 0));
      expect(image.getPixel(500, 875).g, 0, reason: 'the red line (700 units)');
    });

    testWidgets('more pages in a ZIP, one picture for each', (tester) async {
      await open(tester, (n) {
        n.strokes[0] = [line()];
        n.strokes[1] = [line(id: 'm')];
      });
      expect(await export(tester, 'd.zip', all: true, preset: ImagePreset.square), isNull);
      final zip = ZipDecoder().decodeBytes(File('${dir.path}/d.zip').readAsBytesSync());
      expect(zip.files.map((f) => f.name).toList(), hasLength(2));
      expect(zip.files.map((f) => f.name), everyElement(endsWith('.png')));
      for (final f in zip.files) {
        final image = img.decodePng(f.content)!;
        expect((image.width, image.height), (1080, 1080));
      }
      expect(zip.files.first.name, isNot(zip.files.last.name));
    });

    testWidgets('the button is there, and goes with the feature', (tester) async {
      await open(tester, (n) {});
      expect(find.byKey(const ValueKey('export-images-button')), findsOneWidget);
      expect(Feature.exportImages.group, FeatureGroup.creative);
    });
  });
}
