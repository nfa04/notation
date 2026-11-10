import '../ai/ai_prompt.dart';
import '../ai/flashcards.dart';
import '../ai/document_index.dart';

/// The study tools of the graph view, after the ones of OpenKnowledgeBase: flashcards and quiz questions made from the facts of a
/// topic, a grade for the answer a student wrote, and answers that rest on the facts alone. Every prompt asks for lines, not JSON
/// (small models keep to lines better); cards are the ones of the assistant ([Flashcard], [FlashcardDeck]).

/// A fact as the study tools read it.
class StudyFact {
  final String title;
  final String sentence;
  const StudyFact(this.title, this.sentence);

  String get line => title.isEmpty ? sentence : '$title: $sentence';
}

/// The most facts that go into one request (a small model on the device loses the thread with more).
const studyBatch = 10;

/// The facts as the numbered list the prompts take.
String factList(Iterable<StudyFact> facts) => [for (final (i, f) in facts.indexed) '${i + 1}. ${f.line}'].join('\n');

/// Flashcards from facts: the prompt of the assistant, with the facts as the passage (OpenKnowledgeBase's flashcard prompt asks for
/// the same: a short front, a one-sentence back, nothing that is not in the facts).
AiPrompt cardsFromFactsPrompt(List<StudyFact> facts, int count) => flashcardPrompt(factList(facts), count);

/// Quiz questions from the facts of one topic (OpenKnowledgeBase's question prompt): they test understanding, stand on their own and
/// are answered by the facts alone; the answer is the reference a grade is made against.
AiPrompt quizPrompt(List<StudyFact> facts, int count) => AiPrompt(
      system: 'You write quiz questions for a student from a list of facts that belong to one topic. Each question tests that the student '
          'understood the underlying concept, not that they can repeat the words. Rules:\n'
          '- A question makes sense entirely on its own: it never says "according to the text" or "during this period"; it names the subject '
          'and the actual period.\n'
          '- A question can be answered from the facts alone: add no outside information.\n'
          '- The reference answer is the concise, definitive correct answer taken from the facts; when in doubt, include more rather than less.\n'
          '- Write in the language of the facts.\n'
          'Write each question exactly like this, a blank line between questions, and nothing else (no numbering, no introduction):\n'
          'Q: the question\n'
          'A: the reference answer',
      user: 'Facts:\n${factList(facts)}\n\nWrite $count questions.',
    );

/// How a student's answer was judged.
class Grade {
  /// 1 to 10.
  final int score;
  final bool correct;

  /// What was missing or wrong; empty for a perfect answer.
  final String feedback;
  const Grade(this.score, this.correct, this.feedback);
}

/// The prompt that judges [answer] against the reference answer (OpenKnowledgeBase's grade prompt): the idea counts, not the wording.
AiPrompt gradePrompt(String question, String expected, String answer) => AiPrompt(
      system: 'You are an objective tutor judging a student\'s answer to a question. Compare it with the expected answer. Judge the '
          'understanding, not the wording: typos and different phrasing do not matter.\n'
          'Correct: yes if the core concept is right; no if there is a fundamental misunderstanding, a contradiction of the expected answer, or the '
          'main point is missing.\n'
          'Score: 10 complete mastery; 8-9 the core is understood but a small detail is missing or imprecise; 5-7 some of it is right but it is '
          'not connected or half is missing; 2-4 severe misunderstanding; 1 wrong, off topic, or "I don\'t know".\n'
          'Feedback: leave it empty for a 10. Otherwise say briefly and directly what was missing or why the answer is flawed, with no praise '
          'and no filler.\n'
          'Answer in the language of the question, in exactly these three lines and nothing else:\n'
          'Score: a number from 1 to 10\n'
          'Correct: yes or no\n'
          'Feedback: the correction',
      user: 'Question: $question\nExpected answer: $expected\nStudent answer: $answer',
      exact: true,
    );

