import 'package:flutter/widgets.dart';

import '../algebra/mistake_card.dart';
import '../data/card_repository.dart';
import '../graph/study.dart';
import 'study_material.dart';

/// A fact of a knowledge graph, with the note and the page (zero-based) it is from.
typedef FactSpot = ({String noteId, int? page, StudyFact fact});

/// The facts a session's quiz is made of (the knowledge graphs of the facts kind), and the quiz itself. The plan only places a quiz where a
/// part has enough facts and a model can write the questions ([canQuiz]); the questions are made when the quiz is opened.
abstract class StudyFactSource {
  /// Whether a quiz can be made now (it needs an AI model that is ready).
  bool get canQuiz;

  /// The facts of every kept graph that has them, with where each is from.
  Future<List<FactSpot>> facts();

  /// Opens the quiz on [facts] (called [title]).
  Future<void> quiz(BuildContext context, String title, List<StudyFact> facts, {CardRepository? cards});
}

/// A part needs at least this many facts for a quiz.
const quizFacts = 3;

/// A mistake card counts as known once it is not asked again for this many days.
const _mistakeKnownDays = 21;

/// Whether [page] of the note [noteId] is in [u] (a part without pages is the whole of its note's written document: a page is not in it).
bool inUnit(StudyUnit u, String noteId, int? page) =>
    noteId == u.noteId && (u.hasPages ? page != null && page >= u.fromPage! && page <= u.toPage! : page == null);

/// The mistake cards of [u] that are worth doing again (the lines of maths found wrong that were kept, not known well yet), in page order.
List<ReviewCard> mistakesIn(StudyUnit u, Iterable<ReviewCard> cards) => [
      for (final c in cards)
        if (isMistakeCard(c.card.front) && c.schedule.interval < _mistakeKnownDays && inUnit(u, c.source, c.card.page)) c,
    ]..sort((a, b) => (a.card.page ?? 0).compareTo(b.card.page ?? 0));

/// The facts of [u] (from the facts of the graphs, each once).
List<StudyFact> factsIn(StudyUnit u, Iterable<FactSpot> facts) {
  final seen = <String>{};
  return [
    for (final f in facts)
      if (inUnit(u, f.noteId, f.page) && seen.add(f.fact.line)) f.fact,
  ];
}
