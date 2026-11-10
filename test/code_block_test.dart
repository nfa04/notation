import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/markdown/code_highlight.dart';
import 'package:notes/markdown/markdown_parser.dart';
import 'package:notes/markdown/markdown_view.dart';
import 'package:notes/models/rich_text.dart';

void main() {
  test('a fenced block is code with its language; text around it stays Markdown', () {
    final blocks = parseMarkdown('Before\n```dart\nvoid main() {\n  print("hi"); // say\n}\n```\n**after**');
    expect(blocks.map((b) => b.type), [MdBlockType.paragraph, MdBlockType.code, MdBlockType.paragraph]);
    expect(blocks[1].lang, 'dart');
    expect(blocks[1].code, 'void main() {\n  print("hi"); // say\n}');
    expect(blocks[2].runs.single.bold, isTrue);
    // an unclosed fence is only text
    expect(parseMarkdown('```py\nx = 1').map((b) => b.type), everyElement(MdBlockType.paragraph));
  });

  test('code is split into keywords, strings and comments, and an unknown language stays plain', () {
    final tokens = highlightCode('def f(x):\n    return "a"  # note', 'python');
    expect(tokens.any((t) => t.kind == 'keyword' && t.text.contains('def')), isTrue);
    expect(tokens.any((t) => t.kind == 'string'), isTrue);
    expect(tokens.any((t) => t.kind == 'comment'), isTrue);
    expect(tokens.map((t) => t.text).join(), 'def f(x):\n    return "a"  # note');
    expect(highlightCode('x', 'nonsense').single.kind, isNull);
    expect(highlightCode('x', null).single.kind, isNull);
    expect(codeColor('keyword', dark: false), isNot(codeColor('keyword', dark: true)));
  });

  testWidgets('a block of code is shown in colour', (tester) async {
    final c = RichInlineTextController()..text = '```js\nconst a = 1; // one\n```';
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MarkdownView(controller: c, fontSize: 16))));
    expect(find.byKey(const ValueKey('code-block')), findsOneWidget);
    final rich = tester.widget<RichText>(find.descendant(of: find.byKey(const ValueKey('code-block')), matching: find.byType(RichText)));
    final colours = <Color?>{};
    rich.text.visitChildren((s) {
      if (s is TextSpan && s.style?.color != null) colours.add(s.style!.color);
      return true;
    });
    expect(colours.length, greaterThanOrEqualTo(2)); // keyword, number, comment...
  });

  test('the ways people open a block of code all work: more backticks, tildes, words after the language, braces, capitals', () {
    List<MdBlock> code(String src) => parseMarkdown(src).where((b) => b.type == MdBlockType.code).toList();
    expect(code('```python title="x.py"\nx = 1\n```').single.lang, 'python');
    expect(code('```Python\nx = 1\n```').single.lang, 'python');
    expect(code('~~~js\nlet a = 1;\n~~~').single.lang, 'js');
    expect(code('````dart\nvar a = "```";\n````').single.code, 'var a = "```";'); // a longer fence holds shorter ones
    expect(code('```{.python}\nx = 1\n```').single.lang, 'python');
    expect(code('```shell\nls\n```').single.lang, 'bash');
    expect(code('```tsx\nconst a = 1;\n```').single.lang, 'typescript');
    expect(code('  ```c++\nint a;\n  ```').single.lang, 'c++');
    expect(code('```\nno language\n```').single.lang, '');
    expect(code('```sql\nSELECT 1;\n```\nafter').length, 1);
    // inline code with three backticks on one line is not a fence
    expect(code('```not a fence```').length, 0);
    // a tilde block is not closed by backticks
    expect(code('~~~\nx\n```\ny\n~~~').single.code, 'x\n```\ny');
  });

  test('aliases find the right language: shell, tsx, latex and the others people write', () {
    for (final (alias, sample) in [
      ('shell', 'echo "a" # c'),
      ('tsx', 'const a: number = 1; // c'),
      ('latex', '\\section{a} % c'),
      ('yml', 'a: 1\nb: "x" # c'),
      ('c#', 'public class A { int x = 1; // c\n}'),
      ('golang', 'func main() { x := 1 // c\n}'),
      ('rs', 'fn main() { let a = 1; // c\n}'),
    ]) {
      final tokens = highlightCode(sample, normalizeLang(alias));
      expect(tokens.any((t) => t.kind != null), isTrue, reason: alias);
    }
    expect(normalizeLang('  {.Python .numberLines}'), 'python');
    expect(normalizeLang(''), '');
  });

  test('the blocks of code in a text are found with where their code is', () {
    const text = 'intro\n```py\nx = 1\ny = 2\n```\nmiddle\n~~~\nplain\n~~~\n```open';
    final spans = codeBlockSpans(text);
    expect(spans.length, 2, reason: 'a block that is never closed is not one');
    expect(text.substring(spans[0].bodyStart, spans[0].bodyEnd), 'x = 1\ny = 2');
    expect(spans[0].lang, 'py');
    expect(text.substring(spans[0].start, spans[0].start + 5), '```py');
    expect(text.substring(spans[0].end - 3, spans[0].end), '```');
    expect(text.substring(spans[1].bodyStart, spans[1].bodyEnd), 'plain');
    expect(codeBlockSpans('nothing here'), isEmpty);
    final empty = codeBlockSpans('```\n```').single;
    expect(empty.bodyEnd, empty.bodyStart, reason: 'an empty block has no code');
  });

  testWidgets('while it is typed, code in a fence is already in colour and in a fixed-width font (the raw text of the editor)', (tester) async {
    final c = RichInlineTextController()..text = 'Some text\n```dart\nint x = 1; // one\n```\nand more';
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) {
      context = ctx;
      return const SizedBox();
    })));
    final span = c.buildTextSpan(context: context, style: const TextStyle(color: Colors.black), withComposing: false);
    final chars = <TextSpan>[];
    span.visitChildren((s) {
      if (s is TextSpan && s.text != null) chars.add(s);
      return true;
    });
    TextSpan at(String where) => chars[c.text.indexOf(where)];
    expect(at('int').style!.color, isNot(Colors.black), reason: 'a keyword is coloured');
    expect(at('int').style!.fontFamily, 'monospace');
    expect(at('// one').style!.color, Color(codeColor('comment', dark: false)!));
    expect(at('```dart').style!.fontFamily, 'monospace', reason: 'the fence line too');
    expect(at('Some').style!.fontFamily, isNull, reason: 'the text around it is as it was');
    expect(at('and more').style!.color, Colors.black);
    // and in a dark text box the colours are the light ones
    final dark = c.buildTextSpan(context: context, style: const TextStyle(color: Colors.white), withComposing: false);
    final darkChars = <TextSpan>[];
    dark.visitChildren((s) {
      if (s is TextSpan && s.text != null) darkChars.add(s);
      return true;
    });
    expect(darkChars[c.text.indexOf('// one')].style!.color, Color(codeColor('comment', dark: true)!));
  });

  test('a slip in the fences (five backticks to open, four to close) and no language named: still a block, and clearly code is coloured', () {
    const text = '`````\n\nconsole.log("log");\n````';
    final block = parseMarkdown(text).single;
    expect(block.type, MdBlockType.code);
    expect(block.code, '\nconsole.log("log");');
    final spans = codeBlockSpans(text);
    expect(spans.single.bodyEnd, text.length - 5);

    final tokens = highlightCode(block.code, block.lang);
    expect(tokens.any((t) => t.kind == 'string' && t.text.contains('log')), isTrue, reason: 'the string is coloured');
    expect(tokens.map((t) => t.text).join(), block.code);
  });

  test('without a language, code is told from text: code gets colours, a sentence stays plain', () {
    expect(detectLanguage('console.log("log");'), isNotNull);
    expect(detectLanguage('def f(x):\n  return x'), 'python');
    expect(detectLanguage('{"a": 1, "b": [true]}'), 'json');
    expect(detectLanguage('hello world this is text'), isNull);
    expect(detectLanguage('The quick brown fox jumps over the lazy dog.'), isNull);
    expect(detectLanguage('x'), isNull);
    expect(highlightCode('just some words here', null).single.kind, isNull);
    expect(highlightCode('const a = [1, 2]; // list', '').any((t) => t.kind != null), isTrue);
  });

  testWidgets('typed in a text box the way the screenshot has it, the code is in colour and fixed-width', (tester) async {
    final c = RichInlineTextController()..text = '`````\n\nconsole.log("log");\n````';
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) {
      context = ctx;
      return const SizedBox();
    })));
    final span = c.buildTextSpan(context: context, style: const TextStyle(color: Colors.black), withComposing: false);
    final chars = <TextSpan>[];
    span.visitChildren((s) {
      if (s is TextSpan && s.text != null) chars.add(s);
      return true;
    });
    final at = c.text.indexOf('"log"');
    expect(chars[at].style!.color, isNot(Colors.black));
    expect(chars[at].style!.fontFamily, 'monospace');
  });
}
