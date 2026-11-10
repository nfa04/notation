import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ai/note_agent.dart';
import '../automations/automation_service.dart' show NoteEditorHandle;
import '../data/bookmark_repository.dart';
import '../data/card_repository.dart';
import '../data/note_data.dart';
import '../data/note_repository.dart';
import '../data/tag_repository.dart';
import '../data/task_repository.dart';
import '../extensions/extension_host.dart';
import '../history/note_history.dart';
import '../reminders/reminder_service.dart';
import '../search/search_query.dart';
import '../sync/calendar_access.dart';
import '../tags/tag_names.dart';
import 'agent_editable.dart';
import 'library_api.dart';
import 'mcp_protocol.dart';
import 'stored_note_api.dart';

/// What an agent is told about the server when it connects.
const mcpInstructions = 'Notation is a note-taking app. These tools read and change the person\'s notes, folders, tags, tasks, calendar and reminders.\n'
    '- Find a note with list_notes or search_notes, read it with read_note. A note has an id; titles are not unique.\n'
    '- The text of a note is Markdown (# headings, **bold**, - lists, - [ ] tasks). Pen drawings are not text: a note shows only what was typed, '
    'and the handwriting the app has already read.\n'
    '- Locked notes are never available. Notes in the trash are not listed.\n'
    '- Every change to a note keeps a version of it before and after, which the person can restore in the app. Prefer small changes '
    '(append_to_note, replace_in_note) to rewriting a note with set_note_text.\n'
    '- A note that is open in the app is changed through its editor, as the person would.\n'
    '- A note is pages: the written document is page 1, and text boxes, pictures and drawings are placed on pages (list_pages, add_text_box, draw_shape). '
    'Positions are measured from the top left of a page. Look at list_pages before you place anything.';

/// The tools an agent outside the app works on the notes with. Reading goes to the database; changing a note that is open goes through
/// its editor (which would write over anything written behind its back), and a note that is not goes through the repository.
/// Locked notes are refused whatever the state of their lock: the person unlocked them for themselves.
class McpNotes {
  final NoteRepository repository;
  final TaskRepository tasks;
  final TagRepository? tags;

  /// Where versions before and after a change are kept; null: none are.
  final NoteHistory? history;

  /// The editor that has a note open now, if there is one.
  final NoteEditorHandle? Function(String id)? editorOf;

  /// How long an editor that has a note open is given to save it (before a change, and after).
  final Duration saveWait;

  /// What the assistant of the app reaches besides notes and tasks; null: not offered (the tools for it are left out).
  final CardRepository? cards;
  final BookmarkRepository? bookmarks;
  final CalendarAccess? calendar;
  final ReminderService? reminders;

  McpNotes({
    required this.repository,
    required this.tasks,
    this.tags,
    this.history,
    this.editorOf,
    this.saveWait = const Duration(seconds: 10),
    this.cards,
    this.bookmarks,
    this.calendar,
    this.reminders,
  });

  // ---- arguments --------------------------------------------------------------------------------------------------------------

  static const _maxText = 1000000;

  static String _text(Map<String, Object?> a, String key, {bool empty = false}) {
    final v = a[key];
    if (v is! String) throw McpToolError('"$key" is required and has to be text.');
    if (v.isEmpty && !empty) throw McpToolError('"$key" is empty.');
    if (v.length > _maxText) throw McpToolError('"$key" is too long.');
    return v;
  }

  static String? _maybe(Map<String, Object?> a, String key) {
    final v = a[key];
    if (v == null) return null;
    if (v is! String) throw McpToolError('"$key" has to be text.');
    return v.isEmpty ? null : v;
  }

  static int _int(Map<String, Object?> a, String key, int fallback, int min, int max) {
    final v = a[key];
    if (v == null) return fallback;
    if (v is! num) throw McpToolError('"$key" has to be a number.');
    return v.toInt().clamp(min, max);
  }

  static bool _flag(Map<String, Object?> a, String key, [bool fallback = false]) {
    final v = a[key];
    if (v == null) return fallback;
    if (v is! bool) throw McpToolError('"$key" has to be true or false.');
    return v;
  }

  static Map<String, Object?> _object(Map<String, Map<String, Object?>> properties, {List<String> required = const []}) =>
      {'type': 'object', 'properties': properties, if (required.isNotEmpty) 'required': required, 'additionalProperties': false};

