import 'draw_result.dart';
import 'draw_shapes.dart';
import 'dart:ui' show Color;
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'extension_manifest.dart';
import 'isolate_engine.dart';
import 'script_engine.dart';

/// Something an extension asked for that cannot be done (not allowed, not possible here, not valid): the script gets it as an
/// error it can catch.
class ExtensionError implements Exception {
  final String message;
  ExtensionError(this.message);
  @override
  String toString() => message;
}

/// What an extension can do in the place where it is run (the editor with a selection, an automation after an event). What a
/// place cannot do fails with [ExtensionError]; the permissions are checked before these are called.
abstract class ExtensionApi {
  /// The note: `id`, `title` and `text`.
  Future<Map<String, Object?>> note() async => throw ExtensionError('There is no note here.');

  /// Puts text into the note (at the end, or where the cursor is).
  Future<void> insertText(String text) async => throw ExtensionError('Text cannot be inserted here.');

  /// Replaces what is selected.
  Future<void> replaceSelection(String text) async => throw ExtensionError('There is no selection here.');

  /// Replaces [find] in the text of the note with [replacement] (with [all]: everywhere) and says how many times it did.
  Future<int> replaceText(String find, String replacement, {bool all = false}) async => throw ExtensionError('Text cannot be replaced here.');

  /// Formats text of the note as [options] says (see `NoteFormat`) and says what came of it.
  Future<String> formatText(Map<String, Object?> options) async => throw ExtensionError('Text cannot be formatted here.');

  Future<void> setTitle(String title) async => throw ExtensionError('The title cannot be changed here.');

  /// Puts text into the note at its start ([atStart]), or on a line of its own after or before the line [after] / [before] (text of the
  /// note) is on; without any of them at the end, as [insertText].
  Future<void> insertTextAt(String text, {String? after, String? before, bool atStart = false}) async => throw ExtensionError('Text cannot be inserted here.');

  /// How the text of the note is formatted, as lines in the Markdown they are written in and the looks kept beside them (font, size,
  /// colour...); [target] is `all`, `selection` or text of the note.
  Future<String> inspectText(String target) async => throw ExtensionError('The formatting cannot be looked at here.');

  /// The notes that have all the words of [query]: `id`, `title` and `snippet` of each, the best first.
  Future<List<Map<String, Object?>>> searchNotes(String query, {int limit = 10}) async => throw ExtensionError('Notes cannot be searched here.');

  /// Another note: `id`, `title` and `text`.
  Future<Map<String, Object?>> readNote(String id) async => throw ExtensionError('Notes cannot be read here.');

  /// Makes a note with [title] and [text] (Markdown), in the folder called [folder] if given; says its id.
  Future<String> createNote(String title, String text, {String? folder}) async => throw ExtensionError('Notes cannot be created here.');

  /// Gives the note the tags [tags] (the ones it has stay).
  Future<void> addTags(List<String> tags) async => throw ExtensionError('Tags cannot be set here.');

  /// Moves the note into the folder called [folder] (null: out of all folders).
  Future<void> moveToFolder(String? folder) async => throw ExtensionError('The note cannot be moved here.');

  /// Settles the tracked changes of the note (`{++put in++}` and `{--taken out--}`): accepts them ([accept]) or rejects them; says how many.
  Future<int> resolveChanges({required bool accept}) async => throw ExtensionError('Changes cannot be settled here.');

  /// Stars the note [id], or takes the star away.
  Future<void> favoriteNote(String id, bool on) async => throw ExtensionError('Notes cannot be starred here.');

  /// The text of the pages [from] to [to] (from 1) of the PDF of this note, or of the note [id] (its PDF as it was read by the app),
  /// each under "Page N:", cut after about 12 000 characters with a line that says where to go on.
  Future<String> readPdf({String? id, int? from, int? to}) async => throw ExtensionError('PDFs cannot be read here.');

  /// The pages of the PDF of this note (or of the note [id]) that have all the words of [query]: `page` (from 1) and a `snippet`.
  Future<List<Map<String, Object?>>> searchPdf(String query, {String? id}) async => throw ExtensionError('PDFs cannot be searched here.');

  /// The folders: `name`, `parent` (the name of the folder it is in, or null) and how many `notes` are in it.
  Future<List<Map<String, Object?>>> listFolders() async => throw ExtensionError('Folders cannot be looked at here.');

  /// Makes a folder called [name], inside the folder called [parent] if given.
  Future<void> createFolder(String name, {String? parent}) async => throw ExtensionError('Folders cannot be made here.');

  /// Gives the folder called [name] the name [newName].
  Future<void> renameFolder(String name, String newName) async => throw ExtensionError('Folders cannot be renamed here.');

  /// The notes, the last changed first: `id`, `title`, `folder` (its name or null) and `updated` (a day); only those in the folder
  /// called [folder] if given.
  Future<List<Map<String, Object?>>> listNotes({String? folder, int limit = 20}) async => throw ExtensionError('Notes cannot be listed here.');

  /// Moves the note [id] into the folder called [folder] (null: out of all folders).
  Future<void> moveNoteTo(String id, String? folder) async => throw ExtensionError('Notes cannot be moved here.');

