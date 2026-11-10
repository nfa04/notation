import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/assistant_chat.dart';
import 'package:notes/ai/document_index.dart';
import 'package:notes/ai/openai_provider.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/llm/onnx_chat_provider.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
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
      expect(big.prompts.last.history.length, lessThanOrEqualTo(6));
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
    expect(find.byKey(const ValueKey('assistant-page-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('assistant-add-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-target-textBox')));
    await tester.pumpAndSettle();
    expect(find.text('Added to page 1'), findsOneWidget);
    final boxes = tester.widgetList<EditableText>(find.byType(EditableText)).map((e) => e.controller.text);
    // (the answer in the panel is selectable text, which is an editable text too)
    expect(boxes.where((t) => t == 'Entropy never decreases (p. 1).'), hasLength(2));

    await tester.tap(find.byKey(const ValueKey('assistant-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assistant-panel')), findsNothing);
    // the conversation is still there when it is opened again
    await tester.tap(find.byKey(const ValueKey('assistant-button')));
    await tester.pumpAndSettle();
    expect(find.text('What does entropy do?'), findsOneWidget);
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
