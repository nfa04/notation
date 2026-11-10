import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/images/picture_edit.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/models/layers.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const sky = NoteLayer('sky', 'Sky');
const sea = NoteLayer('sea', 'Sea');

DrawingStroke line(String id, String layer, {double y = 100}) => DrawingStroke(
      id: id,
      color: Colors.black,
      width: 4,
      points: [Offset(60, y), Offset(300, y + 10), Offset(500, y)],
      layer: layer,
    );

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('the order of what is on a page', () {
    final three = LayerStack(const [sky, sea]);

    test('everything on one layer, or the lower layers\' pictures and the higher layers\' boxes, needs no ordering', () {
      expect(PageStacking(three, pictures: {0}, ink: {0}, boxes: {0}).isUsual, isTrue);
      expect(PageStacking(three, pictures: {0}, ink: {0, 1}, boxes: {2}).isUsual, isTrue, reason: 'pictures under lines under boxes');
      expect(PageStacking(three, pictures: {}, ink: {}, boxes: {}).isUsual, isTrue);
    });

    test('a picture of a higher layer is over the lines and boxes of a lower one, and the rest is put in order from there on', () {
      final s = PageStacking(three, pictures: {0, 1}, ink: {0, 2}, boxes: {0, 2});
      expect(s.parts.map((p) => (p.kind, p.layer)), [
        (StackKind.picture, 0), (StackKind.ink, 0), (StackKind.box, 0),
        (StackKind.picture, 1), (StackKind.ink, 2), (StackKind.box, 2),
      ]);
      expect(s.isUsual, isFalse);
      expect(s.usualCount, 3);
      expect(s.usualLayers(StackKind.picture), {0});
      expect(s.usualLayers(StackKind.ink), {0});
      expect(s.isUsualFor(StackKind.picture, 1), isFalse);
      expect(s.isUsualFor(StackKind.ink, 2), isFalse);
      expect(s.isUsualFor(StackKind.box, 0), isTrue);
    });

    test('a hidden layer takes no part', () {
      final hidden = LayerStack(const [NoteLayer('sky', 'Sky', visible: false), sea]); // (base, sky: hidden, sea)
      final s = PageStacking(hidden, pictures: {2}, ink: {0, 1}, boxes: {0});
      expect(s.parts.map((p) => (p.kind, p.layer)), [(StackKind.ink, 0), (StackKind.box, 0), (StackKind.picture, 2)]);
      expect(s.usualCount, 2);
    });

    test('lines can be asked for by layer', () {
      final strokes = [line('a', baseLayerId), line('b', 'sky'), line('c', 'sea'), line('d', 'gone')];
      final stack = LayerStack(const [sky, sea]);
      expect(stack.ordered(strokes, only: {1}).map((s) => s.id), ['b']);
      expect(stack.ordered(strokes, only: {0, 2}).map((s) => s.id), ['a', 'd', 'c'], reason: 'a line of a deleted layer is on the base layer');
      expect(stack.ordered(strokes).map((s) => s.id), ['a', 'd', 'b', 'c']);
    });
  });

  group('on the page', () {
    late Directory dir;

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('stacking');
        final file = File('${dir.path}/p.png')..writeAsBytesSync(encodePicture(RgbaPicture.filled(8, 8, 200, 30, 30)));
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote();
        final note = (await repo.loadNote(id))!;
        note.layers = LayerStack(const [sky, sea]);
        note.strokes[0] = [line('low', baseLayerId), line('mid', 'sky', y: 200), line('high', 'sea', y: 300)];
        note.textBoxes[0] = [
          TextBoxWidgetModel(id: 'bbase', position: const Offset(100, 400), size: const Size(200, 60), initialText: 'Base box'),
          TextBoxWidgetModel(id: 'bsea', position: const Offset(100, 500), size: const Size(200, 60), initialText: 'Sea box', layer: 'sea'),
        ];
        note.images[0] = [ImageItem(id: 'psky', path: file.path, position: const Offset(450, 100), size: const Size(100, 100), layer: 'sky')];
        await repo.saveNote(note);
      });
      addTearDown(() => dir.delete(recursive: true));
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    int at(WidgetTester tester, Finder f) => tester.allElements.toList().indexOf(f.evaluate().single);

    Iterable<InkLayerPainter> inkPainters(WidgetTester tester) =>
        tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((c) => c.painter).whereType<InkLayerPainter>();

    testWidgets('a picture on a higher layer lies over the lines of a lower one, and under those of a higher one', (tester) async {
      await open(tester);
      final painters = inkPainters(tester).toList();
      // the lines are in pieces: the lowest layer's (with the box of the base layer over them), then one for each of the others
      expect(painters.map((p) => p.only), [{0}, {1}, {2}]);
      final inks = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      final order = [for (final e in inks.evaluate()) tester.allElements.toList().indexOf(e)];
      final picture = at(tester, find.byKey(const ValueKey('image-pic-psky')));
      expect(order[0], lessThan(picture), reason: 'the base layer\'s lines are under the sky\'s picture');
      expect(picture, lessThan(order[1]), reason: 'the sky\'s lines are over it (the picture is first on its layer)');
      expect(order[1], lessThan(order[2]));
      expect(at(tester, find.text('Base box')), lessThan(picture), reason: 'a box of the base layer is under the picture of the sky');
      expect(at(tester, find.text('Sea box')), greaterThan(order[2]), reason: 'a box is over the lines of its layer');
    });
  });
}