  /// Gives the note [id] the tags [tags] (the ones it has stay).
  Future<void> tagNote(String id, List<String> tags) async => throw ExtensionError('Tags cannot be set here.');

  /// Puts the note [id] in the trash, from where it can be brought back; or brings it back.
  Future<void> trashNote(String id) async => throw ExtensionError('Notes cannot be put in the trash here.');
  Future<void> restoreNote(String id) async => throw ExtensionError('Notes cannot be brought back here.');

  /// The events of the days [from] to [to] (`YYYY-MM-DD`, inclusive; at most 62 days) of the calendars: `title`, `start`, `end` (a day
  /// for an all-day event, else a time like `2026-12-24T09:30`; null when unknown), `allDay` and `calendar`.
  Future<List<Map<String, Object?>>> listEvents(String from, String to) async => throw ExtensionError('The calendar cannot be looked at here.');

  /// Adds an event: [start] and [end] are times like `2026-12-24T09:30` (the end one hour after the start if missing), or days for
  /// an [allDay] event (the end is its last day). It goes to the calendar called [calendar], or the first one that can take events.
  Future<void> addEvent(String title, String start, {String? end, bool allDay = false, String? calendar, String? description}) async =>
      throw ExtensionError('Events cannot be added here.');

  /// Sets a reminder: [text] shown at [at] (a time like `2026-12-24T09:30`), once or [repeat]ed (`daily`, `weekly`, `monthly` or
  /// `yearly`); with [aboutNote] it opens this note when tapped. Says its id.
  Future<String> addReminder(String text, String at, {String repeat = 'once', bool aboutNote = false}) async => throw ExtensionError('Reminders cannot be set here.');

  /// The reminders the person set: `id`, `text`, `at`, `repeat`.
  Future<List<Map<String, Object?>>> listReminders() async => throw ExtensionError('Reminders cannot be looked at here.');

  Future<void> removeReminder(String id) async => throw ExtensionError('Reminders cannot be removed here.');

  /// Keeps flashcards (`front` and `back`) of this note for review; says how many were new (one with a question that is there
  /// already is not added again).
  Future<int> addCards(List<Map<String, String>> cards) async => throw ExtensionError('Flashcards cannot be made here.');

  /// The text boxes on the pages: `id`, `page`, `x`, `y`, `width` (in page units, from the top left of the page) and the `text`.
  Future<List<Map<String, Object?>>> textBoxes() async => throw ExtensionError('The text boxes cannot be looked at here.');

  /// Puts a text box on page number [page] (from 1; default the page in view) at [x], [y]; says its id.
  Future<String> addTextBox(String text, {int? page, double? x, double? y, double? width}) async => throw ExtensionError('Text boxes cannot be added here.');

  /// Moves the text box [id] to [page] / [x] / [y], and/or gives it the [width].
  Future<void> moveTextBox(String id, {int? page, double? x, double? y, double? width}) async => throw ExtensionError('Text boxes cannot be moved here.');

  Future<void> deleteTextBox(String id) async => throw ExtensionError('Text boxes cannot be deleted here.');

  /// The pictures on the pages: `id`, `page`, `x`, `y`, `width`, `height`.
  Future<List<Map<String, Object?>>> images() async => throw ExtensionError('The pictures cannot be looked at here.');

  /// Moves the picture [id] to [page] / [x] / [y], and/or gives it the [width] (the height follows).
  Future<void> moveImage(String id, {int? page, double? x, double? y, double? width}) async => throw ExtensionError('Pictures cannot be moved here.');

  Future<void> deleteImage(String id) async => throw ExtensionError('Pictures cannot be deleted here.');

  /// Draws lines (`{points: [[x, y], ...], color, width, dash, fill}`) on page number [page] (from 1; default the page in view); says how many.
  Future<int> drawStrokes(List<Map<String, Object?>> strokes, {int? page}) async => throw ExtensionError('Nothing can be drawn here.');

  /// Sets up the paper: `paper`, `orientation`, `background` and `margins` (see the docs); says what was set.
  Future<String> setupPage(Map<String, Object?> options) async => throw ExtensionError('The paper cannot be set up here.');

  /// The pages of the note: `page` (from 1), `kind` (`written` for the page with the written document, `pdf` or `notebook`) and
  /// how many `strokes`, `textBoxes` and `images` are on it.
  Future<List<Map<String, Object?>>> pages() async => throw ExtensionError('The pages cannot be looked at here.');

  /// Puts a blank page at page number [at] (from 1; null: at the end), which moves what was there down; says its number.
  Future<int> addPage({int? at}) async => throw ExtensionError('Pages cannot be added here.');

  /// Deletes page number [page] (from 1) with all that is on it.
  Future<void> deletePage(int page) async => throw ExtensionError('Pages cannot be deleted here.');

  /// Moves page number [page] to number [to] (both from 1).
  Future<void> movePage(int page, int to) async => throw ExtensionError('Pages cannot be moved here.');

  /// The tasks: `id`, `title`, `due` (a day or null) and `done`; [done] picks the ones done (true) or open (false).
  Future<List<Map<String, Object?>>> listTasks({bool? done}) async => throw ExtensionError('Tasks cannot be looked at here.');

