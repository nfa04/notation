import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/creative_ideas.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/ideas_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Provider extends ChangeNotifier implements TextModelProvider {
  _Provider({this.answer = '', ProviderState state = ProviderState.ready, this.reason}) : _state = state;
  String answer;
  ProviderState _state;
  @override
  final String? reason;
  final prompts = <AiPrompt>[];

  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  String get description => 'a fake model';
  @override
  ProviderState get state => _state;
  @override
  Future<void> prepare() async {
    _state = ProviderState.ready;
    notifyListeners();
  }

  @override
  Future<String> complete(AiPrompt prompt, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async {
    prompts.add(prompt);
    onPartial?.call(answer);
    return answer;
  }
}

const harbour = '#1B2A41 deep water\n#324A5F slate\n#0C7C59 kelp\n#A9D6E5 morning sky\n#F4E285 first light\n#FFFFFF foam';

void main() {
  setUpAll(AppDatabase.initFfi);

  group('reading the answer', () {
    test('a palette is the colours in it, in order, each once, and nothing else', () {
      expect(parsePalette(harbour).map((c) => c.toARGB32() & 0xFFFFFF).toList(), [0x1B2A41, 0x324A5F, 0x0C7C59, 0xA9D6E5, 0xF4E285, 0xFFFFFF]);
      expect(parsePalette('Sure! Here:\n1. #fa0 orange\n2. rgb(10, 20, 30) navy\n3. #FA0 orange again\n4. rgb(300, 0, 0) too much').map((c) => c.toARGB32()), [0xFFFFAA00, 0xFF0A141E]);
      expect(parsePalette('no colours here, just #nothex and #12345'), isEmpty);
      expect(parsePalette(List.generate(30, (i) => '#${(i * 8).toRadixString(16).padLeft(2, '0')}0000').join('\n'), max: 5), hasLength(5));
    });

    test('ideas are the lines of a list, without the marks', () {
      expect(parseIdeas('Here are some ideas:\n- A **lighthouse** keeper who paints\n- "The tide goes the wrong way"\n* Third\n- A **lighthouse** keeper who paints'),
          ['A lighthouse keeper who paints', 'The tide goes the wrong way', 'Third']);
      expect(parseIdeas('1. One\n2) Two\n\n3. Three'), ['One', 'Two', 'Three']);
      expect(parseIdeas('Ideas:\nJust a line\nAnother line'), ['Just a line', 'Another line'], reason: 'no list: every line, but not the introduction');
      expect(parseIdeas(''), isEmpty);
      expect(parseIdeas(List.generate(30, (i) => '- idea $i').join('\n')), hasLength(10));
    });

    test('the prompts say what is wanted, and in which language', () {
      final p = ideasPrompt(IdeaKind.character, 'the sea', language: 'de');
      expect(p.system, contains('5'));
      expect(p.system, contains('characters'));
      expect(p.system, contains('"de"'));
      expect(p.user, contains('the sea'));
      expect(p.exact, isTrue);
      expect(ideasPrompt(IdeaKind.song, '').user, contains('any subject'));
      final c = palettePrompt('a quiet harbour', count: 4);
      expect(c.system, contains('4'));
      expect(c.user, 'a quiet harbour');
    });
  });

  group('the dialog', () {
    Future<IdeasResult?> run(WidgetTester tester, _Provider provider, Future<void> Function() act) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      IdeasResult? got;
      var closed = false;
      final ai = AiService(providers: [provider]);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              got = await showIdeasDialog(context, ai);
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await act();
      expect(closed, isTrue);
      return got;
    }

    testWidgets('colours need a description; a tap on one keeps that one', (tester) async {
      final provider = _Provider(answer: harbour);
      final got = await run(tester, provider, () async {
        expect(tester.widget<FilledButton>(find.byKey(const ValueKey('ideas-go'))).onPressed, isNull);
        await tester.enterText(find.byKey(const ValueKey('ideas-topic')), 'a quiet harbour at dawn');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('ideas-go')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ideas-colour-5')), findsOneWidget);
        expect(find.byKey(const ValueKey('ideas-colour-6')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('ideas-colour-2')));
        await tester.pumpAndSettle();
      });
      expect(got!.colours.single.toARGB32(), 0xFF0C7C59);
      expect(provider.prompts.single.user, 'a quiet harbour at dawn');
    });

    testWidgets('"Add all" keeps every colour', (tester) async {
      final got = await run(tester, _Provider(answer: harbour), () async {
        await tester.enterText(find.byKey(const ValueKey('ideas-topic')), 'harbour');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('ideas-go')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ideas-add-all')));
        await tester.pumpAndSettle();
      });
      expect(got!.colours, hasLength(6));
      expect(got.text, isNull);
    });

    testWidgets('ideas can start from any topic or none; one is added alone, or all together', (tester) async {
      final provider = _Provider(answer: '- A lighthouse keeper who paints\n- A map of a place that moves');
      var got = await run(tester, provider, () async {
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('ideas-mode')), matching: find.text('Ideas')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ideas-kind-story')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('ideas-go'))); // (no topic is fine here)
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ideas-add-1')));
        await tester.pumpAndSettle();
      });
      expect(got!.text, 'A map of a place that moves');
      expect(provider.prompts.single.system, contains('story premises'));

      got = await run(tester, provider, () async {
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('ideas-mode')), matching: find.text('Ideas')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ideas-go')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ideas-add-all')));
        await tester.pumpAndSettle();
      });
      expect(got!.text, '- A lighthouse keeper who paints\n- A map of a place that moves');
    });

    testWidgets('an answer with nothing usable says so, and one can go back', (tester) async {
      final provider = _Provider(answer: '   ');
      await tester.binding.setSurfaceSize(const Size(900, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) => TextButton(onPressed: () => showIdeasDialog(c, AiService(providers: [provider])), child: const Text('open')))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('ideas-topic')), 'x');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ideas-go')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing usable came back'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ideas-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ideas-go')), findsOneWidget);
    });

    testWidgets('a model that has to be downloaded first is downloaded on request, and one that cannot work here says why', (tester) async {
      final provider = _Provider(answer: harbour, state: ProviderState.needsDownload);
      await tester.binding.setSurfaceSize(const Size(900, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) => TextButton(onPressed: () => showIdeasDialog(c, AiService(providers: [provider])), child: const Text('open')))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ideas-topic')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ideas-download')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ideas-topic')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      final no = _Provider(state: ProviderState.unavailable, reason: 'Not enough memory.');
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) => TextButton(onPressed: () => showIdeasDialog(c, AiService(providers: [no])), child: const Text('open2')))));
      await tester.tap(find.text('open2'));
      await tester.pumpAndSettle();
      expect(find.text('Not enough memory.'), findsOneWidget);
    });
  });

  group('in the editor', () {
    late NoteRepository repo;
    late String id;

    Future<void> open(WidgetTester tester, {AiService? ai, FeatureSettings? features}) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        id = await repo.createNote();
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, ai: ai, features: features)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    testWidgets('there is no button without an assistant, or with the tool off', (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('ideas-button')), findsNothing);
      final store = <String, String>{};
      final features = FeatureSettings((k) async => store[k], (k, v) async => store[k] = v);
      await features.apply({...FeaturePresets.everything}..remove(Feature.ideas));
      await open(tester, ai: AiService(providers: [_Provider()]), features: features);
      expect(find.byKey(const ValueKey('ideas-button')), findsNothing);
      expect(find.byKey(const ValueKey('assistant-button')), findsOneWidget);
    });

    testWidgets('a palette is kept among the colours, and an idea becomes a text box', (tester) async {
      final provider = _Provider(answer: harbour);
      await open(tester, ai: AiService(providers: [provider]));
      await tester.ensureVisible(find.byKey(const ValueKey('ideas-button')));
      await tester.tap(find.byKey(const ValueKey('ideas-button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('ideas-topic')), 'harbour');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ideas-go')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ideas-add-all')));
      await tester.pumpAndSettle();
      final saved = await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return repo.settings.penColors();
      });
      expect(saved!.map((c) => c.toARGB32() & 0xFFFFFF), containsAll([0x1B2A41, 0xA9D6E5, 0xFFFFFF]));

      provider.answer = '- A lighthouse keeper who paints';
      await tester.ensureVisible(find.byKey(const ValueKey('ideas-button')));
      await tester.tap(find.byKey(const ValueKey('ideas-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('ideas-mode')), matching: find.text('Ideas')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ideas-go')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ideas-add-0')));
      await tester.pumpAndSettle();
      expect(find.text('A lighthouse keeper who paints'), findsOneWidget);
    });
  });
}
