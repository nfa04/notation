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
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/image_item.dart';
import 'package:notes/models/layers.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const sky = NoteLayer('sky', 'Sky');

TextBoxWidgetModel box(String id, String text, Offset at, {String layer = baseLayerId}) =>
    TextBoxWidgetModel(id: id, position: at, size: const Size(200, 60), initialText: text, layer: layer);

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('kept with the note', () {
    test('the layer of a text box and of a picture is saved and comes back', () async {
      final dir = await Directory.systemTemp.createTemp('layeritems');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/p.png')..writeAsBytesSync(encodePicture(RgbaPicture.filled(4, 4, 1, 2, 3)));
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.layers = LayerStack(const [sky]);
      note.textBoxes[0] = [box('a', 'one', Offset.zero, layer: 'sky'), box('b', 'two', const Offset(0, 80))];
      note.images[0] = [
        ImageItem(id: 'p1', path: file.path, position: Offset.zero, size: const Size(10, 10), layer: 'sky'),
        ImageItem(id: 'p2', path: file.path, position: const Offset(0, 20), size: const Size(10, 10)),
      ];
      await repo.saveNote(note);
      final back = (await repo.loadNote(id))!;
      expect({for (final b in back.textBoxes[0]!) b.id: b.layer}, {'a': 'sky', 'b': baseLayerId});
      expect({for (final m in back.images[0]!) m.id: m.layer}, {'p1': 'sky', 'p2': baseLayerId});
    });

    test('a whole note exported and imported again keeps them', () async {
      final dir = await Directory.systemTemp.createTemp('layeritemsfile');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/p.png')..writeAsBytesSync(encodePicture(RgbaPicture.filled(4, 4, 1, 2, 3)));
      final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      final files = NoteFileService(repo, supportDirectory: () async => dir);
      final id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.layers = LayerStack(const [sky]);
      note.textBoxes[0] = [box('a', 'one', Offset.zero, layer: 'sky')];
      note.images[0] = [ImageItem(id: 'p1', path: file.path, position: Offset.zero, size: const Size(10, 10), layer: 'sky')];
      await repo.saveNote(note);
      final copy = (await repo.loadNote((await files.importBytes((await files.exportBytes(id))!)).noteId))!;
      expect(copy.textBoxes[0]!.single.layer, 'sky');
      expect(copy.images[0]!.single.layer, 'sky');
    });

    test('devices share the layer of boxes and pictures, and moving one to another layer is a change to send', () async {
      final dir = await Directory.systemTemp.createTemp('layeritemssync');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/p.png')..writeAsBytesSync(encodePicture(RgbaPicture.filled(4, 4, 1, 2, 3)));
      final a = Replica('a'), b = Replica('b');
      final na = NoteData(id: 'n'), nb = NoteData(id: 'n');
      na.layers = LayerStack(const [sky]);
      na.textBoxes[0] = [box('x', 'hello', Offset.zero, layer: 'sky')];
      na.images[0] = [ImageItem(id: 'y', path: file.path, position: Offset.zero, size: const Size(10, 10), layer: 'sky')];
      void send(Replica from, NoteData of, Replica to, NoteData into) {
        for (final op in from.localChanges(of)) {
          to.apply(into, op, makeBox: (i) => TextBoxWidgetModel(id: i, position: Offset.zero), saveImage: (i, bytes, e) => file.path, onNoteField: (f, d) => Replica.applyNoteField(into, f, d));
        }
      }

      send(a, na, b, nb);
      expect(nb.textBoxes[0]!.single.layer, 'sky');
      expect(nb.images[0]!.single.layer, 'sky');
      expect(b.localChanges(nb), isEmpty);
      na.textBoxes[0]!.single.layer = baseLayerId;
      na.images[0]!.single.layer = baseLayerId;
      send(a, na, b, nb);
      expect(nb.textBoxes[0]!.single.layer, baseLayerId);
      expect(nb.images[0]!.single.layer, baseLayerId);
    });
  });

  group('in the editor', () {
    late NoteRepository repo;
    late String id;
    late Directory dir;

    Future<void> open(WidgetTester tester, {LayerStack? layers}) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('layeritemsui');
        final file = File('${dir.path}/p.png')..writeAsBytesSync(encodePicture(RgbaPicture.filled(8, 8, 200, 30, 30)));
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote();
        final note = (await repo.loadNote(id))!;
        note.layers = layers ?? LayerStack(const [sky]);
        note.textBoxes[0] = [box('bsky', 'On the sky', const Offset(100, 100), layer: 'sky'), box('bbase', 'On the base', const Offset(100, 300))];
        note.images[0] = [
          ImageItem(id: 'psky', path: file.path, position: const Offset(450, 100), size: const Size(100, 100), layer: 'sky'),
          ImageItem(id: 'pbase', path: file.path, position: const Offset(450, 300), size: const Size(100, 100)),
        ];
        await repo.saveNote(note);
      });
      addTearDown(() => dir.delete(recursive: true));
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    Future<void> openLayers(WidgetTester tester) async {
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('layers-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('layers-button')));
      await tester.pumpAndSettle();
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    Future<void> settleSave(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pumpAndSettle();
    }

    testWidgets('a hidden layer hides its boxes and pictures, and showing it brings them back', (tester) async {
      await open(tester);
      expect(find.text('On the sky'), findsOneWidget);
      expect(find.byKey(const ValueKey('image-pic-psky')), findsOneWidget);
      await openLayers(tester);
      await tapKey(tester, 'layer-visible-sky');
      await tapKey(tester, 'layers-close');
      expect(find.text('On the sky'), findsNothing);
      expect(find.byKey(const ValueKey('image-pic-psky')), findsNothing);
      expect(find.text('On the base'), findsOneWidget, reason: 'the base layer is as it was');
      expect(find.byKey(const ValueKey('image-pic-pbase')), findsOneWidget);
      await openLayers(tester);
      await tapKey(tester, 'layer-visible-sky');
      await tapKey(tester, 'layers-close');
      expect(find.text('On the sky'), findsOneWidget);
      expect(find.byKey(const ValueKey('image-pic-psky')), findsOneWidget);
      await settleSave(tester);
    });

    testWidgets('a locked layer\'s picture has nothing to take hold of, a see-through layer fades its boxes and pictures', (tester) async {
      await open(tester);
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('image-ctl-psky')), findsOneWidget);
      expect(find.byKey(const ValueKey('image-ctl-pbase')), findsOneWidget);
      await openLayers(tester);
      await tapKey(tester, 'layer-lock-sky');
      await tapKey(tester, 'layer-sky');
      await tester.drag(find.byKey(const ValueKey('layer-opacity')), const Offset(-120, 0));
      await tester.pumpAndSettle();
      await tapKey(tester, 'layers-close');
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('image-ctl-psky')), findsNothing, reason: 'locked');
      expect(find.byKey(const ValueKey('image-ctl-pbase')), findsOneWidget);
      expect(find.byKey(const ValueKey('image-pic-psky')), findsOneWidget, reason: 'but it is still to be seen');
      double opacityAround(Finder f) => tester.widgetList<Opacity>(find.ancestor(of: f, matching: find.byType(Opacity))).map((o) => o.opacity).fold(1.0, (a, b) => a * b);
      double opacityWithin(Finder f) => tester.widgetList<Opacity>(find.descendant(of: f, matching: find.byType(Opacity))).map((o) => o.opacity).fold(1.0, (a, b) => a * b);
      expect(opacityWithin(find.byKey(const ValueKey('image-pic-psky'))), lessThan(0.95));
      expect(opacityAround(find.text('On the sky')), lessThan(0.95));
      expect(opacityWithin(find.byKey(const ValueKey('image-pic-pbase'))), 1);
      expect(opacityAround(find.text('On the base')), 1);
      await settleSave(tester);
    });

    testWidgets('the lasso leaves out a locked layer\'s boxes and pictures, and takes the rest; they can then be moved to a layer in one step', (tester) async {
      await open(tester, layers: LayerStack(const [NoteLayer('sky', 'Sky', locked: true), NoteLayer('sea', 'Sea')]));
      await tester.tap(find.text('Draw'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
      await tester.pumpAndSettle();
      final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
      final left = (1600 - 57 - 800) / 2;
      Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
      // around everything on the page
      final lasso = await tester.startGesture(at(60, 60), kind: PointerDeviceKind.touch);
      for (final p in [at(60, 60), at(600, 60), at(600, 450), at(60, 450), at(60, 65)]) {
        await lasso.moveTo(p);
        await tester.pump();
      }
      await lasso.up();
      await tester.pump();

      // (the page is not too long for this to be one selection: what is selected is what the layers' panel offers to move)
      await tester.ensureVisible(find.byKey(const ValueKey('layers-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('layers-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('layer-menu-sea')));
      await tester.pumpAndSettle();
      expect(find.text('Move the selected drawings here'), findsOneWidget);
      await tester.tap(find.text('Move the selected drawings here'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'layers-close');
      await settleSave(tester);

      final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
      final boxes = {for (final b in saved.textBoxes[0]!) b.id: b.layer};
      final images = {for (final m in saved.images[0]!) m.id: m.layer};
      expect(boxes['bsky'], 'sky', reason: 'locked: not taken by the lasso');
      expect(images['psky'], 'sky');
      expect(boxes['bbase'], 'sea');
      expect(images['pbase'], 'sea');

      // one step takes both back
      await tester.tap(find.byKey(const ValueKey('undo-any')));
      await tester.pumpAndSettle();
      await settleSave(tester);
      final undone = (await tester.runAsync(() => repo.loadNote(id)))!;
      expect({for (final b in undone.textBoxes[0]!) b.id: b.layer}['bbase'], baseLayerId);
      expect({for (final m in undone.images[0]!) m.id: m.layer}['pbase'], baseLayerId);
    });

    testWidgets('a new text box is put on the layer being drawn on, and refused on a hidden one', (tester) async {
      await open(tester);
      await openLayers(tester);
      await tapKey(tester, 'layer-sky'); // draw on it
      await tapKey(tester, 'layers-close');
      // three quick clicks of the mouse make a text box where they are
      final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
      for (var i = 0; i < 3; i++) {
        final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await g.down(origin + const Offset(300, 600));
        await g.up();
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pumpAndSettle();
      await settleSave(tester);
      final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
      final fresh = saved.textBoxes[0]!.where((b) => b.id != 'bsky' && b.id != 'bbase').toList();
      expect(fresh.length, 1);
      expect(fresh.single.layer, 'sky');

      // hide the layer it is on: another box is refused, with the hint
      await openLayers(tester);
      await tapKey(tester, 'layer-visible-sky');
      await tapKey(tester, 'layers-close');
      for (var i = 0; i < 3; i++) {
        final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await g.down(origin + const Offset(300, 700));
        await g.up();
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('layer-blocked')), findsOneWidget);
      await settleSave(tester);
    });
  });
}