  /// Ticks the task [id] off ([done]), or opens it again.
  Future<void> completeTask(String id, {bool done = true}) async => throw ExtensionError('Tasks cannot be changed here.');

  /// Gives the task [id] a new [title] and / or day [due]; with [setDue] the day is put as [due] even when that is null (no day).
  Future<void> updateTask(String id, {String? title, String? due, bool setDue = false}) async => throw ExtensionError('Tasks cannot be changed here.');

  Future<void> removeTask(String id) async => throw ExtensionError('Tasks cannot be deleted here.');

  /// [due] is a day, `YYYY-MM-DD`.
  Future<void> addTask(String title, {String? due}) async => throw ExtensionError('Tasks cannot be added here.');

  /// Shows [text] to the person.
  void message(String text) {}

  Future<void> copy(String text) async => throw ExtensionError('Nothing can be copied here.');
}

/// What an extension keeps between runs (a little JSON of its own).
abstract class ExtensionStorage {
  Future<Map<String, Object?>> read();
  Future<void> write(Map<String, Object?> values);
}

/// A request to a website, with the answer: `status`, `headers` and `body` (text).
/// Announces the event [name] of the extension (one it listed) with [data]; it does not wait for whoever reacts.
typedef ExtensionEmit = void Function(String name, Map<String, Object?> data);

typedef ExtensionFetch = Future<Map<String, Object?>> Function(Uri url, {String method, Map<String, String> headers, String? body});

/// The JavaScript every extension starts with: the object `notation`, which is all of the app that it can reach. Each call goes
/// through the one function `__host`, which the app checks (the permissions) before it does anything.
const _prelude = r'''
(function () {
  'use strict';
  const handlers = { tool: Object.create(null), action: Object.create(null), drawtool: Object.create(null) };
  const host = globalThis.__host;
  async function call(name, args) {
    const reply = JSON.parse(await host(name, JSON.stringify(args === undefined ? null : args)));
    if (reply && reply.error !== undefined) throw new Error(reply.error);
    return reply.value;
  }
  const api = {
    version: 1,
    tool(id, fn) { handlers.tool[id] = fn; },
    action(id, fn) { handlers.action[id] = fn; },
    drawTool(id, fn) { handlers.drawtool[id] = fn; },
    note: Object.freeze({
      get: () => call('note.get'),
      insertText: (text, options) => call('note.insertText', Object.assign({}, options, { text: String(text) })),
      inspect: (options) => call('note.inspect', Object.assign({}, options)),
      addTags: (tags) => call('note.addTags', { tags: Array.from(tags, String) }),
      moveToFolder: (folder) => call('note.moveToFolder', { folder: folder == null ? null : String(folder) }),
      resolveChanges: (options) => call('note.resolveChanges', Object.assign({ accept: true }, options)),
      replaceText: (find, replacement, options) => call('note.replaceText', Object.assign({}, options, { find: String(find), replacement: String(replacement) })),
      format: (options) => call('note.format', Object.assign({}, options)),
      setTitle: (title) => call('note.setTitle', { title: String(title) }),
    }),
    notes: Object.freeze({
      search: (query, options) => call('notes.search', Object.assign({}, options, { query: String(query) })),
      read: (id) => call('notes.read', { id: String(id) }),
      create: (title, text, options) => call('notes.create', Object.assign({}, options, { title: String(title), text: text == null ? '' : String(text) })),
      list: (options) => call('notes.list', Object.assign({}, options)),
      favorite: (id, on) => call('notes.favorite', { id: String(id), on: on === undefined ? true : Boolean(on) }),
      move: (id, folder) => call('notes.move', { id: String(id), folder: folder == null ? null : String(folder) }),
      tag: (id, tags) => call('notes.tag', { id: String(id), tags: Array.from(tags, String) }),
      trash: (id) => call('notes.trash', { id: String(id) }),
      restore: (id) => call('notes.restore', { id: String(id) }),
    }),
    folders: Object.freeze({
      list: () => call('folders.list'),
      create: (name, options) => call('folders.create', Object.assign({}, options, { name: String(name) })),
      rename: (name, newName) => call('folders.rename', { name: String(name), newName: String(newName) }),
    }),
    pdf: Object.freeze({
      read: (options) => call('pdf.read', Object.assign({}, options)),
      search: (query, options) => call('pdf.search', Object.assign({}, options, { query: String(query) })),
    }),
    textBoxes: Object.freeze({
      list: () => call('textBoxes.list'),
      add: (text, options) => call('textBoxes.add', Object.assign({}, options, { text: String(text) })),
      move: (id, options) => call('textBoxes.move', Object.assign({}, options, { id: String(id) })),
      delete: (id) => call('textBoxes.delete', { id: String(id) }),
    }),
    images: Object.freeze({
      list: () => call('images.list'),
      move: (id, options) => call('images.move', Object.assign({}, options, { id: String(id) })),
      delete: (id) => call('images.delete', { id: String(id) }),
    }),
    draw: Object.freeze({
      strokes: (strokes, options) => call('draw.strokes', Object.assign({}, options, { strokes })),
      shape: (options) => call('draw.shape', Object.assign({}, options)),
    }),
    pages: Object.freeze({
      setup: (options) => call('pages.setup', Object.assign({}, options)),
      list: () => call('pages.list'),
      add: (options) => call('pages.add', Object.assign({}, options)),
      delete: (page) => call('pages.delete', { page }),
      move: (page, to) => call('pages.move', { page, to }),
    }),
    selection: Object.freeze({ replace: (text) => call('selection.replace', { text: String(text) }) }),
    calendar: Object.freeze({
      events: (from, to) => call('calendar.events', { from: String(from), to: String(to) }),
      addEvent: (title, start, options) => call('calendar.addEvent', Object.assign({}, options, { title: String(title), start: String(start) })),
    }),
    reminders: Object.freeze({
      add: (text, at, options) => call('reminders.add', Object.assign({}, options, { text: String(text), at: String(at) })),
      list: () => call('reminders.list'),
      remove: (id) => call('reminders.remove', { id: String(id) }),
    }),
    cards: Object.freeze({ add: (cards) => call('cards.add', { cards: Array.from(cards, (c) => ({ front: c && c.front, back: c && c.back })) }) }),
    tasks: Object.freeze({
      add: (title, options) => call('tasks.add', Object.assign({}, options, { title: String(title) })),
      list: (options) => call('tasks.list', Object.assign({}, options)),
      complete: (id, done) => call('tasks.complete', { id: String(id), done: done === undefined ? true : done }),
      update: (id, changes) => call('tasks.update', Object.assign({}, changes, { id: String(id) })),
      remove: (id) => call('tasks.remove', { id: String(id) }),
    }),
    ui: Object.freeze({ message: (text) => call('ui.message', { text: String(text) }) }),
    events: Object.freeze({ emit: (name, data) => call('events.emit', { event: String(name), data: data === undefined ? {} : data }) }),
    clipboard: Object.freeze({ write: (text) => call('clipboard.write', { text: String(text) }) }),
    network: Object.freeze({ fetch: (url, options) => call('network.fetch', Object.assign({}, options, { url: String(url) })) }),
    storage: Object.freeze({
      get: (key) => call('storage.get', { key: String(key) }),
      set: (key, value) => call('storage.set', { key: String(key), value }),
      remove: (key) => call('storage.remove', { key: String(key) }),
    }),
  };
  Object.defineProperty(globalThis, "notation", { value: Object.freeze(api), enumerable: true });
  // the former name of the app, so extensions written before the rename keep working
  Object.defineProperty(globalThis, "uninotes", { value: globalThis.notation, enumerable: false });
  Object.defineProperty(globalThis, '__run', {
    value: async function (kind, id, context) {
      const fn = handlers[kind] && handlers[kind][id];
      if (typeof fn !== 'function') return JSON.stringify({ error: 'This extension has no ' + kind + ' "' + id + '".' });
      try {
        const value = await fn(context);
        return JSON.stringify({ value: value === undefined ? null : value });
      } catch (e) {
        return JSON.stringify({ error: String((e && e.message) || e) });
      }
    },
  });
})();
''';

