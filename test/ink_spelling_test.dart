import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/export/pdf_ink_text.dart' show plainI;
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/ink/ink_grouping.dart' show strokeBounds;
import 'package:notes/models/canvas_models.dart';
import 'package:notes/ink/ink_spelling.dart';
import 'package:notes/spelling/hunspell.dart';
import 'package:notes/spelling/spell_checker.dart';

import 'ink_prefetch_test.dart' show scribble, word;
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

  test('words the reader was unsure of are marked so, spelled right or not, whatever marks they were written with', () {
    final marks = checkedInk([(block: cluster, text: 'the cat\nhapy dog')], checker, unsure: {'Hapy,', 'cat.'});
    final byWord = {for (final m in marks) m.word: m};
    expect(byWord['hapy']!.unsure, isTrue);
    expect(byWord['hapy']!.correct, isFalse);
    expect(byWord['cat']!.unsure, isTrue);
    expect(byWord['cat']!.correct, isTrue);
    expect(byWord['dog']!.unsure, isFalse);
    expect(checkedInk([(block: cluster, text: 'the cat\nhapy dog')], checker).any((m) => m.unsure), isFalse);
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

  // one line: a first word of three letters at x 100, a long gap, then "hapy" (four letters) at x 300
  List<DrawingStroke> lineOf(List<double> xs) => [for (var i = 0; i < xs.length; i++) scribble('w$i', xs[i], 100)];
  final tight = [...lineOf([100, 115, 130]), ...lineOf([300, 315, 330, 345]).map((s) => scribble('x${s.id}', s.points.first.dx, 100))];

  test('with as many written words as words in the text, a word is laid over its own strokes, whatever the letters weigh', () {
    final line = InkCluster(0, tight, tight.map(strokeBounds).reduce((a, b) => a.expandToInclude(b)));
    final marks = misspelledInk([(block: line, text: 'the hapy')], checker);
    final m = marks.single;
    expect(m.word, 'hapy');
    expect(m.rect.left, closeTo(300, 3));
    expect(m.rect.right, closeTo(359, 4));
    expect(m.strokes.length, 4, reason: 'the strokes of the word, to select it');
  });

  test('a formula in front is one written word too, and does not push the word along', () {
    final line = InkCluster(0, tight, tight.map(strokeBounds).reduce((a, b) => a.expandToInclude(b)));
    final marks = misspelledInk([(block: line, text: r'$\frac{1}{2}\rho$ hapy')], checker);
    expect(marks.single.rect.left, closeTo(300, 3), reason: 'estimated from the signs it would be far to the right of here');
  });

  test('when the reading has fewer lines than the writing, the words are still laid over the words they are written as', () {
    // four words on one line of writing, two under them; the reader gave it all as one line
    final two = [
      for (final x in [100.0, 200.0, 300.0, 400.0]) ...word('a$x', x, 100, n: 2),
      for (final x in [100.0, 200.0]) ...word('b$x', x, 160, n: 2),
    ];
    final block = InkCluster(0, two, two.map(strokeBounds).reduce((a, b) => a.expandToInclude(b)));
    final marks = misspelledInk([(block: block, text: 'the cat dog try hapy dog')], checker);
    expect(marks.map((m) => m.word), ['hapy']);
    expect(marks.single.rect.top, closeTo(160, 3), reason: 'the fifth word is the first on the second line');
    expect(marks.single.rect.left, closeTo(100, 3));
    final top = misspelledInk([(block: block, text: 'the hapy dog try cat dog')], checker);
    expect(top.single.rect.top, closeTo(100, 3));
    expect(top.single.rect.left, closeTo(200, 3));
  });

  test('an i with a tick for its dot (read as í) is the plain letter, not a misspelling', () {
    final marks = misspelledInk([(block: cluster, text: 'the cat\nthe dog')], checker);
    expect(marks, isEmpty);
    expect(plainI('archímedischen Prìnzip Ìn'), 'archimedischen Prinzip In');
  });
}