  static Map<String, Object?> _string(String description) => {'type': 'string', 'description': description};
  static Map<String, Object?> _number(String description) => {'type': 'integer', 'description': description};
  static Map<String, Object?> _bool(String description) => {'type': 'boolean', 'description': description};
  static Map<String, Object?> _strings(String description) => {'type': 'array', 'items': {'type': 'string'}, 'description': description};

  static const _noteId = 'The id of the note (from list_notes or search_notes).';
  static String _json(Object? value) => jsonEncode(value);
  static String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ---- looking things up ------------------------------------------------------------------------------------------------------

  /// Fails unless the note exists, is not in the trash and is not locked.
  Future<void> _usable(String id) async {
    if (!await repository.noteExists(id)) throw McpToolError('There is no note with the id "$id". Use list_notes or search_notes to find one.');
    if (await repository.locks.lockModeOf(id) != 0) throw McpToolError('This note is locked. Locked notes are never available to an agent.');
  }

  Future<Map<String, FolderEntry>> _folders() async => {for (final f in await repository.listFolders()) f.id: f};

  static String _pathOf(String? id, Map<String, FolderEntry> folders) {
    final names = <String>[];
    for (var at = id; at != null && names.length < 32;) {
      final f = folders[at];
      if (f == null) break;
      names.insert(0, f.name);
      at = f.parentId;
    }
    return names.join(' / ');
  }

  Future<void> _folder(String? id) async {
    if (id != null && !(await _folders()).containsKey(id)) throw McpToolError('There is no folder with the id "$id". Use list_folders to find one.');
  }

  // ---- reading ----------------------------------------------------------------------------------------------------------------

  Future<String> _listNotes(Map<String, Object?> a) async {
    final folder = _maybe(a, 'folder_id');
    final tag = _maybe(a, 'tag');
    final favorite = _flag(a, 'favorite');
    final limit = _int(a, 'limit', 50, 1, 200), offset = _int(a, 'offset', 0, 0, 1 << 30);
    final folders = await _folders();
    final allTags = await tags?.all() ?? const <String, Set<String>>{};
    Set<String>? tagged;
    if (tag != null) {
      final t = normalizeTag(tag);
      if (t == null) throw McpToolError('"$tag" is not a tag.');
      tagged = await tags?.notesWith(t) ?? {};
    }
    final found = [
      for (final n in await repository.listNotes())
        if (!n.locked && (folder == null || n.folderId == folder) && (!favorite || n.favorite) && (tagged == null || tagged.contains(n.id))) n,
    ];
    return _json({
      'total': found.length,
      'notes': [
        for (final n in found.skip(offset).take(limit))
          {
            'id': n.id,
            'title': n.title,
            'folder_id': n.folderId,
            if (n.folderId != null) 'folder': _pathOf(n.folderId, folders),
            'tags': (allTags[n.id] ?? const <String>{}).toList()..sort(),
            'favorite': n.favorite,
            'kind': n.isPdf ? 'pdf' : 'note',
            'edited': n.updatedAt.toIso8601String(),
          },
      ],
    });
  }

  static const _placeNames = {
    SearchPlace.title: 'title',
    SearchPlace.pdfName: 'pdf name',
    SearchPlace.document: 'document',
    SearchPlace.textBox: 'text box',
    SearchPlace.pdfText: 'pdf text',
    SearchPlace.handwriting: 'handwriting',
  };

  Future<String> _searchNotes(Map<String, Object?> a) async {
    final query = SearchQuery(_text(a, 'query'), regex: _flag(a, 'regex'), caseSensitive: _flag(a, 'case_sensitive'), wholeWord: _flag(a, 'whole_word'));
    final problem = query.problem;
    if (problem != null) throw McpToolError('That pattern is not valid: $problem');
    final limit = _int(a, 'limit', 20, 1, 100);
    final SearchResults results;
    try {
      results = await RunningSearch.start(query, await repository.text.searchSources(), perNote: 4).results;
    } on SearchTooSlow {
      throw McpToolError('The search took too long. Try a simpler pattern.');
    }
    final titles = {for (final n in await repository.listNotes()) n.id: n.title};
    final byNote = <String, List<SearchHit>>{};
    for (final h in results.hits) {
      (byNote[h.noteId] ??= []).add(h);
    }
    return _json({
      'total_matches': results.total,
      'notes_with_matches': byNote.length,
      'notes': [
        for (final e in byNote.entries.take(limit))
          {
            'id': e.key,
            'title': titles[e.key] ?? '',
            'matches': results.countByNote[e.key] ?? e.value.length,
            'snippets': [
              for (final h in e.value)
                {'in': _placeNames[h.place], if (h.page >= 0) 'page': h.page + 1, 'text': '${h.before}[[${h.match}]]${h.after}'},
            ],
          },
      ],
      if (results.cutOff) 'note': 'There are more matches than are shown.',
    });
  }

