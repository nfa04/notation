import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/ink/ink_spelling.dart';
import 'package:notes/spelling/hunspell.dart';
import 'package:notes/spelling/spell_checker.dart';

import 'ink_prefetch_test.dart' show word;
import 'spelling/hunspell_test.dart' show english, englishWords;

void main() {
  late SpellChecker checker;
  setUpAll(() async {
    checker = SpellChecker()..dictionaries = [await HunspellDictionary.parse(utf8.encode(english), utf8.encode(englishWords))];
  });

  // two lines of writing: "a" 94 wide on top, a shorter one under it (as in the PDF text tests)
  final strokes = [...word('a', 100, 100, n: 5), ...word('b', 100, 140, n: 3)];
  final cluster = clusterStrokes(0, strokes).single;

  test('a misspelled word is marked on the line it is written on, near where it is', () {
    final marks = misspelledInk([(block: cluster, text: 'the cat\nhapy dog')], checker);
    expect(marks.map((m) => m.word), ['hapy']);
    final m = marks.single;
    expect(m.page, 0);
    expect(m.key, cluster.key);
    expect(m.rect.left, 100, reason: 'the word starts the line');
    expect(m.rect.top, 140, reason: 'the second line of writing');
    expect(m.rect.right, inInclusiveRange(115, 140), reason: 'about half of the line, not all of it');
  });

  test('words that are right, short words and blocks not read yet are left alone', () {
    expect(misspelledInk([(block: cluster, text: 'the cat\nxq dog')], checker), isEmpty, reason: 'two letters say nothing');
    expect(misspelledInk([(block: cluster, text: null)], checker), isEmpty);
  });

  test('the maths the reader wrote as LaTeX is not checked, and the words after it are still placed along the line', () {
    final marks = misspelledInk([(block: cluster, text: r'the cat' '\n' r'$\frac{1}{2}\rho$ hapy')], checker);
    expect(marks.map((m) => m.word), ['hapy'], reason: 'frac and rho are not words');
    expect(marks.single.rect.left, greaterThan(105), reason: 'it comes after the formula');
  });

  test('nothing is marked without a dictionary', () {
    expect(misspelledInk([(block: cluster, text: 'the\nhapy')], SpellChecker()), isEmpty);
  });
}
