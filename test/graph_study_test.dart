import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/graph/graph_service.dart';
import 'package:notes/graph/study.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/screens/graph_study.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Service extends GraphService {
  final prompts = <AiPrompt>[];
  _Service(super.notes);

  @override
  bool get canStudy => true;

  @override
  Future<String> studyComplete(AiPrompt prompt, {int maxTokens = 900, AiCancel? cancel}) async {
    prompts.add(prompt);
    final s = prompt.system;
    if (s.contains('flashcards')) return 'Q: What do mitochondria make?\nA: ATP, the energy of the cell.\n\nQ: What holds the DNA?\nA: The nucleus.';
    if (s.contains('quiz questions')) return 'Q: Why does a cell need mitochondria?\nA: They make ATP, which is its energy.\n\nQ: Where is the DNA kept?\nA: In the nucleus.';
    if (s.contains('judging')) return prompt.user.contains('Student answer: ATP') ? 'Score: 10\nCorrect: yes\nFeedback:' : 'Score: 4\nCorrect: no\nFeedback: The nucleus is missing.';
    return 'I cannot answer this question from the facts. They say nothing about it.';
  }
}

const facts = [
  StudyFact('Cell: Mitochondria', 'Mitochondria make ATP, the energy of the cell.'),
  StudyFact('Cell: Nucleus', 'The nucleus holds the DNA of the cell.'),
];

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the parts', () {
    test('a grade is read from the lines of the answer, with a score only as the least', () {
      final g = parseGrade('Score: 7\nCorrect: yes\nFeedback: A detail is missing.\nIt is the third step.')!;
      expect((g.score, g.correct), (7, true));
      expect(g.feedback, 'A detail is missing.\nIt is the third step.');
      expect(parseGrade('Score: 10\nCorrect: yes\nFeedback: great')!.feedback, isEmpty, reason: 'a perfect answer needs no correction');
      expect(parseGrade('**Score:** 3\n**Correct:** no')!.correct, isFalse);
      expect(parseGrade('Punkte: 9')!.correct, isTrue, reason: 'no verdict: the score decides');
      expect(parseGrade('no idea'), isNull);
    });

    test('a quiz asks the weakest question next and drops the ones that are mastered', () {
      final quiz = QuizSession([const Flashcard('a?', 'a'), const Flashcard('b?', 'b'), const Flashcard('c?', 'c')]);
      final a = quiz.current!;
      quiz.record(a, const Grade(4, false, 'x'));
      expect(a.weight, closeTo(0.2, 1e-9));
      quiz.advance();
      expect(quiz.current!.question, 'b?', reason: 'the others are less known than a');
      quiz.record(quiz.current!, const Grade(10, true, ''));
      expect(quiz.masteredCount, 1);
      quiz.advance();
      expect(quiz.current!.question, 'c?');
      quiz.record(quiz.current!, const Grade(9, true, ''));
      quiz.advance();
      expect(quiz.current, a, reason: 'only the one that was missed is left');
      quiz.record(a, const Grade(8, true, ''));
      expect(quiz.done, isTrue);
      expect(quiz.overall, 1);
    });

    test('the facts that fit a question are the ones with its words', () {
      final all = [for (var i = 0; i < 30; i++) StudyFact('T$i', 'Filler sentence number $i about something else.'), const StudyFact('Heaps', 'The swim function restores the heap property.')];
      expect(closestFacts('how does the swim function work', all, count: 3).map((f) => f.title), ['Heaps']);
    });

    test('the prompts carry the facts and the rules', () {
      expect(quizPrompt(facts, 4).user, allOf(contains('1. Cell: Mitochondria: Mitochondria make ATP'), contains('4 questions')));
      expect(askFactsPrompt('why?', facts).system, contains('using only the facts'));
      expect(gradePrompt('q', 'e', 'a').user, allOf(contains('Question: q'), contains('Expected answer: e'), contains('Student answer: a')));
    });
  });

  testWidgets('flashcards, a graded quiz and a question from the facts', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late _Service service;
    await tester.runAsync(() async => service = _Service(NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath))));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: GraphStudy(service: service, title: 'Cell', facts: facts))));

    // cards
    await tester.tap(find.byKey(const ValueKey('study-cards-make')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('flashcard-front')), findsOneWidget);
    expect(service.prompts.single.user, contains('Mitochondria make ATP'));
    await tester.tap(find.byKey(const ValueKey('flashcard-flip')));
    await tester.pumpAndSettle();
    expect(find.text('ATP, the energy of the cell.'), findsOneWidget);

    // quiz
    await tester.tap(find.text('Quiz'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quiz-make')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quiz-question')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('quiz-answer')), 'They make ATP');
    await tester.tap(find.byKey(const ValueKey('quiz-send')));
    await tester.pumpAndSettle();
    expect(find.text('Score 4 of 10'), findsOneWidget);
    expect(find.text('The nucleus is missing.'), findsOneWidget);
    expect(find.byKey(const ValueKey('quiz-expected')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quiz-next')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quiz-feedback')), findsNothing);

    // ask
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ask-question')), 'Who discovered the nucleus?');
    await tester.tap(find.byKey(const ValueKey('ask-send')));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot answer'), findsOneWidget);
    expect(service.prompts.last.user, contains('Question: Who discovered the nucleus?'));
  });
}