  Future<String> _readNote(Map<String, Object?> a) async {
    final id = _text(a, 'note_id');
    final max = _int(a, 'max_chars', 40000, 1000, 400000);
    await _usable(id);
    final open = editorOf?.call(id);
    if (open != null) await _saveOpen(open); // (what the person typed a moment ago is not in the database yet)
    final info = await repository.noteInfo(id);
    final times = await repository.noteTimes(id);
    final folders = await _folders();
    final sources = await repository.text.searchSources(noteId: id);
    final noteTags = await tags?.tagsOf(id) ?? const <String>[];
    final b = StringBuffer()
      ..writeln('# ${info?.title ?? ''}')
      ..writeln('id: $id');
    if (info?.folderId != null) b.writeln('folder: ${_pathOf(info!.folderId, folders)} (${info.folderId})');
    if (noteTags.isNotEmpty) b.writeln('tags: ${noteTags.join(', ')}');
    if (info?.pdfName != null) b.writeln('pdf: ${info!.pdfName}');
    if (times != null) b.writeln('created: ${times.created.toIso8601String()}\nedited: ${times.edited.toIso8601String()}');
    if (open != null) b.writeln('open in the app: yes');
    SearchSource? only(SearchPlace p) => sources.where((s) => s.place == p).firstOrNull;
    final document = only(SearchPlace.document);
    if (document != null) b..writeln('\n## Document')..writeln(document.text);
    void pages(SearchPlace place, String heading) {
      final list = sources.where((s) => s.place == place).toList();
      if (list.isEmpty) return;
      b.writeln('\n## $heading');
      for (final s in list) {
        b.writeln('(page ${s.page + 1})\n${s.text}\n');
      }
    }

    pages(SearchPlace.textBox, 'Text boxes');
    pages(SearchPlace.pdfText, 'Text of the PDF');
    pages(SearchPlace.handwriting, 'Handwriting, as read by the app');
    if (document == null && !sources.any((s) => s.place != SearchPlace.title && s.place != SearchPlace.pdfName)) b.writeln('\n(The note has no text.)');
    final text = b.toString().trimRight();
    return text.length <= max ? text : '${text.substring(0, max)}\n\n[Cut off after $max of ${text.length} characters.]';
  }

  Future<String> _listFolders(Map<String, Object?> a) async {
    final folders = await _folders();
    return _json({
      'folders': [
        for (final f in folders.values) {'id': f.id, 'name': f.name, 'parent_id': f.parentId, 'path': _pathOf(f.id, folders), 'notes': f.noteCount},
      ],
    });
  }

  Future<String> _listTags(Map<String, Object?> a) async => _json({'tags': await tags?.counts() ?? const <String, int>{}});

  Future<String> _listTasks(Map<String, Object?> a) async {
    final all = _flag(a, 'include_done');
    return _json({
      'tasks': [
        for (final t in await tasks.listTasks())
          if (all || !t.done) {'id': t.id, 'title': t.title, 'due': t.dueDate == null ? null : _day(t.dueDate!), 'done': t.done},
      ],
    });
  }

  Future<String> _listTrash(Map<String, Object?> a) async => _json({
        'trash': [
          for (final t in await repository.listTrash())
            if (t.lockMode == 0) {'id': t.id, 'title': t.title, 'deleted': t.deletedAt.toIso8601String(), 'kind': t.isPdf ? 'pdf' : 'note'},
        ],
      });

  // ---- changing a note --------------------------------------------------------------------------------------------------------

  Future<void> _saveOpen(NoteEditorHandle open) async {
    // (calls run one at a time: an editor that never answers must not hold up every call after this one)
    try {
      await (() async {
        await open.ready;
        await open.saveNow();
      })()
          .timeout(saveWait);
    } on TimeoutException {
      throw McpToolError('The note is open in the app and did not finish saving, so nothing was changed. Try again in a moment.');
    } catch (e) {
      throw McpToolError('The note is open in the app and could not be saved: $e');
    }
  }

