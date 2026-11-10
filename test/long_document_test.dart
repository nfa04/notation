import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/markdown/live_markdown.dart';
import 'package:notes/screens/document_sheets.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/page_scrollbar.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A document that is several pages long.
String longDocument() => [
      for (var i = 1; i <= 12; i++) ...[
        '## Section $i',
        '- ${List.filled(12, 'Alexander the Great of Macedon conquered the Persian Empire and reached as far as India.').join(' ')}',
        '',
      ],
    ].join('\n');

/// The sheets of a document that is written: each a whole page, a space below the one before, and no line on the space between two or
/// in the margin at the bottom of one (as far as lines are built: the screen and what is around it).
Future<void> expectKeptToSheets(WidgetTester tester, LiveMarkdownController controller, String reason, {int atLeast = 3}) async {
  final state = tester.state<BlockEditorState>(find.byType(BlockEditor));
  for (var i = 0; i < 2000 && !state.allMeasured; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
  final count = state.sheetCount;
  expect(count, greaterThanOrEqualTo(atLeast), reason: reason);
  final rects = <int, Rect>{
    for (var k = 0; k < count; k++)
      if (find.byKey(ValueKey('write-sheet-$k')).evaluate().isNotEmpty) k: tester.getRect(find.byKey(ValueKey('write-sheet-$k'))),
  };
  expect(rects, isNotEmpty, reason: reason);
  final first = rects.values.first;
  for (final k in rects.keys) {
    expect(rects[k]!.height, closeTo(first.height, 0.01), reason: reason);
    if (rects.containsKey(k - 1)) expect(rects[k]!.top - rects[k - 1]!.bottom, closeTo(first.width * 24 / 800, 1.0), reason: '$reason: the space between pages');
  }
  final margin = first.width * 56 / 800;
  for (var at = 0; at < controller.text.length; at += 7) {
    final line = state.screenRectOf(TextRange(start: at, end: at + 1));
    if (line == null || line.height > 100) continue;
    final k = [for (final e in rects.entries) if (line.top >= e.value.top - 0.5 && line.top < e.value.bottom) e.key].firstOrNull;
    if (k == null) {
      expect(line.top, isNot(inInclusiveRange(rects.values.first.top, rects.values.last.bottom)), reason: '$reason: a line at ${line.top} is between two sheets');
      continue;
    }
    expect(line.bottom, lessThanOrEqualTo(rects[k]!.bottom - margin * 0.9 + 1), reason: '$reason: a line from ${line.top} to ${line.bottom} runs into the bottom margin');
  }
}

/// Paragraphs of a few lines each with an empty line between them, as most Markdown is written.
String paragraphs(int count) => [
      for (var i = 1; i <= count; i++) 'Paragraph $i. ${List.filled(5 + i % 4, 'Alexander the Great of Macedon conquered the Persian Empire.').join(' ')}',
    ].join('\n\n');

void main() {
  setUpAll(AppDatabase.initFfi);

  Future<(NoteRepository, String)> makeNote(WidgetTester tester, String text) async {
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.documentText = text;
      await repo.saveNote(note);
    });
    return (repo, id);
  }

  testWidgets('a long document that is opened is not cut off at the end of its first page', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (repo, id) = await makeNote(tester, longDocument());
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // it is read on sheets, each a page of its own with a space between them (not one page that is very long)
    final sheets = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('document-sheet-'));
    expect(sheets.evaluate().length, greaterThan(2));
    final rects = [for (var i = 0; i < sheets.evaluate().length; i++) tester.getRect(find.byKey(ValueKey('document-sheet-$i')))];
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].height, closeTo(rects[0].height, 0.01), reason: 'every sheet is a whole page');
      expect(rects[i].width, closeTo(rects[0].width, 0.01));
      expect(rects[i].top - rects[i - 1].bottom, closeTo(rects[0].height * 24 / (rects[0].width * 1.4142), 1), reason: 'the space between pages');
    }
    expect(tester.getRect(find.byKey(const ValueKey('page-0'))).bottom, greaterThanOrEqualTo(rects.last.bottom));
    // (the page after it comes below the last sheet)
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });

  testWidgets('a document that fits on a page is one sheet, as before', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (repo, id) = await makeNote(tester, '# Short\nhello');
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('document-sheet-0')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });

  testWidgets('a document that grows to many pages while it is being written (in the editor)', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (repo, id) = await makeNote(tester, '# Title\nshort');
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    controller.value = TextEditingValue(text: longDocument(), selection: const TextSelection.collapsed(offset: 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // back to reading it: the page is as long as the text
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('document-sheet-2')), findsOneWidget, reason: 'twelve sections are several pages long');
    // and it is written on sheets too: the text goes on at the top of the next sheet
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('document-sheet-0')), findsNothing);
    expect(find.byKey(const ValueKey('write-sheet-2')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });

  testWidgets('a document that is written keeps to the sheets: no line is on the space between two, and typing moves what comes after', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (repo, id) = await makeNote(tester, '# Title\nshort');
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    final text = longDocument();
    controller.value = TextEditingValue(text: text, selection: const TextSelection.collapsed(offset: 5));
    await tester.pumpAndSettle();

    int sheetCount() => tester.state<BlockEditorState>(find.byType(BlockEditor)).sheetCount;
    Future<void> checkSheets(String reason) => expectKeptToSheets(tester, controller, reason);

    await checkSheets('as it is written');
    final sheetsBefore = sheetCount();
    expect(controller.text, text, reason: 'the text is not changed by being on sheets');

    // lines put in at the top push the rest down: more sheets, still none cut
    controller.value = TextEditingValue(text: '${List.filled(40, 'A new line').join('\n')}\n$text', selection: const TextSelection.collapsed(offset: 5));
    await tester.pumpAndSettle();
    await checkSheets('after lines were put in at the top');
    expect(sheetCount(), greaterThan(sheetsBefore));

    // and taken out again
    controller.value = TextEditingValue(text: text, selection: const TextSelection.collapsed(offset: 5));
    await tester.pumpAndSettle();
    await checkSheets('after they were taken out');
    expect(sheetCount(), sheetsBefore);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });

  testWidgets('paragraphs with an empty line between them keep to the sheets as well, and a page break ends a sheet', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (repo, id) = await makeNote(tester, 'short');
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    final text = paragraphs(40);
    controller.value = TextEditingValue(text: text, selection: const TextSelection.collapsed(offset: 5));
    await tester.pumpAndSettle();
    await expectKeptToSheets(tester, controller, 'paragraphs');
    expect(controller.text, text);

    // a page break in the middle: what is after it begins a sheet
    final at = text.indexOf('Paragraph 3.');
    controller.value = TextEditingValue(text: text.replaceRange(at, at, '\\pagebreak\n'), selection: const TextSelection.collapsed(offset: 5));
    await tester.pumpAndSettle();
    await expectKeptToSheets(tester, controller, 'with a page break');
    final sheet1 = tester.getRect(find.byKey(const ValueKey('write-sheet-1')));
    final after = controller.text.indexOf('Paragraph 3.');
    final top = tester.state<BlockEditorState>(find.byType(BlockEditor)).screenRectOf(TextRange(start: after, end: after + 4))!.top;
    expect(top, closeTo(sheet1.top + sheet1.width * 56 / 800, 2), reason: 'the paragraph after the page break is at the top of the second sheet');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });

  testWidgets('typing at the end of a sheet moves a line on to the next, and the text is the same as it was typed', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (repo, id) = await makeNote(tester, 'short');
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    final text = paragraphs(40);
    controller.value = TextEditingValue(text: text, selection: const TextSelection.collapsed(offset: 5));
    await tester.pumpAndSettle();
    await expectKeptToSheets(tester, controller, 'before typing');

    // typing right where the first sheet ends
    final state = tester.state<BlockEditorState>(find.byType(BlockEditor));
    final second = tester.getRect(find.byKey(const ValueKey('write-sheet-1'))).top;
    var end = 0;
    while (state.screenRectOf(TextRange(start: end, end: end + 1))!.top < second) {
      end = controller.text.indexOf(' ', end + 1);
    }
    var typed = controller.text;
    for (final piece in ['x', '\n', 'yy', ' ', 'zz\n\n']) {
      typed = typed.replaceRange(end, end, piece);
      controller.value = TextEditingValue(text: typed, selection: TextSelection.collapsed(offset: end + piece.length));
      await tester.pumpAndSettle();
      expect(controller.text, typed);
      await expectKeptToSheets(tester, controller, 'after typing "$piece" at the end of a sheet');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });

  testWidgets('a long run of empty lines does not stop the sheets: what comes after it is on sheets too, and a table taller than a sheet does not either', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (repo, id) = await makeNote(tester, 'short');
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    final state = tester.state(find.byType(FixedPageNoteEditor)) as dynamic;
    final summary = ['## Summary', '', for (var i = 0; i < 14; i++) '- ${List.filled(3 + i % 3, 'Ancient Greece was a collection of independent city-states.').join(' ')}'].join('\n');
    // (an agent adds to a note in which someone held Enter down)
    final text = '${longDocument()}\n\\pagebreak\n\n$summary${'\n' * 70}\n$summary';
    await state.agentSetDocument(text);
    await tester.pumpAndSettle();
    await expectKeptToSheets(tester, controller, 'after a run of empty lines', atLeast: 8);

    // more is added at the end, as an agent does: it is on sheets as well
    await state.agentApi.insertText(summary);
    await tester.pumpAndSettle();
    await expectKeptToSheets(tester, controller, 'with more added at the end', atLeast: 9);

    // and it is typed in the run of empty lines
    final at = controller.text.indexOf('\n\n\n\n') + 20;
    controller.value = TextEditingValue(text: controller.text.replaceRange(at, at, 'typed here'), selection: TextSelection.collapsed(offset: at + 10));
    await tester.pumpAndSettle();
    await expectKeptToSheets(tester, controller, 'after typing in the run', atLeast: 9);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });

  for (final (name, line) in const [('plain lines', 'Some words on a line'), ('a list', '- some item of a list')]) {
    testWidgets('writing $name past the end of the last sheet: the caret goes on at the left of the text, on a sheet', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (repo, id) = await makeNote(tester, 'short');
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Document'));
      await tester.pumpAndSettle();
      final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
      final text = paragraphs(6);
      controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
      await tester.pumpAndSettle();
      final blocks = tester.state<BlockEditorState>(find.byType(BlockEditor));
      final sheets = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('write-sheet-'));
      Rect caret() => blocks.screenCaret!;

      void checkCaret(String what, {bool wrapping = false}) {
        final at = caret();
        final left = at.topLeft;
        final rects = [for (final e in sheets.evaluate()) tester.getRect(find.byWidget(e.widget))];
        final paper = rects.where((r) => left.dy >= r.top && left.dy + at.height <= r.bottom).firstOrNull;
        expect(paper, isNotNull, reason: '$what: the caret at y ${left.dy} is not on a sheet');
        // (in a paragraph the caret goes as far as the right margin; on a new line it starts at the left)
        final most = paper!.left + paper.width - (wrapping ? paper.width * 56 / 800 - 2 : 150);
        expect(left.dx, lessThan(most), reason: '$what: the caret is at the right of the sheet, at x ${left.dx}');
        expect(left.dy + at.height, lessThanOrEqualTo(paper.bottom - paper.width * 56 / 800 + 2), reason: '$what: the caret is in the bottom margin, at y ${left.dy}');
      }

      Future<void> type(String s) async {
        for (final ch in s.split('')) {
          final at = controller.selection.baseOffset;
          controller.value = TextEditingValue(text: controller.text.replaceRange(at, at, ch), selection: TextSelection.collapsed(offset: at + 1));
          for (var i = 0; i < 4; i++) {
            await tester.pump();
          }
        }
      }

      // line after line, ending each with Enter, over two sheet ends
      final before = blocks.sheetCount;
      var n = 0;
      var tried = false;
      while (blocks.sheetCount < before + 2 && n < 90) {
        n++;
        await type('\n');
        checkCaret('Enter after line $n');
        if (!tried && blocks.sheetCount > before) {
          // the caret went on to the next sheet by itself. There the text ends: what the keys and the mouse do must stay on the text
          tried = true;
          final end = controller.text.length;
          controller.selection = TextSelection.collapsed(offset: end, affinity: TextAffinity.upstream);
          await tester.pump();
          checkCaret('a caret at the end that leans on the line before');
          await tester.sendKeyEvent(LogicalKeyboardKey.end);
          await tester.pump();
          expect(controller.selection.baseOffset, end, reason: 'End stays in the text');
          checkCaret('after the End key');
          await tester.tapAt(caret().center + const Offset(300, 0));
          await tester.pump(const Duration(milliseconds: 400));
          expect(controller.selection.baseOffset, end, reason: 'a click to the right of the last line is at the end of the text');
          checkCaret('after a click on the last line');
          // Backspace goes back up, and Enter comes down again
          controller.value = TextEditingValue(text: controller.text.substring(0, end - 1), selection: TextSelection.collapsed(offset: end - 1));
          for (var i = 0; i < 4; i++) {
            await tester.pump();
          }
          checkCaret('Backspace at the top of the sheet');
          expect(tester.takeException(), isNull);
          await type('\n');
          checkCaret('Enter again');
        }
        await type(line.startsWith('- ') && n > 1 ? line.substring(2) : line);
        checkCaret('line $n written');
        // Enter twice at the end of a sheet (an empty line, and the one after it)
        if (n % 10 == 0) {
          await type('\n');
          checkCaret('first Enter of two after line $n');
          await type('\n');
          checkCaret('second Enter of two after line $n');
        }
      }
      expect(blocks.sheetCount, before + 2);
      expect(tried, isTrue, reason: 'an Enter ended a sheet');
      await tester.pumpAndSettle();
      await expectKeptToSheets(tester, controller, 'after writing past the end', atLeast: 2);

      if (line.startsWith('- ')) {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
        return; // (the rest is the same in a list, and typing this many keys takes long)
      }

      // one long paragraph, without Enter, over the next sheet end: what is typed goes on at the top of the next sheet
      final now = blocks.sheetCount;
      await type('\n');
      var words = 0;
      while (blocks.sheetCount == now && words < 900) {
        words++;
        await type('word ');
        checkCaret('word $words of a long paragraph', wrapping: true);
      }
      expect(blocks.sheetCount, now + 1, reason: 'a long paragraph goes on to a new sheet');
      await type('more');
      await tester.pumpAndSettle();
      checkCaret('after the long paragraph', wrapping: true);
      final last = tester.getRect(find.byKey(ValueKey('write-sheet-$now')));
      final caretY = caret().top;
      expect(caretY, inInclusiveRange(last.top, last.top + last.height / 2), reason: 'the caret is on the new sheet, near its top');
      await expectKeptToSheets(tester, controller, 'after a long paragraph', atLeast: 2);

      // and back: Backspace over the end of a sheet takes the last sheet away again
      var back = 0;
      while (blocks.sheetCount > now && back < 900) {
        back++;
        final at = controller.selection.baseOffset;
        controller.value = TextEditingValue(text: controller.text.replaceRange(at - 1, at, ''), selection: TextSelection.collapsed(offset: at - 1));
        for (var i = 0; i < 4; i++) {
          await tester.pump();
        }
        checkCaret('Backspace $back', wrapping: true);
      }
      expect(blocks.sheetCount, now);
      await tester.pumpAndSettle();
      await expectKeptToSheets(tester, controller, 'after Backspace', atLeast: 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
    });
  }

  group('the scrollbar of a long document', () {
    final thumb = find.byKey(const ValueKey('page-scrollbar-thumb'));
    ScrollPosition pages(WidgetTester tester) => tester.state<ScrollableState>(find.ancestor(of: find.byKey(const ValueKey('page-0')), matching: find.byType(Scrollable)).first).position;

    Future<void> open(WidgetTester tester, {required bool writing}) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (repo, id) = await makeNote(tester, paragraphs(120));
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      if (writing) {
        await tester.tap(find.text('Document'));
        await tester.pumpAndSettle();
        final state = tester.state<BlockEditorState>(find.byType(BlockEditor));
        for (var i = 0; i < 2000 && !state.allMeasured; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
      }
    }

    Future<void> closed(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
    }

    int total(WidgetTester tester) {
      final texts = find.textContaining(RegExp(r'^Page \d+ / \d+$')).evaluate();
      return int.parse(RegExp(r'/ (\d+)').firstMatch((texts.first.widget as dynamic).data as String)!.group(1)!);
    }

    for (final (name, writing) in const [('read', false), ('written', true)]) {
      testWidgets('of one that is $name: the middle of the track goes to the middle of it, not to its start or end', (tester) async {
        await open(tester, writing: writing);
        final track = tester.getSize(find.byType(PageScrollbar)).height - 64;
        final held = await tester.startGesture(tester.getCenter(thumb));
        await tester.pump();
        await held.moveBy(const Offset(0, 20));
        await tester.pump();
        await held.moveBy(Offset(0, track / 2 - 20));
        await tester.pump();
        final sheets = total(tester);
        expect(sheets, greaterThan(10), reason: 'every sheet is a stop of its own');
        await held.up();
        await tester.pump();
        await tester.pump();
        await tester.pump();
        const sheet = 800 * 1.4142 + 24;
        final scale = tester.getSize(find.byKey(const ValueKey('page-0'))).width / 800;
        expect(pages(tester).pixels, closeTo(sheets / 2 * sheet * scale, 2 * sheet * scale));
        await closed(tester);
      });

      testWidgets('of one that is $name: the thumb is where the screen is, and stays there', (tester) async {
        await open(tester, writing: writing);
        final track = tester.getSize(find.byType(PageScrollbar)).height - 64;
        final held = await tester.startGesture(tester.getCenter(thumb));
        await tester.pump();
        await held.moveBy(const Offset(0, 20));
        await tester.pump();
        await held.moveBy(Offset(0, track * 0.75 - 20));
        await tester.pump();
        await held.up();
        await tester.pump();
        await tester.pump();
        await tester.pump();
        final top = tester.getTopLeft(find.byType(PageScrollbar)).dy;
        expect(tester.getTopLeft(thumb).dy - top, closeTo(track * 0.75, track * 0.04));
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.getTopLeft(thumb).dy - top, closeTo(track * 0.75, track * 0.04));
        await closed(tester);
      });
    }
  });

  group('where the sheets of a document end', () {
    test('a text that fits is on one sheet', () {
      expect(sheetBreaks([20, 40, 60], 60, [], 100), isEmpty);
    });

    test('a sheet ends at the end of the last line that fits, and the next begins there', () {
      final bottoms = [for (var i = 1; i <= 25; i++) i * 20.0]; // 25 lines of 20, 100 to a sheet
      expect(sheetBreaks(bottoms, 500, [], 100), [100, 200, 300, 400]);
      // lines that do not divide the room: nothing is cut through
      expect(sheetBreaks([for (var i = 1; i <= 10; i++) i * 30.0], 300, [], 100), [90, 180, 270]);
    });

    test('a page break ends the sheet where it is, and nothing is after the last one', () {
      final bottoms = [for (var i = 1; i <= 10; i++) i * 20.0];
      expect(sheetBreaks(bottoms, 200, [60], 100), [60, 160]);
      expect(sheetBreaks(bottoms, 200, [200], 1000), isEmpty);
    });

    test('a line taller than a sheet is cut where the sheet is full', () {
      expect(sheetBreaks([250, 270], 270, [], 100), [100, 200]);
    });

    test('there are never more than 500, and no room is no sheets', () {
      expect(sheetBreaks(const [], 1e9, [], 100).length, 500);
      expect(sheetBreaks(const [], 1000, [], 10), isEmpty);
    });
  });

  testWidgets('an entry of the table of contents takes the screen to its heading, in the editor', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (repo, id) = await makeNote(tester, '# Title\nshort');
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    final text = '[toc]\n\n${longDocument()}';
    controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    await tester.pumpAndSettle();
    final scroll = tester.widget<CustomScrollView>(find.byType(CustomScrollView).first).controller!;
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    final heading = text.indexOf('## Section 10');
    final entry = find.byKey(ValueKey('toc-$heading'));
    expect(entry, findsOneWidget);
    final press = await tester.startGesture(tester.getCenter(entry), kind: PointerDeviceKind.stylus);
    await tester.pump(const Duration(milliseconds: 80));
    await press.up();
    await tester.pumpAndSettle();
    expect(controller.selection.baseOffset, heading);
    expect(scroll.offset, greaterThan(1000));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });


  testWidgets('an entry of the table of contents takes the screen to its heading, when the document is only read', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final text = '[toc]\n\n${longDocument()}';
    final (repo, id) = await makeNote(tester, text);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    final scroll = tester.widget<CustomScrollView>(find.byType(CustomScrollView).first).controller!;
    expect(scroll.offset, 0);
    final heading = text.indexOf('## Section 10');
    // (the entry is on the screen in the sheet it is on: what is on a sheet is tapped through the page that is over it)
    await tester.tapAt(tester.getCenter(find.byKey(ValueKey('toc-$heading')).first));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(1000));
    // (the heading is on the screen, near the top)
    final top = tester.getTopLeft(find.textContaining('Section 10', findRichText: true).last).dy;
    expect(top, inInclusiveRange(0, 600));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });


  testWidgets('an entry of the table of contents works on a document that is read and fits on one page', (tester) async {
    tester.view.physicalSize = const Size(1600, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final text = '[toc]\n\n# One\n${List.generate(14, (i) => 'Line $i of one.').join('\n')}\n\n# Two\n${List.generate(14, (i) => 'Line $i of two.').join('\n')}';
    final (repo, id) = await makeNote(tester, text);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('document-sheet-0')), findsNothing, reason: 'it is one page');
    final scroll = tester.widget<CustomScrollView>(find.byType(CustomScrollView).first).controller!;
    expect(scroll.position.maxScrollExtent, greaterThan(100));
    await tester.tapAt(tester.getCenter(find.byKey(ValueKey('toc-${text.indexOf('# Two')}')).first));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(100));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });

}
