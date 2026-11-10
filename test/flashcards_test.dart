
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/assistant_chat.dart';
import 'package:notes/ai/document_index.dart';
import 'package:notes/ai/flashcards.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/markdown/markdown_table.dart';
import 'package:notes/screens/assistant_panel.dart';
import 'package:notes/screens/flashcard_view.dart';

class _Model extends ChangeNotifier implements TextModelProvider, ContextSized {
  _Model(this.answer);
  String answer;
  final prompts = <AiPrompt>[];
  @override
  int get contextChars => 3000;
  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  String get description => '';
  @override
  ProviderState get state => ProviderState.ready;
  @override
  String? get reason => null;
  @override
  Future<void> prepare() async {}
  @override
  Future<String> complete(AiPrompt prompt, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async {
    prompts.add(prompt);
    onPartial?.call(answer);
    return answer;
  }
}

const reply = '''
Here are your cards:

Q: What does entropy do in an isolated system?
A: It never decreases.
Page: 2

**Q:** When is the final exam?
**A:** On 20 June,
in room B12.

3. Question: What is thermodynamics?
   Answer: The study of heat.
''';

void main() {
  group('reading the cards a model wrote', () {
    test('Q/A lines, bold marks, numbering, answers over several lines, pages and an introduction', () {
      final cards = parseFlashcards(reply);
      expect(cards.map((c) => c.front), ['What does entropy do in an isolated system?', 'When is the final exam?', 'What is thermodynamics?']);
      expect(cards.map((c) => c.back), ['It never decreases.', 'On 20 June,\nin room B12.', 'The study of heat.']);
      expect(cards[0].page, 1); // "Page: 2" is page index 1
      expect(cards[1].page, isNull);
    });

    test('a card needs both sides, and the same question is not made twice', () {
      expect(parseFlashcards('Q: only a question\n\nQ: another\nA: with answer\n\nQ: another\nA: again'), hasLength(1));
      expect(parseFlashcards('nothing like a card'), isEmpty);
      expect(parseFlashcards(''), isEmpty);
    });

    test('German labels and a JSON list work too', () {
      expect(parseFlashcards('Frage: Was ist Entropie?\nAntwort: Unordnung.').single.back, 'Unordnung.');
      final json = parseFlashcards('```json\n[{"question":"Why?","answer":"Because."},{"q":"x"}]\n```');
      expect(json.single.front, 'Why?');
      expect(json.single.back, 'Because.');
    });
  });

  group('studying', () {
    final cards = [for (var i = 1; i <= 4; i++) Flashcard('Q$i', 'A$i')];

    test('a round, the missed cards, and starting over', () {
      final deck = FlashcardDeck(cards);
      expect(deck.current!.front, 'Q1');
      deck.flip();
      expect(deck.flipped, isTrue);
      deck.gotIt();
      expect(deck.flipped, isFalse, reason: 'the next card shows its question');
      deck.again();
      deck.gotIt();
      deck.again();
      expect(deck.finished, isTrue);
      expect(deck.knownCount, 2);
      expect(deck.missed.map((c) => c.front), ['Q2', 'Q4']);

      deck.studyMissed();
      expect(deck.roundLength, 2);
      expect(deck.current!.front, 'Q2');
      deck.gotIt();
      deck.gotIt();
      expect(deck.finished, isTrue);
      expect(deck.missed, isEmpty);

      deck.startOver(shuffle: true);
      expect(deck.roundLength, 4);
      expect(deck.position, 0);
      expect(deck.cards.map((c) => c.front), ['Q1', 'Q2', 'Q3', 'Q4'], reason: 'the deck itself keeps its order');
    });

    test('the cards as a table and as text', () {
      final table = parseTableText(cardsAsTable([const Flashcard('a | b?', 'yes'), const Flashcard('Q', 'A\nmore')]))!;
      expect(table.first, ['Question', 'Answer']);
      expect(table[1], ['a | b?', 'yes']);
      expect(table[2], ['Q', 'A more']);
      expect(cardsAsText(cards.take(2).toList()), 'Q: Q1\nA: A1\n\nQ: Q2\nA: A2');
    });
  });

  group('in the assistant', () {
    late _Model model;
    late AiService ai;
    late AssistantChat chat;
    final added = <String>[];
    final jumped = <int>[];

    Future<void> open(WidgetTester tester) async {
      model = _Model(reply);
      ai = AiService(settings: null, providers: [model]);
      added.clear();
      jumped.clear();
      chat = AssistantChat(
        ai: ai,
        index: () async => DocumentIndex([
          ...chunkText('Page 1', 0, 'The final exam is on 20 June in room B12.'),
          ...chunkText('Page 2', 1, 'Entropy never decreases in an isolated system.'),
        ]),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AssistantPanel(ai: ai, chat: chat, onClose: () {}, onAddToNote: (text, target, {title}) => added.add(text), onJumpToPage: jumped.add)),
      ));
    }

    testWidgets('with the flashcards tool off the assistant offers no cards', (tester) async {
      model = _Model(reply);
      ai = AiService(settings: null, providers: [model]);
      chat = AssistantChat(ai: ai, index: () async => DocumentIndex(chunkText('Page 1', 0, 'Some text to ask about.')));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: AssistantPanel(ai: ai, chat: chat, onClose: () {}, flashcards: false))));
      expect(find.byKey(const ValueKey('assistant-flashcards')), findsNothing);
      expect(find.byKey(const ValueKey('assistant-suggestion-flashcards')), findsNothing);
      expect(find.byKey(const ValueKey('assistant-input')), findsOneWidget, reason: 'the conversation is still there');
    });

    testWidgets('make cards, turn them over, miss one, practise it, and put the cards on the note', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('assistant-suggestion-flashcards')));
      await tester.pump();
      expect(find.byKey(const ValueKey('flashcards-make')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('flashcards-count-5')));
      await tester.pump();

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('flashcards-make')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(model.prompts.single.user, contains('Make 5 flashcards'));
      expect(model.prompts.single.user, contains('[Page 1]'));
      expect(chat.deck!.cards, hasLength(3));

      expect(find.byKey(const ValueKey('flashcard-front')), findsOneWidget);
      expect(find.text('What does entropy do in an isolated system?'), findsOneWidget);
      expect(find.byKey(const ValueKey('assistant-input')), findsNothing, reason: 'no chat box over the cards');
      await tester.tap(find.byKey(const ValueKey('flashcard')));
      await tester.pumpAndSettle();
      expect(find.text('It never decreases.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('flashcard-got')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('flashcard-flip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('flashcard-again')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('flashcard-flip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('flashcard-got')));
      await tester.pumpAndSettle();

      expect(find.text('2 of 3 known'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('flashcards-missed')));
      await tester.pumpAndSettle();
      expect(find.text('When is the final exam?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('flashcard-flip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('flashcard-got')));
      await tester.pumpAndSettle();
      expect(find.text('1 of 1 known'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('flashcards-add')));
      expect(added.single, startsWith('| Question | Answer |'));
      expect(parseTableText(added.single)!.length, 4);
    });

    testWidgets('a card from a page can take the reader there', (tester) async {
      await open(tester);
      chat.deck = FlashcardDeck(const [Flashcard('Q', 'A', page: 1)]);
      chat.openFlashcards();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('flashcard-page')));
      expect(jumped, [1]);
    });

    testWidgets('when the model writes nothing usable, the person is told and can try again', (tester) async {
      await open(tester);
      model.answer = 'Sorry, I cannot do that.';
      chat.openFlashcards();
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('flashcards-make')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('flashcards-error')), findsOneWidget);
      expect(chat.deck, isNull);
      expect(find.byKey(const ValueKey('flashcards-make')), findsOneWidget);
    });

    testWidgets('a document without text says so', (tester) async {
      await open(tester);
      final empty = AssistantChat(ai: ai, index: () async => DocumentIndex([]));
      await empty.makeFlashcards(5);
      expect(empty.deck, isNull);
      expect(empty.cardError, contains('no text'));
      expect(model.prompts, isEmpty);
    });
  });
}
