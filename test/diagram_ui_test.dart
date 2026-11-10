import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Outliner extends ChangeNotifier implements TextModelProvider {
  final prompts = <AiPrompt>[];

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
    return '- Thermodynamics\n  - First law\n  - Second law\n    - Entropy';
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late String id;

  Future<void> open(WidgetTester tester, {AiService? ai}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote(title: 'Physics');
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'a', position: const Offset(60, 700), initialText: 'Energy is conserved. Entropy never decreases.')];
      await repo.saveNote(note);
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo, ai: ai)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  Future<NoteSnapshot> saved(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    final note = (await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return repo.loadNote(id);
    }))!;
    return NoteSnapshot(note.strokes[0]?.length ?? 0, [for (final b in note.textBoxes[0] ?? <TextBoxWidgetModel>[]) b.controller.text]);
  }

  testWidgets('a flowchart is made from lines with arrows: boxes and lines on the page, in one step that can be taken back', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('add-diagram')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('diagram-insert'))).onPressed, isNull); // nothing to insert yet
    await tester.enterText(find.byKey(const ValueKey('diagram-text')), 'Start -> Check?\nCheck? -> Done : yes\nCheck? -> Start : no');
    await tester.pump();
    expect(find.byKey(const ValueKey('diagram-preview')), findsOneWidget);
    expect(find.textContaining('Flowchart: 3 boxes'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('diagram-insert')));
    await tester.pumpAndSettle();

    var s = await saved(tester);
    expect(s.strokes, 3); // three arrows, one of them going back
    // the three boxes, the two labels, and the box that was there
    expect(s.texts.toSet(), {'Energy is conserved. Entropy never decreases.', 'Start', 'Check?', 'Done', 'yes', 'no'});

    await tester.tap(find.byKey(const ValueKey('undo-any')));
    await tester.pumpAndSettle();
    s = await saved(tester);
    expect(s.strokes, 0);
    expect(s.texts, ['Energy is conserved. Entropy never decreases.']);

    await tester.tap(find.byKey(const ValueKey('redo-any')));
    await tester.pumpAndSettle();
    s = await saved(tester);
    expect(s.strokes, 3);
  });

  testWidgets('an outline becomes a mind map around the title of the note when it has several top entries', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('add-diagram')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('diagram-example-mindmap')));
    await tester.pump();
    expect(find.textContaining('Mind map: 7 boxes'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('diagram-insert')));
    await tester.pumpAndSettle();
    final s = await saved(tester);
    expect(s.strokes, 6);
    expect(s.texts, containsAll(['Plants', 'Roots', 'Water', 'Flowers']));
    expect(s.texts.length, 8); // seven boxes and the one that was there
  });

  testWidgets('the assistant drafts an outline from the note, which is then drawn', (tester) async {
    final provider = _Outliner();
    await open(tester, ai: AiService(providers: [provider]));
    await tester.tap(find.byKey(const ValueKey('add-diagram')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('diagram-draft')));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }
    expect(provider.prompts.single.user, contains('Entropy never decreases'));
    expect(provider.prompts.single.system, contains('mind map'));
    expect(tester.widget<TextField>(find.byKey(const ValueKey('diagram-text'))).controller!.text, startsWith('- Thermodynamics'));
    await tester.tap(find.byKey(const ValueKey('diagram-insert')));
    await tester.pumpAndSettle();
    final s = await saved(tester);
    expect(s.texts, containsAll(['Thermodynamics', 'First law', 'Second law', 'Entropy']));
    expect(s.strokes, 3);
  });

  testWidgets('without a model there is no draft button', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('add-diagram')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('diagram-draft')), findsNothing);
  });
}

class NoteSnapshot {
  final int strokes;
  final List<String> texts;

  NoteSnapshot(this.strokes, this.texts);
}
