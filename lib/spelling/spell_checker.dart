import 'dart:ui' show TextRange;

import 'hunspell.dart';

/// The words of [text] that are worth checking, with where they are. Left out: code (`` `like this` `` and fenced
/// blocks), formulas (`$...$`), web and e-mail addresses, the targets of links, words that start with `\`, `#` or `@`
/// (LaTeX, tags, mentions), words with digits in them, and single letters.
List<TextRange> spellWords(String text) {
  final skip = <TextRange>[];
  for (final r in [
    RegExp(r'```[\s\S]*?(?:```|$)'),
    RegExp(r'`[^`\n]*`'),
    RegExp(r'\$\$[\s\S]*?\$\$'),
    RegExp(r'\$[^$\n]+\$'),
    RegExp(r'(?:https?://|www\.)\S+'),
    RegExp(r'[\w.+-]+@[\w-]+(?:\.[\w-]+)+'),
    RegExp(r'\]\([^)\n]*\)'),
    RegExp(r'\[\[[^\]\n]*\]\]'),
  ]) {
    for (final m in r.allMatches(text)) {
      skip.add(TextRange(start: m.start, end: m.end));
    }
  }
  bool skipped(int at) => skip.any((r) => at >= r.start && at < r.end);

  final out = <TextRange>[];
  for (final m in RegExp(r"[\p{L}\p{M}\p{N}](?:[\p{L}\p{M}\p{N}'’\-]*[\p{L}\p{M}\p{N}])?", unicode: true).allMatches(text)) {
    final word = m.group(0)!;
    if (word.length < 2 || RegExp(r'\p{N}', unicode: true).hasMatch(word)) continue;
    if (m.start > 0 && const {'\\', '#', '@', '_'}.contains(text[m.start - 1])) continue;
    if (skipped(m.start)) continue;
    out.add(TextRange(start: m.start, end: m.end));
  }
  return out;
}

/// Spell checking with the dictionaries of the languages that are on: a word is right if any of them takes it, which
/// is what a note in two languages needs. Words the person added are right too, and so are words that were set aside
/// for now.
class SpellChecker {
  List<HunspellDictionary> _dictionaries = const [];
  final Set<String> _personal = {};
  final Set<String> _ignored = {};
  final Map<String, bool> _known = {};

  /// Whether there is anything to check with.
  bool get active => _dictionaries.isNotEmpty;

  /// The dictionaries in use (the first is the one suggestions come from first).
  set dictionaries(List<HunspellDictionary> value) {
    _dictionaries = List.of(value);
    _known.clear();
  }

  /// The words the person added.
  Set<String> get personal => Set.unmodifiable(_personal);

  set personal(Set<String> words) {
    _personal
      ..clear()
      ..addAll(words);
    _known.clear();
  }

  void ignore(String word) {
    _ignored.add(word.toLowerCase());
    _known.remove(word);
  }

  bool isCorrect(String word) {
    final known = _known[word];
    if (known != null) return known;
    final lower = word.toLowerCase();
    final result = _personal.contains(word) ||
        _personal.contains(lower) ||
        _ignored.contains(lower) ||
        _dictionaries.isEmpty ||
        _dictionaries.any((d) => d.isCorrect(word));
    if (_known.length > 20000) _known.clear();
    return _known[word] = result;
  }

  /// The places in [text] that are not spelled right.
  List<TextRange> misspellings(String text) {
    if (!active) return const [];
    return [
      for (final r in spellWords(text))
        if (!isCorrect(text.substring(r.start, r.end))) r,
    ];
  }

  /// What [word] may have been meant to be, best first, from every dictionary (each gives its best first).
  List<String> suggestions(String word, {int max = 6}) {
    final lists = [for (final d in _dictionaries) d.suggest(word, max: max)];
    final out = <String>[];
    for (var i = 0; out.length < max; i++) {
      var any = false;
      for (final l in lists) {
        if (i < l.length) {
          any = true;
          if (!out.contains(l[i]) && out.length < max) out.add(l[i]);
        }
      }
      if (!any) break;
    }
    return out;
  }
}