  Future<void> _keep(VersionReason reason, String id, String what) async {
    try {
      await history?.snapshot(id, reason: reason, label: 'Agent (MCP): $what');
    } catch (e) {
      debugPrint('could not keep a version for an agent: $e'); // (a note that keeps no versions does not hold the agent up)
    }
  }

  /// Does [change] to note [id], with a version of the note kept before and after. [open] is the editor that has the note open, if one
  /// has; [change] has to go through it then.
  Future<T> _edit<T>(String id, String what, Future<T> Function(NoteEditorHandle? open) change) async {
    await _usable(id);
    final open = editorOf?.call(id);
    if (open != null) await _saveOpen(open);
    await _keep(VersionReason.assistantBefore, id, what);
    final T out;
    try {
      out = await change(open);
    } on ExtensionError catch (e) {
      throw McpToolError(e.message);
    }
    if (open != null) await _saveOpen(open);
    await _keep(VersionReason.assistant, id, what);
    return out;
  }

  AgentEditable _editable(NoteEditorHandle open) {
    if (open is AgentEditable) return open as AgentEditable;
    throw McpToolError('The note is open in a view that cannot be changed from outside. Close it in the app and try again.');
  }

  /// The names the assistant has for its tools, and what they are called here: its descriptions send the model from one to another.
  static const _names = {
    'note.insertText': 'append_to_note',
    'note.replaceText': 'replace_in_note',
    'note.format': 'format_note_text',
    'note.inspect': 'inspect_note_formatting',
    'note.setTitle': 'set_note_title',
    'note.resolveChanges': 'resolve_tracked_changes',
    'note.get': 'read_note',
    'notes.search': 'search_notes',
    'notes.read': 'read_note',
    'notes.list': 'list_notes',
    'pdf.read': 'read_pdf',
    'pdf.search': 'search_pdf',
    'pages.list': 'list_pages',
    'pages.add': 'add_page',
    'pages.delete': 'delete_page',
    'pages.move': 'move_page',
    'pages.setup': 'set_up_pages',
    'textBoxes.list': 'list_text_boxes',
    'textBoxes.add': 'add_text_box',
    'textBoxes.move': 'move_text_box',
    'textBoxes.delete': 'delete_text_box',
    'images.list': 'list_images',
    'images.move': 'move_image',
    'images.delete': 'delete_image',
    'draw.shape': 'draw_shape',
    'draw.strokes': 'draw_strokes',
    'tasks.list': 'list_tasks',
    'tasks.update': 'update_task',
    'reminders.list': 'list_reminders',
    'note_inspect': 'inspect_note_formatting',
  };

  static final _namesIn = RegExp((_names.keys.toList()..sort((a, b) => b.length.compareTo(a.length))).map(RegExp.escape).join('|'));

  /// [text] with the assistant's names of tools as they are here.
  static String _named(String text) => text.replaceAllMapped(_namesIn, (m) => _names[m[0]]!);

  /// [value] (a JSON schema) with the descriptions in it put through [_named].
  static Object? _renamed(Object? value) {
    if (value is Map) return {for (final e in value.entries) e.key: e.key == 'description' && e.value is String ? _named(e.value as String) : _renamed(e.value)};
    if (value is List) return [for (final v in value) _renamed(v)];
    return value;
  }

  /// A tool of the assistant in the editor ([agentTools]) made into one for a note of the person's choice: the same arguments, checks and
  /// work, with the id of the note added. A note that is open is changed through its editor, one that is not through [StoredNoteApi].
  /// [drop] are arguments of the assistant's tool that are left out (they are about another note: here every call names its note).
  McpTool _viaAssistant(String agentName, {required String name, required String what, bool changes = true, Set<String> drop = const {}}) {
    final tool = agentTools.firstWhere((t) => t.name == agentName);
    final parameters = tool.parameters ?? _object({});
    final properties = (parameters['properties'] as Map).cast<String, Object?>();
    return McpTool(
      name: name,
      description: 'In a note: ${_named(tool.spec.description)}',
      inputSchema: {
        ...parameters,
        'properties': _renamed({'note_id': _string(_noteId), for (final e in properties.entries) if (!drop.contains(e.key)) e.key: e.value}),
        'required': ['note_id', ...?(parameters['required'] as List?)?.cast<String>()],
        'additionalProperties': false,
      },
      changes: changes,
      run: (a) async {
        final id = _text(a, 'note_id');
        final args = {...a}
          ..remove('note_id')
          ..removeWhere((k, _) => drop.contains(k));
        try {
          tool.describe(args); // (checks the arguments before anything is kept)
        } on ExtensionError catch (e) {
          throw McpToolError(e.message);
        }
        Future<String> go(NoteEditorHandle? open) =>
            tool.run(open == null ? StoredNoteApi(repository, id, cards: cards, bookmarks: bookmarks) : _editable(open).agentApi, args);
        if (changes) return _edit(id, what, go);
        await _usable(id);
        final open = editorOf?.call(id);
        if (open != null) await _saveOpen(open);
        try {
          return await go(open);
        } on ExtensionError catch (e) {
          throw McpToolError(e.message);
        }
      },
    );
  }

