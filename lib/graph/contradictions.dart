import 'dart:math' as math;

import '../data/note_data.dart';
import 'graph_builder.dart' show telltaleWords;

/// Two facts of different notes that are about the same thing and give different numbers for it: "the exam is on 20 June" and "the exam is
/// on 21 June", "the speed of sound is 343 m/s" and "... 330 m/s".
class Contradiction {
  final StoredFact a;
  final StoredFact b;

  /// The numbers each says that the other does not.
  final List<String> onlyA, onlyB;

  const Contradiction(this.a, this.b, this.onlyA, this.onlyB);
}

/// The numbers of [text], as they are written without the grouping: `1,000` and `1.000` are `1000`, `3,5` is `3.5`; a year or a time stays.
Set<String> numbersIn(String text) {
  final out = <String>{};
  for (final m in RegExp(r'(?<![\p{L}\p{N}])\d+(?:[.,]\d+)*', unicode: true).allMatches(text)) {
    var n = m[0]!;
    if (RegExp(r'^\d{1,3}([.,]\d{3})+$').hasMatch(n)) {
      n = n.replaceAll(RegExp(r'[.,]'), ''); // a thousands separator
    } else {
      n = n.replaceAll(',', '.');
    }
    if (n.contains('.')) n = n.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    out.add(n.replaceFirst(RegExp(r'^0+(?=\d)'), ''));
  }
  return out;
}

double _cosine(List<double> a, List<double> b) {
  var s = 0.0;
  for (var i = 0; i < math.min(a.length, b.length); i++) {
    s += a[i] * b[i];
  }
  return s;
}

/// The pairs of facts that disagree. Two facts are about the same thing when they have most of their words in common (the words without the
/// numbers), or, when both have a vector from the same model, are very close in meaning; they disagree when each says numbers that
/// the other does not (one that only adds a number to the other's is not a contradiction). Facts of one note do not count: a note
/// may well give two values (before and after).
List<Contradiction> findContradictions(Iterable<StoredFact> facts, {double sameWords = 0.6, double sameMeaning = 0.85, int max = 200}) {
  final list = facts.toList();
  final numbers = [for (final f in list) numbersIn('${f.title} ${f.sentence}')];
  final words = [for (final f in list) telltaleWords('${f.title} ${f.sentence}').toSet()];
  final found = <Contradiction>[];
  for (var i = 0; i < list.length && found.length < max; i++) {
    if (numbers[i].isEmpty) continue;
    for (var j = i + 1; j < list.length && found.length < max; j++) {
      if (numbers[j].isEmpty || list[i].noteId == list[j].noteId) continue;
      final onlyA = numbers[i].difference(numbers[j]), onlyB = numbers[j].difference(numbers[i]);
      if (onlyA.isEmpty || onlyB.isEmpty) continue;
      final shared = words[i].intersection(words[j]).length;
      final smaller = math.min(words[i].length, words[j].length);
      var same = smaller >= 3 && shared / smaller >= sameWords;
      final vi = list[i].vector, vj = list[j].vector;
      if (!same && vi != null && vj != null && vi.length == vj.length) same = _cosine(vi, vj) >= sameMeaning && shared >= 2;
      if (same) found.add(Contradiction(list[i], list[j], onlyA.toList()..sort(), onlyB.toList()..sort()));
    }
  }
  return found;
}