/// The JavaScript every extension starts with (for checking a script without running it).
const String extensionPrelude = _prelude;

/// How a run of an extension came out.
class ExtensionRun {
  /// What the handler returned (a string, or an object with `replace`, `insert` and `message`), null if it returned nothing.
  final Object? value;

  /// Why it failed, if it did.
  final String? error;

  /// What the script wrote with `console.log`.
  final List<String> log;

  const ExtensionRun({this.value, this.error, this.log = const []});

  bool get ok => error == null;
}

/// One run of one extension: a new engine with the script in it, the handler called, everything let go of. The script can only
/// reach the app through [api] (and the storage and the network, if it has the permissions), and only for what was granted.
class ExtensionRuntime {
  final ExtensionManifest manifest;
  final String script;
  final Set<ExtensionPermission> granted;
  final ExtensionApi api;
  final ExtensionStorage storage;
  final ExtensionFetch fetch;

  /// Announces an event of the extension; null: not here.
  final ExtensionEmit? emit;

  /// Another engine to run in (tests); without one the script runs in QuickJS on an isolate of its own, away from the screen.
  final EngineFactory? engineFactory;

  /// How long a run may take in all (waiting for the network and the like); the time a piece of the script may compute without
  /// waiting is shorter, the engine's own limit.
  final Duration limit;

  ExtensionRuntime({
    required this.manifest,
    required this.script,
    required this.granted,
    required this.api,
    required this.storage,
    required this.fetch,
    this.emit,
    this.engineFactory,
    this.limit = const Duration(seconds: 15),
  });

  static const _largestScript = 256 * 1024;
  static const _largestStorage = 64 * 1024;
  static const _largestAnswer = 1024 * 1024;
  static const _largestEventData = 8 * 1024;

