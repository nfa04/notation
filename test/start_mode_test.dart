import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/painters/canvas_painters.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A new blank note opens ready to write when a pen has been used on the device, a note opens in the mode it was left in, and
/// a two-finger tap takes the last line back.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late NoteRepository repo;
  late String id;

  Future<void> open(WidgetTester tester, {Map<String, String> settings = const {}}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings');
      repo = NoteRepository(db);
      id = await repo.createNote();
      for (final e in settings.entries) {
        await repo.settings.set(e.key.replaceAll('<id>', id), e.value);
      }
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  final drawBar = find.byKey(const ValueKey('brush-picker'));

  testWidgets('with no pen seen and nothing remembered a note opens in Select', (tester) async {
    await open(tester);
    expect(drawBar, findsNothing);
  });

  testWidgets('once a pen has been used a blank note opens in Draw', (tester) async {
    await open(tester, settings: {'pen_seen': '1'});
    expect(drawBar, findsOneWidget);
  });

  testWidgets('a note opens in the mode it was left in, whatever the pen did', (tester) async {
    await open(tester, settings: {'note_mode_<id>': 'draw'});
    expect(drawBar, findsOneWidget);
    await open(tester, settings: {'pen_seen': '1', 'note_mode_<id>': 'select'});
    expect(drawBar, findsNothing);
  });

  testWidgets('the first touch of a pen switches an empty note to Draw', (tester) async {
    await open(tester);
    expect(drawBar, findsNothing);
    final page = tester.getCenter(find.byKey(const ValueKey('page-0')));
    final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await g.down(page);
    await g.up();
    await tester.pumpAndSettle();
    expect(drawBar, findsOneWidget);
  });

  testWidgets('Undo and Redo are in the title bar, not in the drawing tools', (tester) async {
    await open(tester, settings: {'pen_seen': '1'});
    expect(find.byKey(const ValueKey('undo-any')), findsOneWidget);
    expect(find.byKey(const ValueKey('redo-any')), findsOneWidget);
    expect(find.byKey(const ValueKey('undo-button')), findsNothing);
  });

  testWidgets('a two-finger tap takes the last line back, a two-finger drag does not', (tester) async {
    await open(tester, settings: {'pen_seen': '1'});
    List strokes() {
      final paint = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is InkLayerPainter);
      return [for (final p in paint.evaluate()) ...((p.widget as CustomPaint).painter as InkLayerPainter).strokes];
    }

    final from = tester.getTopLeft(find.byKey(const ValueKey('page-0'))) + const Offset(100, 100);
    final pen = await tester.createGesture();
    await pen.down(from);
    for (var i = 1; i <= 10; i++) {
      await pen.moveTo(from + Offset(20.0 * i, 10.0 * i));
    }
    await pen.up();
    await tester.pumpAndSettle();
    expect(strokes(), hasLength(1));

    final a = await tester.startGesture(from + const Offset(300, 300), pointer: 11);
    final b = await tester.startGesture(from + const Offset(360, 300), pointer: 12);
    await tester.pump(const Duration(milliseconds: 60));
    await a.moveBy(const Offset(0, 80));
    await b.moveBy(const Offset(0, 80));
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(strokes(), hasLength(1), reason: 'two fingers that moved scroll: they do not undo');

    final c = await tester.startGesture(from + const Offset(300, 300), pointer: 13);
    final d = await tester.startGesture(from + const Offset(360, 300), pointer: 14);
    await tester.pump(const Duration(milliseconds: 60));
    await c.up();
    await d.up();
    await tester.pumpAndSettle();
    expect(strokes(), isEmpty);
  });
}
