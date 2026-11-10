import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/presentation_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  Widget view({int pages = 3, int initial = 0, VoidCallback? onClose, Duration hide = const Duration(seconds: 3)}) => MaterialApp(
        home: PresentationView(
          pageCount: pages,
          initialPage: initial,
          hideAfter: hide,
          pageSize: (i) => const Size(800, 1100),
          pageBuilder: (context, i) => Center(child: Text('Slide ${i + 1}', style: const TextStyle(fontSize: 60))),
          onClose: onClose ?? () {},
        ),
      );

  String pageLabel(WidgetTester tester) => (tester.widget(find.byKey(const ValueKey('presentation-page'))) as dynamic).data as String;

  testWidgets('the pages turn with the keys, a tap on the right or left, and the buttons; and stop at the ends', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(view());
    await tester.pumpAndSettle();
    expect(find.text('Slide 1'), findsOneWidget);
    expect(pageLabel(tester), 'Page 1 of 3');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(pageLabel(tester), 'Page 2 of 3');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(pageLabel(tester), 'Page 3 of 3');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // the end
    await tester.pumpAndSettle();
    expect(pageLabel(tester), 'Page 3 of 3');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(pageLabel(tester), 'Page 2 of 3');
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(pageLabel(tester), 'Page 1 of 3');
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(pageLabel(tester), 'Page 3 of 3');

    // taps: the left third goes back, the rest on
    await tester.tapAt(const Offset(100, 450));
    await tester.pumpAndSettle();
    expect(pageLabel(tester), 'Page 2 of 3');
    await tester.tapAt(const Offset(1200, 450));
    await tester.pumpAndSettle();
    expect(pageLabel(tester), 'Page 3 of 3');

    await tester.tap(find.byKey(const ValueKey('presentation-previous')));
    await tester.pumpAndSettle();
    expect(pageLabel(tester), 'Page 2 of 3');
    await tester.tap(find.byKey(const ValueKey('presentation-next')));
    await tester.pumpAndSettle();
    expect(pageLabel(tester), 'Page 3 of 3');
    await tester.pump(const Duration(seconds: 4)); // (the controls fade)
  });

  testWidgets('it starts at the page asked for and Escape or the close button leave', (tester) async {
    var closed = 0;
    await tester.pumpWidget(view(initial: 1, onClose: () => closed++));
    await tester.pumpAndSettle();
    expect(find.text('Slide 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(closed, 1);
    await tester.tap(find.byKey(const ValueKey('presentation-close')));
    expect(closed, 2);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('B blacks the screen out and a tap brings it back; the pages are not touchable', (tester) async {
    await tester.pumpWidget(view());
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pump();
    expect(find.byKey(const ValueKey('presentation-blackout')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('presentation-blackout')));
    await tester.pump();
    expect(find.byKey(const ValueKey('presentation-blackout')), findsNothing);
    // a tap on the middle of a page turns it: it never reaches what is drawn there
    expect(find.byType(IgnorePointer), findsWidgets);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the laser pointer follows the mouse while it is on, and does not turn pages by a tap', (tester) async {
    await tester.pumpWidget(view());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('presentation-laser')), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(300, 300));
    await mouse.moveTo(const Offset(400, 400));
    await tester.pump();
    expect(find.byKey(const ValueKey('presentation-laser')), findsNothing); // not on

    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    await mouse.moveTo(const Offset(500, 420));
    await tester.pump();
    expect(find.byKey(const ValueKey('presentation-laser')), findsOneWidget);

    // with the laser on a tap does not turn the page
    await tester.tapAt(const Offset(700, 300));
    await tester.pumpAndSettle();
    expect(pageLabel(tester), 'Page 1 of 3');
    // and it goes out after a moment without movement
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('presentation-laser')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the controls fade when nothing moves and come back with the pointer', (tester) async {
    await tester.pumpWidget(view(hide: const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
    double opacity() => tester.widget<AnimatedOpacity>(find.ancestor(of: find.byKey(const ValueKey('presentation-page')), matching: find.byType(AnimatedOpacity))).opacity;
    expect(opacity(), 1);
    await tester.pump(const Duration(milliseconds: 700));
    expect(opacity(), 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    await mouse.moveTo(const Offset(20, 20));
    await tester.pump();
    expect(opacity(), 1);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('from the editor: the note is shown page by page, starting at the page in view, and Escape brings the editor back', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote(title: 'Lecture');
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'a', position: const Offset(60, 60), initialText: 'First page words')];
      note.textBoxes[1] = [TextBoxWidgetModel(id: 'b', position: const Offset(60, 60), initialText: 'Second page words')];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('present-note')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('presentation-pages')), findsOneWidget);
    expect(pageLabel(tester), startsWith('Page 1 of '));
    expect(find.textContaining('First page words'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(pageLabel(tester), startsWith('Page 2 of '));
    expect(find.textContaining('Second page words'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('presentation-pages')), findsNothing);
    expect(find.byKey(const ValueKey('present-note')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a flipbook plays the pages round and round at its speed, stops and starts again, and the speed can be changed', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: PresentationView(
        pageCount: 3,
        flipbook: true,
        fps: 4,
        hideAfter: const Duration(hours: 1),
        pageSize: (i) => const Size(800, 1100),
        pageBuilder: (context, i) => Center(child: Text('Slide ${i + 1}', style: const TextStyle(fontSize: 60))),
        onClose: () {},
      ),
    ));
    await tester.pump();
    expect(pageLabel(tester), 'Page 1 of 3');
    await tester.pump(const Duration(milliseconds: 260));
    expect(pageLabel(tester), 'Page 2 of 3', reason: 'a frame every 250 ms');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
    expect(pageLabel(tester), 'Page 1 of 3', reason: 'after the last the first');

    await tester.tap(find.byKey(const ValueKey('flipbook-play')));
    await tester.pump();
    final stopped = pageLabel(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(pageLabel(tester), stopped, reason: 'stopped');
    await tester.tap(find.byKey(const ValueKey('flipbook-speed')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('flipbook-fps-12')));
    await tester.pumpAndSettle();
    expect(find.text('12 / s'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flipbook-play')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(pageLabel(tester), isNot(stopped), reason: 'a frame every 83 ms');
    // leaving stops the timer (no pending timers are left)
    await tester.pumpWidget(const SizedBox());
  });
}
