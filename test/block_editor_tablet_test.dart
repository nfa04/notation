import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/markdown/live_markdown.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _android = TargetPlatformVariant.only(TargetPlatform.android);

final _long = List.generate(300, (i) => 'line number $i with some words on it to select\n').join();

LiveMarkdownController _doc(String text, [int at = 0]) => LiveMarkdownController()..value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: at));

/// The editor as it is on a tablet, where selections have handles.
Future<BlockEditorState> _open(WidgetTester tester, LiveMarkdownController c, FocusNode focus, {ScrollController? scroll}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: CustomScrollView(controller: scroll, slivers: [
        SliverToBoxAdapter(
          child: BlockEditor(controller: c, focusNode: focus, style: documentTextStyle(16), width: 700, selectionControls: materialTextSelectionHandleControls),
        ),
      ]),
    ),
  ));
  await tester.pump();
  await tester.pump();
  return tester.state<BlockEditorState>(find.byType(BlockEditor));
}

Offset _at(BlockEditorState state, int offset) => state.screenRectOf(TextRange(start: offset, end: offset + 1))!.center;

Future<void> _rest(WidgetTester tester) => tester.pump(const Duration(milliseconds: 400));

final _menu = find.byType(AdaptiveTextSelectionToolbar);

void main() {
  setUpAll(AppDatabase.initFfi);

  group('selecting with a finger', () {
    late FocusNode focus;
    setUp(() => focus = FocusNode());
    tearDown(() => focus.dispose());

    testWidgets('a finger that moves a little while it is held down keeps the whole word', (tester) async {
      final c = _doc('one two three\nsecond line');
      final state = await _open(tester, c, focus);
      final press = await tester.startGesture(_at(state, 9), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 600));
      expect(c.selection, const TextSelection(baseOffset: 8, extentOffset: 13));
      await press.moveBy(const Offset(-3, 1));
      await tester.pump();
      expect(c.selection, const TextSelection(baseOffset: 8, extentOffset: 13));
      await press.up();
      await _rest(tester);
      expect(_menu, findsOneWidget);
    }, variant: _android);

    testWidgets('moved further a long press goes on by whole words, either way', (tester) async {
      final c = _doc('one two three four five');
      final state = await _open(tester, c, focus);
      final press = await tester.startGesture(_at(state, 9), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 600));
      await press.moveTo(_at(state, 20));
      await tester.pump();
      expect((c.selection.start, c.selection.end), (8, 23));
      await press.moveTo(_at(state, 1));
      await tester.pump();
      expect((c.selection.start, c.selection.end), (0, 13));
      await press.up();
      await _rest(tester);
    }, variant: _android);

    testWidgets('a button of the menu is pressed, not closed by the tap on it', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final c = _doc('one two three\nsecond line');
      final state = await _open(tester, c, focus);
      await tester.longPressAt(_at(state, 9));
      await _rest(tester);
      // (a finger stays down for some frames, which a menu that closes at the touch does not outlive)
      final finger = await tester.startGesture(tester.getCenter(find.text('Copy')), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 60));
      await finger.up();
      await _rest(tester);
      expect(copied, ['three']);
    }, variant: _android);

    testWidgets('a finger drawn across the text being written selects, and the menu and handles come with it', (tester) async {
      final c = _doc('one two three four five six seven\nsecond line');
      final state = await _open(tester, c, focus);
      await tester.tapAt(_at(state, 1));
      await _rest(tester);
      final drag = await tester.startGesture(_at(state, 4), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 30));
      for (var i = 0; i < 12; i++) {
        await drag.moveBy(const Offset(12, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await drag.up();
      await _rest(tester);
      expect(c.selection.isCollapsed, isFalse);
      expect(_menu, findsOneWidget);
    }, variant: _android);

    testWidgets('a finger across a document that is not being written does nothing', (tester) async {
      final c = _doc('one two three four five six seven\nsecond line');
      final state = await _open(tester, c, focus);
      final was = c.selection;
      final drag = await tester.startGesture(_at(state, 4), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 30));
      for (var i = 0; i < 12; i++) {
        await drag.moveBy(const Offset(12, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await drag.up();
      await _rest(tester);
      expect(c.selection, was);
      expect(focus.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    }, variant: _android);

    testWidgets('the menu goes with its text when the page scrolls, and away when that has left the screen', (tester) async {
      final c = _doc(_long);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final state = await _open(tester, c, focus, scroll: scroll);
      await tester.longPressAt(_at(state, 310));
      await _rest(tester);
      Offset anchor() => tester.widget<AdaptiveTextSelectionToolbar>(_menu).anchors.primaryAnchor;
      final was = anchor();
      scroll.jumpTo(40);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(anchor().dy, closeTo(was.dy - 40, 1));
      scroll.jumpTo(3000);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(_menu, findsNothing);
    }, variant: _android);

    testWidgets('the keyboard coming does not leave the caret under it', (tester) async {
      final c = _doc(_long);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = await _open(tester, c, focus, scroll: scroll);
      final at = _long.indexOf('line number 16 '); // (near the bottom of the screen)
      await tester.tapAt(_at(state, at));
      await _rest(tester);
      Rect caret() => state.screenRectOf(TextRange(start: c.selection.baseOffset, end: c.selection.baseOffset + 1))!;
      expect(caret().top, greaterThan(500));
      tester.view.viewInsets = const FakeViewPadding(bottom: 500);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(caret().bottom, lessThanOrEqualTo(500));
      tester.view.resetViewInsets();
    }, variant: _android);

    testWidgets('a change that is no concern of the caret does not bring the page back to it', (tester) async {
      final c = _doc(_long);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final state = await _open(tester, c, focus, scroll: scroll);
      await tester.tapAt(_at(state, 10));
      await _rest(tester);
      scroll.jumpTo(5000);
      await _rest(tester);
      await _rest(tester);
      final was = scroll.offset;
      c.revealing = !c.revealing;
      await tester.pump();
      await tester.pump();
      expect(scroll.offset, was);
    }, variant: _android);
  });

  group('the keyboard on a tablet', () {
    for (final (name, size) in [('upright', const Size(1200, 2000)), ('on its side', const Size(2000, 1200))]) {
      testWidgets('held $name, it takes nothing from the page, however tall it is', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.5;
        addTearDown(tester.view.reset);
        late NoteRepository repo;
        late String id;
        await tester.runAsync(() async {
          repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
          id = await repo.createNote();
          final note = (await repo.loadNote(id))!;
          note.documentText = '# A title\n\nSome words to select here.\n' * 40;
          await repo.saveNote(note);
        });
        await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pump(const Duration(seconds: 1));
        await tester.ensureVisible(find.text('Document'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Document'));
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final page = find.byKey(const ValueKey('page-0'));
        final wide = tester.getSize(page).width;
        expect(wide, greaterThan(500));
        final tall = size.height / 1.5;
        for (var keyboard = 0.0; keyboard < tall * 0.7; keyboard += 40) {
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard * 1.5);
          await tester.pump(const Duration(milliseconds: 16));
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getSize(page).width, wide, reason: 'with a keyboard $keyboard tall');
        }
        tester.view.resetViewInsets();
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 3));
      }, variant: _android);
    }
  });
}
