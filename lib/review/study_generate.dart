import 'dart:math' as math;

import '../ai/ai_prompt.dart';
import '../ai/flashcards.dart';
import '../ai/text_provider.dart';
import '../l10n/language.dart';
import 'study_material.dart';
import 'study_topics.dart' show PageTextReader;

/// What was made for a part of a plan: its summary as points (each one sentence, which is also what its quiz is made from) and how many
/// flashcards were made of it (the cards themselves are kept with the other cards).
class UnitMaterial {
  final List<String> points;
  final int cards;

  const UnitMaterial({this.points = const [], this.cards = 0});

  bool get isEmpty => points.isEmpty && cards == 0;

  Map<String, Object?> toJson() => {'p': points, 'c': cards};

  static UnitMaterial? fromJson(Object? j) {
    if (j is! Map) return null;
    final m = UnitMaterial(points: [for (final p in (j['p'] as List?) ?? const []) if (p is String && p.trim().isNotEmpty) p], cards: (j['c'] as num?)?.toInt() ?? 0);
    return m.isEmpty ? null : m;
  }

  @override
  bool operator ==(Object other) => other is UnitMaterial && other.cards == cards && other.points.length == points.length && [for (final (i, p) in points.indexed) other.points[i] == p].every((x) => x);

  @override
  int get hashCode => Object.hash(cards, points.length);
}

/// How much is made for one part: summary points and flashcards (none of either: the part has too little to make anything of).
typedef MaterialBudget = ({int points, int cards});

/// How much to make for a part of [words] words that has [learnMinutes] to learn it and [reviewMinutes] to go over it, when the plan has
/// [minutesAvailable] minutes in all for it (its share of the days to the exam): more words mean more points and cards; short time
/// means fewer of them (a summary to read and a few cards that can be gone over in the time that is left); a lot of time means more.
/// The cards are also limited to how many can be gone over three times in the time after the first going-through.
MaterialBudget materialBudget({required int words, required int learnMinutes, required int reviewMinutes, required int minutesAvailable, int secondsPerCard = 20}) {
  if (words < 40) return (points: 0, cards: 0);
  var points = (words / 70).round().clamp(3, 12);
  var cards = (words / 45).round().clamp(3, 30);
  final need = math.max(1, learnMinutes + reviewMinutes);
  final room = minutesAvailable / need;
  if (room < 1) {
    points = math.max(3, (points * 0.6).round());
    cards = math.min(cards, 4);
  } else if (room >= 2) {
    points = math.min(14, (points * 1.25).round());
    cards = math.min(40, (cards * 1.5).round());
  }
  final spare = math.max(0, minutesAvailable - learnMinutes);
  cards = math.min(cards, math.max(3, spare * 60 ~/ (secondsPerCard * 3)));
  return (points: points, cards: cards);
}

/// The minutes a plan has in all before the exam (the study days from [today] up to the day before it, at most [perDay] minutes of each
/// and as long as the hours [windowMinutes] allow), shared by the parts in proportion to [weights] (part id -> its learning minutes).
Map<String, int> shareMinutes({required DateTime today, required DateTime exam, required Set<int> daysOff, required int perDay, required int windowMinutes, required Map<String, int> weights}) {
  var days = 0;
  final to = DateTime(exam.year, exam.month, exam.day);
  for (var d = DateTime(today.year, today.month, today.day); d.isBefore(to); d = DateTime(d.year, d.month, d.day + 1)) {
    if (!daysOff.contains(d.weekday)) days++;
  }
  final total = days * math.min(perDay, windowMinutes);
  final all = weights.values.fold<int>(0, (n, v) => n + v);
  return {for (final e in weights.entries) e.key: all == 0 ? 0 : (total * e.value / all).round()};
}

/// The request for a summary of [passages] as [points] points.
AiPrompt summaryPrompt(String passages, int points) => AiPrompt(
      system: 'You summarise study material for a student who has to learn it. Write the summary as exactly $points points. Each point is one '
          'sentence that states one fact, definition or idea that is in the text, with the names, numbers and terms the student has to know; '
          'do not invent anything and do not comment on the text. Write in the language of the text. Write each point on its own line, '
          'starting with "- ", and nothing else: no introduction, no heading.',
      user: 'Text:\n$passages\n\nWrite the summary in $points points.',
    );

