import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/stamps.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String dir;
  _Paths(this.dir);

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

DrawingStroke line(Offset a, Offset b, {Color color = Colors.red, String layer = baseLayerId}) =>
    DrawingStroke(color: color, width: 4, points: [a, Offset.lerp(a, b, 0.5)!, b], layer: layer);

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('a stamp', () {
    test('is moved to the corner, copied without links, and put again as new lines of any size at any place', () {
      final original = [line(const Offset(100, 200), const Offset(160, 200)), line(const Offset(130, 190), const Offset(130, 260), layer: 'sky')];
      final stamp = Stamp.of('s', 'Cross', original);
      expect(stamp.bounds.topLeft, Offset.zero);
      expect(stamp.bounds.size, const Size(60, 70));
      expect(stamp.strokes.every((s) => s.link == null && s.layer == baseLayerId), isTrue);
      expect(original.first.points.first, const Offset(100, 200), reason: 'the drawing it was made from is left as it is');
      final put = stamp.placed(const Offset(300, 50), scale: 2, author: 'Noel', layer: 'sea');
      expect(put.map((s) => s.id).toSet().length, 2);
      expect(put.every((s) => s.id != stamp.strokes.first.id && s.layer == 'sea' && s.author == 'Noel'), isTrue);
      expect(put.first.points.first, const Offset(300, 70), reason: 'the stamp\'s box starts at its top, where the vertical line is: this one begins 10 below that, doubled');
      expect(put.first.points.last, const Offset(420, 70));
      expect(put.first.width, 8);
      expect(stamp.strokes.first.points.last, const Offset(60, 10), reason: 'the stamp itself does not change');
    });

    test('is kept in a file, with its name and lines, and taken out again', () async {
      final dir = await Directory.systemTemp.createTemp('stamplib');
      addTearDown(() => dir.delete(recursive: true));
      final library = StampLibrary(() async => dir);
      expect(await library.load(), isEmpty);
      await library.add(Stamp.of('a', 'First', [line(const Offset(0, 0), const Offset(10, 10))]));
      await library.add(Stamp.of('b', 'Second', [line(const Offset(5, 5), const Offset(50, 5), color: Colors.blue)]));
      final back = await library.load();
      expect(back.map((s) => (s.id, s.name)), [('a', 'First'), ('b', 'Second')]);
      expect(back.last.strokes.single.color.toARGB32(), Colors.blue.toARGB32());
      expect(back.last.strokes.single.points.last, const Offset(45, 0));
      await library.rename('a', 'Renamed');
      await library.remove('b');
      expect((await library.load()).map((s) => s.name), ['Renamed']);
      File('${dir.path}/stamps.json').writeAsStringSync('not json');
      expect(await library.load(), isEmpty, reason: 'a damaged file is no stamps');
    });
  });

  testWidgets('selected drawings are saved as a stamp and put on the page from the library, which can be taken back', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('stampui');
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.strokes[0] = [line(const Offset(100, 200), const Offset(200, 200)), line(const Offset(150, 150), const Offset(150, 250))];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    PathProviderPlatform.instance = _Paths(dir.path);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    Future<void> work() async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    List<DrawingStroke> strokes() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      return {for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes}.toList();
    }

    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'));
    await tester.pumpAndSettle();
    final pageTop = tester.getTopLeft(find.byType(CustomScrollView));
    final left = (1600 - 57 - 800) / 2;
    Offset at(double x, double y) => Offset(left + x, pageTop.dy + 16 + y);
    final lasso = await tester.startGesture(at(60, 100), kind: PointerDeviceKind.touch);
    for (final p in [at(60, 100), at(300, 100), at(300, 320), at(60, 320), at(60, 105)]) {
      await lasso.moveTo(p);
      await tester.pump();
    }
    await lasso.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('save-stamp')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('stamp-name')), 'Plus');
    await tester.tap(find.byKey(const ValueKey('stamp-save')));
    await work();
    expect(File('${dir.path}/stamps.json').existsSync(), isTrue);

    await tester.tap(find.byKey(const ValueKey('stamps')));
    await work();
    expect(find.byKey(const ValueKey('stamps-panel')), findsOneWidget, reason: 'beside the page, not a dialog over it');
    expect(find.text('Plus'), findsOneWidget);
    await tester.tap(find.byWidgetPredicate((w) => w is InkWell && w.key.toString().contains("'stamp-")));
    await tester.pumpAndSettle();
    expect(strokes().length, 4, reason: 'two lines more');
    expect(find.byKey(const ValueKey('stamps-panel')), findsOneWidget, reason: 'the library stays open for the next stamp');
    expect(strokes().where((s) => s.points.first.dx < 90).length, 0, reason: 'they are in the middle of the page, not on the first two');

    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    expect(strokes().length, 2);
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
  });
}
