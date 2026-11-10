import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/llm/wordpiece_tokenizer.dart';

void main() {
  final tokenizer = WordPieceTokenizer.parse(File('test/fixtures/minilm_tokenizer.json').readAsStringSync());

  test('it makes the same ids as the reference tokenizer of the model', () {
    // the reference: the `tokenizers` library on the same file
    final expected = (jsonDecode(File('test/fixtures/minilm_tokenizer_reference.json').readAsStringSync()) as Map).cast<String, List>();
    expect(expected, isNotEmpty);
    for (final e in expected.entries) {
      expect(tokenizer.encode(e.key), e.value.cast<int>(), reason: e.key);
    }
  });

  test('text longer than the model reads at once comes in windows, each with its markers', () {
    final long = List.filled(1200, 'word').join(' ');
    final windows = tokenizer.windows(long, window: 100, most: 3);
    expect(windows.length, 3);
    for (final w in windows) {
      expect(w.length, lessThanOrEqualTo(100));
      expect(w.first, tokenizer.cls);
      expect(w.last, tokenizer.sep);
    }
    expect(tokenizer.windows('   ', window: 100), isEmpty);
  });

  test('encode cuts a long text', () {
    expect(tokenizer.encode(List.filled(1000, 'word').join(' '), maxLength: 50).length, 50);
  });
}
