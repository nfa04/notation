import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/assistant_chat.dart';
import 'package:notes/ai/document_index.dart';
import 'package:notes/ai/note_lookup.dart';
import 'package:notes/ai/openai_provider.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/llm/onnx_chat_provider.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/assistant_panel.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/search/search_query.dart' show InkText;
import 'package:notes/sync/caldav_service.dart' show SecretStore;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Provider extends ChangeNotifier implements TextModelProvider, ContextSized {
  _Provider({this.answer = 'It is about entropy (p. 1).', this.chars = 3000});
  final String answer;
  final int chars;
  @override
  int get contextChars => chars;
  final prompts = <AiPrompt>[];
  Completer<void>? hold;
  Object? failWith;

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
    if (failWith != null) throw failWith!;
    var shown = '';
    for (final w in answer.split(' ')) {
      if (cancel?.cancelled ?? false) break;
      shown = shown.isEmpty ? w : '$shown $w';
      onPartial?.call(shown);
      await hold?.future;
    }
    return shown;
  }
}

/// Answers the first time with the start of an answer that reached the limit, then with the rest.
class _CutProvider extends _Provider {
  var _turn = 0;
  @override
  Future<String> complete(AiPrompt prompt, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async {
    prompts.add(prompt);
    final n = _turn++;
    if (n == 0) {
      cancel?.cutOff = true;
      return 'The exam is on 20';
    }
    return n == 1 ? 'June in room B12.' : 'The exam is on 20 June in room B12.';
  }
}

class _Secret implements SecretStore {
  @override
  Future<String?> read() async => 'k';
  @override
  Future<void> write(String v) async {}
  @override
  Future<void> delete() async {}
}

DocumentIndex longDocument() => DocumentIndex([
      for (var p = 0; p < 40; p++)
        ...chunkText('Page ${p + 1}', p, 'Filler text about nothing in particular on page ${p + 1}. ' * 6),
      ...chunkText('Page 41', 40, 'The final exam takes place on 20 June in room B12. Bring a calculator.'),
      ...chunkText('Page 42', 41, 'Entropy never decreases in an isolated system. Thermodynamics studies heat.'),
    ]);

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the document in chunks', () {
    test('text is split at paragraphs, then sentences, then words', () {
      final chunks = chunkText('Page 1', 0, 'First paragraph.\n\nSecond paragraph.\n\n${'Word ' * 300}', maxLength: 100);
      expect(chunks.first.text, 'First paragraph.\nSecond paragraph.'); // short ones share a chunk
      expect(chunks.every((c) => c.text.length <= 100 && c.where == 'Page 1' && c.page == 0), isTrue);
      expect(chunks.length, greaterThan(10)); // the long one is cut up
      expect(chunkText('x', null, '  \n\n  '), isEmpty);
      final sentences = chunkText('x', 1, 'Sentence number one is here. ' * 10, maxLength: 80);
      expect(sentences.every((c) => c.text.endsWith('.')), isTrue); // cut at the full stops
    });

    test('a document that fits is given whole, in order', () {
      final doc = DocumentIndex([
        ...chunkText('Page 1', 0, 'Alpha text.'),
        ...chunkText('Page 2', 1, 'Beta text.'),
        ...chunkText('Page 2', 1, 'More beta.\n\nEven more beta.'),
      ]);
      final e = doc.select('anything', 10000);
      expect(e.complete, isTrue);
      expect(e.text, '[Page 1]\nAlpha text.\n\n[Page 2]\nBeta text.\nMore beta.\nEven more beta.');
    });

    test('a long document gives the passages that match the question', () {
      final doc = longDocument();
      expect(doc.totalChars, greaterThan(10000));
      final e = doc.select('When is the final exam?', 2000);
      expect(e.complete, isFalse);
      expect(e.text, contains('The final exam takes place on 20 June'));
      expect(e.text, isNot(contains('Entropy never decreases')));
      expect(e.text.length, lessThan(2300));
      expect(e.pages.first, 40); // pointing at page 41
      // in document order, whatever the ranking
      final entropy = doc.select('entropy and exam', 2000);
      expect(entropy.text.indexOf('final exam'), lessThan(entropy.text.indexOf('Entropy never')));
    });

