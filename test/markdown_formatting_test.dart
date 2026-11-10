import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/markdown/markdown_formatting.dart';

TextEditingValue v(String t, int a, [int? b]) =>
    TextEditingValue(text: t, selection: TextSelection(baseOffset: a, extentOffset: b ?? a));

String sel(TextEditingValue x) => x.selection.textInside(x.text);

void main() {
  test('wrap and unwrap a selection', () {
    final wrapped = toggleInline(v('hello world', 0, 5), '**');
    expect(wrapped.text, '**hello** world');
    expect(sel(wrapped), 'hello');
    // toggling again, selection inside the markers
    expect(toggleInline(wrapped, '**').text, 'hello world');
    // and with the markers inside the selection
    expect(toggleInline(v('**hello** world', 0, 9), '**').text, 'hello world');
  });

  test('selection is trimmed, empty selection inserts a pair', () {
    expect(toggleInline(v('a  b', 1, 3), '*').text, 'a  b'); // only spaces: nothing
    expect(toggleInline(v('a b c', 1, 4), '~~').text, 'a ~~b~~ c');
    final pair = toggleInline(v('ab', 1), '`');
    expect(pair.text, 'a``b');
    expect(pair.selection.baseOffset, 2);
    expect(toggleInline(pair, '`').text, 'ab');
  });

  test('italic and bold do not confuse each other', () {
    expect(toggleInline(v('**x**', 2, 3), '*').text, '***x***'); // add italic to bold
    expect(toggleInline(v('***x***', 3, 4), '*').text, '**x**'); // remove only italic
    expect(toggleInline(v('***x***', 3, 4), '**').text, '*x*'); // remove only bold
  });

  test('line styles', () {
    expect(toggleLineStyle(v('title', 2), LineStyle.heading2).text, '## title');
    expect(toggleLineStyle(v('## title', 4), LineStyle.heading2).text, 'title');
    expect(toggleLineStyle(v('- title', 4), LineStyle.heading1).text, '# title');
    final list = toggleLineStyle(v('a\nb\nc', 0, 5), LineStyle.numbered);
    expect(list.text, '1. a\n2. b\n3. c');
    expect(toggleLineStyle(list, LineStyle.numbered).text, 'a\nb\nc');
    // only the touched line
    expect(toggleLineStyle(v('a\nb\nc', 2), LineStyle.bullet).text, 'a\n- b\nc');
    // empty line
    final empty = toggleLineStyle(v('', 0), LineStyle.bullet);
    expect([empty.text, empty.selection.baseOffset], ['- ', 2]);
  });

  test('spoken text goes in at the cursor, with a space only where it would run into a word', () {
    final mid = insertSpoken(v('Hello world', 5), 'there');
    expect([mid.text, mid.selection.baseOffset], ['Hello there world', 11]);
    final end = insertSpoken(v('Hello', 5), 'world');
    expect([end.text, end.selection.baseOffset], ['Hello world', 11]);
    expect(insertSpoken(v('Hello. ', 7), 'Next').text, 'Hello. Next');
    expect(insertSpoken(v('', 0), 'First').text, 'First');
    expect(insertSpoken(v('a, b', 1), 'x').text, 'a x, b'); // (no space before a comma)
    expect(insertSpoken(v('one two three', 4, 7), 'ONE').text, 'one ONE three'); // replaces the selection
  });
}