  /// Calls the [kind] (`tool` or `action`) [id] of the extension with [context] (JSON).
  Future<ExtensionRun> run(String kind, String id, Map<String, Object?> context) async {
    if (script.length > _largestScript) return const ExtensionRun(error: 'The script is too big.');
    final log = <String>[];
    void console(String line) {
      if (log.length < 50) log.add(line.length > 500 ? '${line.substring(0, 500)}...' : line);
      debugPrint('[ext ${manifest.id}] $line');
    }

    ScriptEngine? engine;
    try {
      final call = '__run(${jsonEncode(kind)}, ${jsonEncode(id)}, ${jsonEncode(context)})';
      final String raw;
      final make = engineFactory;
      if (make == null) {
        raw = await runInIsolate(
          prelude: _prelude,
          script: script,
          scriptName: manifest.main,
          call: call,
          host: (name, payload) async => await _host([name, payload]) as String,
          onConsole: console,
          overall: limit,
        );
      } else {
        engine = make(onConsole: console);
        engine.register('__host', _host);
        engine.eval(_prelude, filename: 'notation');
        engine.eval(script, filename: manifest.main);
        raw = (await engine.evalAsync(call, filename: 'run', timeout: limit)).toString();
      }
      final reply = jsonDecode(raw);
      if (reply is Map && reply['error'] != null) return ExtensionRun(error: _friendly('${reply['error']}'), log: log);
      return ExtensionRun(value: reply is Map ? reply['value'] : null, log: log);
    } on ExtensionError catch (e) {
      return ExtensionRun(error: e.message, log: log);
    } catch (e) {
      return ExtensionRun(error: _friendly('$e'.replaceFirst(RegExp(r'^\w*Exception: '), '')), log: log);
    } finally {
      engine?.dispose();
    }
  }

  /// What the engine says when a limit is hit, in words for a person.
  static String _friendly(String text) => text.contains('interrupted')
      ? 'The script ran for too long.'
      : (text.contains('out of memory') ? 'The script used too much memory.' : (text.contains('stack overflow') ? 'The script calls itself too deeply.' : text));

  void _need(ExtensionPermission p) {
    if (!manifest.permissions.contains(p)) throw ExtensionError('This extension did not ask for the permission "${p.id}".');
    if (!granted.contains(p)) throw ExtensionError('The permission "${p.id}" was not given to this extension.');
  }

  Future<Object?> _host(List<Object?> args) async {
    try {
      final name = args[0] as String;
      final raw = args[1] as String?;
      final payload = raw == null ? null : jsonDecode(raw);
      final value = await _dispatch(name, payload is Map ? payload.cast<String, Object?>() : const {});
      return jsonEncode({'value': value});
    } on ExtensionError catch (e) {
      return jsonEncode({'error': e.message});
    } catch (e) {
      return jsonEncode({'error': 'Something went wrong: $e'});
    }
  }

  String _string(Map<String, Object?> p, String key, {int max = 100000}) {
    final v = p[key];
    if (v is! String) throw ExtensionError('"$key" has to be text.');
    if (v.length > max) throw ExtensionError('"$key" is too long.');
    return v;
  }

  int? _optPage(Map<String, Object?> p, [String key = 'page']) {
    final v = p[key];
    if (v == null) return null;
    if (v is! int || v < 1) throw ExtensionError('"$key" has to be a page number, from 1.');
    return v;
  }

  double? _optNumber(Map<String, Object?> p, String key, {bool positive = false}) {
    final v = p[key];
    if (v == null) return null;
    if (v is! num || !v.isFinite || v.abs() > 100000 || positive && v <= 0) throw ExtensionError('"$key" has to be a${positive ? ' positive' : ''} number.');
    return v.toDouble();
  }

  int _pageNumber(Map<String, Object?> p, String key) {
    final v = p[key];
    if (v is! int || v < 1) throw ExtensionError('"$key" has to be a page number, from 1.');
    return v;
  }

