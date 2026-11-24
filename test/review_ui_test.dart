import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/screens/review_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('keys: space turns the card over and back, arrows skip, 1-4 rate once the answer shows', (tester) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      final cards = CardRepository(db);
      await cards.addAll('keys', const [Flashcard('first?', 'one'), Flashcard('second?', 'two')], now: DateTime(2026, 3, 1, 9));
      await tester.pumpWidget(MaterialApp(home: ReviewScreen(cards: cards, source: 'keys', clock: () => DateTime(2026, 3, 1, 9))));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // a rating before the answer was seen does nothing
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('2 left'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('flashcard-back')), findsOneWidget);
      // and back again
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('flashcard-back')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('flashcard')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('flashcard-back')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('flashcard')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('flashcard-back')), findsNothing);

      // an arrow goes to the other card without answering, and back
      final first = find.text('first?');
      expect(first, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('second?'), findsOneWidget);
      expect(first, findsNothing);
      expect(find.text('2 left'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(first, findsOneWidget);

      // 4 = easy
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('1 left'), findsOneWidget);
      expect(find.text('second?'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // "again" puts the card back in the queue
      expect(find.text('1 left'), findsOneWidget);
      await db.close();
    });
  });

  final t0 = DateTime(2026, 3, 1, 9);

  testWidgets('a round: show the answer, rate it; "again" brings the card back; the schedule is kept', (tester) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      final cards = CardRepository(db);
      await cards.addAll('n1', const [Flashcard('Capital of France?', 'Paris'), Flashcard('2 + 2?', '4')], now: t0);

      await tester.pumpWidget(MaterialApp(home: ReviewScreen(cards: cards, clock: () => t0)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(const ValueKey('flashcard-front')), findsOneWidget);
      expect(find.byKey(const ValueKey('flashcard-back')), findsNothing);
      expect(find.text('2 left'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('flashcard-flip')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('flashcard-back')), findsOneWidget);
      // the buttons say when the card would come back
      expect(find.text('10 min'), findsOneWidget);
      expect(find.text('1 d'), findsNWidgets(2)); // hard and good
      expect(find.text('4 d'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('review-again')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // the next card, and the missed one waits at the end
      expect(find.text('Capital of France?'), findsNothing);
      expect(find.text('2 left'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('flashcard-flip')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('review-good')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Capital of France?'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('flashcard-flip')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('review-easy')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('review-done')), findsOneWidget);
      expect(find.textContaining('3 reviewed: 1 again, 0 hard, 1 good, 1 easy'), findsOneWidget);

      // "good" put a card on its next day, "easy" (after the "again") four days on
      expect(await cards.dueCount(now: t0), 0);
      expect(await cards.dueCount(now: DateTime(2026, 3, 2)), 1);
      expect(await cards.dueCount(now: DateTime(2026, 3, 6)), 2);
      await db.close();
    });
  });

  testWidgets('with nothing due it says so', (tester) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await tester.pumpWidget(MaterialApp(home: ReviewScreen(cards: CardRepository(db), clock: () => t0)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('No cards are due.'), findsOneWidget);
      await db.close();
    });
  });

  testWidgets('the dashboard button shows how many are due and hides when nothing is kept', (tester) async {
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      final cards = CardRepository(db);
      await tester.pumpWidget(MaterialApp(home: Scaffold(appBar: AppBar(actions: [ReviewButton(cards: cards)]))));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('review-cards')), findsNothing);
      await cards.addAll('n1', const [Flashcard('Q', 'A')]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('review-cards')), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      await db.close();
    });
  });
}
