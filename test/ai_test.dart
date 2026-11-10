import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/llm/causal_lm.dart';
import 'package:notes/llm/chat_models.dart';
import 'package:notes/llm/onnx_chat_provider.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/ai_summary_dialog.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A provider that answers with a fixed text, growing it word by word.
class _FakeProvider extends ChangeNotifier implements TextModelProvider {
  _FakeProvider(this.id, {this.state = ProviderState.ready, this.answer = 'A short summary.', this.reason});
  @override
  final String id;
  @override
  ProviderState state;
  @override
  String? reason;
  final String answer;
  final prompts = <AiPrompt>[];
  var prepared = 0;
  Completer<void>? hold;

  @override
  String get label => 'Fake $id';
  @override
  String get description => 'A stand-in.';
  @override
  Future<void> prepare() async {
    prepared++;
    state = ProviderState.ready;
    notifyListeners();
  }

  @override
  Future<String> complete(AiPrompt prompt, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async {
    prompts.add(prompt);
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

class _FakeLm implements CausalLm {
  List<int> answer;
  final prompts = <List<int>>[];
  int? prefix;
  bool closed = false;
  double? penalty;
  _FakeLm(this.answer);
  @override
  Future<List<int>> generate(
    List<int> prompt, {
    required int maxNewTokens,
    required Set<int> stop,
    int sharedPrefix = 0,
    void Function(List<int> generated)? onProgress,
    bool Function()? shouldStop,
    double repetitionPenalty = 1,
  }) async {
    prompts.add(prompt);
    prefix = sharedPrefix;
    penalty = repetitionPenalty;
    final out = <int>[];
    for (final t in answer) {
      if (shouldStop?.call() ?? false) break;
      out.add(t);
      onProgress?.call(out);
    }
    return out;
  }

  @override
  Future<void> close() async => closed = true;
}

String tinyTokenizer() => jsonEncode({
      'model': {
        'type': 'BPE',
        'vocab': {'h': 0, 'e': 1, 'l': 2, 'o': 3, 'Ġ': 4, 'he': 5, 'll': 6, 'hell': 7, 'hello': 8},
        'merges': [
          ['h', 'e'],
          ['l', 'l'],
          ['he', 'll'],
          ['hell', 'o'],
        ],
      },
      'added_tokens': [
        {'id': 100, 'content': '<|endoftext|>', 'special': true},
        {'id': 101, 'content': '<|im_start|>', 'special': true},
        {'id': 102, 'content': '<|im_end|>', 'special': true},
        {'id': 103, 'content': '<think>', 'special': false},
      ],
    });

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the prompt', () {
    test('the standard one asks for a paragraph and puts the text in', () {
      final p = SummaryConfig.defaults.promptFor('  Some long text here.  ');
      expect(p.system, SummaryConfig.defaultSystem);
      expect(p.user, 'Summarize the following text in a short paragraph.\n\nSome long text here.');
    });

    test('the length is a word in the request', () {
      final c = SummaryConfig.defaults.copyWith(length: SummaryLength.bullets);
      expect(c.promptFor('x y z').user, contains('a short bullet list of the main points'));
      expect(SummaryConfig.defaults.copyWith(length: SummaryLength.brief).promptFor('x y z').user, contains('one or two sentences'));
    });

    test('a request of the person\'s own, with the text where they put it', () {
      const c = SummaryConfig(system: 'Be terse.', instruction: 'Text: «{text}» -> {length}');
      final p = c.promptFor('abc def ghi');
      expect(p.system, 'Be terse.');
      expect(p.user, 'Text: «abc def ghi» -> a short paragraph');
    });

    test('a request without {text} still gets the text, at the end', () {
      const c = SummaryConfig(instruction: 'Make it short.');
      expect(c.promptFor('abc def ghi').user, 'Make it short.\n\nabc def ghi');
    });

    test('a very long text is cut', () {
      final p = SummaryConfig.defaults.promptFor('word ' * 5000);
      expect(p.user.length, lessThan(SummaryConfig.maxTextLength + 200));
      expect(p.user, endsWith('...'));
    });

    test('it is saved as text, and unreadable or empty parts fall back', () {
      const c = SummaryConfig(system: 'S', instruction: 'I {text}', length: SummaryLength.bullets);
      final back = SummaryConfig.decode(c.encode());
      expect((back.system, back.instruction, back.length), ('S', 'I {text}', SummaryLength.bullets));
      expect(SummaryConfig.decode(null).isDefault, isTrue);
      expect(SummaryConfig.decode('not json').isDefault, isTrue);
      expect(SummaryConfig.decode('{"system":"  ","length":"huge"}').isDefault, isTrue);
    });

    test('more than two words are worth summarizing', () {
      expect(worthSummarizing('one two three'), isTrue);
      expect(worthSummarizing('one two'), isFalse);
      expect(worthSummarizing('  one   two  '), isFalse);
      expect(worthSummarizing(null), isFalse);
      expect(worthSummarizing('a\nb\nc'), isTrue);
    });
  });

