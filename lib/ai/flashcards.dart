import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'ai_prompt.dart';
import 'cloze.dart';

/// The kinds of cards there are.
abstract final class CardKind {
  /// A question and its answer (Markdown, formulas as `$...$`).
  static const basic = 'basic';

  /// A text with parts hidden (`{{c1::...}}`): [Flashcard.front] is the text, [Flashcard.back] words added to the answer, and
  /// `media['n']` the number of the part this card asks for.
  static const cloze = 'cloze';

  /// A part of a page of a note, with parts of it covered: see `RegionCard`.
  static const region = 'region';
}

/// One card: a question on the front, its answer on the back.
class Flashcard {
  final String front;
  final String back;

  /// The page (zero-based) the card is from, when the model said.
  final int? page;

  /// One of [CardKind].
  final String kind;

  /// What a card that is not [CardKind.basic] needs besides its texts (JSON-like: maps, lists, strings and numbers).
  final Map<String, Object?>? media;

  const Flashcard(this.front, this.back, {this.page, this.kind = CardKind.basic, this.media});

  /// A cloze card asking for part [number] of [text]; [extra] is shown under the answer.
  Flashcard.cloze(String text, int number, {String extra = '', this.page})
      : front = text,
        back = extra,
        kind = CardKind.cloze,
        media = {'n': number};

  /// The number of the hidden part a cloze card asks for.
  int get clozeNumber => (media?['n'] as num?)?.toInt() ?? 1;

  /// What makes this card another than the other cards of its source: the question, and for a cloze card which part it hides (the
  /// cards of one text are as many cards as it hides parts), for a card of a page where on which page and which cover it lifts.
  String get identity => switch (kind) {
        CardKind.cloze => '$front#c$clozeNumber',
        CardKind.region => 'region:${media?['picture']}:${media?['ask']}:${media?['reverse'] == true ? 'r' : ''}',
        _ => front,
      };

  /// The question and the answer as they are shown (Markdown): for a cloze card the text with the part hidden, and with it shown.
  (String, String) get faces {
    if (kind != CardKind.cloze) return (front, back);
    final (f, b) = clozeFaces(front, clozeNumber);
    return (f, back.trim().isEmpty ? b : '$b\n\n$back');
  }
}

/// One card for each part [text] hides (none when it hides nothing).
List<Flashcard> clozeCards(String text, {String extra = '', int? page}) => [for (final n in clozeNumbers(text)) Flashcard.cloze(text, n, extra: extra, page: page)];

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

  /// Leaves this card for later in the round (it goes to the end) and shows the next one.
  void skip() {
    if (finished || _queue.length - _index < 2) return;
    _queue.add(_queue.removeAt(_index));
    _flipped = false;
    notifyListeners();
  }

  /// Brings back the card that was last put off (the other way of [skip]).
  void unskip() {
    if (finished || _queue.length - _index < 2) return;
    _queue.insert(_index, _queue.removeLast());
    _flipped = false;
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

/// What a card of a part of a page holds besides its texts ([Flashcard.media] of a [CardKind.region] card): the picture of the part,
/// where it was (to open the note there), the parts covered on it, and which one this card asks for.
///
/// The picture is taken when the card is made (a card is asked without the note: on another device, on the web, after the note was
/// deleted, in Anki); the note and its page are kept to go back to.
class RegionCard {
  /// The id of the picture (see `CardRepository.putPicture`) and its size in pixels.
  final String picture;
  final int width, height;

  /// The note, its page (zero-based) and the part of the page (in the page's units) the picture shows.
  final String? note;
  final int? page;
  final List<double>? area;

  /// The covers, as parts of the picture (left, top, width, height, each 0 to 1).
  final List<List<double>> masks;

  /// The cover this card asks for (-1: none, the picture is the question or the answer as it is).
  final int ask;

  /// Whether the other covers stay on while one is asked (all hidden, one asked), or come off (only the one asked is hidden).
  final bool hideAll;

  /// The picture is the answer to a typed question instead of the question.
  final bool reverse;

  const RegionCard({
    required this.picture,
    required this.width,
    required this.height,
    this.note,
    this.page,
    this.area,
    this.masks = const [],
    this.ask = -1,
    this.hideAll = false,
    this.reverse = false,
  });

  static RegionCard? of(Flashcard card) {
    final m = card.media;
    if (card.kind != CardKind.region || m == null || m['picture'] is! String) return null;
    List<double>? nums(Object? o) => o is List ? [for (final v in o) if (v is num) v.toDouble()] : null;
    return RegionCard(
      picture: m['picture'] as String,
      width: (m['w'] as num?)?.toInt() ?? 1,
      height: (m['h'] as num?)?.toInt() ?? 1,
      note: m['note'] as String?,
      page: (m['page'] as num?)?.toInt(),
      area: nums(m['area']),
      masks: [for (final r in (m['masks'] as List?) ?? const []) if (nums(r) case final n? when n.length == 4) n],
      ask: (m['ask'] as num?)?.toInt() ?? -1,
      hideAll: m['hideAll'] == true,
      reverse: m['reverse'] == true,
    );
  }

  Map<String, Object?> toMedia() => {
        'picture': picture,
        'w': width,
        'h': height,
        'note': ?note,
        'page': ?page,
        'area': ?area,
        if (masks.isNotEmpty) 'masks': masks,
        'ask': ask,
        if (hideAll) 'hideAll': true,
        if (reverse) 'reverse': true,
      };

  /// The card: [question] and [answer] are the texts with the picture (either may be empty).
  Flashcard card({String question = '', String answer = ''}) =>
      Flashcard(question, answer, page: page, kind: CardKind.region, media: toMedia());

  /// The covers drawn on [front] (or the back): the one asked is filled on the front and outlined on the back; the others are filled
  /// on both when [hideAll], else not drawn. The answer is (rect, asked, filled).
  List<(List<double>, bool, bool)> coversOn({required bool front}) => [
        for (final (i, r) in masks.indexed)
          if (i == ask) (r, true, front) else if (hideAll) (r, false, true),
      ];

  /// One card for each cover (none without covers).
  static List<Flashcard> coverCards(RegionCard base) => [
        for (var i = 0; i < base.masks.length; i++)
          RegionCard(
            picture: base.picture,
            width: base.width,
            height: base.height,
            note: base.note,
            page: base.page,
            area: base.area,
            masks: base.masks,
            ask: i,
            hideAll: base.hideAll,
          ).card(),
      ];
}