/// The points in a model's [reply]: lines that start with a dash, a bullet or a number (a line that goes on is joined to its point),
/// at most [max] of them. A reply with no such line gives its sentences, one point each.
List<String> parseSummaryPoints(String reply, {int max = 16}) {
  final points = <String>[];
  final bullet = RegExp(r'^\s*(?:[-*•–]|\d+[.)])\s+(.*\S)\s*$');
  for (final raw in reply.split('\n')) {
    final line = raw.replaceAll('**', '').replaceAll('__', '');
    final m = bullet.firstMatch(line);
    if (m != null) {
      points.add(m.group(1)!.trim());
    } else if (points.isNotEmpty && line.trim().isNotEmpty && line.startsWith(RegExp(r'\s{2,}\S'))) {
      points[points.length - 1] = '${points.last} ${line.trim()}';
    }
  }
  if (points.isEmpty) {
    for (final s in reply.split(RegExp(r'(?<=[.!?])\s+'))) {
      final t = s.trim();
      if (t.length >= 20) points.add(t);
    }
  }
  return [for (final p in points) if (p.length >= 8) p].take(max).toList();
}

/// How many characters of a part's text one request shows the model (a small model on the device loses the thread with more).
const _charsPerRequest = 6000;

/// Makes the summary and the flashcards of the parts of a plan with an AI model, from the text that was read of them (the PDF and the
/// handwriting by page, the written document by its sections). Only where the person asks for it.
class StudyMaterialMaker {
  final PageTextReader pageTexts;

  /// The written document of a note.
  final Future<String> Function(String noteId) documentText;

  /// The model to ask (null: none), and whether the AI features are on.
  final TextModelProvider? Function() model;
  final bool Function() enabled;

  StudyMaterialMaker({required this.pageTexts, required this.documentText, required this.model, required this.enabled});

  bool get ready => enabled() && model()?.state == ProviderState.ready;

  final _pageCache = <String, Map<int, String>>{};

  /// The text of [u] as passages for the model, a page after the other with "[Page n]" marks; shortened evenly when it is long.
  /// Empty when nothing was read of it.
  Future<String> passagesOf(StudyUnit u) async {
    if (u.hasPages) {
      final texts = _pageCache[u.noteId] ??= await pageTexts(u.noteId);
      final pages = [for (var p = u.fromPage!; p <= u.toPage!; p++) if ((texts[p]?.trim() ?? '').isNotEmpty) p];
      if (pages.isEmpty) return '';
      final each = math.max(150, _charsPerRequest ~/ pages.length);
      return [for (final p in pages) '[Page ${p + 1}]\n${_start(texts[p]!, each)}'].join('\n\n');
    }
    final text = textOfSection(await documentText(u.noteId), u.title).trim();
    return _start(text, _charsPerRequest);
  }

  /// Forgets what was read (the texts may have changed).
  void forget() => _pageCache.clear();

  /// The summary and the cards of [u] from its [passages], as [budget] says. A [StateError] says why when the model cannot be asked.
  Future<({UnitMaterial material, List<Flashcard> cards})> make(StudyUnit u, String passages, MaterialBudget budget, {AiCancel? cancel}) async {
    final provider = model();
    if (provider == null || !ready) throw StateError(tr('No AI model is ready.'));
    var points = const <String>[];
    var cards = const <Flashcard>[];
    if (budget.points > 0) {
      final reply = await provider.complete(summaryPrompt(passages, budget.points), maxTokens: 70 * budget.points + 60, cancel: cancel);
      if (cancel?.cancelled ?? false) return (material: const UnitMaterial(), cards: const <Flashcard>[]);
      points = parseSummaryPoints(reply, max: budget.points + 3);
    }
    if (budget.cards > 0) {
      final reply = await provider.complete(flashcardPrompt(passages, budget.cards), maxTokens: 80 * budget.cards + 60, cancel: cancel);
      if (cancel?.cancelled ?? false) return (material: const UnitMaterial(), cards: const <Flashcard>[]);
      cards = [
        for (final c in parseFlashcards(reply).take(budget.cards + 3))
          Flashcard(c.front, c.back, page: u.hasPages ? (c.page != null && c.page! >= u.fromPage! && c.page! <= u.toPage! ? c.page : u.fromPage) : null),
      ];
    }
    return (material: UnitMaterial(points: points, cards: cards.length), cards: cards);
  }

  static String _start(String text, int chars) {
    final t = text.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    return t.length <= chars ? t : '${t.substring(0, chars)}…';
  }
}
