import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/layers.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late NoteRepository repo;
  late String id;

  Future<void> open(WidgetTester tester, {LayerStack? layers, List<DrawingStroke> strokes = const []}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      if (layers != null) note.layers = layers;
      if (strokes.isNotEmpty) note.strokes[0] = strokes;
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
  }

  List<DrawingStroke> strokes() {
    final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
    return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
  }

  Future<void> drag(WidgetTester tester, Offset from, Offset to) async {
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    final g = await tester.createGesture();
    await g.down(origin + from);
    for (var i = 1; i <= 12; i++) {
      await g.moveTo(origin + Offset.lerp(from, to, i / 12)!);
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  Future<void> openLayers(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('layers-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('layers-button')));
    await tester.pumpAndSettle();
  }

  Future<void> done(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('layers-close')));
    await tester.pumpAndSettle();
  }

  Future<void> settleSave(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
  }

  const sky = NoteLayer('sky', 'Sky');

  testWidgets('a layer is added from the panel, new lines are drawn on it, and it is kept with the note', (tester) async {
    await open(tester);
    await openLayers(tester);
    expect(find.byKey(const ValueKey('layer-row-')), findsOneWidget, reason: 'the base layer is the only one');
    await tester.tap(find.byKey(const ValueKey('layer-add')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Layer 2'), findsOneWidget);
    await done(tester);

    await drag(tester, const Offset(100, 100), const Offset(400, 160));
    final s = strokes().single;
    expect(s.layer, isNot(baseLayerId));
    await settleSave(tester);
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
    expect(saved.layers.length, 2);
    expect(saved.strokes[0]!.single.layer, s.layer);
  });

  testWidgets('drawing on a hidden or locked layer is refused with a hint that offers the panel', (tester) async {
    await open(tester, layers: LayerStack(const [NoteLayer('sky', 'Sky', visible: false)]));
    await openLayers(tester);
    await tester.tap(find.byKey(const ValueKey('layer-sky')));
    await tester.pumpAndSettle();
    await done(tester);
    await drag(tester, const Offset(100, 100), const Offset(400, 160));
    expect(strokes(), isEmpty);
    expect(find.byKey(const ValueKey('layer-blocked')), findsOneWidget);
    expect(find.textContaining('hidden'), findsOneWidget);

    // show it, lock it: a different hint
    await openLayers(tester);
    await tester.tap(find.byKey(const ValueKey('layer-visible-sky')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('layer-lock-sky')));
    await tester.pumpAndSettle();
    await done(tester);
    await drag(tester, const Offset(100, 100), const Offset(400, 160));
    expect(strokes(), isEmpty);
    expect(find.textContaining('locked'), findsOneWidget);

    // unlock: drawing works
    await openLayers(tester);
    await tester.tap(find.byKey(const ValueKey('layer-lock-sky')));
    await tester.pumpAndSettle();
    await done(tester);
    await drag(tester, const Offset(100, 100), const Offset(400, 160));
    expect(strokes().single.layer, 'sky');
    await settleSave(tester);
  });

  testWidgets('the eraser leaves what is on a locked layer, and what is on a hidden layer, and takes the rest', (tester) async {
    final a = DrawingStroke(id: 'base', color: Colors.black, width: 4, points: [for (var i = 0; i <= 10; i++) Offset(100.0 + i * 20, 200)]);
    final b = DrawingStroke(id: 'locked', color: Colors.black, width: 4, points: [for (var i = 0; i <= 10; i++) Offset(100.0 + i * 20, 300)], layer: 'sky');
    final c = DrawingStroke(id: 'hid', color: Colors.black, width: 4, points: [for (var i = 0; i <= 10; i++) Offset(100.0 + i * 20, 400)], layer: 'gone');
    await open(tester, layers: LayerStack(const [sky, NoteLayer('gone', 'Gone', visible: false)]).replaced(sky.copyWith(locked: true)), strokes: [a, b, c]);
    final eraser = find.byIcon(Icons.auto_fix_normal_outlined);
    await tester.ensureVisible(eraser.first);
    await tester.pumpAndSettle();
    await tester.tap(eraser.first);
    await tester.pumpAndSettle();
    for (final y in [200.0, 300.0, 400.0]) {
      await drag(tester, Offset(100, y), Offset(300, y));
    }
    expect({for (final s in strokes()) s.id}, {'locked', 'hid'}, reason: 'only the line on the open layer went');
    await settleSave(tester);
  });

  testWidgets('the selected drawings move onto another layer in one step, which can be taken back', (tester) async {
    final line = DrawingStroke(id: 'l', color: Colors.black, width: 4, points: [for (var i = 0; i <= 10; i++) Offset(100.0 + i * 20, 200)]);
    await open(tester, layers: LayerStack(const [sky]), strokes: [line]);
    // a short tap with a pen picks the drawing under it
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.down(origin + const Offset(200, 200));
    await g.up();
    await tester.pumpAndSettle();

    await openLayers(tester);
    await tester.tap(find.byKey(const ValueKey('layer-menu-sky')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move the selected drawings here'));
    await tester.pumpAndSettle();
    await done(tester);
    expect(strokes().single.layer, 'sky');

    await tester.drag(find.byKey(const ValueKey('layers-button')), const Offset(0, 900));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('undo-button')));
    await tester.pumpAndSettle();
    expect(strokes().single.layer, baseLayerId);
    await settleSave(tester);
  });

  testWidgets('a change to the layers can be taken back', (tester) async {
    await open(tester);
    await openLayers(tester);
    await tester.tap(find.byKey(const ValueKey('layer-add')));
    await tester.pumpAndSettle();
    await done(tester);
    await tester.pump(const Duration(seconds: 1)); // (the change is noticed a moment after it)
    await tester.tap(find.byKey(const ValueKey('undo-any'))); // (the one in the top bar follows the undo state)
    await tester.pumpAndSettle();
    await openLayers(tester);
    expect(find.byKey(const ValueKey('layer-row-')), findsOneWidget);
    expect(find.textContaining('Layer 2'), findsNothing);
    await done(tester);
    await settleSave(tester);
  });

  testWidgets('on a wide screen the layers stand beside the note and stay open while drawing; the button shuts them', (tester) async {
    await open(tester);
    await openLayers(tester);
    expect(find.byKey(const ValueKey('layers-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('layers-done')), findsNothing, reason: 'a panel, not a dialog');
    await tester.tap(find.byKey(const ValueKey('layer-add')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Layer 2'), findsOneWidget);

    // no dialog in the way: the pen draws on the new layer with the panel still open
    await drag(tester, const Offset(100, 100), const Offset(400, 160));
    expect(strokes().single.layer, isNot(baseLayerId));
    expect(find.byKey(const ValueKey('layers-panel')), findsOneWidget);

    // the panel can be made narrower or wider with the bar between it and the note
    final before = tester.getSize(find.byKey(const ValueKey('layers-panel'))).width;
    await tester.drag(find.byKey(const ValueKey('layers-resize')), const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('layers-panel'))).width, before + 60);

    await tester.tap(find.byKey(const ValueKey('layers-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('layers-panel')), findsNothing);
    await settleSave(tester);
  });

  testWidgets('on a narrow screen the layers are still a dialog', (tester) async {
    await open(tester);
    tester.view.physicalSize = const Size(800, 1000);
    await tester.pumpAndSettle();
    await openLayers(tester);
    expect(find.byKey(const ValueKey('layers-panel')), findsNothing);
    expect(find.byKey(const ValueKey('layers-done')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('layers-done')));
    await tester.pumpAndSettle();
    await settleSave(tester);
  });

  testWidgets('only one panel stands beside the note: the search and the layers take each other\'s place', (tester) async {
    await open(tester);
    await openLayers(tester);
    expect(find.byKey(const ValueKey('layers-panel')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('layers-panel')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('layers-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('layers-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('find-panel')), findsNothing);
    await settleSave(tester);
  });

  testWidgets('the panel sets a blend mode and a clip on the chosen layer, and puts layers in a group that folds away', (tester) async {
    await open(tester, layers: LayerStack(const [NoteLayer('sky', 'Sky'), NoteLayer('sea', 'Sea')]));
    await openLayers(tester);
    // the layer drawn on is the base one: choose Sea, then its blend mode
    await tester.tap(find.byKey(const ValueKey('layer-sea')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('layer-blend')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('layer-blend-multiply')).last, warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('layer-clip')));
    await tester.pumpAndSettle();

    // Sea into a new group; the group row shows, and folding hides Sea
    await tester.tap(find.byKey(const ValueKey('layer-menu-sea')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('layer-new-group-sea')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Group 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('layer-row-sea')), findsOneWidget);
    final fold = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('group-fold-'));
    await tester.tap(fold);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('layer-row-sea')), findsNothing, reason: 'folded away');
    await tester.tap(fold);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('layer-row-sea')), findsOneWidget);

    await settleSave(tester);
    final note = (await tester.runAsync(() => repo.loadNote(id)))!;
    final sea = note.layers.layers.firstWhere((l) => l.id == 'sea');
    expect(sea.blend, LayerBlend.multiply);
    expect(sea.clip, isTrue);
    expect(sea.group, isNotEmpty);
    expect(note.layers.layers.where((l) => l.isGroup), hasLength(1));
  });
}
