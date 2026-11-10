import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/brush_library.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/models/brush.dart';
import 'package:notes/models/brush_desc.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  tearDown(() => CustomBrushes.sync(const []));

  late NoteRepository repo;
  late String id;

  Future<void> open(WidgetTester tester, {FeatureSettings? features, String? drawnWith}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings'); // (an in-memory database is shared by the tests of a file)
      repo = NoteRepository(db);
      id = await repo.createNote();
      if (drawnWith != null) {
        final note = (await repo.loadNote(id))!;
        note.strokes[0] = [DrawingStroke(color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(50.0 + i * 10, 80.0)], brush: drawnWith)];
        await repo.saveNote(note);
      }
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, features: features)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
  }

  List<DrawingStroke> strokes() {
    final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
    return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('brush-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('brush-picker')));
    await tester.pumpAndSettle();
  }

  Future<void> later(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  testWidgets('a brush designed in the menu is saved, chosen, drawn with, and in the menu from then on', (tester) async {
    await open(tester);
    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('brush-design')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-preview')), findsOneWidget);

    // a roller, drier than usual, with a name
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('brush-kind')), matching: find.text('Roller')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('brush-name')), 'Dry wall');
    await tester.drag(find.byKey(const ValueKey('brush-knob-dryness')), const Offset(120, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('brush-save')));
    await later(tester);
    expect(find.byKey(const ValueKey('brush-preview')), findsNothing, reason: 'the dialog is closed');

    final made = CustomBrushes.all.single;
    expect(made.name, 'Dry wall');
    expect(made.kind, BrushKind.roller);
    expect(made['dryness'], greaterThan(0.3));
    expect(Brushes.isListed(made.id), isTrue);

    // the next line is drawn with it
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    final g = await tester.createGesture();
    await g.down(origin + const Offset(100, 100));
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(origin + Offset(100 + i * 30.0, 100 + i * 5.0));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(strokes().single.brush, made.id);
    expect(strokes().single.width, closeTo(3 * 5, 1e-9), reason: 'the width chosen (3), as thick as the roller makes it');

    // and it is in the menu
    await openMenu(tester);
    expect(find.byKey(ValueKey('brush-${made.id}')), findsOneWidget);
    expect(find.text('Dry wall'), findsOneWidget);
  });

  testWidgets('a brush that came with a note is not in the menu until the person adds it', (tester) async {
    await open(tester);
    final theirs = BrushDesc(BrushKind.soft, 'From a friend');
    await tester.runAsync(() => BrushLibrary(repo.settings).adopt([theirs]));
    await openMenu(tester);
    expect(find.byKey(ValueKey('brush-${theirs.id}')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('brush-design')));
    await tester.pumpAndSettle();
    await later(tester); // (the dialog reads the library once it is open)
    await tester.tap(find.byKey(const ValueKey('brush-from-notes')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('brush-design-${theirs.id}')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('brush-toggle-listed')));
    await tester.tap(find.byKey(const ValueKey('brush-toggle-listed')));
    await later(tester);
    expect(Brushes.isListed(theirs.id), isTrue);
    await tester.tap(find.byKey(const ValueKey('brush-close')));
    await tester.pumpAndSettle();
    await openMenu(tester);
    expect(find.byKey(ValueKey('brush-${theirs.id}')), findsOneWidget);
  });

  testWidgets('changing a brush that is kept makes a new brush; the old one stays for the lines drawn with it', (tester) async {
    await open(tester);
    final old = BrushDesc(BrushKind.ink, 'Liner', const {'width': 0.8});
    await tester.runAsync(() => BrushLibrary(repo.settings).save(old));
    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('brush-design')));
    await tester.pumpAndSettle();
    await later(tester);
    await tester.tap(find.byKey(ValueKey('brush-design-${old.id}')));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('brush-knob-width')), const Offset(150, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('brush-save')));
    await later(tester);
    expect(CustomBrushes.all.length, 2);
    expect(Brushes.byId(old.id), isNotNull, reason: 'lines drawn with it keep their look');
    expect(Brushes.isListed(old.id), isFalse);
    final next = CustomBrushes.all.firstWhere((d) => d.id != old.id);
    expect(next.name, 'Liner');
    expect(next['width'], greaterThan(0.8));
    expect(Brushes.isListed(next.id), isTrue);
  });

  testWidgets('a stamp brush is designed with the numbers typed in, the advanced numbers are under Advanced, and a brush that uses them opens it', (tester) async {
    await open(tester);
    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('brush-design')));
    await tester.pumpAndSettle();
    await later(tester);
    expect(find.byKey(const ValueKey('brush-advanced')), findsOneWidget, reason: 'the ink has advanced numbers too');
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('brush-kind')), matching: find.text('Stamp')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-knob-spacing')), findsOneWidget);
    expect(find.byKey(const ValueKey('brush-knob-hue')), findsNothing, reason: 'closed');
    await tester.enterText(find.byKey(const ValueKey('brush-knob-spacing-value')), '1.5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byKey(const ValueKey('brush-knob-spacing'))).value, 1.5);
    // a number out of range is brought into it
    await tester.enterText(find.byKey(const ValueKey('brush-knob-spacing-value')), '99');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byKey(const ValueKey('brush-knob-spacing'))).value, 3);
    await tester.enterText(find.byKey(const ValueKey('brush-knob-spacing-value')), '1.5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('brush-advanced')));
    await tester.tap(find.byKey(const ValueKey('brush-advanced')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-knob-hue')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('brush-knob-hue')));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('brush-knob-hue')), const Offset(120, 0));
    await tester.pumpAndSettle();
    // the shape is chosen from names, in steps
    await tester.ensureVisible(find.byKey(const ValueKey('brush-knob-shape')));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('brush-knob-shape')), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(find.text('Leaf'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('brush-name')), 'Confetti');
    await tester.tap(find.byKey(const ValueKey('brush-save')));
    await later(tester);

    final made = CustomBrushes.all.single;
    expect(made.kind, BrushKind.stamp);
    expect(made.name, 'Confetti');
    expect(made['spacing'], 1.5);
    expect(made['hue'], greaterThan(0));
    expect(made['shape'], 4);
    expect(Brushes.byId(made.id), isA<StampBrush>());

    // opened again, its advanced numbers are open
    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('brush-design')));
    await tester.pumpAndSettle();
    await later(tester);
    await tester.tap(find.byKey(ValueKey('brush-design-${made.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-knob-hue')), findsOneWidget);
  });

  testWidgets('a brush can be deleted from the library after the question; asking and then keeping it leaves it', (tester) async {
    await open(tester);
    final d = BrushDesc(BrushKind.ink, 'Short lived', const {'width': 0.7});
    await tester.runAsync(() => BrushLibrary(repo.settings).save(d));
    await openMenu(tester);
    expect(find.byKey(ValueKey('brush-${d.id}')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('brush-design')));
    await tester.pumpAndSettle();
    await later(tester);
    expect(find.byKey(const ValueKey('brush-delete')), findsNothing, reason: 'nothing is chosen yet');
    await tester.tap(find.byKey(ValueKey('brush-design-${d.id}')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('brush-delete')));
    await tester.tap(find.byKey(const ValueKey('brush-delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-delete-ask')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('brush-delete-no')));
    await tester.tap(find.byKey(const ValueKey('brush-delete-no')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-delete-ask')), findsNothing);
    expect(Brushes.byId(d.id), isNotNull);

    await tester.tap(find.byKey(const ValueKey('brush-delete')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('brush-delete-yes')));
    await tester.tap(find.byKey(const ValueKey('brush-delete-yes')));
    await later(tester);
    expect(Brushes.byId(d.id), isNull);
    expect(find.byKey(ValueKey('brush-design-${d.id}')), findsNothing);
    expect(find.byKey(const ValueKey('brush-message')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('brush-close')));
    await tester.pumpAndSettle();
    await openMenu(tester);
    expect(find.byKey(ValueKey('brush-${d.id}')), findsNothing);
  });

  testWidgets('a note with lines of a brush of an extension this device does not have says so, once; a known brush and the pen say nothing', (tester) async {
    await open(tester, drawnWith: 'ext:glitter-pack/sparkle');
    expect(find.byKey(const ValueKey('missing-extension-brush')), findsOneWidget);
    expect(find.textContaining('glitter-pack'), findsOneWidget);
  });

  testWidgets('no warning for a note drawn with the pen', (tester) async {
    await open(tester, drawnWith: penBrushId);
    expect(find.byKey(const ValueKey('missing-extension-brush')), findsNothing);
  });

  Future<void> openDesigner(WidgetTester tester) async {
    await open(tester);
    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('brush-design')));
    await tester.pumpAndSettle();
    await later(tester);
  }

  Future<void> show(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
  }

  testWidgets('the advanced numbers are under headings; a curve for the pen is switched on and dragged, and takes the place of the pressure numbers', (tester) async {
    await openDesigner(tester);
    await show(tester, find.byKey(const ValueKey('brush-advanced')));
    await tester.tap(find.byKey(const ValueKey('brush-advanced')));
    await tester.pumpAndSettle();
    for (final heading in ['Pen response', 'Shape', 'Colour', 'Line style', 'Blending']) {
      expect(find.byKey(ValueKey('brush-group-$heading')), findsOneWidget, reason: heading);
    }
    // (the pressure curve number is a slider; when the curve is on, the curve takes its place)
    expect(find.byKey(const ValueKey('brush-knob-pressureCurve')), findsOneWidget);
    expect(find.byKey(const ValueKey('brush-curve-pressure')), findsNothing);
    await show(tester, find.byKey(const ValueKey('brush-curve-pressure-on')));
    await tester.tap(find.byKey(const ValueKey('brush-curve-pressure-on')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-knob-pressureCurve')), findsNothing);
    expect(find.byKey(const ValueKey('brush-curve-pressure')), findsOneWidget);
    await show(tester, find.byKey(const ValueKey('brush-curve-pressure')));
    // (the middle point goes up)
    await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('brush-curve-pressure'))), const Offset(0, -30));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('brush-name')), 'Curvy');
    await tester.tap(find.byKey(const ValueKey('brush-save')));
    await later(tester);
    final made = CustomBrushes.all.single;
    expect(made['pressureAt50'], greaterThan(1.2));
    expect(made['pressureAt0'], 1, reason: 'it began as the response there was: a straight line at the width that is set');
    expect(made['pressureAt100'], 1);
    expect((Brushes.byId(made.id) as ParamBrush).params.pressurePoints, isNotNull);

    // opened again: the curve is there, and switching it off takes its numbers away
    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('brush-design')));
    await tester.pumpAndSettle();
    await later(tester);
    await tester.tap(find.byKey(ValueKey('brush-design-${made.id}')));
    await tester.pumpAndSettle();
    await show(tester, find.byKey(const ValueKey('brush-curve-pressure-on')));
    await tester.tap(find.byKey(const ValueKey('brush-curve-pressure-on')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-curve-pressure')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('brush-save')));
    await later(tester);
    expect(CustomBrushes.all.any((b) => b['pressureAt50'] != null && b.id != made.id), isFalse);
  });

  testWidgets('dashes show their gap only when there are dashes, and a shadow its distance only when there is a shadow', (tester) async {
    await openDesigner(tester);
    await show(tester, find.byKey(const ValueKey('brush-advanced')));
    await tester.tap(find.byKey(const ValueKey('brush-advanced')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-knob-dash')), findsOneWidget);
    expect(find.byKey(const ValueKey('brush-knob-dashGap')), findsNothing);
    expect(find.byKey(const ValueKey('brush-knob-shadowDistance')), findsNothing);
    expect(find.byKey(const ValueKey('brush-knob-outlineTone')), findsNothing);
    await show(tester, find.byKey(const ValueKey('brush-knob-dash')));
    await tester.drag(find.byKey(const ValueKey('brush-knob-dash')), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-knob-dashGap')), findsOneWidget);
    await show(tester, find.byKey(const ValueKey('brush-knob-shadow')));
    await tester.drag(find.byKey(const ValueKey('brush-knob-shadow')), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-knob-shadowDistance')), findsOneWidget);
    expect(find.byKey(const ValueKey('brush-knob-shadowBlur')), findsOneWidget);
    await show(tester, find.byKey(const ValueKey('brush-knob-outline')));
    await tester.drag(find.byKey(const ValueKey('brush-knob-outline')), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-knob-outlineTone')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('brush-save')));
    await later(tester);
    final made = CustomBrushes.all.single;
    expect(made['dash'], greaterThan(0));
    expect(made['shadow'], greaterThan(0));
    expect(made['outline'], greaterThan(0));
    // (and the preview drew all of it without a failure)
    expect(tester.takeException(), isNull);
  });

  testWidgets('a mix is made of two brushes chosen from the library and the starting ones, and is saved with them', (tester) async {
    await openDesigner(tester);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('brush-kind')), matching: find.text('Mix')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brush-part-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('brush-part-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('brush-knob-sizeB')), findsOneWidget);
    expect(find.byKey(const ValueKey('brush-advanced')), findsNothing, reason: 'a mix has no advanced numbers');
    // the second part: the stars
    await show(tester, find.byKey(const ValueKey('brush-part-1')));
    await tester.tap(find.byKey(const ValueKey('brush-part-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stars (Stamp)').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('brush-name')), 'Starry');
    await tester.tap(find.byKey(const ValueKey('brush-save')));
    await later(tester);
    final made = CustomBrushes.all.single;
    expect(made.kind, BrushKind.mix);
    expect(made.parts[0].kind, BrushKind.ink);
    expect(made.parts[1].kind, BrushKind.stamp);
    expect(made.parts[1].name, 'Stars');
    expect(Brushes.byId(made.id), isA<MixBrush>());
    expect(Brushes.isListed(made.id), isTrue);
  });

  testWidgets('a brush is copied as text and taken in from text, and saving a copy leaves the brush it was made from in the menu', (tester) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await openDesigner(tester);
    await tester.enterText(find.byKey(const ValueKey('brush-name')), 'Shared');
    await tester.drag(find.byKey(const ValueKey('brush-knob-taper')), const Offset(100, 0));
    await tester.pumpAndSettle();
    await show(tester, find.byKey(const ValueKey('brush-copy-code')));
    await tester.tap(find.byKey(const ValueKey('brush-copy-code')));
    await tester.pumpAndSettle();
    expect(clipboard, startsWith(BrushDesc.codePrefix));
    final copied = BrushDesc.fromCode(clipboard!);
    expect(copied.name, 'Shared');
    expect(copied['taper'], greaterThan(0));
    expect(CustomBrushes.all, isEmpty, reason: 'copying does not keep it');

    // another kind is in the designer now; the text brings the brush in, kept and in the menu
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('brush-kind')), matching: find.text('Roller')));
    await tester.pumpAndSettle();
    await show(tester, find.byKey(const ValueKey('brush-paste-code')));
    await tester.tap(find.byKey(const ValueKey('brush-paste-code')));
    await later(tester);
    expect(CustomBrushes.of(copied.id), copied);
    expect(Brushes.isListed(copied.id), isTrue);
    expect(find.byKey(const ValueKey('brush-knob-nibFlatness')), findsNothing);
    expect(find.byKey(const ValueKey('brush-knob-taper')), findsOneWidget, reason: 'the designer shows the brush that came in');

    // text that is not a brush says so, and takes in nothing
    clipboard = 'hello';
    await show(tester, find.byKey(const ValueKey('brush-paste-code')));
    await tester.tap(find.byKey(const ValueKey('brush-paste-code')));
    await later(tester);
    expect(find.byKey(const ValueKey('brush-message')), findsOneWidget);
    expect(CustomBrushes.all.length, 1);

    // a copy: change a number and save it as a brush of its own; both are in the menu
    await show(tester, find.byKey(const ValueKey('brush-save-copy')));
    await tester.tap(find.byKey(const ValueKey('brush-save-copy')));
    await later(tester);
    expect(CustomBrushes.all.length, 1, reason: 'the same numbers are the same brush');
    await tester.drag(find.byKey(const ValueKey('brush-knob-jitter')), const Offset(100, 0));
    await tester.pumpAndSettle();
    await show(tester, find.byKey(const ValueKey('brush-save-copy')));
    await tester.tap(find.byKey(const ValueKey('brush-save-copy')));
    await later(tester);
    expect(CustomBrushes.all.length, 2);
    expect(CustomBrushes.all.every((b) => Brushes.isListed(b.id)), isTrue, reason: 'the brush it was made from stays in the menu');
  });

  testWidgets('with the brush tools off there is no designer in the menu', (tester) async {
    final store = <String, String>{};
    final features = FeatureSettings((k) async => store[k], (k, v) async => store[k] = v);
    await features.apply({...FeaturePresets.everything}..removeAll([Feature.brushes]));
    await open(tester, features: features);
    await openMenu(tester);
    expect(find.byKey(const ValueKey('brush-design')), findsNothing);
  });
}
