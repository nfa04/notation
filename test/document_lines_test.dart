import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/block_editor/document_lines.dart';
import 'package:notes/markdown/live_markdown.dart';
import 'package:notes/markdown/markdown_parser.dart';

void main() {
  group('the lines of the document', () {
    test('every line of a text is a block, a blank one too', () {
      for (final text in const ['', 'a', '\n', 'a\n', '\na', 'a\n\nb', '| a |\n|---|\n| b |\n\nc', '```\ncode\n```\nnext', '```\nopen', 'a\n\n\n']) {
        final blocks = parseMarkdown(text);
        expect(blocks, isNotEmpty, reason: 'in ${jsonish(text)}');
        expect(blocks.first.start, 0, reason: 'in ${jsonish(text)}');
        expect(blocks.last.end, text.length, reason: 'in ${jsonish(text)}');
        for (var i = 1; i < blocks.length; i++) {
          expect(blocks[i].start, blocks[i - 1].end + 1, reason: 'in ${jsonish(text)}');
        }
      }
    });

    test('whatever is typed, the lines are those of the text and the others keep what they had', () {
      const pieces = ['# Heading', 'A paragraph.', '- item', '- [ ] task', '| a | b |\n|---|---|\n| 1 | 2 |', '```\ncode\n```', '', '> quote', '\$\$x\$\$'];
      const typed = ['a', ' ', '\n', '\n\n', '`', '```', '```\n', '|', '| x |', '|---|', '#', '# ', '- ', 'word\nword'];
      for (var seed = 0; seed < 300; seed++) {
        final r = Random(seed);
        var text = List.generate(1 + r.nextInt(16), (_) => pieces[r.nextInt(pieces.length)]).join('\n');
        var parsed = ParsedText(text, parseMarkdown(text));
        final model = DocumentLines((_) => 10)..update(parsed);
        for (final l in model.lines) {
          model.setHeight(l, 10.0 + l.id);
        }
        for (var step = 0; step < 40; step++) {
          final p = r.nextInt(text.length + 1), q = min(text.length, p + (r.nextBool() ? 0 : r.nextInt(6)));
          final now = text.replaceRange(p, q, r.nextBool() ? typed[r.nextInt(typed.length)] : '');
          if (now == text) continue;
          final before = {for (final l in model.lines) l.id: (l, model.blocks[l.index], l.version, l.height)};
          parsed = reparsed(text, parsed.blocks, now);
          final change = model.update(parsed);
          text = now;

          final why = 'seed $seed step $step in ${jsonish(text)}';
          expect(model.length, parsed.blocks.length, reason: why);
          for (var i = 0; i < model.length; i++) {
            expect(model.lines[i].index, i, reason: why);
          }
          var y = 0.0;
          for (var i = 0; i < model.length; i++) {
            expect(model.topOf(i), y, reason: why);
            expect(model.lineAtY(y), i, reason: why);
            y += model.lines[i].height;
          }
          expect(model.height, y, reason: why);
          for (final b in parsed.blocks) {
            expect(model.lines[model.lineAt(b.start)].index, parsed.blocks.indexOf(b), reason: why);
          }
          // a line that did not change is the same line, with the same height
          if (change == null) continue;
          for (var i = 0; i < model.length; i++) {
            final l = model.lines[i];
            if (i >= change.first && i < change.end) continue;
            final was = before[l.id];
            expect(was, isNotNull, reason: why);
            expect(l.version, was!.$3, reason: why);
            expect(l.height, was.$4, reason: why);
            expect(now.substring(model.blocks[i].start, model.blocks[i].end), isNotNull);
            expect(model.blocks[i].type, was.$2.type, reason: why);
            expect(model.blocks[i].end - model.blocks[i].start, was.$2.end - was.$2.start, reason: why);
          }
          for (final l in model.lines) {
            if (!l.measured) model.setHeight(l, 10.0 + l.id);
          }
        }
      }
    });

    test('a key in a long text changes one line', () {
      final text = List.generate(3000, (i) => 'Line number $i of the text').join('\n');
      final model = DocumentLines((_) => 24)..update(ParsedText(text, parseMarkdown(text)));
      final now = text.replaceRange(4000, 4000, 'x');
      final change = model.update(reparsed(text, model.blocks, now))!;
      expect(change.end - change.first, 1);
      expect(change.sameCount, isTrue);
    });
  });

  group('the lines on sheets of paper', () {
    const room = 900.0, step = 1124.0;

    test('no row of any line is ever off a sheet, whatever the lines are, and a key moves only what comes after it', () {
      for (var seed = 0; seed < 200; seed++) {
        final r = Random(seed);
        final count = 5 + r.nextInt(300);
        final text = List.generate(count, (i) => r.nextInt(30) == 0 ? r'\\pagebreak' : 'line $i').join('\n');
        final m = DocumentLines((_) => 24)
          ..sheets = (room: room, step: step)
          ..update(ParsedText(text, parseMarkdown(text)));
        for (final l in m.lines) {
          final rows = 1 + r.nextInt(r.nextInt(10) == 0 ? 60 : 8);
          l.rows = rows == 1 ? null : [for (var k = 1; k <= rows; k++) k * 24.0];
          m.setHeight(l, rows * 24.0);
        }
        var last = -1.0;
        for (var i = 0; i < m.length; i++) {
          final l = m.lines[i];
          final top = m.topOf(i);
          expect(top, greaterThanOrEqualTo(last), reason: 'seed $seed line $i goes back up');
          for (var k = 0; k < l.height ~/ 24; k++) {
            final y = top + k * 24.0 + l.shift(k * 24.0);
            final sheet = (y / step).floor() * step;
            expect(y + 24, lessThanOrEqualTo(sheet + room + 0.5), reason: 'seed $seed line $i row $k runs off the sheet');
          }
          expect(l.natural(l.shift(12) + 12), 12, reason: 'there and back');
          if (i > 0 && m.blocks[i - 1].type == MdBlockType.pageBreak && top % step > 0.5) fail('seed $seed: nothing may follow a page break on its sheet');
          last = top + l.height + l.breaks.fold(0.0, (a, b) => a + b.gap);
        }
        expect(m.height, last);
        expect(m.sheetCount, ((last - 1) / step).floor() + 1, reason: 'there is paper under the last row');
      }
    });

    test('a row taller than a sheet runs over it and the text goes on after it', () {
      const text = 'a\nb\nc';
      final m = DocumentLines((_) => 24)
        ..sheets = (room: room, step: step)
        ..update(ParsedText(text, parseMarkdown(text)));
      m.setHeight(m.lines[1], 2000);
      expect(m.topOf(0), 0);
      expect(m.topOf(1), step, reason: 'it starts on a sheet of its own');
      expect(m.topOf(2), greaterThanOrEqualTo(step + 2000));
      expect(m.topOf(2) % step, lessThan(room));
    });
  });

  group('one block drawn alone', () {
    testWidgets('looks as it does with all of the text', (tester) async {
      const doc = '# Heading\n\nSome **bold** text and a [link](https://x.y) and \$x^2\$.\n\n- item one\n- [ ] a task\n- [x] done\n\n'
          '> a quote\n\n{align=center}Centred\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```dart\nvar x = 1;\n```\n\n1. one\n2. two\n\nFootnote[^1] here\n\n[^1]: the note\n\nFigure: A caption\n\n---\n\nEnd';
      final c = LiveMarkdownController()..value = const TextEditingValue(text: doc);
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })));
      const base = TextStyle(fontSize: 16);
      for (final reveal in [null, const TextSelection.collapsed(offset: 15), TextSelection.collapsed(offset: doc.indexOf('Centred') + 2), TextSelection.collapsed(offset: doc.indexOf('item'))]) {
        final whole = runsOf(liveMarkdownSpan(context, c, base, width: 400, reveal: reveal));
        final blocks = parsedMarkdown(c);
        final facts = LiveFacts.of(doc, blocks);
        final parts = <(String?, double?, FontWeight?, FontStyle?)>[];
        for (final b in blocks) {
          final from = b.start;
          final source = LiveSource(
            owner: b,
            text: doc.substring(b.start, b.end),
            attributes: const [],
            misspelled: const [],
            found: const [],
            grammar: () => const [],
            blocks: [b.shifted(-from)],
            facts: () => facts.forBlock(b),
          );
          final touching = reveal != null && reveal.baseOffset >= b.start && reveal.baseOffset <= b.end;
          final local = reveal == null ? null : TextSelection.collapsed(offset: touching ? reveal.baseOffset - from : b.end - b.start + 5);
          parts.addAll(runsOf(liveBlockSpan(context, source, base, width: 400, reveal: local)));
          if (b.end < doc.length) parts.add(('\n', null, null, null));
        }
        expect(flat(parts), flat(whole), reason: 'with the caret at ${reveal?.baseOffset}');
      }
    });
  });
}

/// Per character: what is drawn, how big, how heavy, how slanted. Newlines are left out: how a line ends is not the same in two paragraphs.
List<(String, double?, FontWeight?, FontStyle?)> flat(List<(String?, double?, FontWeight?, FontStyle?)> runs) => [
      for (final r in runs)
        if (r.$1 == null)
          ('<widget>', null, null, null)
        else
          for (final c in r.$1!.split(''))
            if (c != '\n') (c, r.$2, r.$3, r.$4),
    ];

List<(String?, double?, FontWeight?, FontStyle?)> runsOf(InlineSpan span) {
  final out = <(String?, double?, FontWeight?, FontStyle?)>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      if (s.text != null) out.add((s.text, s.style?.fontSize, s.style?.fontWeight, s.style?.fontStyle));
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    } else {
      out.add((null, null, null, null));
    }
  }

  walk(span);
  return out;
}

String jsonish(String s) => s.replaceAll('\n', r'\n');