  /// A tool of the assistant that is about the person's tasks, calendar or reminders rather than a note, as a tool. A reminder can be
  /// about a note (it opens it when tapped): that is a "note_id" here.
  McpTool _viaLibrary(String agentName, {required String name, bool changes = true, bool destructive = false}) {
    final tool = agentTools.firstWhere((t) => t.name == agentName);
    final aboutNote = agentName == 'reminders.add';
    final parameters = tool.parameters ?? _object({});
    final properties = (parameters['properties'] as Map).cast<String, Object?>();
    return McpTool(
      name: name,
      description: _named(tool.spec.description),
      inputSchema: {
        ...parameters,
        'properties': _renamed({
          for (final e in properties.entries)
            if (aboutNote && e.key == 'aboutNote') 'note_id': _string('A note the reminder is about: tapping the reminder opens it.') else e.key: e.value,
        }),
        'additionalProperties': false,
      },
      changes: changes,
      destructive: destructive,
      run: (a) async {
        final args = {...a};
        String? note;
        if (aboutNote) {
          note = _maybe(a, 'note_id');
          args.remove('note_id');
          if (note != null) {
            await _usable(note);
            args['aboutNote'] = true;
          }
        }
        try {
          tool.describe(args);
          return await tool.run(McpLibraryApi(tasks: tasks, calendar: calendar, reminders: reminders, aboutNoteId: note), args);
        } on ExtensionError catch (e) {
          throw McpToolError(e.message);
        }
      },
    );
  }

  /// The assistant's `tasks.add`, as a tool.
  McpTool _viaTasks() {
    final tool = agentTools.firstWhere((t) => t.name == 'tasks.add');
    return McpTool(
      name: 'add_task',
      description: 'Adds a task (to-do) to the person\'s calendar; "due" is a day like 2026-12-24.',
      inputSchema: tool.parameters!,
      changes: true,
      run: (a) async {
        try {
          tool.describe(a);
          final api = _TaskApi(tasks);
          final said = await tool.run(api, a);
          return api.created == null ? said : '$said Its id is ${api.created}.';
        } on ExtensionError catch (e) {
          throw McpToolError(e.message);
        }
      },
    );
  }

  Future<String> _setText(Map<String, Object?> a) async {
    final id = _text(a, 'note_id'), text = _text(a, 'text', empty: true);
    return _edit(id, 'rewrite the text', (open) async {
      if (open == null) {
        await StoredNoteApi(repository, id).setDocument(text);
      } else {
        await _editable(open).agentSetDocument(text);
      }
      return 'Replaced the text of the note.';
    });
  }

  Future<String> _createNote(Map<String, Object?> a) async {
    final title = _maybe(a, 'title') ?? 'Untitled Note';
    final text = a['text'] == null ? '' : _text(a, 'text', empty: true);
    final folder = _maybe(a, 'folder_id');
    final noteTags = a['tags'];
    if (noteTags != null && (noteTags is! List || noteTags.any((t) => t is! String))) throw McpToolError('"tags" has to be a list of text.');
    await _folder(folder);
    final id = await repository.createNote(title: title, folderId: folder);
    if (text.isNotEmpty) {
      final note = (await repository.loadNote(id))!;
      note.documentText = text;
      await repository.saveNote(note);
    }
    if (noteTags != null) await tags?.setTags(id, (noteTags as List).cast<String>());
    return 'Made the note "$title". Its id is $id.';
  }

