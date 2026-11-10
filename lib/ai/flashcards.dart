import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'ai_prompt.dart';

/// One card: a question on the front, its answer on the back.
class Flashcard {
  final String front;
  final String back;

  /// The page (zero-based) the card is from, when the model said.
  final int? page;

  const Flashcard(this.front, this.back, {this.page});
}

/// The prompt that asks for [count] cards from the [passages] of a document. The cards come back as
/// plain lines (`Q:` / `A:` / `Page:`), which small models keep to better than JSON.
AiPrompt flashcardPrompt(String passages, int count) => AiPrompt(
      system: 'You make flashcards for a student from the passages of their notes. Each card tests one fact, '
          'definition or idea that is in the passages; do not invent anything. Keep the question short and the '
          'answer to a sentence or two. Write in the language of the passages. Write each card exactly like this:\n'
          'Q: the question\n'
          'A: the answer\n'
          'Page: the number of the page the card is from, taken from the [Page N] marks (leave the line out if there is none)\n'
          'Put a blank line between cards. Write nothing else: no numbering, no introduction.',
      user: 'Passages of the document:\n$passages\n\nMake $count flashcards.',
    );

final _question = RegExp(r'^\s*(?:[-*]\s*)?(?:\d+[.)]\s*)?(?:Q(?:uestion)?|Front|Frage|Vorderseite)\s*\d*\s*[:.\-)]\s*(.*)$', caseSensitive: false);
final _answer = RegExp(r'^\s*(?:[-*]\s*)?(?:A(?:nswer)?|Back|Antwort|R(?:ü|u)ckseite)\s*\d*\s*[:.\-)]\s*(.*)$', caseSensitive: false);
final _page = RegExp(r'^\s*(?:[-*]\s*)?(?:Page|P|Seite|S)\.?\s*[:.]?\s*(\d+)\s*$', caseSensitive: false);

/// The cards in what a model wrote: `Q:`/`A:` lines (also numbered, bold, or as Question/Answer or Front/Back),
/// or a JSON list. Text that is no card is ignored; a card needs both sides.
List<Flashcard> parseFlashcards(String text) {
  final json = _fromJson(text);
  if (json.isNotEmpty) return json;
  final cards = <Flashcard>[];
  String? front, back;
  int? page;
  var onBack = false;

  void finish() {
    final f = front?.trim() ?? '', b = back?.trim() ?? '';
    if (f.isNotEmpty && b.isNotEmpty && !cards.any((c) => c.front == f)) cards.add(Flashcard(f, b, page: page));
    front = back = null;
    page = null;
    onBack = false;
  }

  for (var raw in text.split('\n')) {
    final line = raw.replaceAll('**', '').replaceAll('__', '');
    final q = _question.firstMatch(line);
    if (q != null && !(onBack && front != null && _answer.hasMatch(line))) {
      finish();
      front = q.group(1);
      continue;
    }
    final a = _answer.firstMatch(line);
    if (a != null && front != null) {
      back = a.group(1);
      onBack = true;
      continue;
    }
    final p = _page.firstMatch(line);
    if (p != null && front != null) {
      final n = int.tryParse(p.group(1)!);
      if (n != null && n >= 1) page = n - 1;
      continue;
    }
    if (line.trim().isEmpty) {
      if (back != null) finish(); // a blank line after the answer ends the card
      continue;
    }
    if (front == null) continue; // an introduction
    if (onBack) {
      back = '$back\n${line.trim()}';
    } else {
      front = '$front ${line.trim()}';
    }
  }
  finish();
  return cards;
}

List<Flashcard> _fromJson(String text) {
  final start = text.indexOf('['), end = text.lastIndexOf(']');
  if (start < 0 || end <= start) return const [];
  try {
    final list = jsonDecode(text.substring(start, end + 1));
    if (list is! List) return const [];
    String? pick(Map m, List<String> keys) {
      for (final k in keys) {
        final v = m[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return null;
    }

    return [
      for (final m in list.whereType<Map>())
        if (pick(m, ['q', 'question', 'front']) case final f? when pick(m, ['a', 'answer', 'back']) != null)
          Flashcard(f, pick(m, ['a', 'answer', 'back'])!),
    ];
  } catch (_) {
    return const [];
  }
}

/// A set of cards being studied: one round goes through the cards that are left, each marked as known
/// or to see again; then the missed ones can be studied, or everything again.
class FlashcardDeck extends ChangeNotifier {
  final List<Flashcard> cards;
  final Random _random;

  FlashcardDeck(this.cards, {Random? random})
      : _random = random ?? Random(),
        _queue = List.of(cards);

  List<Flashcard> _queue;
  final List<Flashcard> _missed = [];
  int _index = 0;
  int _known = 0;
  bool _flipped = false;

  /// The card in front of the person; null when the round is over.
  Flashcard? get current => _index < _queue.length ? _queue[_index] : null;

  /// Whether the answer side shows.
  bool get flipped => _flipped;

  bool get finished => _index >= _queue.length;

  /// How far this round is, and how long.
  int get position => _index;
  int get roundLength => _queue.length;

  /// What this round found known / to see again.
  int get knownCount => _known;
  List<Flashcard> get missed => List.unmodifiable(_missed);

  void flip() {
    if (finished) return;
    _flipped = !_flipped;
    notifyListeners();
  }

  /// The person knew it.
  void gotIt() => _next(known: true);

  /// The person did not: it comes up in the round of missed cards.
  void again() => _next(known: false);

  void _next({required bool known}) {
    if (finished) return;
    if (known) {
      _known++;
    } else {
      _missed.add(current!);
    }
    _index++;
    _flipped = false;
    notifyListeners();
  }

  /// A new round with only the cards that were missed.
  void studyMissed() => _start(List.of(_missed));

  /// A new round with all the cards, in the order they were made or shuffled.
  void startOver({bool shuffle = false}) => _start(List.of(cards), shuffle: shuffle);

  void _start(List<Flashcard> queue, {bool shuffle = false}) {
    _queue = queue;
    if (shuffle) _queue.shuffle(_random);
    _missed.clear();
    _index = 0;
    _known = 0;
    _flipped = false;
    notifyListeners();
  }
}
