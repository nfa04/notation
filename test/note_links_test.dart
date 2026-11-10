
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/markdown/markdown_parser.dart';
import 'package:notes/markdown/mention.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

TextEditingValue at(String text, [int? cursor]) =>
    TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor ?? text.length));

void main() {
  setUpAll(AppDatabase.initFfi);

  group('typing @', () {
    test('a mention starts at an @ after a space or at the start', () {
      expect(mentionAt(at('@'))!.start, 0);
      expect(mentionAt(at('see @phy'))!.start, 4);
      expect(mentionAt(at('see @phy'))!.query, 'phy');
      expect(mentionAt(at('see @phy'))!.start, 4);
    });

    test('not in addresses, not once the word is over, not with a selection', () {
      expect(mentionAt(at('mail me@example.com')), isNull);
      expect(mentionAt(at('see @phy and more')), isNull);
      expect(mentionAt(at('@a b')), isNull);
      expect(mentionAt(const TextEditingValue(text: '@ab', selection: TextSelection(baseOffset: 0, extentOffset: 3))), isNull);
    });

    test('the cursor in the middle only looks at what is before it', () {
      expect(mentionAt(at('x @ab tail', 5))!.query, 'ab');
    });

    test('choosing a note writes the link and puts the cursor after it', () {
      final v = at('see @ph and more', 7);
      final out = withNoteLink(v, mentionAt(v)!, 'n1', 'Physics');
      expect(out.text, 'see [Physics](note:n1)  and more');
      expect(out.selection.baseOffset, 'see [Physics](note:n1) '.length);
    });

    test('brackets in a title do not break the link, an empty title is Untitled', () {
      expect(noteLink('x', 'a [b] c'), '[a (b) c](note:x)');
      expect(noteLink('x', ' '), '[Untitled](note:x)');
    });
  });

  group('links in Markdown', () {
    test('a link is a run with a target', () {
      final run = parseMarkdown('go to [My note](note:abc) now').single.runs;
      expect(run.map((r) => r.text), ['go to ', 'My note', ' now']);
      expect(run[1].link, 'note:abc');
      expect(run[0].link, isNull);
    });

    test('its place in the source is kept', () {
      const src = 'a [b](note:1)';
      final link = parseMarkdown(src).single.runs.last;
      expect(src.substring(link.src, link.src + link.text.length), 'b');
    });

    test('not a link: no target, a space in it, or no closing bracket', () {
      for (final src in ['[a]', '[a]()', '[a](b c)', '[a(b)', 'x [ y ] z']) {
        expect(parseMarkdown(src).single.runs.every((r) => r.link == null), isTrue, reason: src);
      }
    });

    test('links sit in lists and headings and next to formulas', () {
      expect(parseMarkdown('- [x](note:1)').single.runs.single.link, 'note:1');
      expect(parseMarkdown(r'# [x](note:1) $a$').single.runs.first.link, 'note:1');
    });
  });

  testWidgets('@ in a text box offers the other notes; the link opens that note', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late NoteRepository repo;
    late String id, other;
    await tester.runAsync(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      other = await repo.createNote(title: 'Thermodynamics');
      await repo.createNote(title: 'Groceries');
      id = await repo.createNote(title: 'Physics');
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: 'see ')];
      await repo.saveNote(note);
    });
    String? opened;
    await tester.pumpWidget(MaterialApp(
      home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, onOpenNote: (n) => opened = n),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(origin + const Offset(150, 130)); // into the box
    await tester.pumpAndSettle();
    final field = tester.state<EditableTextState>(find.byType(EditableText).first);
    expect(find.byKey(const ValueKey('mention-list')), findsNothing);

    field.widget.controller.value = at('see @th');
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mention-list')), findsOneWidget);
    Finder inList(String t) => find.descendant(of: find.byKey(const ValueKey('mention-list')), matching: find.text(t));
    expect(inList('Thermodynamics'), findsOneWidget); // matches what was typed
    expect(inList('Groceries'), findsNothing);
    expect(inList('Physics'), findsNothing); // not itself

    await tester.tap(inList('Thermodynamics'));
    await tester.pumpAndSettle();
    expect(field.widget.controller.text, 'see [Thermodynamics](note:$other) ');
    expect(find.byKey(const ValueKey('mention-list')), findsNothing);

    // leave the box: it shows the link, and a tap on it opens that note
    await tester.tapAt(origin + const Offset(700, 800));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(ValueKey('link-note:$other')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    expect(opened, other);
  });
}
