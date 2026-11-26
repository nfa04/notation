import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/cloze.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/ai/spaced_repetition.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/card_repository.dart';
import 'package:notes/export/anki_export.dart';
import 'package:notes/export/anki_import.dart';
import 'package:notes/markdown/markdown_view.dart';
import 'package:notes/screens/review_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);
  final now = DateTime(2026, 11, 26, 10);

  group('cloze texts', () {
    const text = 'The {{c1::stack}} is {{c2::LIFO::an order}}, a {{c1::stack}} again.';

    test('the parts are numbered, each number once', () {
      expect(clozeNumbers(text), [1, 2]);
      expect(hasCloze(text), isTrue);
      expect(hasCloze('nothing hidden'), isFalse);
    });

    test('a card hides its part in bold, with the hint, and shows it in bold on the back', () {
      expect(clozeFaces(text, 1), ('The **[...]** is LIFO, a **[...]** again.', 'The **stack** is LIFO, a **stack** again.'));
      expect(clozeFaces(text, 2).$1, 'The stack is **[an order]**, a stack again.');
    });

    test('words chosen in a text are hidden as the next number, without the spaces round them', () {
      const plain = 'Mitochondria make ATP from glucose.';
      final once = hideAsCloze(plain, plain.indexOf('ATP') - 1, plain.indexOf('ATP') + 3);
      expect(once, 'Mitochondria make {{c1::ATP}} from glucose.');
      final twice = hideAsCloze(once, once.indexOf('glucose'), once.indexOf('glucose') + 7);
      expect(twice, 'Mitochondria make {{c1::ATP}} from {{c2::glucose}}.');
      expect(hideAsCloze(twice, twice.indexOf('ATP'), twice.indexOf('ATP') + 2), twice, reason: 'inside a hidden part: nothing changes');
      expect(hideAsCloze(plain, 3, 3), plain);
      expect(hideAsCloze(plain, 12, 13), plain, reason: 'only a space');
    });

    test('a text gives a card for each part, and each card is another card', () {
      final cards = clozeCards(text, extra: 'Data structures', page: 4);
      expect(cards.map((c) => c.clozeNumber), [1, 2]);
      expect(cards.map((c) => c.identity).toSet().length, 2);
      expect(cards.first.page, 4);
      expect(cards.first.faces.$2, 'The **stack** is LIFO, a **stack** again.\n\nData structures');
      expect(clozeCards('nothing hidden'), isEmpty);
    });
  });

  group('kept for review', () {
    late Database db;
    late CardRepository cards;
    setUp(() async {
      db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('review_cards');
      cards = CardRepository(db);
    });
    tearDown(() => db.close());

    test('the cards of one text are kept apart, with their kind and part, and not twice', () async {
      const text = 'The {{c1::stack}} is {{c2::LIFO}}.';
      expect(await cards.addAll('n1', [...clozeCards(text), const Flashcard('Q', 'A')], now: now), 3);
      expect(await cards.addAll('n1', clozeCards(text), now: now), 0);
      final all = await cards.all(source: 'n1');
      expect(all.map((c) => (c.card.kind, c.card.kind == CardKind.cloze ? c.card.clozeNumber : 0)), [('cloze', 1), ('cloze', 2), ('basic', 0)]);
      expect(all.first.card.faces.$1, 'The **[...]** is LIFO.');
      expect(all.last.card.media, isNull);
    });

    testWidgets('a cloze card is asked with its part hidden, and formulas are drawn', (tester) async {
      await tester.runAsync(() async {
        await cards.addAll('n1', [Flashcard.cloze(r'The derivative of $x^2$ is {{c1::$2x$}}.', 1)], now: now);
        await tester.pumpWidget(MaterialApp(home: ReviewScreen(cards: cards, clock: () => now)));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      });
      expect(find.descendant(of: find.byKey(const ValueKey('flashcard-front')), matching: find.byType(MarkdownView)), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'\*\*\[\.\.\.\]\*\*')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('flashcard-flip')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.bySemanticsLabel(RegExp(r'\*\*\$2x\$\*\*')), findsOneWidget);
    });
  });

  group('Anki', () {
    test('cloze cards go out as one cloze note with a card per part, and come back as cloze cards with their schedules', () async {
      final work = Directory.systemTemp.createTempSync('cloze_anki');
      addTearDown(() => work.deleteSync(recursive: true));
      const text = r'Big O of binary search is {{c1::$O(\log n)$}}, of a scan {{c2::$O(n)$}}.';
      final learned = CardSchedule(interval: 12, ease: 2.3, reps: 3, due: now.add(const Duration(days: 5)));
      final bytes = await ankiPackage([
        AnkiCard(id: 'a', deck: 'Algorithms', front: text, back: 'Lecture 2', schedule: learned, cloze: 1),
        const AnkiCard(id: 'b', deck: 'Algorithms', front: text, back: 'Lecture 2', schedule: CardSchedule(), cloze: 2),
        const AnkiCard(id: 'c', deck: 'Algorithms', front: 'Plain?', back: 'Yes', schedule: CardSchedule()),
      ], workDirectory: work, now: now);
      final read = await readAnkiPackage(bytes, workDirectory: work, now: now);
      expect(read, hasLength(3));
      final cloze = read.where((c) => c.cloze != null).toList()..sort((a, b) => a.cloze!.compareTo(b.cloze!));
      expect(cloze.map((c) => c.cloze), [1, 2]);
      expect(cloze.first.clozeText, text);
      expect(cloze.first.clozeExtra, 'Lecture 2');
      expect(cloze.first.card.kind, CardKind.cloze);
      expect(cloze.first.schedule.interval, 12);
      expect(cloze.last.schedule.reps, 0);
      expect(read.singleWhere((c) => c.cloze == null).card.kind, CardKind.basic);
    });
  });
}
