import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:notes/markdown/document_export.dart';
import 'package:notes/markdown/docx_import.dart';
import 'package:notes/markdown/live_markdown.dart';
import 'package:notes/markdown/markdown_formatting.dart';
import 'package:notes/markdown/markdown_parser.dart';
import 'package:notes/models/page_format.dart';
import 'package:notes/models/rich_text.dart';

TextEditingValue v(String text, [int? at]) => TextEditingValue(text: text, selection: TextSelection.collapsed(offset: at ?? text.length));

/// A 2 x 3 pixel PNG.
final png = img.encodePng(img.Image(width: 2, height: 3));

final pages = DocumentPages(format: PageFormat.a4, title: 'Report', date: DateTime(2026, 10, 29));

const sample = '[header]: {title}\n[footer]: Page {page} of {pages}\n\n'
    '{align=center}# Title\n'
    '[toc]\n'
    'Some **bold** and *italic* text[^1].\n'
    '- one\n  - deeper\n1. first\n2. second\n'
    '> a quote\n'
    '| a | b |\n|---|---|\n| 1 | 2 |\n'
    r'\pagebreak' '\n'
    '## Next\n'
    '![A dot|100](image:dot.png)\n\n'
    '[^1]: The note.';

void main() {
  group('the parts of a document', () {
    test('page breaks, the table of contents, footnotes, header and footer, pictures', () {
      final blocks = parseMarkdown(sample);
      expect(documentSettings(blocks), {'header': '{title}', 'footer': 'Page {page} of {pages}'});
      expect(blocks.where((b) => b.type == MdBlockType.toc), hasLength(1));
      expect(blocks.where((b) => b.type == MdBlockType.pageBreak), hasLength(1));
      final note = blocks.firstWhere((b) => b.type == MdBlockType.footnote);
      expect((note.label, note.runs.single.text), ('1', 'The note.'));
      expect(footnoteNumbers(blocks), {'1': 1});
      final picture = blocks.expand((b) => b.runs).firstWhere((r) => r.image != null);
      expect((picture.image, picture.text, picture.imageWidth), ('image:dot.png', 'A dot', 100.0));
      expect(tocEntries(blocks).map((e) => (e.$1, e.$2)), [(1, 'Title'), (2, 'Next')]);
    });

    test('footnotes are numbered in the order the text refers to them', () {
      expect(footnoteNumbers(parseMarkdown('b[^x] a[^y] again[^x]\n[^y]: y\n[^x]: x')), {'x': 1, 'y': 2});
    });

    test('a footnote is put in with the next number, its text at the end with the others', () {
      var x = insertFootnote(v('One. Two.', 4));
      expect(x.text, 'One.[^1] Two.\n\n[^1]: ');
      expect(x.selection.baseOffset, x.text.length);
      x = insertFootnote(v('${x.text}first', 4));
      expect(x.text, 'One.[^2][^1] Two.\n\n[^1]: first\n[^2]: ');
    });

    test('a table of contents and a page break go on lines of their own', () {
      expect(insertBlockLine(v('a\nb', 1), '[toc]').text, 'a\n[toc]\n\nb');
      expect(insertBlockLine(v('a\n\nb', 2), r'\pagebreak').text, 'a\n\\pagebreak\n\nb');
    });

    test('header and footer lines are set, changed and taken away at the top', () {
      var x = setDocumentSetting(v('Text', 2), 'footer', 'Page {page}');
      expect(x.text, '[footer]: Page {page}\n\nText');
      expect(x.selection.baseOffset, 2 + '[footer]: Page {page}\n\n'.length);
      x = setDocumentSetting(x, 'header', 'Mine');
      expect(x.text, '[header]: Mine\n[footer]: Page {page}\n\nText');
      x = setDocumentSetting(x, 'footer', 'P. {page}');
      expect(x.text, '[header]: Mine\n[footer]: P. {page}\n\nText');
      x = setDocumentSetting(x, 'header', '');
      expect(x.text, '[footer]: P. {page}\n\nText');
    });

    test('typing makes quotes curly and -- a dash, but not in code', () {
      expect(typed(v('say ', 4), v('say "', 5)).text, 'say “');
      expect(typed(v('say “hi', 7), v('say “hi"', 8)).text, 'say “hi”');
      expect(typed(v('it', 2), v("it'", 3)).text, 'it’');
      expect(typed(v('a --', 4), v('a -- ', 5)).text, 'a – ');
      expect(typed(v('--', 2), v('-- ', 3)).text, '-- ');
      expect(typed(v('`a', 2), v('`a"', 3)).text, '`a"');
      expect(typed(v('```\nx', 5), v('```\nx"', 6)).text, '```\nx"');
    });

    test('a sentence starts with a capital letter, once its first word is written', () {
      String type(String before) => typed(v(before, before.length), v('$before ', before.length + 1)).text;
      expect(type('hello'), 'Hello ');
      expect(type('Hi there. this'), 'Hi there. This ');
      expect(type('Why? because'), 'Why? Because ');
      expect(type('# title'), '# Title ');
      expect(type('- [ ] milk'), '- [ ] Milk ');
      expect(type('1. first'), '1. First ');
      expect(type('> quoted'), '> Quoted ');
      expect(type('{align=center}middle'), '{align=center}Middle ');
      // not in the middle of a sentence, after a short form, in settings, tables, code or formulas
      expect(type('Hi there'), 'Hi there ');
      expect(type('See e.g. this'), 'See e.g. this ');
      expect(type('Dr. who'), 'Dr. who ');
      expect(type('Wait... what'), 'Wait... what ');
      expect(type('[header]: page'), '[header]: page ');
      expect(type('| cell'), '| cell ');
      expect(type('`code'), '`code ');
      expect(type('```\nlet'), '```\nlet ');
      expect(type('iPhone'), 'iPhone ');
    });
  });

  group('the document as files', () {
    test('plain text and Markdown', () {
      final plain = documentPlainText(sample);
      expect(plain, contains('Title\nContents\nTitle\n  Next\nSome bold and italic text[1].'));
      expect(plain, contains('• one\n  • deeper\n1. first'));
      expect(plain, contains('\f'));
      expect(plain, isNot(contains('[header]')));
      expect(documentMarkdown(sample), contains('\n# Title\n'));
      expect(documentMarkdown(sample), isNot(contains('{align=center}')));
    });

    test('a web page', () {
      final html = documentHtml(sample, [TextSpanAttribute(start: sample.indexOf('text'), end: sample.indexOf('text') + 4, type: AttributeType.font, value: 'Serif')],
          title: 'Report', pictures: {'image:dot.png': png});
      expect(html, contains('<h1 style="text-align:center">Title</h1>'));
      expect(html, contains('<strong>bold</strong>'));
      expect(html, contains("font-family:'Liberation Serif'"));
      expect(html, contains('<sup><a href="#fn-1" id="ref-1">1</a></sup>'));
      expect(html, contains('data:image/png;base64,'));
      expect(html, contains('page-break-after:always'));
    });

    test('a PDF cut into pages', () async {
      final c = RichInlineTextController()..text = sample;
      final bytes = await documentPdf(c, pages, pictures: {'image:dot.png': png});
      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      // the page break makes a second page
      expect(RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes)).length, greaterThanOrEqualTo(2));
    });

    test('a Word document, read back in', () async {
      final at = sample.indexOf('italic');
      final spans = [
        TextSpanAttribute(start: at, end: at + 6, type: AttributeType.font, value: 'Serif'),
        TextSpanAttribute(start: at, end: at + 6, type: AttributeType.color, value: '#C62828'),
      ];
      final docx = documentDocx(sample, spans, pages, pictures: {'image:dot.png': png});
      final zip = ZipDecoder().decodeBytes(docx);
      final xml = utf8.decode(zip.findFile('word/document.xml')!.content as List<int>);
      expect(xml, contains('<w:pStyle w:val="Heading1"/>'));
      expect(xml, contains('<w:jc w:val="center"/>'));
      expect(xml, contains('<w:footnoteReference w:id="1"/>'));
      expect(xml, contains('<w:br w:type="page"/>'));
      expect(xml, contains('TOC \\o'));
      expect(xml, contains('w:ascii="Times New Roman"'));
      expect(zip.findFile('word/media/image1.png'), isNotNull);
      expect(utf8.decode(zip.findFile('word/footer1.xml')!.content as List<int>), contains('PAGE'));
      expect(utf8.decode(zip.findFile('word/footnotes.xml')!.content as List<int>), contains('The note.'));

      final kept = <String>[];
      final back = await importDocx(docx, keepPicture: (b, ext) async {
        kept.add(ext);
        return 'image:back.$ext';
      });
      expect(back.text, startsWith('[header]: Report\n[footer]: Page {page} of {pages}\n\n'));
      expect(back.text, contains('{align=center}# Title'));
      expect(back.text, contains('[toc]'));
      expect(back.text, contains('Some **bold** and *italic* text[^1].'));
      expect(back.text, contains('- one\n  - deeper\n1. first\n2. second'));
      expect(back.text, contains('> a quote'));
      expect(back.text, contains('| a | b |\n|---|---|\n| 1 | 2 |'));
      expect(back.text, contains('\\pagebreak\n## Next'));
      expect(back.text, contains('](image:back.png)'));
      expect(back.text, endsWith('[^1]: The note.'));
      expect(kept, ['png']);
      final font = back.spans.firstWhere((s) => s.type == AttributeType.font);
      expect((font.value, back.text.substring(font.start, font.end)), ('Serif', 'italic'));
      expect(back.spans.firstWhere((s) => s.type == AttributeType.color).value, '#C62828');
    });

    test('something that is not a Word document is said to be so', () async {
      await expectLater(importDocx(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    });

    test('a zip with a flood of files is refused as too big', () async {
      final flood = Archive();
      for (var i = 0; i < 10001; i++) {
        flood.addFile(ArchiveFile.bytes('f$i', const [1]));
      }
      final bytes = Uint8List.fromList(ZipEncoder().encode(flood));
      await expectLater(importDocx(bytes), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('too big'))));
    });

    test('a zip that is no Word document (no word/document.xml) is said to be so', () async {
      final other = Archive()..addFile(ArchiveFile.bytes('hello.txt', utf8.encode('hi')));
      await expectLater(importDocx(Uint8List.fromList(ZipEncoder().encode(other))), throwsFormatException);
    });

    test('the size of a picture is read from its header', () {
      expect(pictureSize(png), (2, 3));
    });
  });

  testWidgets('footnotes, the contents, a page break and the footer show as themselves', (tester) async {
    late TextSpan span;
    final c = RichInlineTextController()..text = sample;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      span = liveMarkdownSpan(context, c, documentTextStyle(16), width: 500);
      return SizedBox(width: 500, child: RichText(text: span));
    })));
    expect(find.byKey(const ValueKey('footnote-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-toc')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-page-break')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-setting-footer')), findsOneWidget);
    expect(find.textContaining('Next'), findsWidgets); // (in the contents)
  });

  group('tracked changes and comments', () {
    TextEditingValue apply(TextEditingValue old, TextEditingValue now) => suggested(old, now) ?? now;

    test('are read from their marks', () {
      final runs = parseMarkdown('{++new++} {--old--} {==this==}{>>a note<<}').single.runs;
      expect(runs.firstWhere((r) => r.inserted).text, 'new');
      expect(runs.firstWhere((r) => r.deleted).text, 'old');
      expect(runs.firstWhere((r) => r.commented).text, 'this');
      expect(runs.firstWhere((r) => r.comment).text, 'a note');
      expect(wordCount('{++new++} {--old--} kept{>>a note<<}'), 2);
    });

    test('typing is marked as put in, deleting as taken out', () {
      var x = apply(v('ab', 1), v('axb', 2));
      expect((x.text, x.selection.baseOffset), ('a{++x++}b', 5));
      x = apply(x, v('a{++xy++}b', 6)); // typed on in it
      expect(x.text, 'a{++xy++}b');
      x = apply(x, v('a{++x++}b', 5)); // a mistake in it taken out for good
      expect(x.text, 'a{++x++}b');
      x = apply(x, v('a{++++}b', 4)); // and the rest of it: it goes
      expect((x.text, x.selection.baseOffset), ('ab', 1));

      x = apply(v('abc', 2), v('ac', 1)); // Backspace
      expect((x.text, x.selection.baseOffset), ('a{--b--}c', 1));
      x = apply(x, v('{--b--}c', 0)); // and again, before it: it grows
      expect((x.text, x.selection.baseOffset), ('{--ab--}c', 0));
      x = apply(v('abc', 1), v('ac', 1)); // Delete
      expect((x.text, x.selection.baseOffset), ('a{--b--}c', 8));

      x = apply(v('one two', 4), const TextEditingValue(text: 'one 2', selection: TextSelection.collapsed(offset: 5)));
      expect(x.text, 'one {--two--}{++2++}');
    });

    test('a line break typed in a change ends it there and goes on with it on the next line', () {
      String br(String text, int at) {
        final x = apply(v(text, at), v(text.replaceRange(at, at, '\n'), at + 1));
        return '${x.text.substring(0, x.selection.baseOffset)}|${x.text.substring(x.selection.baseOffset)}';
      }

      expect(br('{++something++}', 12), '{++something++}\n|'); // (at its end)
      expect(br('{++somenew++}', 7), '{++some++}\n{++|new++}');
      expect(br('a {--oldgone--} b', 8), 'a {--old--}\n|{--gone--} b');
      expect(br('- {++milk++}', 9), '- {++milk++}\n- |'); // (a list goes on)
      expect(br('plain', 2), 'pl\n|ain'); // (not in a change: as usual)
    });

    test('the controller tracks what is typed while tracking is on', () {
      final c = LiveMarkdownController()..value = v('Hello world', 5);
      c.suggesting = true;
      c.value = v('Hello, world', 6);
      expect(c.text, 'Hello{++,++} world');
      c.suggesting = false;
      c.value = v('${c.text}!');
      expect(c.text, 'Hello{++,++} world!');
    });

    test('are accepted or rejected, one or all', () {
      const text = 'a {++new++} b {--old--} c';
      String done(List<({int start, int end, String text})> edits) {
        var out = text;
        for (final e in edits.reversed) {
          out = out.replaceRange(e.start, e.end, e.text);
        }
        return out;
      }

      expect(done(decideChanges(text, accept: true)), 'a new b  c');
      expect(done(decideChanges(text, accept: false)), 'a  b old c');
      expect(done(decideChanges(text, accept: true, only: const TextSelection.collapsed(offset: 5))), 'a new b {--old--} c');
      expect(hasTrackedChanges(text), isTrue);
      expect(settledText('x {==y==}{>>why<<} {--z--}'), 'x y ');
    });

    test('a comment goes on the selection, or at the caret', () {
      expect(addComment(const TextEditingValue(text: 'one two', selection: TextSelection(baseOffset: 4, extentOffset: 7)), 'Why?').text,
          'one {==two==}{>>Why?<<}');
      expect(addComment(v('one', 3), 'Hm').text, 'one{>>Hm<<}');
    });

    test('are Word\'s own in a Word document, and read back', () async {
      const text = 'Kept {++new++}{--old--} and {==this==}{>>Check it<<} too.';
      final docx = documentDocx(text, const [], pages);
      final zip = ZipDecoder().decodeBytes(docx);
      final xml = utf8.decode(zip.findFile('word/document.xml')!.content as List<int>);
      expect(xml, contains('<w:ins '));
      expect(xml, contains('<w:delText xml:space="preserve">old</w:delText>'));
      expect(xml, contains('<w:commentRangeStart w:id="0"/>'));
      expect(utf8.decode(zip.findFile('word/comments.xml')!.content as List<int>), contains('Check it'));
      expect((await importDocx(docx)).text, text);
      expect(documentPlainText(text), 'Kept new and this too.');
      expect(documentHtml(text, const []), contains('<ins>new</ins><del>old</del>'));
    });
  });
}
