import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation_service.dart' show NoteEditorHandle, TitleSetter;
import 'package:notes/data/app_database.dart';
import 'package:notes/data/lock_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/tag_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/extensions/extension_host.dart';
import 'package:notes/history/note_history.dart';
import 'package:notes/mcp/agent_editable.dart';
import 'package:notes/mcp/mcp_notes.dart';
import 'package:notes/mcp/mcp_protocol.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// An editor with a note open: what an agent changes goes through it, and the calls are written down.
class _OpenEditor implements NoteEditorHandle, AgentEditable, TitleSetter {
  final calls = <String>[];
  final api = _Api();
  _OpenEditor() {
    api.calls = calls;
  }

  @override
  Future<void> get ready async {}
  @override
  Future<void> saveNow() async => calls.add('save');
  @override
  String get noteTitle => 'Open';
  @override
  Future<String?> exportPdfTo(String path) async => null;
  @override
  Future<List<String>> pdfTextLines() async => [];
  @override
  ExtensionApi get agentApi => api;
  @override
  Future<void> agentSetDocument(String text) async => calls.add('document: $text');
  @override
  void setNoteTitle(String title) => calls.add('title: $title');
}

/// An editor that takes the note and never says it is saved.
class _StuckEditor extends _OpenEditor {
  @override
  Future<void> saveNow() => Completer<void>().future;
}

class _Api extends ExtensionApi {
  late List<String> calls;
  @override
  Future<void> insertText(String text) async => calls.add('insert: $text');
  @override
  Future<int> replaceText(String find, String replacement, {bool all = false}) async {
    calls.add('replace: $find -> $replacement');
    return 1;
  }

  @override
  Future<void> insertTextAt(String text, {String? after, String? before, bool atStart = false}) async => calls.add('insert at: $text after=$after before=$before start=$atStart');

  @override
  Future<String> inspectText(String target) async {
    calls.add('inspect: $target');
    return 'looked';
  }

  @override
  Future<String> formatText(Map<String, Object?> options) async {
    calls.add('format: ${jsonEncode(options)}');
    return 'Done: formatted.';
  }

  @override
  Future<void> setTitle(String title) async => calls.add('api title: $title');
}

class _Versions extends NoteHistory {
  _Versions(super.db, super.notes);
  final kept = <String>[];

