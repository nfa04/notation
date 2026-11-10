import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/block_editor.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_file.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/markdown/document_export.dart';
import 'package:notes/markdown/docx_import.dart';
import 'package:notes/markdown/grammar.dart';
import 'package:notes/markdown/html_import.dart';
import 'package:notes/markdown/live_markdown.dart';
import 'package:notes/markdown/markdown_formatting.dart';
import 'package:notes/markdown/markdown_parser.dart';
import 'package:notes/markdown/markdown_table.dart';
import 'package:notes/models/page_format.dart';
import 'package:notes/models/rich_text.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/lookup_panel.dart';
import 'package:notes/speech/speakable_text.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

TextEditingValue v(String text, [int? at]) => TextEditingValue(text: text, selection: TextSelection.collapsed(offset: at ?? text.length));

final pages = DocumentPages(format: PageFormat.a4, title: 'T', date: DateTime(2026, 10, 29));

void main() {
  setUpAll(AppDatabase.initFfi);

  group('tables', () {
    const table = 'Before\n| a | b |\n| --- | --- |\n| 1 | 2 |\nAfter';

    test('the table at the caret, and the row and column the caret is in', () {
      final t = tableAt(table, table.indexOf('2'))!;
      expect((t.row, t.column, t.lines.length), (1, 1, 3));
      expect(tableAt(table, 2), isNull);
    });

    test('rows and columns are added and deleted, and columns aligned', () {
      var x = editTable(v(table, table.indexOf('1')), TableAction.rowBelow)!;
      expect(x.text, 'Before\n| a | b |\n| --- | --- |\n| 1 | 2 |\n|  |  |\nAfter');
      x = editTable(v(table, table.indexOf('b')), TableAction.columnRight)!;
      expect(x.text, 'Before\n| a | b |  |\n| --- | --- | --- |\n| 1 | 2 |  |\nAfter');
      x = editTable(v(table, table.indexOf('1')), TableAction.deleteRow)!;
      expect(x.text, 'Before\n| a | b |\n| --- | --- |\nAfter');
      expect(editTable(v(table, table.indexOf('a')), TableAction.deleteRow), isNull); // (the head stays)
      x = editTable(v(table, table.indexOf('2')), TableAction.alignCenter)!;
      expect(x.text, contains('| --- | :-: |'));
      expect(parseMarkdown(x.text).firstWhere((b) => b.type == MdBlockType.table).aligns, ['', 'center']);
      x = editTable(v(table, table.indexOf('a')), TableAction.deleteColumn)!;
      expect(x.text, 'Before\n| b |\n| --- |\n| 2 |\nAfter');
    });

    test('alignment reaches the Word document and the web page', () {
      const aligned = '| a | b |\n| :-: | --: |\n| 1 | 2 |';
      expect(documentHtml(aligned, const []), contains('<td style="text-align:right">2</td>'));
      final xml = utf8.decode(ZipDecoder().decodeBytes(documentDocx(aligned, const [], pages)).findFile('word/document.xml')!.content as List<int>);
      expect(xml, contains('<w:jc w:val="center"/>'));
    });
  });

  group('named styles', () {
    test('are read from the document and written back', () {
      final x = setDocumentSetting(v('# Hi'), 'style-h1', const NamedStyle(font: 'Serif', size: 20, color: 0xFF1565C0).toString());
      expect(x.text, '[style-h1]: font=Serif size=20 color=#1565C0\n\n# Hi');
      final style = documentStyles(parseMarkdown(x.text))['h1']!;
      expect((style.font, style.size, style.color), ('Serif', 20.0, 0xFF1565C0));
    });

    testWidgets('give their paragraphs their look, under what is picked for single words', (tester) async {
      late TextSpan span;
      final c = RichInlineTextController()..text = '[style-h1]: font=Serif size=24 color=#1565C0\n# Big title\nbody';
      final at = c.text.indexOf('title');
      c.attributes.add(TextSpanAttribute(start: at, end: at + 5, type: AttributeType.color, value: '#C62828'));
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
        span = liveMarkdownSpan(context, c, documentTextStyle(16), width: 500);
        return const SizedBox();
      })));
      final pieces = <(String, TextStyle?)>[];
      span.visitChildren((s) {
        if (s is TextSpan && s.text != null) pieces.add((s.text!, s.style));
        return true;
      });
      final big = pieces.firstWhere((p) => p.$1.contains('Big')).$2!;
      expect((big.fontFamily, big.fontSize, big.color), ('LiberationSerif', 32.0, const Color(0xFF1565C0)));
      expect(pieces.firstWhere((p) => p.$1.contains('title')).$2!.color, const Color(0xFFC62828));
    });

    test('are Word\'s styles and CSS', () {
      const text = '[style-h1]: font=Serif size=20\n[style-body]: color=#424242\n# A\nb';
      final styles = utf8.decode(ZipDecoder().decodeBytes(documentDocx(text, const [], pages)).findFile('word/styles.xml')!.content as List<int>);
      expect(styles, contains('<w:rFonts w:ascii="Times New Roman"'));
      expect(styles, contains('<w:color w:val="424242"/>'));
      final html = documentHtml(text, const []);
      expect(html, contains('h1 { font-family:'));
      expect(html, contains('p, li, blockquote { color: #424242 }'));
    });
  });

  group('captions and cross-references', () {
    const text = '# Intro {#intro}\n![x](a.png)\nFigure: A cat {#fig:cat}\n| a |\n|---|\n| 1 |\nTable: Numbers {#tbl:n}\nFigure: A dog\nSee {@fig:cat}, {@tbl:n} and {@intro}.';

    test('captions are numbered, references read as what they point to', () {
      final blocks = parseMarkdown(text);
      expect(blocks.where((b) => b.type == MdBlockType.caption).map((b) => b.label), ['figure', 'table', 'figure']);
      expect(crossReferences(blocks), {'intro': 'Intro', 'fig:cat': 'Figure 1', 'tbl:n': 'Table 1'});
      expect(documentPlainText(text), contains('Figure 1: A cat\n'));
      expect(documentPlainText(text), contains('Figure 2: A dog\nSee Figure 1, Table 1 and Intro.'));
    });

    test('a reference is put in, and a heading without a name gets one', () {
      final x = insertCrossReference(v('# Methods\nAs said in ', 21), 0);
      expect(x.text, '# Methods {#sec:methods}\nAs said in {@sec:methods}');
      expect(referenceTargets(text).map((t) => t.$2), ['Intro', 'Figure 1: A cat', 'Table 1: Numbers', 'Figure 2: A dog']);
    });
  });

  test('grammar: twice, two spaces, a space before a mark, a small sentence start, a and an', () {
    final issues = grammarIssues('This is is fine.  it works , mostly. A apple and an pear. An hour, a user, e.g. this.\n`code  is code`');
    expect([for (final g in issues) (g.message, g.replacement)], [
      ('"is" is written twice', 'is'),
      ('Two spaces', ' '),
      ('A sentence starts with a capital letter', 'I'),
      ('A space before ","', ','),
      ('"an" before a vowel', 'An'),
      ('"a" before a consonant', 'a'),
    ]);
  });

  test('columns go into the Word document and the web page', () {
    const text = '[columns]: 2\n\nText';
    expect(utf8.decode(ZipDecoder().decodeBytes(documentDocx(text, const [], pages)).findFile('word/document.xml')!.content as List<int>),
        contains('<w:cols w:num="2"'));
    expect(documentHtml(text, const []), contains('column-count: 2'));
  });

  test('formatted text from the clipboard keeps its formatting', () {
    final read = importHtml('<h2 style="text-align:center">Title</h2><p>Some <b>bold</b> and <span style="color:rgb(198,40,40);font-family:Georgia">red serif</span>'
        ' <a href="https://a.b">link</a>.</p><ul><li>one<ul><li>two</li></ul></li></ul><ol start="3"><li>three</li></ol><blockquote>said</blockquote>'
        '<table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>');
    expect(read.text,
        '{align=center}## Title\nSome **bold** and red serif [link](https://a.b).\n- one\n  - two\n3. three\n> said\n| a | b |\n| --- | --- |\n| 1 | 2 |');
    final color = read.spans.firstWhere((s) => s.type == AttributeType.color);
    expect((read.text.substring(color.start, color.end), color.value), ('red serif', '#C62828'));
    expect(read.spans.firstWhere((s) => s.type == AttributeType.font).value, 'Serif');
  });

  test('a yellow highlight, superscript and subscript come in as Markdown', () async {
    final read = importHtml('<p>H<sub>2</sub>O and x<sup>2</sup>, <mark>key</mark>, <span style="background-color:#a5d6a7">green</span>,'
        ' <sup>a b</sup>.</p>');
    expect(read.text, 'H~2~O and x^2^, ==key==, green, a b.');
    final green = read.spans.firstWhere((s) => s.type == AttributeType.highlight);
    expect((read.text.substring(green.start, green.end), green.value), ('green', '#A5D6A7'));
    final raised = read.spans.firstWhere((s) => s.type == AttributeType.superscript);
    expect(read.text.substring(raised.start, raised.end), 'a b'); // (with a space: no Markdown for it)

    // and from Word
    const text = 'H~2~O and x^2^, ==key==.';
    final docx = documentDocx(text, const [], DocumentPages(format: PageFormat.a4, title: 'T', date: DateTime(2026, 10, 29)));
    final back = await importDocx(docx);
    expect(back.text, text);
    expect(back.spans, isEmpty);
  });

  test('a note file carries the pictures of the written document', () {
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
    final note = NoteData(id: 'n', documentText: 'A picture: ![dot](image:n-doc-1.png)');
    final parsed = decodeNoteFile(encodeNoteFile(NoteFileParts(note, documentImages: {'image:n-doc-1.png': png})));
    expect(parsed.documentImages, {'image:n-doc-1.png': png});
  });

  test('a word is looked up in a thesaurus', () {
    expect(LookupSource.synonyms.urlFor('happy').toString(), 'https://www.thesaurus.com/browse/happy');
  });

  test('reading aloud skips the document\'s own marks', () {
    expect(speakableText('[footer]: Page {page}\n{align=center}# Title {#t}\nSay {++this++}{--that--}{>>a note<<}, see {@t}.\n[toc]'),
        'Title\nSay this, see.');
  });

  testWidgets('in the editor: the format painter, a template, focus mode', (tester) async {
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
      note.documentText = 'one **two** three';
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    final c = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    // (the bar is wider than the screen: a button is scrolled to first)
    Future<void> tapBar(String key) async {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    Future<void> view(String key) async {
      await tapBar('doc-view');
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    c.attributes.add(TextSpanAttribute(start: 6, end: 9, type: AttributeType.font, value: 'Serif'));

    // the painter: copied from "two" (bold, Serif), put on "three"
    c.selection = const TextSelection.collapsed(offset: 7);
    await tester.pump();
    await tapBar('doc-painter');
    expect(c.copiedLook, isNotNull);
    c.selection = const TextSelection(baseOffset: 12, extentOffset: 17);
    await tester.pump();
    await tapBar('doc-painter');
    expect(c.text, 'one **two** **three**');
    expect(c.attributes.where((a) => a.type == AttributeType.font && c.text.substring(a.start, a.end) == 'three'), hasLength(1));
    expect(c.copiedLook, isNull);

    // focus mode and the reading view are switched; a selection says how many words it has
    await view('doc-focus');
    expect(c.focusMode, isTrue);
    expect(find.text('1 of 3 words'), findsOneWidget); // ("three" is still selected)
    await view('doc-reading');
    expect(c.readingView, isTrue);
    await view('doc-reading');

    // a theme sets the styles together
    await tapBar('doc-styles');
    await tester.tap(find.byKey(const ValueKey('style-theme-Classic')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('styles-ok')));
    await tester.pumpAndSettle();
    expect(c.text, startsWith('[style-body]: font=Serif\n[style-h1]: font=Serif size=22\n'));
    c.setDirectly(TextEditingValue(text: c.text.substring(c.text.indexOf('one'))));
    await tester.pump();

    // a template, after what is there
    await tapBar('doc-insert');
    await tester.tap(find.byKey(const ValueKey('doc-insert-template')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('template-Meeting notes')));
    await tester.pumpAndSettle();
    expect(c.text, startsWith('one **two** **three**\n\n# [Meeting] - [date]'));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });

  test('superscript and subscript are written as Pandoc writes them, not over spaces', () {
    final runs = parseMarkdown('H~2~O, x^2^, ~5 to ~10, ~~gone~~').single.runs;
    expect(runs.where((r) => r.subscript).map((r) => r.text), ['2']);
    expect(runs.where((r) => r.superscript).map((r) => r.text), ['2']);
    expect(runs.where((r) => r.strike).map((r) => r.text), ['gone']);
    expect(runs.where((r) => !r.subscript && !r.strike).map((r) => r.text).join(), contains('~5 to ~10'));
    expect(toggleInline(const TextEditingValue(text: '~~a~~', selection: TextSelection(baseOffset: 2, extentOffset: 3)), '~').text, '~~~a~~~');
  });

  testWidgets('in the editor: the buttons write in Markdown what Markdown has', (tester) async {
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
      note.documentText = 'water H2O and x2 big words';
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    final c = tester.widget<BlockEditor>(find.byType(BlockEditor)).controller;
    Future<void> tapBar(String key) async {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    Future<void> select(String word, {int skip = 0}) async {
      var at = c.text.indexOf(word);
      for (var k = 0; k < skip; k++) {
        at = c.text.indexOf(word, at + 1);
      }
      c.selection = TextSelection(baseOffset: at, extentOffset: at + word.length);
      await tester.pump();
    }

    Future<void> highlight(String hex) async {
      await tapBar('doc-highlight');
      await tester.tap(find.text(hex).last);
      await tester.pumpAndSettle();
    }

    await select('2');
    await tapBar('doc-subscript');
    expect(c.text, 'water H~2~O and x2 big words');
    c.selection = const TextSelection.collapsed(offset: 9); // (the caret in it: it is taken off again)
    await tester.pump();
    await tapBar('doc-subscript');
    expect(c.text, 'water H2O and x2 big words');

    await select('2', skip: 1);
    await tapBar('doc-superscript');
    expect(c.text, 'water H2O and x^2^ big words');
    await tapBar('doc-subscript'); // (the one goes, the other comes)
    expect(c.text, 'water H2O and x~2~ big words');

    await select('big words'); // (a space: Markdown cannot raise it, the look of the text does)
    await tapBar('doc-superscript');
    expect(c.text, 'water H2O and x~2~ big words');
    expect(c.attributes.single.type, AttributeType.superscript);
    await tapBar('doc-superscript');
    expect(c.attributes, isEmpty);

    await select('words');
    await highlight('#FFF176');
    expect(c.text, 'water H2O and x~2~ big ==words==');
    await highlight('#A5D6A7'); // (another colour has no Markdown)
    expect(c.text, 'water H2O and x~2~ big words');
    expect(c.attributes.single.value, '#A5D6A7');
    expect(c.text.substring(c.attributes.single.start, c.attributes.single.end), 'words');
    await highlight('#FFF176');
    expect(c.text, 'water H2O and x~2~ big ==words==');
    expect(c.attributes, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
  });
}