  // ---- organising -------------------------------------------------------------------------------------------------------------

  Future<String> _move(Map<String, Object?> a) async {
    final id = _text(a, 'note_id'), folder = _maybe(a, 'folder_id');
    await _usable(id);
    await _folder(folder);
    await repository.moveNote(id, folder);
    return folder == null ? 'The note is in no folder now.' : 'Moved the note into the folder.';
  }

  Future<String> _trash(Map<String, Object?> a) async {
    final id = _text(a, 'note_id');
    await _usable(id);
    if (editorOf?.call(id) != null) throw McpToolError('The note is open in the app. Close it there first.');
    await repository.trashNote(id);
    return 'The note is in the trash. The person can bring it back there, and so can restore_note.';
  }

  Future<String> _restore(Map<String, Object?> a) async {
    final id = _text(a, 'note_id');
    final gone = [for (final t in await repository.listTrash()) if (t.lockMode == 0) t.id];
    if (!gone.contains(id)) throw McpToolError('There is no such note in the trash. Use list_trash to see what is there.');
    await repository.restoreNote(id);
    return 'The note is back.';
  }

  Future<String> _favorite(Map<String, Object?> a) async {
    final id = _text(a, 'note_id'), on = _flag(a, 'favorite', true);
    await _usable(id);
    await repository.setFavorite(id, on);
    return on ? 'The note is starred.' : 'The star is taken off the note.';
  }

  Future<String> _setTags(Map<String, Object?> a) async {
    final id = _text(a, 'note_id');
    final list = a['tags'];
    if (list is! List || list.any((t) => t is! String)) throw McpToolError('"tags" has to be a list of text.');
    final tagRepository = tags;
    if (tagRepository == null) throw McpToolError('Tags are not available.');
    await _usable(id);
    await tagRepository.setTags(id, list.cast<String>());
    return 'The tags of the note are now: ${(await tagRepository.tagsOf(id)).join(', ')}.';
  }

  Future<String> _createFolder(Map<String, Object?> a) async {
    final name = _text(a, 'name'), parent = _maybe(a, 'parent_id');
    await _folder(parent);
    return 'Made the folder "$name". Its id is ${await repository.createFolder(name, parentId: parent)}.';
  }

  Future<String> _renameFolder(Map<String, Object?> a) async {
    final id = _text(a, 'folder_id'), name = _text(a, 'name');
    await _folder(id);
    await repository.renameFolder(id, name);
    return 'The folder is now called "$name".';
  }

  Future<String> _moveFolder(Map<String, Object?> a) async {
    final id = _text(a, 'folder_id'), parent = _maybe(a, 'parent_id');
    await _folder(id);
    await _folder(parent);
    try {
      await repository.moveFolder(id, parent);
    } on ArgumentError catch (e) {
      throw McpToolError('${e.message}');
    }
    return 'Moved the folder.';
  }

  Future<String> _deleteFolder(Map<String, Object?> a) async {
    final id = _text(a, 'folder_id');
    await _folder(id);
    await repository.deleteFolder(id);
    return 'Deleted the folder and the folders in it. The notes that were in them are kept, in no folder.';
  }

  Future<String> _taskDone(Map<String, Object?> a) async {
    final id = _text(a, 'task_id'), done = _flag(a, 'done', true);
    if (!(await tasks.listTasks()).any((t) => t.id == id)) throw McpToolError('There is no task with the id "$id". Use list_tasks to find one.');
    await tasks.setDone(id, done);
    return done ? 'The task is done.' : 'The task is open again.';
  }

  // ---- the list ---------------------------------------------------------------------------------------------------------------