  @override
  Future<NoteVersion?> snapshot(String noteId, {VersionReason reason = VersionReason.edit, bool manual = false, String? label, String? who}) async {
    kept.add('${reason.name}: $label');
    return null;
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late NoteRepository repo;
  late TaskRepository tasks;
  late TagRepository tags;
  late _Versions versions;
  late McpProtocol protocol;
  final open = <String, _OpenEditor>{};
  var canChange = true;

  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    for (final t in ['notes', 'folders', 'tasks', 'note_tags']) {
      await db.delete(t);
    }
    repo = NoteRepository(db);
    tasks = TaskRepository(db);
    tags = TagRepository(db);
    versions = _Versions(db, repo);
    open.clear();
    canChange = true;
    final notes = McpNotes(repository: repo, tasks: tasks, tags: tags, history: versions, editorOf: (id) => open[id], saveWait: const Duration(milliseconds: 200));
    protocol = McpProtocol(tools: () => notes.tools, canChange: () => canChange);
  });

  var next = 0;

  /// Calls a tool; gives the text and whether it failed.
  Future<(String, bool)> call(String name, [Map<String, Object?> args = const {}]) async {
    final r = await protocol.handle({'jsonrpc': '2.0', 'id': ++next, 'method': 'tools/call', 'params': {'name': name, 'arguments': args}});
    final result = (r!.body['result'] as Map);
    return (((result['content'] as List).single as Map)['text'] as String, result['isError'] == true);
  }

  Future<Map<String, dynamic>> json(String name, [Map<String, Object?> args = const {}]) async {
    final (text, failed) = await call(name, args);
    expect(failed, isFalse, reason: text);
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<String> make(String title, [String text = '', Map<String, Object?> more = const {}]) async {
    final (reply, failed) = await call('create_note', {'title': title, 'text': text, ...more});
    expect(failed, isFalse, reason: reply);
    return RegExp(r'Its id is (\S+)\.').firstMatch(reply)!.group(1)!;
  }

  test('every tool has a name an agent can use, a description and an object for a schema', () {
    final names = McpNotes(repository: repo, tasks: tasks).tools.map((t) => t.name).toList();
    expect(names.toSet().length, names.length);
    for (final t in McpNotes(repository: repo, tasks: tasks).tools) {
      expect(t.name, matches(RegExp(r'^[a-z_]{1,64}$')));
      expect(t.description, isNotEmpty);
      expect(t.inputSchema['type'], 'object');
      for (final r in (t.inputSchema['required'] as List? ?? const [])) {
        expect((t.inputSchema['properties'] as Map), contains(r), reason: '${t.name} requires $r');
      }
    }
  });

  test('a note is made, found in the list and by a search, and read', () async {
    final id = await make('Thermodynamics', '# Entropy\n\nEntropy never decreases in an isolated system.');
    final list = await json('list_notes');
    expect(list['total'], 1);
    expect((list['notes'] as List).single, containsPair('title', 'Thermodynamics'));

    final found = await json('search_notes', {'query': 'isolated system'});
    expect(found['total_matches'], 1);
    final hit = (found['notes'] as List).single as Map;
    expect(hit['id'], id);
    expect(((hit['snippets'] as List).single as Map)['text'], contains('[[isolated system]]'));
    expect((await json('search_notes', {'query': 'zebra'}))['total_matches'], 0);
    expect((await json('search_notes', {'query': r'Entr\w+', 'regex': true}))['total_matches'], greaterThan(0));

    final (read, failed) = await call('read_note', {'note_id': id});
    expect(failed, isFalse);
    expect(read, startsWith('# Thermodynamics\nid: $id'));
    expect(read, contains('## Document'));
    expect(read, contains('Entropy never decreases'));
  });

  test('a plain search takes the options it is given: whole words, capitals, and words with characters that mean something in a pattern', () async {
    await make('Weather', 'Sunny with a sun hat. Sun again. Cost (approx.) 5+5?');
    expect((await json('search_notes', {'query': 'sun'}))['total_matches'], 3);
    expect((await json('search_notes', {'query': 'sun', 'whole_word': true}))['total_matches'], 2);
    expect((await json('search_notes', {'query': 'Sun', 'case_sensitive': true}))['total_matches'], 2);
    expect((await json('search_notes', {'query': '(approx.) 5+5?'}))['total_matches'], 1, reason: 'a plain search is not a pattern');
    expect((await json('search_notes', {'query': r'\d\+\d', 'regex': true}))['total_matches'], 1);
  });

  test('a broken pattern, a missing argument and a note that is not there say what is wrong', () async {
    final (pattern, patternFailed) = await call('search_notes', {'query': '(', 'regex': true});
    expect(patternFailed, isTrue);
    expect(pattern, contains('not valid'));
    final (missingId, missingFailed) = await call('read_note', {});
    expect(missingFailed, isTrue);
    expect(missingId, contains('"note_id" is required'));
    final (gone, failed) = await call('read_note', {'note_id': 'nope'});
    expect(failed, isTrue);
    expect(gone, contains('There is no note'));
  });

  test('text is added at the end, replaced, and formatted, in a note that is not open', () async {
    final id = await make('Plan', 'First line.');
    expect((await call('append_to_note', {'note_id': id, 'text': 'Second line.'})).$2, isFalse);
    expect((await repo.loadNote(id))!.documentText, 'First line.\n\nSecond line.');

    final (replaced, failed) = await call('replace_in_note', {'note_id': id, 'find': 'First', 'replacement': 'Opening'});
    expect(failed, isFalse, reason: replaced);
    expect((await repo.loadNote(id))!.documentText, 'Opening line.\n\nSecond line.');
    final (missing, notFound) = await call('replace_in_note', {'note_id': id, 'find': 'zebra', 'replacement': 'x'});
    expect(notFound, isTrue);
    expect(missing, contains('not in the note'));

    final (formatted, bad) = await call('format_note_text', {'note_id': id, 'target': 'Opening', 'bold': true});
    expect(bad, isFalse, reason: formatted);
    expect((await repo.loadNote(id))!.documentText, '**Opening** line.\n\nSecond line.');
    expect((await call('format_note_text', {'note_id': id, 'target': 'Opening', 'wobble': true})).$2, isTrue); // not a look there is

    expect((await call('set_note_title', {'note_id': id, 'title': 'Plan B'})).$2, isFalse);
    expect((await repo.noteInfo(id))!.title, 'Plan B');
    expect((await call('set_note_text', {'note_id': id, 'text': 'All new.'})).$2, isFalse);
    expect((await repo.loadNote(id))!.documentText, 'All new.');
  });

  test('text goes after or before a line, or at the start, and the formatting can be looked at', () async {
    final id = await make('Lines', 'one\n\nthree');
    expect((await call('append_to_note', {'note_id': id, 'text': 'two', 'after': 'one'})).$2, isFalse);
    expect((await repo.loadNote(id))!.documentText, 'one\ntwo\n\nthree');
    expect((await call('append_to_note', {'note_id': id, 'text': 'zero', 'at': 'start'})).$2, isFalse);
    expect((await repo.loadNote(id))!.documentText, startsWith('zero\n'));
    final (missing, failed) = await call('append_to_note', {'note_id': id, 'text': 'x', 'before': 'zebra'});
    expect(failed, isTrue, reason: missing);

    await call('format_note_text', {'note_id': id, 'target': 'three', 'bold': true});
    final (inspected, bad) = await call('inspect_note_formatting', {'note_id': id});
    expect(bad, isFalse, reason: inspected);
    expect(inspected, contains('**three**'));
  });

  test('looking at the formatting needs no permission to change and keeps no version', () async {
    final id = await make('Look', 'text');
    canChange = false;
    versions.kept.clear();
    expect((await call('inspect_note_formatting', {'note_id': id})).$2, isFalse);
    expect(versions.kept, isEmpty);
    final editor = open[id] = _OpenEditor();
    expect((await call('inspect_note_formatting', {'note_id': id, 'target': 'text'})).$1, 'looked');
    expect(editor.calls, ['save', 'inspect: text']);
  });

  test('inserting at a place goes through the editor of a note that is open', () async {
    final id = await make('Open', 'x');
    final editor = open[id] = _OpenEditor();
    await call('append_to_note', {'note_id': id, 'text': 'new', 'after': 'x'});
    expect(editor.calls, contains('insert at: new after=x before=null start=false'));
  });

  test('every change keeps a version of the note before it and after it', () async {
    final id = await make('Versions', 'text');
    versions.kept.clear();
    await call('append_to_note', {'note_id': id, 'text': 'more'});
    expect(versions.kept, ['assistantBefore: Agent (MCP): append text', 'assistant: Agent (MCP): append text']);
  });

  test('a note that is open is changed through its editor, never in the database behind its back', () async {
    final id = await make('Open', 'in the database');
    final editor = open[id] = _OpenEditor();
    expect((await call('append_to_note', {'note_id': id, 'text': 'from the agent'})).$2, isFalse);
    expect((await call('replace_in_note', {'note_id': id, 'find': 'a', 'replacement': 'b'})).$2, isFalse);
    expect((await call('format_note_text', {'note_id': id, 'target': 'all', 'italic': true})).$2, isFalse);
    expect((await call('set_note_title', {'note_id': id, 'title': 'New'})).$2, isFalse);
    expect((await call('set_note_text', {'note_id': id, 'text': 'whole'})).$2, isFalse);
    expect(editor.calls.where((c) => c != 'save'), [
      'insert: from the agent',
      'replace: a -> b',
      'format: {"target":"all","italic":true}',
      'api title: New',
      'document: whole',
    ]);
    // saved first (what the person typed a moment ago), and again after
    expect(editor.calls.first, 'save');
    expect(editor.calls.last, 'save');
    final note = (await repo.loadNote(id))!;
    expect(note.documentText, 'in the database');
    expect(note.title, 'Open');
  });

  test('reading a note that is open saves it first', () async {
    final id = await make('Open', 'x');
    final editor = open[id] = _OpenEditor();
    await call('read_note', {'note_id': id});
    expect(editor.calls, ['save']);
    expect((await call('read_note', {'note_id': id})).$1, contains('open in the app: yes'));
  });

  test('an editor that never finishes saving fails the call cleanly, changes nothing, and does not hold up the calls after it', () async {
    final stuck = await make('Stuck', 'as it was');
    final fine = await make('Fine', 'x');
    open[stuck] = _StuckEditor();
    for (final (tool, args) in [
      ('read_note', <String, Object?>{}),
      ('append_to_note', {'text': 'more'}),
      ('replace_in_note', {'find': 'as', 'replacement': 'was'}),
    ]) {
      final (text, failed) = await call(tool, {'note_id': stuck, ...args});
      expect(failed, isTrue, reason: tool);
      expect(text, contains('did not finish saving'), reason: tool);
    }
    expect((await repo.loadNote(stuck))!.documentText, 'as it was');
    expect((await call('read_note', {'note_id': fine})).$2, isFalse, reason: 'the next call is answered');
  });

  test('a note that is open cannot be put in the trash', () async {
    final id = await make('Open');
    open[id] = _OpenEditor();
    final (text, failed) = await call('trash_note', {'note_id': id});
    expect(failed, isTrue);
    expect(text, contains('open in the app'));
    expect(await repo.noteExists(id), isTrue);
  });

  test('on a note with a PDF, or an infinite canvas, text goes into a text box', () async {
    final id = await make('Canvas');
    final note = (await repo.loadNote(id))!;
    note.pdfPath = '/nowhere.pdf';
    note.pdfName = 'nowhere.pdf';
    note.pdfPageCount = 2;
    note.textBoxes[0] = [TextBoxWidgetModel(id: 'a', position: const Offset(10, 10), initialText: 'existing')];
    await repo.saveNote(note);
    final (text, failed) = await call('append_to_note', {'note_id': id, 'text': 'added'});
    expect(failed, isFalse, reason: text);
    final after = (await repo.loadNote(id))!;
    expect(after.documentText, isEmpty);
    expect([for (final list in after.textBoxes.values) for (final b in list) b.controller.text], containsAll(['existing', 'added']));
    expect((await call('set_note_text', {'note_id': id, 'text': 'x'})).$1, contains('no written document'));
  });

  test('locked notes are never listed, found, read or changed, even when they were unlocked in this run', () async {
    final id = await make('Secret', 'the password is swordfish');
    await repo.locks.putLock(id, LockRow(mode: 1, salt: Uint8List(16), iterations: 1));
    repo.locks.unlocked.add(id);
    expect((await json('list_notes'))['total'], 0);
    expect((await json('search_notes', {'query': 'swordfish'}))['total_matches'], 0);
    for (final (tool, args) in [
      ('read_note', <String, Object?>{}),
      ('append_to_note', {'text': 'x'}),
      ('replace_in_note', {'find': 'a', 'replacement': 'b'}),
      ('set_note_title', {'title': 'x'}),
      ('move_note', <String, Object?>{}),
      ('set_note_tags', {'tags': <String>[]}),
      ('trash_note', <String, Object?>{}),
      ('set_note_favorite', <String, Object?>{}),
    ]) {
      final (text, failed) = await call(tool, {'note_id': id, ...args});
      expect(failed, isTrue, reason: tool);
      expect(text, contains('locked'), reason: tool);
    }
    expect((await repo.loadNote(id))!.documentText, 'the password is swordfish');
  });

  test('folders are made, renamed, moved and deleted, and notes are filed in them', () async {
    final school = (await call('create_folder', {'name': 'School'})).$1;
    final schoolId = RegExp(r'Its id is (\S+)\.').firstMatch(school)!.group(1)!;
    final mathsId = RegExp(r'Its id is (\S+)\.').firstMatch((await call('create_folder', {'name': 'Maths', 'parent_id': schoolId})).$1)!.group(1)!;
    final folders = (await json('list_folders'))['folders'] as List;
    expect([for (final f in folders) (f as Map)['path']], containsAll(['School', 'School / Maths']));

    final id = await make('Algebra', 'x', {'folder_id': mathsId});
    expect(((await json('list_notes', {'folder_id': mathsId}))['notes'] as List).single, containsPair('folder', 'School / Maths'));
    expect((await call('rename_folder', {'folder_id': mathsId, 'name': 'Algebra'})).$2, isFalse);
    expect((await call('move_folder', {'folder_id': schoolId, 'parent_id': mathsId})).$1, contains('itself'), reason: 'a folder cannot go into its own subfolder');
    expect((await call('move_note', {'note_id': id})).$2, isFalse);
    expect((await repo.noteInfo(id))!.folderId, isNull);
    expect((await call('move_note', {'note_id': id, 'folder_id': 'nope'})).$1, contains('no folder'));
    await call('move_note', {'note_id': id, 'folder_id': mathsId});
    expect((await call('delete_folder', {'folder_id': schoolId})).$2, isFalse);
    expect(await repo.noteExists(id), isTrue, reason: 'the notes in a deleted folder are kept');
    expect((await repo.noteInfo(id))!.folderId, isNull);
    expect((await json('list_folders'))['folders'], isEmpty);
  });

  test('tags, stars, the trash and tasks', () async {
    final id = await make('Tagged', 'x', {'tags': ['Work', 'school/maths']});
    expect(((await json('list_notes'))['notes'] as List).single['tags'], ['school/maths', 'work']);
    expect((await json('list_notes', {'tag': 'school'}))['total'], 1, reason: 'a tag is found under the tags it is nested in');
    expect((await json('list_notes', {'tag': 'other'}))['total'], 0);
    expect((await json('list_tags'))['tags'], {'school/maths': 1, 'work': 1});
    await call('set_note_tags', {'note_id': id, 'tags': ['#Done']});
    expect((await json('list_tags'))['tags'], {'done': 1});

    await call('set_note_favorite', {'note_id': id});
    expect((await json('list_notes', {'favorite': true}))['total'], 1);

    expect((await call('trash_note', {'note_id': id})).$2, isFalse);
    expect((await json('list_notes'))['total'], 0);
    expect(((await json('list_trash'))['trash'] as List).single, containsPair('id', id));
    expect((await call('read_note', {'note_id': id})).$2, isTrue);
    expect((await call('restore_note', {'note_id': id})).$2, isFalse);
    expect((await json('list_notes'))['total'], 1);
    expect((await call('restore_note', {'note_id': id})).$2, isTrue, reason: 'it is not in the trash any more');

    expect((await call('add_task', {'title': 'Hand in', 'due': '2026-12-24'})).$2, isFalse);
    expect((await call('add_task', {'title': 'Bad day', 'due': 'tomorrow'})).$2, isTrue);
    final list = (await json('list_tasks'))['tasks'] as List;
    expect(list.single, containsPair('due', '2026-12-24'));
    await call('set_task_done', {'task_id': (list.single as Map)['id']});
    expect((await json('list_tasks'))['tasks'], isEmpty);
    expect(((await json('list_tasks', {'include_done': true}))['tasks'] as List).single, containsPair('done', true));
  });

  test('while changes are off the tools that only look still work and nothing is changed', () async {
    final id = await make('Mine', 'untouched');
    canChange = false;
    final names = [for (final t in ((await protocol.handle({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}))!.body['result'] as Map)['tools'] as List) (t as Map)['name']];
    expect(names, containsAll(['list_notes', 'search_notes', 'read_note']));
    expect(names, isNot(contains('append_to_note')));
    expect(names, isNot(contains('trash_note')));
    expect((await call('append_to_note', {'note_id': id, 'text': 'x'})).$2, isTrue);
    expect((await call('read_note', {'note_id': id})).$2, isFalse);
    expect((await repo.loadNote(id))!.documentText, 'untouched');
  });

  test('the notes cannot be deleted for good through any tool', () {
    final names = McpNotes(repository: repo, tasks: tasks).tools.map((t) => t.name);
    // (what is deleted is a folder, a page, a text box, a picture or a task: never a note; the notes go to the trash)
    expect(names.where((n) => n.contains('delete') || n.contains('purge') || n.contains('empty')), unorderedEquals(['delete_folder', 'delete_page', 'delete_text_box', 'delete_image', 'delete_task']));
  });
}
