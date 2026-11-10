import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/automations/note_sorter.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/llm/embedding_service.dart';
import 'package:notes/screens/automations_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Stands in for the sentence model: each word is one direction, so texts that share
/// words are alike; and it counts how often it was asked.
class FakeEmbedder implements TextEmbedder {
  int calls = 0;
  @override
  String get modelId => 'fake';

  @override
  Future<Float32List> embed(String text) async {
    calls++;
    final v = Float32List(128);
    for (final w in text.toLowerCase().split(RegExp(r'[^a-zäöü]+')).where((w) => w.length > 2)) {
      v[w.hashCode.abs() % 128] += 1;
    }
    final norm = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
    if (norm > 0) {
      for (var i = 0; i < v.length; i++) {
        v[i] /= norm;
      }
    }
    return v;
  }
}

const maths = 'Derivative integral limit calculus theorem function derivative integral limit series convergence';
const cooking = 'Recipe pasta tomato basil boil water salt pasta tomato sauce garlic olive recipe kitchen';

void main() {
  setUpAll(AppDatabase.initFfi);

  group('choosing a folder', () {
    Float32List unit(int i) => Float32List(8)..[i] = 1;
    SortCandidate folder(String id, List<Float32List> notes, {Float32List? name}) =>
        SortCandidate(id, id, notes, name ?? unit(7));

    test('the folder with the most alike notes wins', () {
      final d = chooseFolder(unit(0), [folder('math', [unit(0), unit(0)]), folder('food', [unit(1)])], SortStrictness.normal);
      expect(d.folderId, 'math');
      expect(d.reason, contains('Moved to "math"'));
    });

    test('too little likeness, or two folders about equal, is not a choice', () {
      final weak = chooseFolder(unit(2), [folder('math', [unit(0)]), folder('food', [unit(1)])], SortStrictness.normal);
      expect(weak.folderId, isNull);
      expect(weak.reason, startsWith('Not sure'));
      final tie = chooseFolder(unit(0), [folder('a', [unit(0)]), folder('b', [unit(0)])], SortStrictness.normal);
      expect(tie.folderId, isNull);
      expect(tie.reason, contains('about equally'));
    });

    test('a note already in the best folder stays; an empty folder is judged by its name', () {
      final stays = chooseFolder(unit(0), [folder('math', [unit(0)]), folder('food', [unit(1)])], SortStrictness.normal, current: 'math');
      expect(stays.folderId, isNull);
      expect(stays.reason, startsWith('Already'));
      final byName = chooseFolder(unit(3), [folder('empty', [], name: unit(3)), folder('food', [unit(1)])], SortStrictness.normal);
      expect(byName.folderId, 'empty');
    });

    test('stricter settings need more', () {
      final v = Float32List(8)..[0] = 0.5..[3] = 0.866; // about half alike to the notes of "math"
      final folders = [folder('math', [unit(0)]), folder('food', [unit(2)])];
      expect(chooseFolder(v, folders, SortStrictness.eager).folderId, 'math');
      expect(chooseFolder(v, folders, SortStrictness.normal).folderId, 'math');
      expect(chooseFolder(v, folders, SortStrictness.careful).folderId, isNull);
    });
  });

  group('sorting notes', () {
    late NoteRepository notes;
    late FakeEmbedder embedder;
    late NoteSorter sorter;
    late String mathFolder, foodFolder;

    Future<String> note(String title, String text, {String? folder}) async {
      final id = await notes.createNote(title: title, folderId: folder);
      final n = (await notes.loadNote(id))!..documentText = text;
      await notes.saveNote(n);
      return id;
    }

    setUp(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('notes');
      await db.delete('folders');
      notes = NoteRepository(db);
      embedder = FakeEmbedder();
      sorter = NoteSorter(notes, embedder, ready: () => true);
      mathFolder = await notes.createFolder('Mathematics');
      foodFolder = await notes.createFolder('Cooking');
      await note('Analysis 1', maths, folder: mathFolder);
      await note('Analysis 2', '$maths convergence theorem', folder: mathFolder);
      await note('Dinner', cooking, folder: foodFolder);
    });

    test('a note about calculus goes to the mathematics folder', () async {
      final id = await note('Exam prep', 'Calculus: limit and derivative of a function, integral theorem');
      final result = await sorter.sort(id);
      expect(result, contains('Moved to "Mathematics"'));
      expect((await notes.noteInfo(id))!.folderId, mathFolder);
    });

    test('a recipe goes to cooking', () async {
      final id = await note('Sunday', 'Boil water, add salt, cook the pasta with tomato and basil in the kitchen');
      await sorter.sort(id);
      expect((await notes.noteInfo(id))!.folderId, foodFolder);
    });

    test('a note about something else is left where it is, and says why', () async {
      final id = await note('Holiday', 'Flights to Lisbon, hotel near the beach, museum tickets, train schedule');
      final result = await sorter.sort(id);
      expect(result, startsWith('Not sure'));
      expect((await notes.noteInfo(id))!.folderId, isNull);
    });

    test('notes that are filed are left alone unless asked, and short notes say too little', () async {
      final filed = await note('Cooking maths', maths, folder: foodFolder);
      expect(await sorter.sort(filed), startsWith('Left alone'));
      expect((await notes.noteInfo(filed))!.folderId, foodFolder);
      await sorter.sort(filed, unfiledOnly: false);
      expect((await notes.noteInfo(filed))!.folderId, mathFolder);
      final tiny = await note('x', 'hi');
      expect(await sorter.sort(tiny), startsWith('Not enough text'));
    });

    test('only the folders inside the chosen one are filed into', () async {
      final course = await notes.createFolder('Courses');
      final inner = await notes.createFolder('Calculus course', parentId: course);
      await note('Lecture 1', maths, folder: inner);
      final id = await note('Exam prep', 'Calculus: limit and derivative of a function, integral theorem');
      await sorter.sort(id, within: course);
      expect((await notes.noteInfo(id))!.folderId, inner); // not the better-matching folder outside
    });

    test('what a note said is kept: it is read again only when its text changed', () async {
      final id = await note('Exam prep', 'Calculus: limit and derivative of a function, integral theorem');
      await sorter.sort(id, unfiledOnly: false);
      final after = embedder.calls;
      await sorter.sort(id, unfiledOnly: false);
      expect(embedder.calls, after); // nothing was read again
      final n = (await notes.loadNote(id))!..documentText = 'Boil water, add salt, cook the pasta with tomato and basil';
      await notes.saveNote(n);
      await sorter.sort(id, unfiledOnly: false);
      expect(embedder.calls, greaterThan(after)); // only the changed note (folder names are kept too)
      expect(embedder.calls - after, 1);
    });

    test('without the model it says so and moves nothing', () async {
      final id = await note('Exam prep', 'Calculus: limit and derivative of a function, integral theorem');
      final s = NoteSorter(notes, embedder, ready: () => false);
      expect(await s.sort(id), contains('not installed'));
      expect((await notes.noteInfo(id))!.folderId, isNull);
    });
  });

  group('as an automation, only for notes that changed', () {
    late NoteRepository notes;
    late TaskRepository tasks;
    late AutomationService service;
    late NoteSorter sorter;
    late String math;

    Future<String> note(String text, {String? folder}) async {
      final id = await notes.createNote(title: 'Note', folderId: folder);
      final n = (await notes.loadNote(id))!..documentText = text;
      await notes.saveNote(n);
      return id;
    }

    setUp(() async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      await db.delete('settings', where: "key LIKE 'automations%'");
      await db.delete('notes');
      await db.delete('folders');
      notes = NoteRepository(db);
      tasks = TaskRepository(db);
      sorter = NoteSorter(notes, FakeEmbedder(), ready: () => true);
      service = AutomationService(notes, tasks, sorter: sorter);
      await service.load();
      math = await notes.createFolder('Mathematics');
      await notes.createFolder('Cooking');
      await note(maths, folder: math);
    });
    tearDown(() => service.dispose());

    test('closing a note sorts it, in the background, and says what happened', () async {
      await service.add(const Automation(id: 's', event: AutomationEvent.noteClosed, action: AutomationAction.sortIntoFolder));
      final id = await note('Calculus: limit and derivative of a function, integral theorem');
      final out = await service.run(AutomationEvent.noteClosed, noteId: id, title: 'Note');
      expect(out.single, contains('background'));
      await service.sortingDone;
      expect((await notes.noteInfo(id))!.folderId, math);
      expect(service.all.single.lastResult, contains('Moved to "Mathematics"'));
    });

    test('an unchanged note does not run it again; an edit does', () async {
      await service.add(const Automation(id: 's', event: AutomationEvent.noteClosed, action: AutomationAction.sortIntoFolder));
      final id = await note('Holiday flights to Lisbon, hotel near the beach, museum tickets');
      expect(await service.run(AutomationEvent.noteClosed, noteId: id, title: 'Note'), hasLength(1));
      await service.sortingDone;
      expect(await service.run(AutomationEvent.noteClosed, noteId: id, title: 'Note'), isEmpty); // not edited since
      expect(await service.run(AutomationEvent.noteClosed, noteId: id, title: 'Note'), isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      final n = (await notes.loadNote(id))!..documentText = 'Calculus: limit and derivative of a function, integral theorem';
      await notes.saveNote(n);
      expect(await service.run(AutomationEvent.noteClosed, noteId: id, title: 'Note'), hasLength(1));
      await service.sortingDone;
      expect((await notes.noteInfo(id))!.folderId, math);
    });

    test('opening and closing are separate, and moving a note is not a change', () async {
      await service.add(const Automation(id: 'o', event: AutomationEvent.noteOpened, action: AutomationAction.moveToFolder, params: {'folder': 'x'}));
      await service.add(const Automation(id: 'c', event: AutomationEvent.noteClosed, action: AutomationAction.moveToFolder, params: {'folder': 'x'}));
      final target = await notes.createFolder('Target');
      final id = await note('words words words');
      await service.update(service.all[0].copyWith(params: {'folder': target}));
      await service.update(service.all[1].copyWith(params: {'folder': target}));
      expect(await service.run(AutomationEvent.noteOpened, noteId: id, title: 'Note'), hasLength(1));
      expect(await service.run(AutomationEvent.noteClosed, noteId: id, title: 'Note'), hasLength(1)); // its own record
      expect(await service.run(AutomationEvent.noteOpened, noteId: id, title: 'Note'), isEmpty);
      await notes.moveNote(id, null); // moving is not an edit
      expect(await service.run(AutomationEvent.noteClosed, noteId: id, title: 'Note'), isEmpty);
    });

    test('what the app remembers survives a restart', () async {
      await service.add(const Automation(id: 'c', event: AutomationEvent.noteClosed, action: AutomationAction.moveToFolder));
      final target = await notes.createFolder('Target');
      await service.update(service.all.single.copyWith(params: {'folder': target}));
      final id = await note('words words words');
      expect(await service.run(AutomationEvent.noteClosed, noteId: id, title: 'Note'), hasLength(1));
      final again = AutomationService(notes, tasks);
      await again.load();
      expect(await again.run(AutomationEvent.noteClosed, noteId: id, title: 'Note'), isEmpty);
      again.dispose();
    });

    test('other events are not held back', () async {
      await service.add(const Automation(id: 'a', event: AutomationEvent.noteCreated, action: AutomationAction.addTask, params: {'title': 'x'}));
      final id = await note('words words words');
      expect(await service.run(AutomationEvent.noteCreated, noteId: id, title: 'Note'), hasLength(1));
      expect(await service.run(AutomationEvent.noteCreated, noteId: id, title: 'Note'), hasLength(1));
    });
  });

  group('the sentence model service', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('embed_');
      final dir = Directory('${root.path}/embed_multilingual')..createSync();
      File('${dir.path}/model.onnx').writeAsStringSync('x');
      File('${dir.path}/tokenizer.json').writeAsStringSync(jsonEncode({
        'model': {
          'type': 'Unigram',
          'unk_id': 3,
          'vocab': [['<s>', 0], ['<pad>', 0], ['</s>', 0], ['<unk>', 0], ['▁hello', -1.0], ['▁world', -1.0]],
        },
      }));
    });
    tearDown(() => root.delete(recursive: true));

    test('it mean-pools what the model gives, and makes a vector of length 1', () async {
      final seen = <List<int>>[];
      final service = EmbeddingService(
        modelsRoot: () async => root,
        keepLoaded: const Duration(milliseconds: 1),
        // the model "says" [3, 4, 0, 0...] for the first token and [0 ...] for the others
        run: (path, ids, tokenTypes, width) async {
          seen.add(ids);
          return [for (var t = 0; t < ids.length; t++) for (var d = 0; d < width; d++) t == 0 ? (d == 0 ? 3.0 : d == 1 ? 4.0 : 0.0) : 0.0];
        },
      );
      await service.load();
      expect(service.installed, isTrue);
      final v = await service.embed('hello world');
      expect(v.length, 384);
      expect(seen.single, [0, 4, 5, 2]); // <s> hello world </s>
      expect(math.sqrt(v.fold<double>(0, (s, x) => s + x * x)), closeTo(1, 1e-5));
      expect(v[0], closeTo(0.6, 1e-5));
      expect(v[1], closeTo(0.8, 1e-5));
      expect(cosine(v, v), closeTo(1, 1e-5));
      service.dispose();
    });

    test('a model that is not downloaded says so', () async {
      final service = EmbeddingService(modelsRoot: () async => Directory('${root.path}/nowhere'), run: (a, b, c, d) async => []);
      await service.load();
      expect(service.installed, isFalse);
      await expectLater(service.embed('text'), throwsStateError);
      service.dispose();
    });
  });

  testWidgets('the dialog offers sorting after a note is closed, with its choices', (tester) async {
    Automation? saved;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => saved = await showDialog<Automation>(
            context: context,
            builder: (_) => const AutomationDialog(folders: [FolderEntry(id: 'f', parentId: null, name: 'Courses', noteCount: 0)]),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('automation-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move the note to the folder it fits best (by what it says)').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('automation-unfiled')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('automation-unfiled')));
    await tester.tap(find.byKey(const ValueKey('automation-unfiled'))); // also notes that are filed
    await tester.ensureVisible(find.byKey(const ValueKey('automation-within')));
    await tester.tap(find.byKey(const ValueKey('automation-within')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Only into the folders inside Courses').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('automation-save')));
    await tester.tap(find.byKey(const ValueKey('automation-save')));
    await tester.pumpAndSettle();
    expect(saved!.action, AutomationAction.sortIntoFolder);
    expect(saved!.params, {'within': 'f', 'unfiledOnly': '0', 'strictness': 'normal'});
  });
}