  late final List<McpTool> tools = [
    McpTool(
      name: 'list_notes',
      description: 'Lists notes, the most recently edited first: id, title, folder, tags, kind (note or pdf). Locked notes and notes in the trash are left out.',
      inputSchema: _object({
        'folder_id': _string('Only the notes directly in this folder.'),
        'tag': _string('Only notes with this tag (or a tag nested under it).'),
        'favorite': _bool('Only starred notes.'),
        'limit': _number('At most this many (default 50, up to 200).'),
        'offset': _number('Skip this many (to read the next page).'),
      }),
      run: _listNotes,
    ),
    McpTool(
      name: 'search_notes',
      description: 'Searches the text of all notes (titles, written documents, text boxes, the text of PDFs and handwriting the app has read) and gives the notes '
          'that match with snippets; the match is marked [[like this]].',
      inputSchema: _object({
        'query': _string('What to look for.'),
        'regex': _bool('The query is a regular expression.'),
        'case_sensitive': _bool('Capitals matter.'),
        'whole_word': _bool('Only whole words.'),
        'limit': _number('At most this many notes (default 20).'),
      }, required: ['query']),
      run: _searchNotes,
    ),
    McpTool(
      name: 'read_note',
      description: 'Reads a note: title, folder, tags, dates and all of its text (the written document, text boxes by page, the text of a PDF, handwriting the app has read).',
      inputSchema: _object({'note_id': _string(_noteId), 'max_chars': _number('Cut the text off after this many characters (default 40000).')}, required: ['note_id']),
      run: _readNote,
    ),
    McpTool(name: 'list_folders', description: 'Lists all folders with their id, name, parent and path.', inputSchema: _object({}), run: _listFolders),
    McpTool(name: 'list_tags', description: 'Lists the tags in use with the number of notes that have each. Tags nest with "/" ("school/maths").', inputSchema: _object({}), run: _listTags),
    McpTool(
      name: 'list_tasks',
      description: 'Lists the tasks (to-dos) of the person, with their due day.',
      inputSchema: _object({'include_done': _bool('Also the tasks that are done.')}),
      run: _listTasks,
    ),
    McpTool(name: 'list_trash', description: 'Lists the notes in the trash.', inputSchema: _object({}), run: _listTrash),
    McpTool(
      name: 'create_note',
      description: 'Makes a new note, with text if you give it (Markdown), in a folder and with tags if you like.',
      inputSchema: _object({
        'title': _string('The title.'),
        'text': _string('The text, in Markdown.'),
        'folder_id': _string('The folder to put it in.'),
        'tags': _strings('Tags to give it.'),
      }),
      changes: true,
      run: _createNote,
    ),
    McpTool(
      name: 'set_note_text',
      description: 'Replaces the whole written document of a note with new text (Markdown). The formatting of the old text is lost; a version of the note is kept, but '
          'prefer append_to_note and replace_in_note for small changes.',
      inputSchema: _object({'note_id': _string(_noteId), 'text': _string('The new text.')}, required: ['note_id', 'text']),
      changes: true,
      destructive: true,
      run: _setText,
    ),
    _viaAssistant('note.insertText', name: 'append_to_note', what: 'append text'),
    _viaAssistant('note.replaceText', name: 'replace_in_note', what: 'replace text'),
    _viaAssistant('note.format', name: 'format_note_text', what: 'format text'),
    _viaAssistant('note.setTitle', name: 'set_note_title', what: 'change the title'),
    _viaAssistant('note.inspect', name: 'inspect_note_formatting', what: 'look at the formatting', changes: false),
    _viaAssistant('note.resolveChanges', name: 'resolve_tracked_changes', what: 'settle tracked changes'),
    _viaAssistant('pdf.read', name: 'read_pdf', what: 'read the PDF', changes: false, drop: {'id'}),
    _viaAssistant('pdf.search', name: 'search_pdf', what: 'search the PDF', changes: false, drop: {'id'}),
    if (cards != null) _viaAssistant('cards.add', name: 'add_flashcards', what: 'make flashcards'),
    _viaAssistant('pages.list', name: 'list_pages', what: 'look at the pages', changes: false),
    _viaAssistant('pages.add', name: 'add_page', what: 'add a page'),
    _viaAssistant('pages.delete', name: 'delete_page', what: 'delete a page'),
    _viaAssistant('pages.move', name: 'move_page', what: 'move a page'),
    _viaAssistant('pages.setup', name: 'set_up_pages', what: 'set up the paper'),
    _viaAssistant('textBoxes.list', name: 'list_text_boxes', what: 'look at the text boxes', changes: false),
    _viaAssistant('textBoxes.add', name: 'add_text_box', what: 'add a text box'),
    _viaAssistant('textBoxes.move', name: 'move_text_box', what: 'move a text box'),
    _viaAssistant('textBoxes.delete', name: 'delete_text_box', what: 'delete a text box'),
    _viaAssistant('images.list', name: 'list_images', what: 'look at the pictures', changes: false),
    _viaAssistant('images.move', name: 'move_image', what: 'move a picture'),
    _viaAssistant('images.delete', name: 'delete_image', what: 'delete a picture'),
    _viaAssistant('draw.shape', name: 'draw_shape', what: 'draw a shape'),
    _viaAssistant('draw.strokes', name: 'draw_strokes', what: 'draw lines'),
    McpTool(
      name: 'move_note',
      description: 'Moves a note into a folder, or out of all folders when folder_id is left out.',
      inputSchema: _object({'note_id': _string(_noteId), 'folder_id': _string('The folder; leave out for no folder.')}, required: ['note_id']),
      changes: true,
      run: _move,
    ),
    McpTool(
      name: 'set_note_tags',
      description: 'Makes the given tags the tags of a note (the ones it has now are replaced). Use list_notes to see the tags it has.',
      inputSchema: _object({'note_id': _string(_noteId), 'tags': _strings('The tags, like "work" or "school/maths".')}, required: ['note_id', 'tags']),
      changes: true,
      run: _setTags,
    ),
    McpTool(
      name: 'set_note_favorite',
      description: 'Stars a note, or takes the star away.',
      inputSchema: _object({'note_id': _string(_noteId), 'favorite': _bool('true stars it (the default), false takes the star away.')}, required: ['note_id']),
      changes: true,
      run: _favorite,
    ),
    McpTool(
      name: 'trash_note',
      description: 'Puts a note in the trash, where it stays for 30 days and can be brought back. A note that is open in the app cannot be.',
      inputSchema: _object({'note_id': _string(_noteId)}, required: ['note_id']),
      changes: true,
      run: _trash,
    ),
    McpTool(
      name: 'restore_note',
      description: 'Brings a note back from the trash.',
      inputSchema: _object({'note_id': _string('The id of the note (from list_trash).')}, required: ['note_id']),
      changes: true,
      run: _restore,
    ),
    McpTool(
      name: 'create_folder',
      description: 'Makes a folder, inside another one if parent_id is given.',
      inputSchema: _object({'name': _string('The name.'), 'parent_id': _string('The folder to make it in.')}, required: ['name']),
      changes: true,
      run: _createFolder,
    ),
    McpTool(
      name: 'rename_folder',
      description: 'Renames a folder.',
      inputSchema: _object({'folder_id': _string('The folder.'), 'name': _string('The new name.')}, required: ['folder_id', 'name']),
      changes: true,
      run: _renameFolder,
    ),
    McpTool(
      name: 'move_folder',
      description: 'Moves a folder into another folder, or to the top when parent_id is left out.',
      inputSchema: _object({'folder_id': _string('The folder.'), 'parent_id': _string('The folder to move it into.')}, required: ['folder_id']),
      changes: true,
      run: _moveFolder,
    ),
    McpTool(
      name: 'delete_folder',
      description: 'Deletes a folder and the folders in it. The notes in them are kept, in no folder.',
      inputSchema: _object({'folder_id': _string('The folder.')}, required: ['folder_id']),
      changes: true,
      destructive: true,
      run: _deleteFolder,
    ),
    _viaTasks(),
    McpTool(
      name: 'set_task_done',
      description: 'Ticks a task off, or opens it again.',
      inputSchema: _object({'task_id': _string('The id of the task (from list_tasks).'), 'done': _bool('true ticks it off (the default).')}, required: ['task_id']),
      changes: true,
      run: _taskDone,
    ),
    _viaLibrary('tasks.update', name: 'update_task'),
    _viaLibrary('tasks.remove', name: 'delete_task', destructive: true),
    if (calendar != null) _viaLibrary('calendar.events', name: 'list_calendar_events', changes: false),
    if (calendar != null) _viaLibrary('calendar.addEvent', name: 'add_calendar_event'),
    if (reminders != null) _viaLibrary('reminders.list', name: 'list_reminders', changes: false),
    if (reminders != null) _viaLibrary('reminders.add', name: 'add_reminder'),
    if (reminders != null) _viaLibrary('reminders.remove', name: 'remove_reminder', destructive: true),
  ];
}

/// The part of the assistant's API that adds a task, done on the task list.
class _TaskApi extends ExtensionApi {
  final TaskRepository tasks;

  /// The id of the task that was made.
  String? created;

  _TaskApi(this.tasks);

  @override
  Future<void> addTask(String title, {String? due}) async {
    created = await tasks.createTask(title, dueDate: due == null ? null : DateTime.parse(due));
  }
}
