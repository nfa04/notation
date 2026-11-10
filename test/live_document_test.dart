import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/markdown/live_markdown.dart';
import 'package:notes/markdown/markdown_formatting.dart';
import 'package:notes/markdown/markdown_parser.dart';
import 'package:notes/models/rich_text.dart';
import 'package:notes/outline/outline.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

TextEditingValue v(String text, [int? at, int? end]) =>
    TextEditingValue(text: text, selection: TextSelection(baseOffset: at ?? text.length, extentOffset: end ?? at ?? text.length));

/// The pieces a span is drawn in, with their styles (a widget: null text).
List<(String?, TextStyle?)> pieces(InlineSpan span) {
  final out = <(String?, TextStyle?)>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      if (s.text != null) out.add((s.text, s.style));
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    } else {
      out.add((null, null));
    }
  }

  walk(span);
  return out;
}

bool hiddenIn(InlineSpan span, String text) => pieces(span).any((p) => p.$1 == text && p.$2?.fontSize == 0);
bool shownIn(InlineSpan span, String text) => pieces(span).any((p) => p.$1 != null && p.$1!.contains(text) && p.$2?.fontSize != 0);

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the Markdown of the written document', () {
    test('headings go to six levels, and a line can start with how it is laid out', () {
      final b = parseMarkdown('{align=center spacing=1.5}## Title\n#### Four\n###### Six');
      expect(b[0].type, MdBlockType.heading);
      expect(b[0].level, 2);
      expect(b[0].format, const ParagraphFormat(align: 'center', spacing: 1.5));
      expect(b[0].tokenEnd, '{align=center spacing=1.5}'.length);
      expect(b[0].contentStart, '{align=center spacing=1.5}## '.length);
      expect(b[0].runs.single.text, 'Title');
      expect(b[1].level, 4);
      expect(b[2].level, 6);
      // an unknown word makes it no token: the line is text
      expect(parseMarkdown('{align=middle}x').single.runs.single.text, '{align=middle}x');
    });

    test('tasks, nested items, quotes, rules and ==highlight==', () {
      final b = parseMarkdown('- [x] done\n  - nested\n> said\n---\na ==mark== b');
      expect((b[0].type, b[0].checked, b[0].runs.single.text), (MdBlockType.task, true, 'done'));
      expect((b[1].type, b[1].depth), (MdBlockType.bullet, 1));
      expect((b[2].type, b[2].runs.single.text), (MdBlockType.quote, 'said'));
      expect(b[3].type, MdBlockType.rule);
      final mark = b[4].runs.firstWhere((r) => r.highlight);
      expect(mark.text, 'mark');
      final pair = b[4].markup.single;
      final at = 'a ==mark== b'.indexOf('==') + b[4].start;
      expect((pair.start, pair.innerStart, pair.innerEnd, pair.end), (at, at + 2, at + 6, at + 8));
    });

    test('readers of the text do not see the layout, and the outline finds a laid-out heading', () {
      expect(withoutParagraphFormats('{align=right}# A\nb'), '# A\nb');
      expect(headingsOf('{align=center}# Title', 0).single.title, 'Title');
    });

    test('words are counted as they read', () {
      expect(wordCount('{align=center}# Hi there\n**bold** `x` [link](https://a.b)\n---'), 5);
    });
  });

  group('formatting picked from the bar', () {
    test('stays on its words while text is typed before, in and after it', () {
      final c = RichInlineTextController()..text = 'hello world';
      c.attributes.add(TextSpanAttribute(start: 6, end: 11, type: AttributeType.font, value: 'Serif'));
      c.value = v('hello big world', 10);
      expect((c.attributes.single.start, c.attributes.single.end), (10, 15));
      c.value = v('hello big worlds', 16); // typed at its end: joins it
      expect((c.attributes.single.start, c.attributes.single.end), (10, 16));
      c.value = v('hello big wds', 12); // "orl" cut out of it
      expect((c.attributes.single.start, c.attributes.single.end), (10, 13));
      expect(c.attributes.single.value, 'Serif');
      c.value = v('hello big ', 10);
      expect(c.attributes, isEmpty);
    });

    test('a word made to start a sentence keeps its look', () {
      final c = LiveMarkdownController()..value = v('red', 0, 3);
      c.setAttribute(AttributeType.color, '#C62828');
      c.value = v('red ', 4);
      expect(c.text, 'Red ');
      expect((c.attributes.single.start, c.attributes.single.end), (0, 4)); // (the space takes the look before it, as always)
    });

    test('picked with nothing selected, it goes on what is typed next', () {
      final c = RichInlineTextController()..value = v('ab', 1);
      c.setAttribute(AttributeType.size, '18');
      expect(c.attributeAt(AttributeType.size, 1)?.value, '18');
      c.value = v('aXYb', 3);
      expect(c.attributes.single.type, AttributeType.size);
      expect((c.attributes.single.start, c.attributes.single.end), (1, 3));
      expect(c.attributes.single.sizeValue, 1.5);
    });

    test('is put on and taken off a selection, and cleared', () {
      final c = RichInlineTextController()..value = v('one two three', 4, 7);
      c.toggleAttribute(AttributeType.underline);
      expect(c.hasAttribute(AttributeType.underline, 4, 7), isTrue);
      c.setAttribute(AttributeType.color, '#C62828');
      expect(c.attributes.firstWhere((a) => a.type == AttributeType.color).colorValue, 0xFFC62828);
      c.value = c.value.copyWith(selection: const TextSelection(baseOffset: 0, extentOffset: 13));
      c.clearAttributes();
      expect(c.attributes, isEmpty);
    });
  });

  group('typing in the written document', () {
    test('Enter continues a list, and ends it on an empty item', () {
      expect(typed(v('- a', 3), v('- a\n', 4)).text, '- a\n- ');
      expect(typed(v('  3. a', 6), v('  3. a\n', 7)).text, '  3. a\n  4. ');
      expect(typed(v('- [x] a', 7), v('- [x] a\n', 8)).text, '- [x] a\n- [ ] ');
      expect(typed(v('> a', 3), v('> a\n', 4)).text, '> a\n> ');
      final ended = typed(v('- a\n- ', 6), v('- a\n- \n', 7));
      expect((ended.text, ended.selection.baseOffset), ('- a\n', 4));
      expect(typed(v('plain', 5), v('plain\n', 6)).text, 'plain\n');
    });

    test('the layout of a paragraph goes on to the next one, and stays with it when Enter is at its start', () {
      final next = typed(v('{align=center}Title', 19), v('{align=center}Title\n', 20));
      expect((next.text, next.selection.baseOffset), ('{align=center}Title\n{align=center}', 34));
      final above = typed(v('{align=center}Title', 14), v('{align=center}\nTitle', 15));
      expect((above.text, above.selection.baseOffset), ('\n{align=center}Title', 15));
    });

    test('Backspace takes a list marker or a layout away, and a joined line does not keep its layout token', () {
      final unlisted = typed(v('- a', 2), v('-a', 1));
      expect((unlisted.text, unlisted.selection.baseOffset), ('a', 0));
      expect(typed(v('{align=right}a', 13), v('{align=righta', 12)).text, 'a');
      expect(typed(v('x\n{align=center}y', 1, 1), v('x{align=center}y', 1)).text, 'xy');
    });

    test('the caret does not stop inside the hidden layout', () {
      final c = LiveMarkdownController()..text = '{align=center}Title';
      c.selection = const TextSelection.collapsed(offset: 3);
      expect(c.selection.baseOffset, 14);
    });

    test('a task is ticked and unticked', () {
      final c = LiveMarkdownController()..text = '- [ ] milk';
      c.toggleTask(2);
      expect(c.text, '- [x] milk');
      c.toggleTask(2);
      expect(c.text, '- [ ] milk');
    });
  });

  group('the bar\'s paragraph tools', () {
    test('alignment, indent and spacing are written as the line\'s token, and the usual layout has none', () {
      var x = changeParagraphFormat(v('a\nb', 0, 3), (f) => f.copyWith(align: 'center'));
      expect(x.text, '{align=center}a\n{align=center}b');
      x = changeParagraphFormat(v(x.text, 15), (f) => f.copyWith(indent: 2, spacing: 2));
      expect(x.text, '{align=center indent=2 spacing=2}a\n{align=center}b');
      expect(paragraphFormatAt(x.text, 0), const ParagraphFormat(align: 'center', indent: 2, spacing: 2));
      x = changeParagraphFormat(v(x.text, 1), (f) => ParagraphFormat.plain);
      expect(x.text, 'a\n{align=center}b');
    });

    test('paragraph styles keep the layout; lists nest; rules go on a line of their own; Markdown is cleared', () {
      expect(setLineStyle(v('{align=center}Title', 16), LineStyle.heading4).text, '{align=center}#### Title');
      expect(setLineStyle(v('## Title', 4), null).text, 'Title');
      expect(toggleLineStyle(v('a', 1), LineStyle.task).text, '- [ ] a');
      expect(lineStyleAt('> q', 2), LineStyle.quote);
      expect(nestListItems(v('- a\n- b', 5), deeper: true)!.text, '- a\n  - b');
      expect(nestListItems(v('- a\n  - b', 7), deeper: false)!.text, '- a\n- b');
      expect(nestListItems(v('plain', 2), deeper: true), isNull);
      final ruled = insertRule(v('a\nb', 1));
      expect((ruled.text, ruled.selection.baseOffset), ('a\n---\n\nb', 6));
      final cleared = clearInlineMarkdown(v('**a** and ~~b~~ c', 0, 17));
      expect(cleared.text, 'a and b c');
    });
  });

  group('how it looks', () {
    Future<TextSpan> spanOf(WidgetTester tester, String text, {TextSelection? reveal}) async {
      late TextSpan span;
      final c = RichInlineTextController()..text = text;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          span = liveMarkdownSpan(context, c, documentTextStyle(16), width: 500, reveal: reveal);
          return const SizedBox();
        }),
      ));
      return span;
    }

    testWidgets('the # of a heading shows only while the caret is on it, the stars of bold only while it is in it', (tester) async {
      const text = '# Title\nsome **bold** text';
      final away = await spanOf(tester, text, reveal: TextSelection.collapsed(offset: text.length));
      expect(hiddenIn(away, '# '), isTrue);
      expect(hiddenIn(away, '**'), isTrue);
      expect(shownIn(away, 'Title'), isTrue);
      expect(pieces(away).firstWhere((p) => p.$1 == 'bold').$2!.fontWeight, FontWeight.bold);

      final onHeading = await spanOf(tester, text, reveal: const TextSelection.collapsed(offset: 3));
      expect(shownIn(onHeading, '# '), isTrue);
      expect(hiddenIn(onHeading, '**'), isTrue);

      final inBold = await spanOf(tester, text, reveal: TextSelection.collapsed(offset: text.indexOf('bold') + 2));
      expect(shownIn(inBold, '**'), isTrue);
    });

    testWidgets('fonts, sizes and colours picked from the bar are drawn', (tester) async {
      late TextSpan span;
      final c = RichInlineTextController()..text = 'plain fancy';
      c.attributes.addAll([
        TextSpanAttribute(start: 6, end: 11, type: AttributeType.font, value: 'Serif'),
        TextSpanAttribute(start: 6, end: 11, type: AttributeType.size, value: '24'),
        TextSpanAttribute(start: 6, end: 11, type: AttributeType.color, value: '#C62828'),
      ]);
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
        span = liveMarkdownSpan(context, c, documentTextStyle(16), width: 500);
        return const SizedBox();
      })));
      final fancy = pieces(span).firstWhere((p) => p.$1 == 'fancy').$2!;
      expect(fancy.fontFamily, 'LiberationSerif');
      expect(fancy.fontSize, 32);
      expect(fancy.color, const Color(0xFFC62828));
    });

    testWidgets('a table, a rule and a laid-out paragraph show as themselves until the caret goes into them', (tester) async {
      const text = '{align=center}Centred\n---\n| a | b |\n|---|---|\n| 1 | 2 |';
      final c = LiveMarkdownController()..text = text;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 500, child: TextField(controller: c, maxLines: null, strutStyle: StrutStyle.disabled))),
      ));
      expect(find.byKey(const ValueKey('live-paragraph-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-rule')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-table-0')), findsOneWidget);

      c.revealing = true;
      c.selection = TextSelection.collapsed(offset: text.indexOf('| 1'));
      await tester.pump();
      expect(find.byKey(const ValueKey('live-table-0')), findsNothing);
      expect(find.byKey(const ValueKey('live-paragraph-0')), findsOneWidget);
    });

    testWidgets('a task\'s box is ticked with a tap', (tester) async {
      final c = LiveMarkdownController()..text = '- [ ] milk';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 500, child: TextField(controller: c, maxLines: null))),
      ));
      await tester.tap(find.byKey(const ValueKey('task-0')));
      await tester.pump();
      expect(c.text, '- [x] milk');
    });
  });

  testWidgets('in the editor the document is written as it looks: no preview, a formatting bar, a font kept with the note', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.documentText = '# Title\nsome words here';
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    expect(find.text('Preview'), findsNothing);
    expect(find.text('4 words'), findsOneWidget);

    final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    controller.selection = const TextSelection(baseOffset: 13, extentOffset: 18); // "words"
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('doc-font')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('doc-font-Serif')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('doc-align-center')));
    await tester.pumpAndSettle();
    expect(controller.text, '# Title\n{align=center}some words here');

    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1300)));
    await tester.pump(const Duration(milliseconds: 1000));
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
    expect(saved.documentText, '# Title\n{align=center}some words here');
    final font = saved.documentSpans.single;
    expect((font.type, font.value, saved.documentText.substring(font.start, font.end)), (AttributeType.font, 'Serif', 'words'));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });

  testWidgets('in the editor, pages end where a page break is, things are inserted from the bar, and the document can be exported', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.documentText = 'First page\n\\pagebreak\nSecond page';
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    // (the second page is a sheet of its own, below the first)
    expect(find.byKey(const ValueKey('write-sheet-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('write-sheet-2')), findsNothing);
    expect(find.byKey(const ValueKey('live-page-break')), findsOneWidget);
    expect(find.byKey(const ValueKey('export-document')), findsOneWidget);

    final controller = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    controller.selection = const TextSelection.collapsed(offset: 10);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('doc-insert')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('doc-insert-footnote')));
    await tester.pumpAndSettle();
    expect(controller.text, 'First page[^1]\n\\pagebreak\nSecond page\n\n[^1]: ');
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });
}
