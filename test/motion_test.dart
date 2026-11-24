import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/screens/flashcard_view.dart';
import 'package:notes/style/motion.dart';

Widget _app(Widget child, {bool noMotion = false}) =>
    MaterialApp(builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: noMotion), child: c!), home: Scaffold(body: child));

void main() {
  testWidgets('Reveal grows to its height, and is gone once it has shrunk', (tester) async {
    var open = false;
    late StateSetter set;
    await tester.pumpWidget(_app(StatefulBuilder(builder: (context, s) {
      set = s;
      return Column(children: [Reveal(open: open, child: const SizedBox(key: ValueKey('inner'), height: 100, width: 100))]);
    })));
    expect(find.byKey(const ValueKey('inner')), findsNothing);
    set(() => open = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final partway = tester.getSize(find.byType(Reveal)).height;
    expect(partway, inExclusiveRange(0, 100));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(Reveal)).height, 100);
    set(() => open = false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inner')), findsNothing);
  });

  testWidgets('Reveal opens at once when motion is off', (tester) async {
    var open = false;
    late StateSetter set;
    await tester.pumpWidget(_app(noMotion: true, StatefulBuilder(builder: (context, s) {
      set = s;
      return Column(children: [Reveal(open: open, child: const SizedBox(height: 100, width: 100))]);
    })));
    set(() => open = true);
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(find.byType(Reveal)).height, 100);
  });

  testWidgets('a flashcard turns over: edge-on in the middle, the other face after', (tester) async {
    var front = true;
    late StateSetter set;
    await tester.pumpWidget(_app(StatefulBuilder(builder: (context, s) {
      set = s;
      return FlipCard(front: front, face: (f) => Text(f ? 'question' : 'answer'));
    })));
    expect(find.text('question'), findsOneWidget);
    set(() => front = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('question'), findsOneWidget); // still the first half of the turn
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('answer'), findsOneWidget);
    expect(find.text('question'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('answer'), findsOneWidget);
  });

  testWidgets('FadeOnChange fades in when it appears', (tester) async {
    await tester.pumpWidget(_app(const FadeOnChange(token: 'a', child: Text('x'))));
    expect(tester.widget<FadeTransition>(find.byType(FadeTransition).last).opacity.value, 0);
    await tester.pumpAndSettle();
    expect(tester.widget<FadeTransition>(find.byType(FadeTransition).last).opacity.value, 1);
  });

  test('a deck puts a card off and brings it back', () {
    final deck = FlashcardDeck(const [Flashcard('a', '1'), Flashcard('b', '2'), Flashcard('c', '3')]);
    deck.skip();
    expect(deck.current!.front, 'b');
    deck.skip();
    expect(deck.current!.front, 'c');
    deck.unskip();
    expect(deck.current!.front, 'b');
    expect(deck.roundLength, 3);
    expect(deck.position, 0);
    final one = FlashcardDeck(const [Flashcard('a', '1')])..skip();
    expect(one.current!.front, 'a');
  });

  testWidgets('a deck of the assistant: space turns the card over and back, 2 says it was known', (tester) async {
    final deck = FlashcardDeck(const [Flashcard('q1', 'a1'), Flashcard('q2', 'a2')]);
    await tester.pumpWidget(_app(DeckView(deck: deck, onNew: () {})));
    await tester.tap(find.byKey(const ValueKey('flashcard')));
    await tester.pumpAndSettle();
    expect(deck.flipped, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(deck.flipped, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('q2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2); // not turned yet: nothing
    await tester.pumpAndSettle();
    expect(deck.knownCount, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pumpAndSettle();
    expect(deck.knownCount, 1);
    expect(find.text('q1'), findsOneWidget);
  });
}