    test('word endings and other languages still find the passage, little words do not count', () {
      final doc = DocumentIndex([
        ...chunkText('Page 1', 0, 'Die Prüfungen finden im Juni statt.' * 1),
        for (var i = 0; i < 30; i++) ...chunkText('Page ${i + 2}', i + 1, 'Nichts Besonderes hier, nur Fülltext ${'x' * 60} $i'),
      ]);
      expect(doc.select('Wann ist die Prüfung?', 800).text, contains('Prüfungen finden'));
      expect(searchTerms('What is the exams of the year?'), ['exams', 'year']);
    });

    test('a question without anything to look for gets the start and a spread of the rest', () {
      final e = longDocument().select('Summarize this document', 3000);
      expect(e.complete, isFalse);
      expect(e.text, startsWith('[Page 1]'));
      expect(RegExp(r'\[Page \d+\]').allMatches(e.text).length, greaterThan(3));
      expect(e.pages, isEmpty);
    });

    test('an empty document and one passage longer than the room', () {
      expect(DocumentIndex([]).select('q', 100).complete, isTrue);
      final one = DocumentIndex([DocChunk('Page 1', 0, 'x' * 5000)]);
      expect(one.select('anything', 1000).text.length, lessThan(1300));
    });
  });

  group('what is sent', () {
    const prompt = AiPrompt(system: 'S', user: 'Q2', history: [AiTurn(true, 'Q1'), AiTurn(false, 'A1')]);

    test('the on-device format puts the history between the instructions and the question', () {
      final q3 = OnnxChatProvider.chat(prompt);
      expect(q3.fixed, '<|im_start|>system\nS<|im_end|>\n');
      expect(q3.question,
          '<|im_start|>user\nQ1<|im_end|>\n<|im_start|>assistant\nA1<|im_end|>\n<|im_start|>user\nQ2<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n');
      expect(OnnxChatProvider.chat(const AiPrompt(system: 'S', user: 'Q'), thinking: false).question,
          '<|im_start|>user\nQ<|im_end|>\n<|im_start|>assistant\n');
    });

    test('a service of the OpenAI kind gets the turns as messages', () async {
      late Map<String, dynamic> body;
      final p = OpenAiProvider(
        secret: _Secret(),
        transport: (url, headers, b, cancel) {
          body = jsonDecode(b) as Map<String, dynamic>;
          return Stream.value('data: {"choices":[{"delta":{"content":"ok"}}]}\n\ndata: [DONE]\n\n');
        },
      );
      await p.save(const OpenAiConfig(model: 'm'), 'k');
      await p.complete(prompt);
      expect(body['messages'], [
        {'role': 'system', 'content': 'S'},
        {'role': 'user', 'content': 'Q1'},
        {'role': 'assistant', 'content': 'A1'},
        {'role': 'user', 'content': 'Q2'},
      ]);
      expect(p.contextChars, greaterThan(20000));
    });

    test('a small on-device model is given little of the document', () {
      expect(OnnxChatProvider().contextChars, 3500); // before a choice: the smallest
    });
  });

  group('the conversation', () {
    late _Provider provider;
    late AssistantChat chat;

    setUp(() {
      provider = _Provider();
      chat = AssistantChat(ai: AiService(providers: [provider]), index: () async => longDocument());
    });

    test('a question is answered from the passages, with the page', () async {
      await chat.ask('When is the final exam?');
      expect(chat.messages.map((m) => (m.fromUser, m.text)), [(true, 'When is the final exam?'), (false, 'It is about entropy (p. 1).')]);
      final sent = provider.prompts.single;
      expect(sent.system, AiTask.assistant.defaultSystem);
      expect(sent.user, contains('The final exam takes place on 20 June'));
      expect(sent.user, endsWith('Question: When is the final exam?'));
      expect(sent.history, isEmpty);
      expect(chat.messages.last.pages.first, 40);
      expect(chat.busy, isFalse);
    });

    test('the answer is checked against the passages it names', () async {
      final cited = _Provider(answer: 'The final exam takes place on 20 June [Page 41].');
      final one = AssistantChat(ai: AiService(providers: [cited]), index: () async => longDocument());
      await one.ask('When is the final exam?');
      final check = one.messages.last.check!;
      expect(check.sources.map((s) => (s.mark.mark, s.mark.page, s.supported)), [('Page 41', 40, true)]);
      // a made-up page, and a statement the page does not make
      final wrong = _Provider(answer: 'Mitochondria produce energy inside every living cell [Page 41]. See [Page 999].');
      final two = AssistantChat(ai: AiService(providers: [wrong]), index: () async => longDocument());
      await two.ask('When is the final exam?');
      final bad = two.messages.last.check!;
      expect(bad.sources.single.supported, isFalse);
      expect(bad.unknown, ['Page 999']);
      // and the model is told to name them
      expect(wrong.prompts.single.system, contains('after each statement'));
    });

    test('what was said before is given along, and a short follow-up still finds the passage', () async {
      await chat.ask('When is the final exam?');
      await chat.ask('and where?');
      final sent = provider.prompts.last;
      expect([for (final t in sent.history) (t.fromUser, t.text)],
          [(true, 'When is the final exam?'), (false, 'It is about entropy (p. 1).')]);
      expect(sent.user, contains('room B12')); // "and where?" alone would find nothing
      expect(sent.user, endsWith('Question: and where?'));
    });

    test('the room depends on the provider, and the history is limited', () async {
      final big = _Provider(chars: 100000);
      final c = AssistantChat(ai: AiService(providers: [big]), index: () async => longDocument());
      await c.ask('When is the final exam?');
      expect(big.prompts.single.user, contains('Filler text about nothing in particular on page 2.')); // all of it fits

      for (var i = 0; i < 6; i++) {
        await c.ask('question $i');
      }
      expect(big.prompts.last.history.length, lessThanOrEqualTo(10));
      expect(big.prompts.last.history.first.fromUser, isTrue);
    });

    test('a failure is shown as the answer and is not sent again as history', () async {
      provider.failWith = StateError('network down');
      await chat.ask('First?');
      expect(chat.messages.last.failed, isTrue);
      expect(chat.messages.last.text, 'network down');
      provider.failWith = null;
      await chat.ask('Second?');
      expect(provider.prompts.last.history, isEmpty);
      expect(chat.messages.last.failed, isFalse);
    });

    test('stopping keeps what was written, and a new conversation starts clean', () async {
      provider.hold = Completer<void>();
      final done = chat.ask('Slow question?');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chat.busy, isTrue);
      expect(chat.messages.last.text, 'It');
      chat.stop();
      provider.hold!.complete();
      await done;
      expect(chat.busy, isFalse);
      expect(chat.messages.last.text, 'It');
      chat.clear();
      expect(chat.messages, isEmpty);
    });

    test('a document with no text says so to the model', () async {
      final empty = AssistantChat(ai: AiService(providers: [provider]), index: () async => DocumentIndex([]));
      await empty.ask('Anything?');
      expect(provider.prompts.last.user, contains('The document has no text'));
    });
  });

  group('what the assistant reads for a question', () {
    test('a question names its pages, "this page" is the one looked at, a summary is about everything', () {
      expect(focusOf('Summarize page 12', pageCount: 30).pages, [11]);
      expect(focusOf('What do pages 3-5 say?', pageCount: 30).pages, [2, 3, 4]);
      expect(focusOf('Fasse Seite 7 zusammen', pageCount: 30).pages, [6]);
      expect(focusOf('Explain this page', currentPage: 4, pageCount: 30).pages, [4]);
      expect(focusOf('What is on page 99?', pageCount: 30).scope, isNot(QuestionScope.pages));
      expect(focusOf('What are the key points?').scope, QuestionScope.whole);
      expect(focusOf('Was sind die wichtigsten Punkte?').scope, QuestionScope.whole);
      expect(focusOf('When is the exam?').scope, QuestionScope.passages);
    });

    test('a passage that says it in other words is found by its vector', () {
      final doc = longDocument();
      // the question shares no word with the passage about entropy; the "sentence model" says they are close
      final vectors = [for (final c in doc.chunks) c.text.contains('Entropy') ? Float32List.fromList([1, 0]) : Float32List.fromList([0, 1])];
      final asked = Float32List.fromList([1, 0.1]);
      expect(doc.select('Why does disorder grow?', 1500).text, isNot(contains('Entropy never decreases')));
      expect(doc.withVectors(vectors).select('Why does disorder grow?', 1500, queryVector: asked).text, contains('Entropy never decreases'));
    });

    test('the model is told where the person is, what is selected, the date and what part of the note it sees', () async {
      final provider = _Provider(chars: 2000);
      final c = AssistantChat(
        ai: AiService(providers: [provider]),
        index: () async => longDocument(),
        whereAmI: () => const NoteContext(title: 'Physics', page: 40, pageCount: 42, selected: 'Bring a calculator.'),
      );
      await c.ask('Explain this page');
      final user = provider.prompts.single.user;
      expect(user, contains('The note is called "Physics" and has 42 pages.'));
      expect(user, contains('The user is looking at page 41.'));
      expect(user, contains('Today is '));
      expect(user, contains('You are given page 41'));
      expect(user, contains('Selected by the user:\nBring a calculator.'));
      expect(user, contains('The final exam takes place on 20 June'));
      expect(c.messages.last.given, contains('The final exam takes place'));
    });

    test('the sentence model is asked only for passages it did not read before', () async {
      final provider = _Provider(chars: 2000);
      final read = <String>[];
      final c = AssistantChat(
        ai: AiService(providers: [provider]),
        index: () async => longDocument(),
        embed: (text) async {
          read.add(text);
          return Float32List.fromList([text.contains('Entropy') || text.contains('disorder') ? 1 : 0, 1]);
        },
        keptVectors: () async => {for (final c in longDocument().chunks.take(10)) c.text: Float32List.fromList([0, 1])},
      );
      await c.ask('Why does disorder grow in a closed box?');
      final first = read.length;
      expect(first, lessThanOrEqualTo(33)); // the question and at most 32 passages
      expect(read.skip(1).toSet().intersection(longDocument().chunks.take(10).map((c) => c.text).toSet()), isEmpty); // kept ones are not read again
      await c.ask('Why does disorder grow in a closed box?');
      expect(read.skip(first + 1).toSet().intersection(read.take(first).toSet()), isEmpty);
    });

    test('an answer that was cut off can be continued in the same message, and the last question asked again', () async {
      final provider = _CutProvider();
      final c = AssistantChat(ai: AiService(providers: [provider]), index: () async => longDocument());
      await c.ask('When is the final exam?');
      expect(c.messages.last.cutOff, isTrue);
      await c.continueAnswer();
      expect(c.messages.length, 2);
      expect(c.messages.last.text, 'The exam is on 20 June in room B12.');
      expect(c.messages.last.cutOff, isFalse);
      expect(provider.prompts.last.history.last.text, 'The exam is on 20');
      expect(provider.prompts.last.user, contains('cut off'));
      await c.retry();
      expect(c.messages.length, 2);
      expect(provider.prompts.length, 3);
    });

    test('the conversation is kept and taken up again; clearing it forgets it', () async {
      String? kept;
      AssistantChat open() => AssistantChat(
            ai: AiService(providers: [_Provider()]),
            index: () async => longDocument(),
            loadChat: () async => kept,
            saveChat: (json) async => kept = json,
          );
      final first = open();
      await first.ask('When is the final exam?');
      expect(kept, isNotNull);
      final again = open();
      await again.restoreChat();
      expect(again.messages.map((m) => m.text), ['When is the final exam?', 'It is about entropy (p. 1).']);
      expect(again.messages.last.pages, isNotEmpty);
      again.clear();
      expect(kept, isNull);
    });

    test('a note the question refers to is given whole, with its id, in both chats', () async {
      final provider = _Provider(chars: 3000);
      final c = AssistantChat(
        ai: AiService(providers: [provider]),
        index: () async => longDocument(),
        lookup: NoteLookup(find: (q) async => [const NoteRef('n1', 'Chemistry')], read: (id, limit) async => 'Acids donate protons.'),
      );
      await c.ask('Compare it with @Chemistry', refs: const [NoteRef('n1', 'Chemistry')]);
      final user = provider.prompts.single.user;
      expect(user, contains('[Chemistry (id n1)]\nAcids donate protons.'));
      expect(c.messages.first.refs.single.id, 'n1');
      await c.ask('And without a note');
      expect(provider.prompts.last.user, isNot(contains('Acids donate protons.')), reason: 'only for the question that names it');
    });

    test('the newest answer is given whole in the history, older ones shortened', () async {
      final provider = _Provider(chars: 48000, answer: 'word ' * 400);
      final c = AssistantChat(ai: AiService(providers: [provider]), index: () async => longDocument());
      await c.ask('First?');
      await c.ask('Second?');
      await c.ask('Third?');
      final history = provider.prompts.last.history;
      expect(history.last.text.length, greaterThan(1500));
      expect(history[1].text.length, greaterThan(1500)); // there was room for both
    });
  });

  testWidgets('the assistant beside a note: ask, read the answer, go to the page, add it to the note', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.title = 'Physics';
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: 'Entropy never decreases in an isolated system.')];
      await repo.saveNote(note);
      // handwriting that was read before
      await repo.text.saveInkText(id, [const InkText(key: 'k1', page: 0, text: 'Heat flows from hot to cold.', bounds: Rect.fromLTRB(100, 300, 400, 340))], {'k1'});
      // and a formula read above it
      await repo.text.saveInkReads(id, [(key: 'f1', ids: '', text: null, latex: r'\Delta S \geq 0', place: (page: 0, top: 200.0, left: 100.0))]);
    });
    final provider = _Provider(answer: 'Entropy never decreases (p. 1).');
    final ai = AiService(providers: [provider]);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, ai: ai)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('assistant-panel')), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button'))); // the toolbar scrolls sideways
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assistant-panel')), findsOneWidget);
    expect(find.text('Fake'), findsOneWidget); // who answers

    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'What does entropy do?');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    for (var i = 0; i < 40 && find.byKey(const ValueKey('assistant-answer-1')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('Entropy never decreases (p. 1).'), findsOneWidget);
    // what the model was given: the title and the text box
    final sent = provider.prompts.single;
    expect(sent.user, contains('[Title]\nPhysics'));
    expect(sent.user, contains('[Page 1]\nEntropy never decreases in an isolated system.'));
    expect(sent.user, contains('✎ \$\\Delta S \\geq 0\$\n✎ Heat flows from hot to cold.')); // the handwriting, the formula first as it is higher up
    expect(sent.user, contains('The note is called "Physics"'));
    expect(sent.user, contains('You are given all of its text.'));
    // the answer names page 1 and the page says it: a source to go to, with no doubt
    expect(find.byKey(const ValueKey('assistant-cite-1-0-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('assistant-claim-doubt-1-0')), findsNothing);
    expect(find.byKey(const ValueKey('assistant-uncited-1')), findsNothing);
    // what the model read can be looked at
    await tester.tap(find.byKey(const ValueKey('assistant-given-1')));
    await tester.pumpAndSettle();
    expect((tester.widget<SelectableText>(find.byKey(const ValueKey('assistant-given-text')))).data, contains('Heat flows from hot to cold.'));
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assistant-retry')), findsOneWidget);
    expect(find.byKey(const ValueKey('assistant-continue')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('assistant-add-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-target-textBox')));
    await tester.pumpAndSettle();
    expect(find.text('Added to page 1'), findsOneWidget);
    final boxes = tester.widgetList<EditableText>(find.byType(EditableText)).map((e) => e.controller.text);
    expect(boxes.where((t) => t == 'Entropy never decreases (p. 1).'), hasLength(1)); // the new text box (the answer is drawn, not editable)

    await tester.tap(find.byKey(const ValueKey('assistant-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assistant-panel')), findsNothing);
    // the conversation is still there when it is opened again
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    expect(find.text('What does entropy do?'), findsOneWidget);
    // and it was kept for the next time the note is opened (real time for the writes to the database)
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump();
    }
    final kept = await tester.runAsync(() => repo.settings.get('assistant_chat:$id'));
    expect(kept, contains('What does entropy do?'));
  });

  testWidgets('a source chip lights up the words of the passage in the note, and the assistant stays open', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: 'Entropy never decreases in an isolated system.')];
      await repo.saveNote(note);
      await repo.text.saveInkText(id, [const InkText(key: 'k1', page: 0, text: 'Heat flows from hot to cold.', bounds: Rect.fromLTRB(100, 300, 400, 340))], {'k1'});
    });
    final provider = _Provider(answer: 'Entropy never decreases in an isolated system [Page 1]. Heat flows from hot to cold [Page 1].');
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, ai: AiService(providers: [provider]))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'What does entropy do?');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    for (var i = 0; i < 40 && find.byKey(const ValueKey('assistant-answer-1')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    // page 1 holds the text box and the handwriting: the first statement rests on the box, the second on handwriting read by the app
    expect(provider.prompts.single.user, contains('✎ Heat flows from hot to cold.'));
    expect(provider.prompts.single.system, contains('✎'));
    expect(find.byKey(const ValueKey('assistant-cite-1-0-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('assistant-cite-ink-1-0-0')), findsNothing); // (one chip for the page: the first statement decides)
    await tester.tap(find.byKey(const ValueKey('assistant-cite-1-0-0')));
    await tester.pumpAndSettle();
    expect((tester.widget<TextField>(find.byKey(const ValueKey('find-field')))).controller!.text, contains(r'Entropy\s+never'));
    expect(find.byKey(const ValueKey('assistant-panel')), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  });

  testWidgets('typing @ offers notes; the picked one goes with the question', (tester) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = _Provider();
    final chat = AssistantChat(
      ai: AiService(providers: [provider]),
      index: () async => longDocument(),
      lookup: NoteLookup(
        find: (q) async => [for (final t in ['Chemistry', 'Physics']) if (t.toLowerCase().contains(q.toLowerCase())) NoteRef(t.toLowerCase(), t)],
        read: (id, limit) async => 'Text of $id.',
      ),
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AssistantPanel(ai: AiService(providers: [provider]), chat: chat))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'Compare with @ch');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assistant-mention-chemistry')), findsOneWidget);
    expect(find.byKey(const ValueKey('assistant-mention-physics')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('assistant-mention-chemistry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assistant-mentions')), findsNothing);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('assistant-input'))).controller!.text, 'Compare with @Chemistry ');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    for (var i = 0; i < 20 && provider.prompts.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(provider.prompts.single.user, contains('[Chemistry (id chemistry)]\nText of chemistry.'));
  });

  testWidgets('no assistant button without an AI service', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assistant-button')), findsNothing);
  });

  // needs PDFium, which only a built app bundles (see pdf_page_loader_test.dart)
  final pdfium = File('build/linux/x64/debug/bundle/lib/libpdfium.so');

  testWidgets('the text of every page of an imported PDF reaches the assistant', skip: !pdfium.existsSync(), (tester) async {
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('as_');
      final doc = pw.Document();
      doc.addPage(pw.Page(build: (_) => pw.Text('Introduction to heat', style: const pw.TextStyle(fontSize: 24))));
      doc.addPage(pw.Page(build: (_) => pw.Text('The final exam is on 20 June', style: const pw.TextStyle(fontSize: 24))));
      final file = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.pdfName = 'a.pdf';
      note.pdfPath = file.path;
      note.pdfPageCount = 2;
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    final provider = _Provider();
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, ai: AiService(providers: [provider]))));
    for (var i = 0; i < 60 && find.byKey(const ValueKey('assistant-button')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300)); // (the panel slides in, from when this frame is done)
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byKey(const ValueKey('assistant-input')), 'When is the exam?');
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    for (var i = 0; i < 80 && provider.prompts.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(provider.prompts, hasLength(1));
    expect(provider.prompts.single.user, contains('[Page 1]\nIntroduction to heat'));
    expect(provider.prompts.single.user, contains('[Page 2]\nThe final exam is on 20 June'));
    await tester.pump(const Duration(milliseconds: 600));
  });
}
