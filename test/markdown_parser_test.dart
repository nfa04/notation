import 'package:flutter_test/flutter_test.dart';
import 'package:notes/markdown/markdown_parser.dart';

void main() {
  test('inline formats', () {
    final b = parseMarkdown('a **b *c*** ~~d~~ `e` f').single;
    final r = {for (final x in b.runs) x.text: x};
    expect(r['b ']!.bold, isTrue);
    expect(r['c']!.bold && r['c']!.italic, isTrue);
    expect(r['d']!.strike, isTrue);
    expect(r['e']!.code, isTrue);
    expect(b.runs.map((x) => x.text).join(), 'a b c d e f');
  });

  test('blocks', () {
    final b = parseMarkdown('# T\n- x\n2. y\nplain');
    expect(b.map((x) => x.type), [
      MdBlockType.heading,
      MdBlockType.bullet,
      MdBlockType.numbered,
      MdBlockType.paragraph
    ]);
    expect(b[0].level, 1);
    expect(b[2].level, 2);
  });

  test('unmatched markers stay literal, source offsets are right', () {
    final src = 'x * y\n**bold**';
    final b = parseMarkdown(src);
    expect(b[0].runs.map((x) => x.text).join(), 'x * y');
    final run = b[1].runs.single;
    expect(src.substring(run.src, run.src + run.text.length), 'bold');
  });

  group('formulas', () {
    test(r'$...$ is a formula inside a line', () {
      final runs = parseMarkdown(r'the area is $\pi r^2$ here').single.runs;
      expect(runs.map((r) => (r.text, r.math)), [('the area is ', false), (r'\pi r^2', true), (' here', false)]);
      expect(runs[1].src, 'the area is \$'.length); // the source offset of the formula itself
    });

    test(r'$$...$$ on its own line is a display formula', () {
      final block = parseMarkdown(r'$$\frac{a}{b}$$').single;
      expect(block.type, MdBlockType.math);
      expect(block.runs.single.text, r'\frac{a}{b}');
      expect(block.runs.single.math, isTrue);
    });

    test('markdown marks inside a formula are left alone', () {
      final runs = parseMarkdown(r'*a* and $x_1 * y_2$').single.runs;
      expect(runs.where((r) => r.math).single.text, r'x_1 * y_2');
      expect(runs.first.italic, isTrue);
    });

    test('money is not a formula', () {
      final runs = parseMarkdown(r'it costs $5 and then $6 more').single.runs;
      expect(runs.any((r) => r.math), isFalse);
      expect(runs.map((r) => r.text).join(), r'it costs $5 and then $6 more');
    });

    test('a lone dollar sign stays text', () {
      expect(parseMarkdown(r'a $ b').single.runs.any((r) => r.math), isFalse);
      expect(parseMarkdown(r'open $x never closed').single.runs.any((r) => r.math), isFalse);
    });

    test('formulas work inside bold and in list items', () {
      final bold = parseMarkdown(r'**so $x$ it is**').single.runs;
      expect(bold.where((r) => r.math).single.bold, isTrue);
      final item = parseMarkdown(r'- $a+b$').single;
      expect(item.type, MdBlockType.bullet);
      expect(item.runs.single.math, isTrue);
    });
  });
}