/// The grade in what a model wrote, or null when it did not say a score.
Grade? parseGrade(String text) {
  final score = RegExp(r'(?:score|punkte|note)\s*[:=]?\s*\**\s*(\d{1,2})', caseSensitive: false).firstMatch(text);
  if (score == null) return null;
  final n = int.parse(score.group(1)!).clamp(1, 10);
  final correct = RegExp(r'(?:correct|richtig)\s*[:=]?\s*\**\s*(yes|no|true|false|ja|nein)', caseSensitive: false).firstMatch(text)?.group(1)?.toLowerCase();
  final feedback = RegExp(r'^\s*\**(?:feedback|r(?:ü|u)ckmeldung)\**\s*[:=]?\s*(.*(?:\n(?!\s*\**(?:score|correct|richtig)\b).*)*)', caseSensitive: false, multiLine: true).firstMatch(text)?.group(1)?.trim() ?? '';
  return Grade(n, correct == null ? n >= 7 : const {'yes', 'true', 'ja'}.contains(correct), n >= 10 ? '' : feedback);
}

/// The prompt that answers a question from the facts and from nothing else (OpenKnowledgeBase's search prompt): it explains and
/// connects the facts, and says so when they do not contain the answer.
AiPrompt askFactsPrompt(String question, List<StudyFact> facts) => AiPrompt(
      system: 'You are a study assistant that explains concepts clearly. Answer the student\'s question using only the facts you are given.\n'
          '- Rely exclusively on the facts: not on your training data or general knowledge, even if you know something to be true.\n'
          '- If the facts do not contain enough to answer fully, say plainly that you cannot answer this question from the facts, and explain what '
          'information is missing.\n'
          '- This is for studying, so do not give a bare answer: synthesize the facts, explain the mechanism or concept, and walk the student through '
          'how the facts lead to the answer. You may combine facts logically, but never invent facts, dates, names or mechanisms.\n'
          '- Answer in the language of the question. Name the numbers of the facts you used in brackets, like (2, 5).',
      user: 'Facts:\n${factList(facts)}\n\nQuestion: $question',
    );

/// The [count] facts of [all] that fit [question] best by their words (the facts of a whole graph are too many for one request).
List<StudyFact> closestFacts(String question, List<StudyFact> all, {int count = studyBatch}) {
  final terms = searchTerms(question).toSet();
  if (terms.isEmpty || all.length <= count) return all.take(count).toList();
  double score(StudyFact f) {
    final has = searchTerms(f.line).toSet();
    return terms.where(has.contains).length / terms.length;
  }

  final scored = [for (final f in all) (fact: f, score: score(f))]..sort((a, b) => b.score.compareTo(a.score));
  return [for (final s in scored.take(count)) if (s.score > 0) s.fact];
}

/// A question of a quiz, with how well it is known.
class QuizQuestion {
  final String question;
  final String expected;
  double weight = 0;
  bool mastered = false;
  QuizQuestion(this.question, this.expected);
}

/// A quiz being taken: the weakest question that is not mastered comes next, and a grade raises the weight of its question
/// (as in OpenKnowledgeBase: by half of the score, a correct answer or a weight over 0.95 masters it).
class QuizSession {
  final List<QuizQuestion> questions;
  QuizQuestion? current;

  QuizSession(List<Flashcard> made) : questions = [for (final c in made) QuizQuestion(c.front, c.back)] {
    current = next();
  }

  /// The question to ask after [current], or null when all are mastered.
  QuizQuestion? next() {
    QuizQuestion? best;
    for (final q in questions) {
      if (q.mastered || identical(q, current)) continue;
      if (best == null || q.weight < best.weight) best = q;
    }
    return best ?? (current != null && !current!.mastered ? current : null);
  }

  /// Takes a grade for [q].
  void record(QuizQuestion q, Grade g) {
    q.weight = (q.weight + 0.5 * g.score / 10).clamp(0, 1).toDouble();
    if (g.correct || q.weight > 0.95) {
      q.mastered = true;
      q.weight = 1;
    }
  }

  void advance() => current = next();

  /// How well the topic is known, 0 to 1.
  double get overall => questions.isEmpty ? 0 : questions.map((q) => q.weight).reduce((a, b) => a + b) / questions.length;
  int get masteredCount => questions.where((q) => q.mastered).length;
  bool get done => questions.every((q) => q.mastered);
}
