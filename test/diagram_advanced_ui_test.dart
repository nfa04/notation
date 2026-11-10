import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  late NoteRepository repo;
  late String id;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
      id = await repo.createNote(title: 'CS');
    });
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-diagram')));
    await tester.pumpAndSettle();
  }

  Future<({int strokes, List<String> texts})> saved(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    final note = (await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return repo.loadNote(id);
    }))!;
    return (strokes: note.strokes[0]?.length ?? 0, texts: [for (final b in note.textBoxes[0] ?? <TextBoxWidgetModel>[]) b.controller.text]);
  }

  Future<void> mode(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(ValueKey('diagram-mode-$name')));
    await tester.pumpAndSettle();
  }

  String text(WidgetTester tester) => tester.widget<TextField>(find.byKey(const ValueKey('diagram-text'))).controller!.text;

  testWidgets('an automaton: a preview, facts, and states and arrows on the page', (tester) async {
    await open(tester);
    await mode(tester, 'automaton');
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('diagram-insert'))).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('diagram-example')));
    await tester.pumpAndSettle();
    expect(text(tester), contains('q0 -a-> q1'));
    expect(find.byKey(const ValueKey('diagram-preview')), findsOneWidget);
    expect(find.textContaining('Automaton: 2 boxes'), findsOneWidget);
    expect(find.byKey(const ValueKey('diagram-facts')), findsOneWidget);
    expect(find.text('DFA'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('diagram-insert')));
    await tester.pumpAndSettle();
    final s = await saved(tester);
    expect(s.texts.toSet().containsAll({'q0', 'q1', 'a', 'b'}), isTrue);
    // 4 transitions, the ring of the accepting state and the arrow into the start
    expect(s.strokes, 6);
  });

  testWidgets('a word is tried on the automaton', (tester) async {
    await open(tester);
    await mode(tester, 'automaton');
    await tester.tap(find.byKey(const ValueKey('diagram-example')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('automaton-word')), 'abba');
    await tester.pump();
    expect(find.text('accepted'), findsOneWidget);
    expect(find.byKey(const ValueKey('automaton-path')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('automaton-word')), 'ab');
    await tester.pump();
    expect(find.text('rejected'), findsOneWidget);
    expect(find.text('q0 → q1 → q1'), findsOneWidget);
  });

  testWidgets('an NFA is made deterministic, and the text is replaced', (tester) async {
    await open(tester);
    await mode(tester, 'automaton');
    await tester.tap(find.byKey(const ValueKey('diagram-example')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('diagram-example'))); // the second example is an NFA
    await tester.pumpAndSettle();
    expect(find.text('NFA'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('automaton-dfa'))).onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('automaton-dfa')));
    await tester.pumpAndSettle();
    expect(text(tester), contains('{q0,q1}'));
    expect(find.text('DFA'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('automaton-dfa'))).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('automaton-minimize')));
    await tester.pumpAndSettle();
    expect(find.text('DFA'), findsOneWidget);
  });

  testWidgets('a tree from numbers, with its walks', (tester) async {
    await open(tester);
    await mode(tester, 'tree');
    await tester.tap(find.byKey(const ValueKey('diagram-example')));
    await tester.pumpAndSettle();
    expect(text(tester), startsWith('bst:'));
    expect(find.text('1 3 4 6 7 8 10 13 14'), findsOneWidget); // the inorder walk of a search tree
    expect(find.byKey(const ValueKey('tree-balance')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tree-balance')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('diagram-insert')));
    await tester.pumpAndSettle();
    final s = await saved(tester);
    expect(s.texts, containsAll(['8', '3', '10', '1', '6', '14', '4', '7', '13']));
    expect(s.strokes, 8);
    // nine nodes, and nine balance factors beside them
    expect(s.texts.length, 18);
  });

  testWidgets('a graph with its shortest paths shown', (tester) async {
    await open(tester);
    await mode(tester, 'graph');
    await tester.tap(find.byKey(const ValueKey('diagram-example')));
    await tester.pumpAndSettle();
    expect(find.text('Spanning tree'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('graph-highlight-shortest')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('diagram-insert')));
    await tester.pumpAndSettle();
    final s = await saved(tester);
    expect(s.texts, containsAll(['A', 'B', 'C', 'D', 'E']));
    expect(s.strokes, 6);
    expect(s.texts, contains('11')); // the distance to E: A-C 1, C-B 2, B-D 5, D-E 3
  });

  testWidgets('what cannot be read is told', (tester) async {
    await open(tester);
    await mode(tester, 'graph');
    await tester.enterText(find.byKey(const ValueKey('diagram-text')), 'A - B\nA - B C');
    await tester.pump();
    expect(find.byKey(const ValueKey('diagram-problems')), findsOneWidget);
    expect(find.textContaining('Line 2 is not understood'), findsOneWidget);
  });

  testWidgets('each kind keeps its own text when the kind is changed', (tester) async {
    await open(tester);
    await mode(tester, 'graph');
    await tester.enterText(find.byKey(const ValueKey('diagram-text')), 'A - B');
    await mode(tester, 'tree');
    expect(text(tester), '');
    await mode(tester, 'graph');
    expect(text(tester), 'A - B');
  });
}
