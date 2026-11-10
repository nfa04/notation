import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/export/svg_export.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/gradient.dart';
import 'package:notes/models/layers.dart';
import 'package:notes/models/stroke_label.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

DrawingStroke line({String id = 'a', Color color = const Color(0xFFFF0000), double width = 4, String layer = baseLayerId, String brush = penBrushId, StrokeDash dash = StrokeDash.solid}) =>
    DrawingStroke(id: id, color: color, width: width, points: [for (var i = 0; i <= 5; i++) Offset(10.0 + i * 20, 50)], layer: layer, brush: brush, dash: dash);

Future<String> svg(DrawingStroke s, {SvgDefs? defs, double sensitivity = 0.6}) => svgStroke(s, sensitivity: sensitivity, defs: defs ?? SvgDefs(), raster: (_) async => '<image id="picture"/>');

void main() {
  group('a line as SVG', () {
    test('a pen line is a path with its colour, width and round ends', () async {
      final out = await svg(line());
      expect(out, contains('<path d="M10 50L30 50L50 50L70 50L90 50L110 50"'));
      expect(out, contains('stroke="#ff0000"'));
      expect(out, contains('stroke-width="4"'));
      expect(out, contains('stroke-linecap="round"'));
      expect(out, isNot(contains('stroke-opacity')), reason: 'opaque: nothing to say');
      expect(out, isNot(contains('stroke-dasharray')));
    });

    test('see-through, dashed and dotted lines say so', () async {
      expect(await svg(line(color: const Color(0x80FF0000))), contains('stroke-opacity="0.5"'));
      expect(await svg(line(dash: StrokeDash.dashed)), contains('stroke-dasharray="14 10"'));
      expect(await svg(line(dash: StrokeDash.dotted)), contains('stroke-dasharray="0.1 8.8"'));
    });

    test('a closed shape has its fill under the line, a gradient is written once into the defs', () async {
      DrawingStroke box({FillGradient? g}) => DrawingStroke(color: Colors.black, width: 2, fill: const Color(0xFF00FF00), gradient: g, points: const [Offset(0, 0), Offset(100, 0), Offset(100, 50), Offset(0, 50), Offset(0, 0)]);
      final plain = await svg(box());
      expect(plain.indexOf('fill="#00ff00"'), lessThan(plain.indexOf('stroke="#000000"')));
      expect(plain, contains('Z"'), reason: 'the fill is closed');
      final defs = SvgDefs();
      final shaded = await svg(box(g: const FillGradient(end: Color(0xFF0000FF), angle: 0)), defs: defs);
      expect(shaded, contains('fill="url(#grad1)"'));
      expect(defs.toString(), contains('<linearGradient id="grad1"'));
      expect(defs.toString(), contains('stop-color="#0000ff"'));
    });

    test('a fill made by the bucket (no line of its own) is only a fill', () async {
      final fill = DrawingStroke(color: const Color(0x00000000), width: 1, fill: const Color(0xFFFF8800), points: const [Offset(0, 0), Offset(50, 0), Offset(50, 50), Offset(0, 0)]);
      final out = await svg(fill);
      expect(out, contains('fill="#ff8800"'));
      expect(out, isNot(contains('stroke=')));
    });

    test('a line drawn with pressure is an outline, thicker where it was pressed', () async {
      final s = line();
      s.pressures = [20, 60, 120, 200, 255, 255];
      final out = await svg(s);
      expect(out, contains('fill="#ff0000"'));
      expect(out, contains('A'), reason: 'round joints');
      expect(out, isNot(contains('stroke-width')));
    });

    test('a line with text along it is a picture of it', () async {
      final s = line();
      s.label = StrokeLabel(text: 'Hello');
      expect(await svg(s), '<image id="picture"/>');
    });
  });

  group('the page', () {
    test('layers are named groups with their opacity and blend mode, a hidden layer and an empty one are left out', () {
      final layers = LayerStack(const [NoteLayer(baseLayerId, 'Sketch'), NoteLayer('s', 'Shade & light', opacity: 0.5, blend: LayerBlend.multiply), NoteLayer('h', 'Hidden', visible: false), NoteLayer('e', 'Empty')]);
      final parts = {
        0: SvgLayerParts()..ink.add('<path id="one"/>'),
        1: SvgLayerParts()..ink.add('<path id="two"/>')..pictures.add('<image id="pic"/>'),
        2: SvgLayerParts()..ink.add('<path id="three"/>'),
      };
      final out = svgDocument(view: const Rect.fromLTWH(0, 0, 800, 1000), layers: layers, parts: parts, defs: SvgDefs(), behind: ['<rect id="paper"/>'], title: 'My <note>');
      expect(out, contains('viewBox="0 0 800 1000"'));
      expect(out, contains('<title>My &lt;note&gt;</title>'));
      expect(out, contains('inkscape:label="Sketch"'));
      expect(out, contains('inkscape:label="Shade &amp; light"'));
      expect(out, contains('opacity="0.5"'));
      expect(out, contains('style="mix-blend-mode:multiply"'));
      expect(out, isNot(contains('three')), reason: 'hidden');
      expect(out, isNot(contains('Empty')));
      expect(out.indexOf('id="paper"'), lessThan(out.indexOf('id="one"')));
      expect(out.indexOf('id="pic"'), lessThan(out.indexOf('id="two"')), reason: 'pictures under the lines of a layer');
      expect(out.indexOf('"one"'), lessThan(out.indexOf('"two"')), reason: 'the layers in order');
    });

    test('a group holds its layers, and a hidden group takes them with it', () {
      final layers = LayerStack(const [NoteLayer('g', 'Group', isGroup: true, opacity: 0.4), NoteLayer('a', 'A', group: 'g'), NoteLayer('b', 'B', group: 'g')]);
      final parts = {1: SvgLayerParts()..ink.add('<path id="a1"/>'), 2: SvgLayerParts()..ink.add('<path id="b1"/>')};
      final out = svgDocument(view: const Rect.fromLTWH(0, 0, 10, 10), layers: layers, parts: parts, defs: SvgDefs());
      expect(out.indexOf('inkscape:label="Group"'), lessThan(out.indexOf('inkscape:label="A"')));
      expect(out, contains('opacity="0.4"'));
      final hidden = svgDocument(view: const Rect.fromLTWH(0, 0, 10, 10), layers: layers.replaced(layers.layers[1].copyWith(visible: false)), parts: parts, defs: SvgDefs());
      expect(hidden, isNot(contains('a1')));
      expect(hidden, isNot(contains('b1')));
    });

    test('a picture is embedded with its place', () {
      expect(svgImage([1, 2, 3], 'image/png', const Rect.fromLTWH(10, 20, 30, 40)), allOf(contains('xlink:href="data:image/png;base64,AQID"'), contains('x="10" y="20" width="30" height="40"')));
    });
  });

  group('in the editor', () {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('svgexport'));
    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('the button saves the page: the paper, the lines as shapes, the layers as groups', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote();
        final NoteData note = (await repo.loadNote(id))!;
        note.layers = LayerStack(const [NoteLayer(baseLayerId, 'Ink'), NoteLayer('t', 'Colour')]);
        note.strokes[0] = [line(), line(id: 'b', color: const Color(0xFF0000FF), layer: 't')];
        await repo.saveNote(note);
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('export-svg-button')), findsOneWidget);

      String? problem = 'not run';
      var done = false;
      final state = tester.state(find.byType(FixedPageNoteEditor)) as dynamic;
      (state.exportSvgTo('${dir.path}/a.svg') as Future<String?>).then((r) {
        problem = r;
        done = true;
      });
      for (var i = 0; i < 200 && !done; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(done, isTrue);
      expect(problem, isNull);
      final text = File('${dir.path}/a.svg').readAsStringSync();
      expect(text, startsWith('<?xml'));
      final doc = XmlDocument.parse(text); // (well formed)
      expect(doc.rootElement.getAttribute('viewBox'), isNotNull);
      expect(text, contains('id="paper"'));
      expect(text, contains('inkscape:label="Ink"'));
      expect(text, contains('inkscape:label="Colour"'));
      expect(text, contains('stroke="#ff0000"'));
      expect(text, contains('stroke="#0000ff"'));
      expect(text.indexOf('#ff0000'), lessThan(text.indexOf('#0000ff')), reason: 'the layers in order');
    });
  });
}
