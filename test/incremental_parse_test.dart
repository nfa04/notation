import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/markdown/grammar.dart';
import 'package:notes/markdown/markdown_formatting.dart';
import 'package:notes/markdown/markdown_parser.dart';

String run(MdRun r) => '${r.text}@${r.src}/${r.bold}${r.italic}${r.strike}${r.code}${r.highlight}${r.superscript}${r.subscript}${r.inserted}${r.deleted}${r.commented}${r.comment}${r.math}/${r.link}/${r.cite?.length}/${r.footnote}/${r.ref}/${r.image}/${r.imageWidth}';

/// All that is in [b], to compare.
String all(MdBlock b) => [
      b.type, b.level, b.code, b.lang, b.start, b.end, b.tokenEnd, b.contentStart, b.depth, b.checked, b.label, b.format.align, b.format.indent, b.format.spacing, b.aligns,
      [for (final r in b.runs) run(r)],
      [for (final row in b.rows) [for (final cell in row) [for (final r in cell) run(r)]]],
      [for (final m in b.markup) '${m.kind}${m.start},${m.end},${m.innerStart},${m.innerEnd},${m.id}'],
    ].join('|');

void main() {
  const lines = [
    'A line of plain text', '', '# Heading', '## Another', '- item', '- [ ] task', '- [x] done', '1. first', '> quote', '---', '```', '```dart', 'code in it', '~~~',
    '| a | b |', '|---|---|', '| 1 | 2 |', r'$$x^2$$', '**bold** and *italic* and `code`', '[link](note:abc)', '[^1]: a note', '{align=center}Centred', 'Figure: a cat {#fig:cat}',
    '[toc]', '[pagebreak]', '[bibliography]', '{@fig:cat} and [@smith2020]', '{++in++}{--out--}{>>said<<}', '   ', '|not a table',
  ];
  const typed = ['a', ' ', '\n', '\n\n', '`', '```', '```\n', '|', '| x |', '|---|', '#', '# ', '- ', '**', '~~~\n', '\$\$', '[', '{', 'word\nword'];

  test('a change gives what reading all of the text gives, whatever the change is', () {
    final r = Random(11);
    var edited = 0, partly = 0;
    for (var round = 0; round < 1500; round++) {
      var text = List.generate(1 + r.nextInt(16), (_) => lines[r.nextInt(lines.length)]).join('\n');
      var blocks = parseMarkdown(text);
      for (var step = 0; step < 12; step++) {
        final from = r.nextInt(text.length + 1);
        final to = r.nextInt(3) == 0 ? min(text.length, from + r.nextInt(30)) : from;
        final put = r.nextInt(3) == 0 ? '' : typed[r.nextInt(typed.length)];
        final now = text.replaceRange(from, to, put);
        final made = reparsed(text, blocks, now);
        expect([for (final b in made.blocks) all(b)], [for (final b in parseMarkdown(now)) all(b)], reason: 'from ${jsonish(text)} to ${jsonish(now)}');
        expect(wordCount(now, blocks: made.blocks), wordCount(now));
        edited++;
        if (made.changedFrom != null) partly++;
        text = now;
        blocks = made.blocks;
      }
    }
    expect(partly, greaterThan(edited ~/ 2), reason: 'it should not read everything most of the time');
  });

  test('the grammar check of a change finds what checking all of the text finds', () {
    const pieces = ['It was over.', 'then it went on', 'the the', 'word word', 'word', 'a apple', 'an pear', 'two  spaces', 'a space , here', 'e.g. this', 'And so...', '', '', '   ', '`code the the`', '# Heading', '- item', '```', 'an', 'hour', 'a', 'apple', 'done.', 'next'];
    const typed = ['a', ' ', '  ', '\n', '\n\n', '.', '. ', ',', 'the', 'the ', 'an ', 'a ', '```', '```\n', '`', '...'];
    String shown(List<GrammarIssue> issues) => ([for (final g in issues) '${g.start}:${g.end}:${g.message}:${g.replacement}']..sort()).join('\n');
    final r = Random(5);
    var issues = 0, partly = 0;
    for (var round = 0; round < 1500; round++) {
      var text = List.generate(1 + r.nextInt(18), (_) => pieces[r.nextInt(pieces.length)]).join('\n');
      var parsed = ParsedText(text, parseMarkdown(text));
      var found = grammarIssues(text, blocks: parsed.blocks);
      for (var step = 0; step < 12; step++) {
        final from = r.nextInt(text.length + 1);
        final to = r.nextInt(3) == 0 ? min(text.length, from + r.nextInt(12)) : from;
        final now = text.replaceRange(from, to, r.nextInt(3) == 0 ? '' : typed[r.nextInt(typed.length)]);
        final made = reparsed(text, parsed.blocks, now);
        final after = grammarIssuesAfter(made, text, found);
        expect(shown(after), shown(grammarIssues(now)), reason: 'from ${jsonish(text)} to ${jsonish(now)}');
        issues += after.length;
        if (made.changedFrom != null) partly++;
        text = now;
        parsed = made;
        found = after;
      }
    }
    expect(issues, greaterThan(5000));
    expect(partly, greaterThan(5000));
  });

  test('typing into one paragraph of a long text reads only that paragraph', () {
    final text = List.generate(2000, (i) => 'Line number $i of the text').join('\n');
    final blocks = parseMarkdown(text);
    final at = text.indexOf('Line number 900');
    final made = reparsed(text, blocks, text.replaceRange(at, at, 'x'));
    expect(made.changedFrom, at);
    expect(made.changedTo - made.changedFrom!, 'xLine number 900 of the text'.length);
    expect(identical(made.blocks[10], blocks[10]), isTrue);
  });
}

String jsonish(String s) => s.replaceAll('\n', r'\n');