  group('the service', () {
    late SettingsRepository settings;
    setUp(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key LIKE 'ai_%'");
      settings = SettingsRepository(db);
    });

    test('the first provider answers until another is chosen, and the choice is kept', () async {
      final a = _FakeProvider('a'), b = _FakeProvider('b', answer: 'From b.');
      final ai = AiService(settings: settings, providers: [a, b]);
      await ai.load();
      expect(ai.provider!.id, 'a');
      expect(await ai.summarize('one two three'), 'A short summary.');
      await ai.chooseProvider('b');
      expect(await ai.summarize('one two three'), 'From b.'); // a cloud provider is just another entry
      expect(a.prompts.length, 1);

      final again = AiService(settings: settings, providers: [_FakeProvider('a'), _FakeProvider('b')]);
      await again.load();
      expect(again.provider!.id, 'b');
      expect(AiService(providers: [_FakeProvider('a')]).provider!.id, 'a'); // an unknown choice falls back
    });

    test('"tell me more" and "ask" have their own prompts, which can be changed and are kept', () async {
      final p = _FakeProvider('a', answer: 'More.');
      final ai = AiService(settings: settings, providers: [p]);
      await ai.load();
      expect(ai.template(AiTask.explain).isDefault && ai.template(AiTask.ask).isDefault, isTrue);

      expect(await ai.explain('entropy'), 'More.');
      expect(p.prompts.last.system, AiTask.explain.defaultSystem);
      expect(p.prompts.last.user, contains('entropy'));
      expect(p.prompts.last.user, startsWith('Tell me more'));

      await ai.ask('The cat sat.', 'Who sat?');
      expect(p.prompts.last.user, 'Passage:\nThe cat sat.\n\nQuestion: Who sat?');

      // what a template leaves out is added, never dropped
      await ai.setTemplate(const PromptTemplate(AiTask.ask, system: 'Terse.', instruction: 'Answer.'));
      await ai.ask('The cat sat.', 'Who sat?');
      expect(p.prompts.last.system, 'Terse.');
      expect(p.prompts.last.user, 'Answer.\n\nWho sat?\n\nThe cat sat.');

      final again = AiService(settings: settings, providers: [p]);
      await again.load();
      expect(again.template(AiTask.ask).system, 'Terse.');
      expect(again.template(AiTask.explain).isDefault, isTrue);
      expect(PromptTemplate.decode(AiTask.ask, 'garbage').isDefault, isTrue);
      expect(hasWords('  '), isFalse);
      expect(hasWords('entropy'), isTrue);
    });

    test('the prompt of the settings is what the provider is asked', () async {
      final p = _FakeProvider('a');
      final ai = AiService(settings: settings, providers: [p]);
      await ai.load();
      await ai.setSummaryConfig(const SummaryConfig(system: 'Terse.', instruction: 'Short: {text}'));
      await ai.summarize('some text here');
      expect(p.prompts.single.system, 'Terse.');
      expect(p.prompts.single.user, 'Short: some text here');

      final again = AiService(settings: settings, providers: [p]);
      await again.load();
      expect(again.summaryConfig.system, 'Terse.');
    });

    test('it can summarize only when a provider can work here', () {
      expect(AiService(providers: [_FakeProvider('a')]).canSummarize, isTrue);
      expect(AiService(providers: [_FakeProvider('a', state: ProviderState.needsDownload)]).canSummarize, isTrue);
      expect(AiService(providers: [_FakeProvider('a', state: ProviderState.unavailable)]).canSummarize, isFalse);
      expect(AiService(providers: []).canSummarize, isFalse);
    });

    test('a change in a provider is a change in the service', () async {
      final p = _FakeProvider('a', state: ProviderState.needsDownload);
      final ai = AiService(providers: [p]);
      var heard = 0;
      ai.addListener(() => heard++);
      await p.prepare();
      expect(heard, 1);
    });
  });

  group('the model on the device', () {
    late Directory dir;
    late SettingsRepository settings;
    final opened = <ChatModelSpec>[];
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('chat_');
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key LIKE 'ai_%'");
      settings = SettingsRepository(db);
      opened.clear();
    });
    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    OnnxChatProvider make({int? ram = 8000, _FakeLm? lm, Duration keep = const Duration(seconds: 30), bool withSettings = true}) =>
        OnnxChatProvider(
          settings: withSettings ? settings : null,
          ram: () async => ram,
          open: (_, spec) async {
            opened.add(spec);
            return lm ?? _FakeLm([]);
          },
          modelsRoot: () async => dir,
          keepLoaded: keep,
          download: (url, path, progress) async {
            progress(0.5);
            await File(path).writeAsString(url.endsWith('tokenizer.json') ? tinyTokenizer() : 'model');
            progress(1);
          },
        );

    test('the big models: many files, a lot of memory, never the default', () async {
      final mid = ChatModelSpec.qwen3Mid.files;
      expect(mid.keys, ['model_q4.onnx', 'model_q4.onnx_data', 'model_q4.onnx_data_1', 'tokenizer.json']);
      expect(mid['model_q4.onnx_data_1']!.url,
          'https://huggingface.co/onnx-community/Qwen3-4B-Instruct-2507-ONNX/resolve/main/onnx/model_q4.onnx_data_1');
      expect(mid['tokenizer.json']!.url, endsWith('Qwen3-4B-Instruct-2507-ONNX/resolve/main/tokenizer.json'));
      final big = ChatModelSpec.qwen3Big.files;
      expect(big.keys, ['model.onnx', 'model.onnx.data', 'tokenizer.json']);
      expect(big['model.onnx.data']!.url, contains('Qwen3-8B-ONNX/resolve/main/onnxruntime/cpu_and_mobile/cpu-int4-kld-block-128/'));
      expect(big['tokenizer.json']!.url, contains('cpu-int4-kld-block-128/tokenizer.json'));
      expect(ChatModelSpec.qwen3Big.downloadMb, closeTo(6088, 2));
      expect(ChatModelSpec.qwen3Mid.downloadMb, closeTo(3973, 2));

      final laptop = make(ram: 46000);
      await laptop.load();
      expect(laptop.selectedModelId, 'qwen3-1.7b'); // not a 10 GB download unasked
      final byId = {for (final o in laptop.modelOptions) o.id: o};
      expect(byId['qwen3-14b']!.supported, isTrue);
      final phone = make(ram: 7600); // an "8 GB" phone
      await phone.load();
      final phoneOptions = {for (final o in phone.modelOptions) o.id: o};
      expect(phoneOptions['qwen3-4b-2507']!.supported, isTrue);
      expect(phoneOptions['qwen3-8b']!.reason, allOf(contains('12 GB'), contains('7.6 GB')));
    });

    test('without a choice it starts with the biggest model the device can run', () async {
      final big = make(ram: 8000);
      await big.load();
      expect(big.selectedModelId, 'qwen3-1.7b');
      final small = make(ram: 3700); // a "4 GB" phone
      await small.load();
      expect(small.selectedModelId, 'qwen3-0.6b');
      expect(small.state, ProviderState.needsDownload); // it can be used
      final unknown = make(ram: null);
      await unknown.load();
      expect(unknown.supported, isTrue);
    });

    test('a device with very little memory cannot use any, and is told why', () async {
      final p = make(ram: 1800);
      await p.load();
      expect(p.state, ProviderState.unavailable);
      expect(p.reason, allOf(contains('3 GB'), contains('1.8 GB')));
      await expectLater(p.complete(const AiPrompt(system: 's', user: 'u')), throwsStateError);
    });

    test('every size is listed, and those the device cannot run are marked', () async {
      final p = make(ram: 3700);
      await p.load();
      final byId = {for (final o in p.modelOptions) o.id: o};
      expect(byId.keys, containsAll(['qwen2.5-0.5b', 'qwen3-0.6b', 'qwen2.5-1.5b', 'qwen3-1.7b']));
      expect(byId['qwen3-0.6b']!.supported, isTrue);
      expect(byId['qwen2.5-0.5b']!.supported, isTrue);
      expect(byId['qwen3-1.7b']!.supported, isFalse);
      expect(byId['qwen3-1.7b']!.reason, allOf(contains('4 GB'), contains('3.7 GB')));
      expect(byId['qwen3-1.7b']!.detail, contains('GB download'));
    });

    test('choosing a model switches the files, keeps the other downloads and is remembered', () async {
      final p = make(ram: 8000);
      await p.load();
      await p.prepare(); // the big one
      expect(p.state, ProviderState.ready);
      expect({for (final o in p.modelOptions) o.id: o.installed}['qwen3-1.7b'], isTrue);

      await p.selectModel('qwen2.5-0.5b');
      expect(p.selectedModelId, 'qwen2.5-0.5b');
      expect(p.state, ProviderState.needsDownload); // its own files
      expect(p.sizeMb, ChatModelSpec.qwen25Small.downloadMb);
      await p.prepare();
      expect(p.state, ProviderState.ready);
      expect(File('${dir.path}/llm_qwen25_05b/model_q4.onnx').existsSync(), isTrue);
      expect(File('${dir.path}/llm_large/model_q4.onnx').existsSync(), isTrue); // still there
      expect({for (final o in p.modelOptions) o.id: o.installed}, containsPair('qwen3-1.7b', true));

      // a new start finds the choice
      final again = make(ram: 8000);
      await again.load();
      expect(again.selectedModelId, 'qwen2.5-0.5b');
      expect(again.state, ProviderState.ready);

      // removing one leaves the other
      await again.remove();
      expect(Directory('${dir.path}/llm_qwen25_05b').existsSync(), isFalse);
      expect(File('${dir.path}/llm_large/model_q4.onnx').existsSync(), isTrue);
      expect({for (final o in again.modelOptions) o.id: o.installed}['qwen3-1.7b'], isTrue);
    });

    test('a model the device cannot run makes the provider unavailable if it is chosen anyway (the list does not allow it)', () async {
      final p = make(ram: 3700);
      await p.load();
      await p.selectModel('qwen3-1.7b');
      expect(p.state, ProviderState.unavailable);
      await p.selectModel('qwen3-0.6b');
      expect(p.state, ProviderState.needsDownload);
    });

    test('download, then ready; the size is the chosen model\'s', () async {
      final p = make();
      await p.load();
      expect(p.state, ProviderState.needsDownload);
      await p.prepare();
      expect(p.state, ProviderState.ready);
      expect(p.sizeMb, greaterThan(1700));
    });

    test('it asks the model in the chat format and streams what it says, instructions as the shared start', () async {
      final lm = _FakeLm([8, 4, 8]);
      final p = make(lm: lm);
      await p.load();
      await p.prepare();
      final partials = <String>[];
      final answer = await p.complete(const AiPrompt(system: 'Be brief.', user: 'hello'), onPartial: partials.add);
      expect(answer, 'hello hello');
      expect(partials, ['hello hello']); // a few tokens at a time
      expect(lm.prefix, greaterThan(0));
      expect(lm.prefix, lessThan(lm.prompts.single.length));
      expect(lm.penalty, greaterThan(1));
      expect(opened.single.id, 'qwen3-1.7b');
    });

    test('Qwen3 gets the empty thinking block, Qwen2.5 does not', () {
      const prompt = AiPrompt(system: 'Be brief.', user: 'hello');
      final q3 = OnnxChatProvider.chat(prompt);
      expect(q3.fixed, '<|im_start|>system\nBe brief.<|im_end|>\n');
      expect(q3.question, '<|im_start|>user\nhello<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n');
      expect(OnnxChatProvider.chat(prompt, thinking: false).question, '<|im_start|>user\nhello<|im_end|>\n<|im_start|>assistant\n');
      expect(ChatModelSpec.qwen3Small.thinking && ChatModelSpec.qwen3Large.thinking, isTrue);
      expect(ChatModelSpec.qwen25Small.thinking || ChatModelSpec.qwen25Large.thinking, isFalse);
    });

    test('the model is opened with the shape of the chosen one', () async {
      final lm = _FakeLm([8]);
      final p = make(lm: lm);
      await p.load();
      await p.selectModel('qwen2.5-0.5b');
      await p.prepare();
      await p.complete(const AiPrompt(system: 's', user: 'u'));
      expect((opened.single.layers, opened.single.kvHeads, opened.single.headDim), (24, 2, 64));
      // another size afterwards: the first one is let go and the new one opened
      await p.selectModel('qwen3-0.6b');
      await p.prepare();
      await p.complete(const AiPrompt(system: 's', user: 'u'));
      expect(opened.map((s) => s.id), ['qwen2.5-0.5b', 'qwen3-0.6b']);
      expect(lm.closed, isTrue);
    });

    test('stopping returns what there is, and is not an error', () async {
      final lm = _FakeLm([8, 8, 8, 8, 8, 8]);
      final p = make(lm: lm);
      await p.load();
      await p.prepare();
      final cancel = AiCancel();
      final answer = await p.complete(const AiPrompt(system: 's', user: 'u'), cancel: cancel, onPartial: (_) => cancel.cancel());
      expect(answer.isNotEmpty, isTrue);
      expect(lm.prompts.length, 1);
      expect(await p.complete(const AiPrompt(system: 's', user: 'u'), cancel: cancel), '');
      expect(lm.prompts.length, 1);
    });

    test('the model is freed a while after the answer', () async {
      final lm = _FakeLm([8]);
      final p = make(lm: lm, keep: const Duration(milliseconds: 50));
      await p.load();
      await p.prepare();
      await p.complete(const AiPrompt(system: 's', user: 'u'));
      expect(lm.closed, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(lm.closed, isTrue);
    });

    test('without the download it says so', () async {
      final p = make();
      await p.load();
      await expectLater(p.complete(const AiPrompt(system: 's', user: 'u')), throwsStateError);
    });
  });

  group('the dialog for questions and "tell me more"', () {
    Future<void> open(WidgetTester tester, AiService ai, AiTask task, {void Function(String?)? done}) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final r = await showDialog<String>(
                  context: context, builder: (_) => AiSummaryDialog(ai: ai, text: 'The cat sat on the mat.', task: task));
              done?.call(r);
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
    }

    testWidgets('the question is asked first, then the answer is written', (tester) async {
      final p = _FakeProvider('a', answer: 'The cat.');
      String? added;
      await open(tester, AiService(providers: [p]), AiTask.ask, done: (r) => added = r);
      await tester.pumpAndSettle();
      expect(find.text('Ask a question'), findsOneWidget); // the title
      expect(p.prompts, isEmpty);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('ask-send'))).onPressed, isNull); // nothing asked yet
      await tester.enterText(find.byKey(const ValueKey('ask-question')), 'Who sat?');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ask-send')));
      await tester.pumpAndSettle();
      expect(p.prompts.single.user, 'Passage:\nThe cat sat on the mat.\n\nQuestion: Who sat?');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('summary-text'))).controller!.text, 'The cat.');
      await tester.tap(find.byKey(const ValueKey('summary-add')));
      await tester.pumpAndSettle();
      expect(added, 'The cat.');
    });

    testWidgets('tell me more starts at once', (tester) async {
      final p = _FakeProvider('a', answer: 'It is a sentence.');
      await open(tester, AiService(providers: [p]), AiTask.explain);
      await tester.pumpAndSettle();
      expect(find.text('Tell me more'), findsOneWidget);
      expect(p.prompts.single.user, contains('The cat sat on the mat.'));
      expect(p.prompts.single.system, AiTask.explain.defaultSystem);
      expect(find.byKey(const ValueKey('summary-text')), findsOneWidget);
    });

    testWidgets('a provider that needs a download asks before the question', (tester) async {
      final p = _FakeProvider('a', state: ProviderState.needsDownload);
      await open(tester, AiService(providers: [p]), AiTask.ask);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('summary-download')));
      await tester.pumpAndSettle();
      expect(p.prepared, 1);
      expect(find.byKey(const ValueKey('ask-question')), findsOneWidget);
    });
  });

  group('the dialog', () {
    Future<String?> open(WidgetTester tester, AiService ai, {String text = 'one two three four'}) async {
      String? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDialog<String>(context: context, builder: (_) => AiSummaryDialog(ai: ai, text: text)),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      return result;
    }

    testWidgets('a ready provider writes the summary, which can be edited and added', (tester) async {
      final p = _FakeProvider('a', answer: 'Four words in total.');
      final ai = AiService(providers: [p]);
      await open(tester, ai);
      await tester.pumpAndSettle();
      expect(p.prompts.single.user, contains('one two three four'));
      expect(tester.widget<TextField>(find.byKey(const ValueKey('summary-text'))).controller!.text, 'Four words in total.');
      await tester.enterText(find.byKey(const ValueKey('summary-text')), 'Four words.');
      await tester.tap(find.byKey(const ValueKey('summary-add')));
      await tester.pumpAndSettle();
      expect(find.byType(AiSummaryDialog), findsNothing);
    });

    testWidgets('it shows the summary as it grows, and Stop keeps what there is', (tester) async {
      final p = _FakeProvider('a', answer: 'one two three four five')..hold = Completer<void>();
      final ai = AiService(providers: [p]);
      await open(tester, ai);
      await tester.pump();
      expect(find.text('one'), findsOneWidget); // the first words are on screen already
      expect(find.byKey(const ValueKey('summary-stop')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('summary-stop')));
      p.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('summary-text')), findsOneWidget); // done, with the start
      expect(tester.widget<TextField>(find.byKey(const ValueKey('summary-text'))).controller!.text, startsWith('one'));
    });

    testWidgets('a provider that needs a download asks first, then goes on', (tester) async {
      final p = _FakeProvider('a', state: ProviderState.needsDownload);
      final ai = AiService(providers: [p]);
      await open(tester, ai);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('summary-download')), findsOneWidget);
      expect(p.prompts, isEmpty);
      await tester.tap(find.byKey(const ValueKey('summary-download')));
      await tester.pumpAndSettle();
      expect(p.prepared, 1);
      expect(find.byKey(const ValueKey('summary-text')), findsOneWidget);
    });

    testWidgets('a provider that cannot work here says why', (tester) async {
      final p = _FakeProvider('a', state: ProviderState.unavailable, reason: 'Needs 4 GB.');
      await open(tester, AiService(providers: [p]));
      await tester.pumpAndSettle();
      expect(find.text('Needs 4 GB.'), findsOneWidget);
      expect(p.prompts, isEmpty);
    });

    testWidgets('a failure is shown', (tester) async {
      final p = _Failing();
      await open(tester, AiService(providers: [p]));
      await tester.pumpAndSettle();
      expect(find.textContaining('network down'), findsOneWidget);
    });
  });

  testWidgets('settings: the prompt can be changed, saved and reset, the provider shows its state', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = await tester.runAsync(() => AppDatabase.open(path: inMemoryDatabasePath));
    await tester.runAsync(() => db!.delete('settings', where: "key LIKE 'ai_%'"));
    final settings = SettingsRepository(db!);
    final p = _FakeProvider('a', state: ProviderState.needsDownload);
    final small = _FakeProvider('small', state: ProviderState.unavailable, reason: 'This needs a device with at least 4 GB of memory.');
    final ai = AiService(settings: settings, providers: [p, small]);

    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), ai: ai)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('ai-system')), 400, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const ValueKey('ai-unavailable')), findsOneWidget);
    expect(find.textContaining('4 GB'), findsWidgets);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('ai-save'))).onPressed, isNull); // nothing changed

    await tester.enterText(find.byKey(const ValueKey('ai-system')), 'Be terse.');
    await tester.enterText(find.byKey(const ValueKey('ai-instruction')), 'Short: {text}');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-save')));
    await tester.pumpAndSettle();
    expect(ai.summaryConfig.system, 'Be terse.');
    expect(ai.summaryConfig.instruction, 'Short: {text}');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(await tester.runAsync(() => settings.get('ai_summary_config')), contains('Be terse.'));

    await tester.tap(find.byKey(const ValueKey('ai-reset')));
    await tester.pumpAndSettle();
    expect(ai.summaryConfig.isDefault, isTrue);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-system'))).controller!.text, SummaryConfig.defaultSystem);

    await tester.tap(find.text('Use this').first);
    await tester.pumpAndSettle();
    expect(ai.provider!.id, 'small');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200))); // (the saves finish)
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('settings: the prompts of "tell me more" and "ask" can be changed and reset', (tester) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = await tester.runAsync(() => AppDatabase.open(path: inMemoryDatabasePath));
    await tester.runAsync(() => db!.delete('settings', where: "key LIKE 'ai_%'"));
    final settings = SettingsRepository(db!);
    final ai = AiService(settings: settings, providers: [_FakeProvider('a')]);
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), ai: ai)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('ai-ask-system')), 400, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('ai-ask-save'))).onPressed, isNull);

    await tester.enterText(find.byKey(const ValueKey('ai-ask-instruction')), 'Q: {question}\n{text}');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-ask-save')));
    await tester.pumpAndSettle();
    expect(ai.template(AiTask.ask).instruction, 'Q: {question}\n{text}');
    expect(ai.template(AiTask.explain).isDefault, isTrue); // the others are untouched
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(await tester.runAsync(() => settings.get('ai_ask_config')), contains('Q: {question}'));

    await tester.tap(find.byKey(const ValueKey('ai-ask-reset')));
    await tester.pumpAndSettle();
    expect(ai.template(AiTask.ask).isDefault, isTrue);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-ask-instruction'))).controller!.text, AiTask.ask.defaultInstruction);

    await tester.scrollUntilVisible(find.byKey(const ValueKey('ai-explain-system')), -400, scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.byKey(const ValueKey('ai-explain-system')), 'Explain like I am five.');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-explain-save')));
    await tester.pumpAndSettle();
    expect(ai.template(AiTask.explain).system, 'Explain like I am five.');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  });

  testWidgets('settings: the model picker lists the sizes, shows what the device cannot run and switches', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = await tester.runAsync(() => AppDatabase.open(path: inMemoryDatabasePath));
    await tester.runAsync(() => db!.delete('settings', where: "key LIKE 'ai_%'"));
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('picker_'));
    addTearDown(() => dir!.delete(recursive: true));
    final provider = OnnxChatProvider(
      settings: SettingsRepository(db!),
      ram: () async => 3700,
      modelsRoot: () async => dir!,
      download: (url, path, progress) async => File(path).writeAsString('x'),
    );
    await tester.runAsync(provider.load);
    final ai = AiService(providers: [provider]);

    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), ai: ai)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('ai-model-qwen3-1.7b')), 400, scrollable: find.byType(Scrollable).first);

    for (final id in ['qwen2.5-0.5b', 'qwen3-0.6b', 'qwen2.5-1.5b', 'qwen3-1.7b']) {
      expect(find.byKey(ValueKey('ai-model-$id')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('ai-model-reason-qwen3-1.7b')), findsOneWidget); // too big for 3.7 GB
    expect(find.byKey(const ValueKey('ai-model-reason-qwen2.5-1.5b')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-model-reason-qwen3-0.6b')), findsNothing);
    expect(provider.selectedModelId, 'qwen3-0.6b'); // the biggest that fits

    // a model the device cannot run does not react
    await tester.tap(find.byKey(const ValueKey('ai-model-qwen3-1.7b')));
    await tester.pumpAndSettle();
    expect(provider.selectedModelId, 'qwen3-0.6b');

    await tester.tap(find.byKey(const ValueKey('ai-model-qwen2.5-0.5b')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(provider.selectedModelId, 'qwen2.5-0.5b');
    expect(find.textContaining('0.8 GB'), findsWidgets); // the download of the chosen one

    await tester.tap(find.byKey(const ValueKey('ai-download')));
    for (var i = 0; i < 40 && find.textContaining('(downloaded)').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(provider.state, ProviderState.ready);
    await tester.pumpAndSettle();
    expect(find.textContaining('(downloaded)'), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('highlighted text of more than two words offers a summary that is added under it', (tester) async {
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
      note.textBoxes[0] = [
        TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: 'The cat sat on the mat.\nSecond paragraph.'),
      ];
      await repo.saveNote(note);
    });
    final provider = _FakeProvider('a', answer: 'A cat on a mat.');
    final ai = AiService(providers: [provider]);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, ai: ai)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(origin + const Offset(150, 130)); // into the box
    await tester.pumpAndSettle();
    final field = tester.state<EditableTextState>(find.byType(EditableText).first);

    // two words: no summary
    field.widget.controller.selection = const TextSelection(baseOffset: 0, extentOffset: 7);
    await tester.pump();
    field.showToolbar();
    await tester.pumpAndSettle();
    expect(find.text('Summarize'), findsNothing);
    expect(find.text('Tell me more'), findsOneWidget); // these work on any selection
    expect(find.text('Ask a question'), findsOneWidget);
    field.hideToolbar();
    await tester.pumpAndSettle();

    // six words: summary, added under the paragraph
    field.widget.controller.selection = const TextSelection(baseOffset: 0, extentOffset: 23);
    await tester.pump();
    field.showToolbar();
    await tester.pumpAndSettle();
    expect(find.text('Summarize'), findsOneWidget);
    await tester.tap(find.text('Summarize'));
    await tester.pumpAndSettle();
    expect(provider.prompts.single.user, contains('The cat sat on the mat.'));
    await tester.tap(find.byKey(const ValueKey('summary-add')));
    await tester.pumpAndSettle();
    expect(field.widget.controller.text, 'The cat sat on the mat.\n\nA cat on a mat.\nSecond paragraph.');
  });

  testWidgets('no summary is offered when the provider cannot work on this device', (tester) async {
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
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: 'one two three four five')];
      await repo.saveNote(note);
    });
    final ai = AiService(providers: [_FakeProvider('a', state: ProviderState.unavailable)]);
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, ai: ai)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(origin + const Offset(150, 130));
    await tester.pumpAndSettle();
    final field = tester.state<EditableTextState>(find.byType(EditableText).first);
    field.widget.controller.selection = const TextSelection(baseOffset: 0, extentOffset: 23);
    await tester.pump();
    field.showToolbar();
    await tester.pumpAndSettle();
    expect(find.text('Summarize'), findsNothing);
    expect(find.text('Tell me more'), findsNothing);
    expect(find.text('Ask a question'), findsNothing);
  });
}

class QwenTok {}

class _Failing extends _FakeProvider {
  _Failing() : super('f');
  @override
  Future<String> complete(AiPrompt prompt, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async =>
      throw StateError('network down');
}