  Future<Object?> _dispatch(String name, Map<String, Object?> p) async {
    switch (name) {
      case 'note.get':
        _need(ExtensionPermission.noteRead);
        return await api.note();
      case 'note.insertText':
        _need(ExtensionPermission.noteWrite);
        final after = p['after'], before = p['before'], at = p['at'];
        if (after == null && before == null && at == null) {
          await api.insertText(_string(p, 'text'));
          return null;
        }
        if (after != null && before != null || (after != null || before != null) && at != null) throw ExtensionError('Say one of "after", "before" and "at".');
        if (after is! String? || before is! String? || at != null && at != 'start' && at != 'end') throw ExtensionError('"after" and "before" have to be text from the note, "at" "start" or "end".');
        await api.insertTextAt(_string(p, 'text'), after: after, before: before, atStart: at == 'start');
        return null;
      case 'note.inspect':
        _need(ExtensionPermission.noteRead);
        final target = p['target'];
        if (target != null && target is! String) throw ExtensionError('"target" has to be text.');
        return await api.inspectText((target as String?) ?? 'all');
      case 'notes.search':
        _need(ExtensionPermission.notesReadAll);
        final limit = p['limit'];
        if (limit != null && limit is! num) throw ExtensionError('"limit" has to be a number.');
        return await api.searchNotes(_string(p, 'query', max: 200), limit: ((limit as num?)?.toInt() ?? 10).clamp(1, 20));
      case 'notes.read':
        _need(ExtensionPermission.notesReadAll);
        return await api.readNote(_string(p, 'id', max: 200));
      case 'notes.create':
        _need(ExtensionPermission.notesManage);
        final folder = p['folder'];
        if (folder != null && folder is! String) throw ExtensionError('"folder" has to be the name of a folder.');
        return {'id': await api.createNote(_string(p, 'title', max: 200), _string(p, 'text'), folder: folder as String?)};
      case 'folders.list':
        _need(ExtensionPermission.notesReadAll);
        return await api.listFolders();
      case 'folders.create':
        _need(ExtensionPermission.notesManage);
        final parent = p['parent'];
        if (parent != null && parent is! String) throw ExtensionError('"parent" has to be the name of a folder.');
        await api.createFolder(_string(p, 'name', max: 100), parent: parent as String?);
        return null;
      case 'folders.rename':
        _need(ExtensionPermission.notesManage);
        await api.renameFolder(_string(p, 'name', max: 100), _string(p, 'newName', max: 100));
        return null;
      case 'notes.list':
        _need(ExtensionPermission.notesReadAll);
        final listed = p['folder'], listLimit = p['limit'];
        if (listed != null && listed is! String) throw ExtensionError('"folder" has to be the name of a folder.');
        if (listLimit != null && listLimit is! num) throw ExtensionError('"limit" has to be a number.');
        return await api.listNotes(folder: listed as String?, limit: ((listLimit as num?)?.toInt() ?? 20).clamp(1, 50));
      case 'notes.move':
        _need(ExtensionPermission.notesManage);
        final moveTo = p['folder'];
        if (moveTo != null && moveTo is! String) throw ExtensionError('"folder" has to be the name of a folder, or null.');
        await api.moveNoteTo(_string(p, 'id', max: 200), moveTo as String?);
        return null;
      case 'notes.tag':
        _need(ExtensionPermission.notesManage);
        final names = p['tags'];
        if (names is! List || names.isEmpty || names.length > 20 || names.any((t) => t is! String || t.length > 60)) throw ExtensionError('"tags" has to be a list of at most 20 names.');
        await api.tagNote(_string(p, 'id', max: 200), names.cast<String>());
        return null;
      case 'notes.trash':
        _need(ExtensionPermission.notesDelete);
        await api.trashNote(_string(p, 'id', max: 200));
        return null;
      case 'notes.restore':
        _need(ExtensionPermission.notesDelete);
        await api.restoreNote(_string(p, 'id', max: 200));
        return null;
      case 'note.addTags':
        _need(ExtensionPermission.notesManage);
        final tags = p['tags'];
        if (tags is! List || tags.isEmpty || tags.length > 20 || tags.any((t) => t is! String || t.length > 60)) throw ExtensionError('"tags" has to be a list of at most 20 names.');
        await api.addTags(tags.cast<String>());
        return null;
      case 'note.moveToFolder':
        _need(ExtensionPermission.notesManage);
        final to = p['folder'];
        if (to != null && to is! String) throw ExtensionError('"folder" has to be the name of a folder, or null.');
        await api.moveToFolder(to as String?);
        return null;
      case 'note.resolveChanges':
        _need(ExtensionPermission.noteWrite);
        final accept = p['accept'];
        if (accept is! bool) throw ExtensionError('"accept" has to be true (accept the changes) or false (reject them).');
        return {'settled': await api.resolveChanges(accept: accept)};
      case 'notes.favorite':
        _need(ExtensionPermission.notesManage);
        final on = p['on'];
        if (on is! bool) throw ExtensionError('"on" has to be true or false.');
        await api.favoriteNote(_string(p, 'id', max: 200), on);
        return null;
      case 'note.replaceText':
        _need(ExtensionPermission.noteWrite);
        return await api.replaceText(_string(p, 'find'), _string(p, 'replacement'), all: p['all'] == true);
      case 'note.format':
        _need(ExtensionPermission.noteWrite);
        return await api.formatText(p);
      case 'selection.replace':
        _need(ExtensionPermission.noteWrite);
        await api.replaceSelection(_string(p, 'text'));
        return null;
      case 'note.setTitle':
        _need(ExtensionPermission.noteWrite);
        await api.setTitle(_string(p, 'title', max: 200));
        return null;
      case 'pdf.read':
        final readId = p['id'];
        if (readId != null && readId is! String) throw ExtensionError('"id" has to be the id of a note.');
        _need(readId == null ? ExtensionPermission.noteRead : ExtensionPermission.notesReadAll);
        return await api.readPdf(id: readId as String?, from: _optPage(p, 'from'), to: _optPage(p, 'to'));
      case 'pdf.search':
        final searchId = p['id'];
        if (searchId != null && searchId is! String) throw ExtensionError('"id" has to be the id of a note.');
        _need(searchId == null ? ExtensionPermission.noteRead : ExtensionPermission.notesReadAll);
        return await api.searchPdf(_string(p, 'query', max: 200), id: searchId as String?);
      case 'textBoxes.list':
        _need(ExtensionPermission.noteRead);
        return await api.textBoxes();
      case 'textBoxes.add':
        _need(ExtensionPermission.noteWrite);
        return {'id': await api.addTextBox(_string(p, 'text', max: 20000), page: _optPage(p), x: _optNumber(p, 'x'), y: _optNumber(p, 'y'), width: _optNumber(p, 'width', positive: true))};
      case 'textBoxes.move':
        _need(ExtensionPermission.noteWrite);
        await api.moveTextBox(_string(p, 'id', max: 200), page: _optPage(p), x: _optNumber(p, 'x'), y: _optNumber(p, 'y'), width: _optNumber(p, 'width', positive: true));
        return null;
      case 'textBoxes.delete':
        _need(ExtensionPermission.noteWrite);
        await api.deleteTextBox(_string(p, 'id', max: 200));
        return null;
      case 'images.list':
        _need(ExtensionPermission.noteRead);
        return await api.images();
      case 'images.move':
        _need(ExtensionPermission.noteWrite);
        await api.moveImage(_string(p, 'id', max: 200), page: _optPage(p), x: _optNumber(p, 'x'), y: _optNumber(p, 'y'), width: _optNumber(p, 'width', positive: true));
        return null;
      case 'images.delete':
        _need(ExtensionPermission.noteWrite);
        await api.deleteImage(_string(p, 'id', max: 200));
        return null;
      case 'draw.strokes':
        _need(ExtensionPermission.drawPage);
        final lines = p['strokes'];
        // (checked here, as it is for a drawing tool: the same limits, the same messages)
        parseDrawnStrokes(lines, color: const Color(0xFF000000), width: 2);
        return {'drawn': await api.drawStrokes((lines as List).cast<Map<String, Object?>>(), page: _optPage(p))};
      case 'draw.shape':
        _need(ExtensionPermission.drawPage);
        final lines = shapeStrokes(p);
        parseDrawnStrokes(lines, color: const Color(0xFF000000), width: 2);
        return {'drawn': await api.drawStrokes(lines, page: _optPage(p))};
      case 'pages.setup':
        _need(ExtensionPermission.pagesEdit);
        return await api.setupPage(Map.of(p));
      case 'pages.list':
        _need(ExtensionPermission.noteRead);
        return await api.pages();
      case 'pages.add':
        _need(ExtensionPermission.pagesEdit);
        final at = p['at'];
        if (at != null && (at is! int || at < 1)) throw ExtensionError('"at" has to be a page number, from 1.');
        return {'page': await api.addPage(at: at as int?)};
      case 'pages.delete':
        _need(ExtensionPermission.pagesEdit);
        await api.deletePage(_pageNumber(p, 'page'));
        return null;
      case 'pages.move':
        _need(ExtensionPermission.pagesEdit);
        await api.movePage(_pageNumber(p, 'page'), _pageNumber(p, 'to'));
        return null;
      case 'calendar.events':
        _need(ExtensionPermission.calendarManage);
        final from = p['from'], to = p['to'];
        final day = RegExp(r'^\d{4}-\d{2}-\d{2}$');
        if (from is! String || to is! String || !day.hasMatch(from) || !day.hasMatch(to)) throw ExtensionError('"from" and "to" have to be days like 2026-12-24.');
        if (DateTime.parse(to).difference(DateTime.parse(from)).inDays > 62 || to.compareTo(from) < 0) throw ExtensionError('"to" has to be on or after "from", and not more than 62 days later.');
        return await api.listEvents(from, to);
      case 'calendar.addEvent':
        _need(ExtensionPermission.calendarManage);
        final allDay = p['allDay'];
        if (allDay != null && allDay is! bool) throw ExtensionError('"allDay" has to be true or false.');
        final shape = allDay == true ? RegExp(r'^\d{4}-\d{2}-\d{2}$') : RegExp(r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}$');
        final startAt = p['start'], endAt = p['end'];
        if (startAt is! String || !shape.hasMatch(startAt) || endAt != null && (endAt is! String || !shape.hasMatch(endAt))) {
          throw ExtensionError(allDay == true ? '"start" and "end" have to be days like 2026-12-24.' : '"start" and "end" have to be times like 2026-12-24T09:30.');
        }
        final where = p['calendar'], about = p['description'];
        if (where != null && where is! String || about != null && about is! String) throw ExtensionError('"calendar" and "description" have to be text.');
        await api.addEvent(_string(p, 'title', max: 300), startAt.replaceFirst(' ', 'T'),
            end: (endAt as String?)?.replaceFirst(' ', 'T'), allDay: allDay == true, calendar: where as String?, description: about as String?);
        return null;
      case 'reminders.add':
        _need(ExtensionPermission.remindersManage);
        final at = p['at'];
        if (at is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}$').hasMatch(at)) throw ExtensionError('"at" has to be a time like 2026-12-24T09:30.');
        final repeat = p['repeat'] ?? 'once';
        if (!const ['once', 'daily', 'weekly', 'monthly', 'yearly'].contains(repeat)) throw ExtensionError('"repeat" has to be once, daily, weekly, monthly or yearly.');
        final about = p['aboutNote'];
        if (about != null && about is! bool) throw ExtensionError('"aboutNote" has to be true or false.');
        return {'id': await api.addReminder(_string(p, 'text', max: 300), at.replaceFirst(' ', 'T'), repeat: repeat as String, aboutNote: about == true)};
      case 'reminders.list':
        _need(ExtensionPermission.remindersManage);
        return await api.listReminders();
      case 'reminders.remove':
        _need(ExtensionPermission.remindersManage);
        await api.removeReminder(_string(p, 'id', max: 200));
        return null;
      case 'cards.add':
        _need(ExtensionPermission.cardsAdd);
        final cards = p['cards'];
        if (cards is! List || cards.isEmpty || cards.length > 30) throw ExtensionError('"cards" has to be a list of 1 to 30 cards, each {front, back}.');
        final made = <Map<String, String>>[];
        for (final c in cards) {
          final front = c is Map ? c['front'] : null, back = c is Map ? c['back'] : null;
          if (front is! String || back is! String || front.trim().isEmpty || back.trim().isEmpty || front.length > 1000 || back.length > 2000) throw ExtensionError('Each card needs a "front" and a "back" of text.');
          made.add({'front': front, 'back': back});
        }
        return {'added': await api.addCards(made)};
      case 'tasks.list':
        _need(ExtensionPermission.tasksManage);
        final done = p['done'];
        if (done != null && done is! bool) throw ExtensionError('"done" has to be true or false.');
        return await api.listTasks(done: done as bool?);
      case 'tasks.complete':
        _need(ExtensionPermission.tasksManage);
        final done = p['done'];
        if (done is! bool) throw ExtensionError('"done" has to be true or false.');
        await api.completeTask(_string(p, 'id', max: 200), done: done);
        return null;
      case 'tasks.update':
        _need(ExtensionPermission.tasksManage);
        final due = p['due'];
        if (due != null && (due is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(due))) throw ExtensionError('"due" has to be a day like 2026-12-24.');
        final title = p['title'];
        if (title != null && (title is! String || title.isEmpty || title.length > 300)) throw ExtensionError('"title" has to be text of up to 300 characters.');
        if (title == null && !p.containsKey('due')) throw ExtensionError('Say a "title" or a "due" day.');
        await api.updateTask(_string(p, 'id', max: 200), title: title as String?, due: due as String?, setDue: p.containsKey('due'));
        return null;
      case 'tasks.remove':
        _need(ExtensionPermission.tasksManage);
        await api.removeTask(_string(p, 'id', max: 200));
        return null;
      case 'tasks.add':
        _need(ExtensionPermission.tasks);
        final due = p['due'];
        if (due != null && (due is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(due))) throw ExtensionError('"due" has to be a day like 2026-12-24.');
        await api.addTask(_string(p, 'title', max: 300), due: due as String?);
        return null;
      case 'ui.message':
        api.message(_string(p, 'text', max: 2000));
        return null;
      case 'clipboard.write':
        _need(ExtensionPermission.clipboard);
        await api.copy(_string(p, 'text'));
        return null;
      case 'network.fetch':
        _need(ExtensionPermission.network);
        final url = Uri.tryParse(_string(p, 'url', max: 2000));
        if (url == null || url.scheme != 'https' || url.host.isEmpty) throw ExtensionError('Only https addresses can be used.');
        if (!manifest.hosts.contains(url.host.toLowerCase())) throw ExtensionError('This extension may not talk to ${url.host}.');
        final headers = <String, String>{};
        final rawHeaders = p['headers'];
        if (rawHeaders is Map) {
          for (final e in rawHeaders.entries) {
            headers['${e.key}'] = '${e.value}';
          }
        }
        final body = p['body'];
        final answer = await fetch(url, method: '${p['method'] ?? 'GET'}'.toUpperCase(), headers: headers, body: body is String ? body : null);
        if ('${answer['body']}'.length > _largestAnswer) throw ExtensionError('The answer is too big.');
        return answer;
      case 'events.emit':
        _need(ExtensionPermission.eventsEmit);
        final name = _string(p, 'event', max: 40);
        if (!manifest.events.any((e) => e.id == name)) throw ExtensionError('This extension did not list the event "$name".');
        final data = p['data'];
        if (data is! Map) throw ExtensionError('"data" has to be an object.');
        if (jsonEncode(data).length > _largestEventData) throw ExtensionError('The data of an event is too big (at most 8 KB).');
        final announce = emit;
        if (announce == null) throw ExtensionError('Events cannot be announced here.');
        announce(name, data.cast<String, Object?>());
        return null;
      case 'storage.get':
        return (await storage.read())[_string(p, 'key', max: 200)];
      case 'storage.set':
        final all = await storage.read();
        all[_string(p, 'key', max: 200)] = p['value'];
        if (jsonEncode(all).length > _largestStorage) throw ExtensionError('The extension keeps too much (at most 64 KB).');
        await storage.write(all);
        return null;
      case 'storage.remove':
        final all = await storage.read();
        all.remove(_string(p, 'key', max: 200));
        await storage.write(all);
        return null;
    }
    throw ExtensionError('Unknown call: $name');
  }
}
