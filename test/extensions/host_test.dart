import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/extensions/extension_host.dart';
import 'package:notes/extensions/extension_manifest.dart';
import 'package:notes/extensions/script_engine.dart';

/// What a place offers an extension, as a recording.
class _Api extends ExtensionApi {
  final calls = <String>[];
  final messages = <String>[];
  @override
  Future<Map<String, Object?>> note() async => {'id': 'n1', 'title': 'Physics', 'text': 'one two three'};
  @override
  Future<void> insertText(String text) async => calls.add('insert:$text');
  @override
  Future<void> replaceSelection(String text) async => calls.add('replace:$text');
  @override
  Future<void> setTitle(String title) async => calls.add('title:$title');
  @override
  Future<void> insertTextAt(String text, {String? after, String? before, bool atStart = false}) async => calls.add('insertAt:$text:$after:$before:$atStart');
  @override
  Future<String> inspectText(String target) async => 'looks of $target';
  @override
  Future<int> replaceText(String find, String replacement, {bool all = false}) async => 2;
  @override
  Future<String> formatText(Map<String, Object?> options) async => 'formatted ${jsonEncode(options)}';
  @override
  Future<List<Map<String, Object?>>> searchNotes(String query, {int limit = 10}) async => [{'id': 'n2', 'title': 'Biology', 'snippet': '$query $limit'}];
  @override
  Future<Map<String, Object?>> readNote(String id) async => {'id': id, 'title': 'Biology', 'text': 'cells'};
  @override
  Future<String> createNote(String title, String text, {String? folder}) async {
    calls.add('create:$title:$text:$folder');
    return 'new1';
  }

  @override
  Future<void> addTags(List<String> tags) async => calls.add('tags:${tags.join(',')}');
  @override
  Future<void> moveToFolder(String? folder) async => calls.add('move:$folder');
  @override
  Future<String> readPdf({String? id, int? from, int? to}) async => 'pdf:$id:$from:$to';
  @override
  Future<List<Map<String, Object?>>> searchPdf(String query, {String? id}) async => [{'page': 2, 'snippet': '$query:$id'}];
  @override
  Future<int> resolveChanges({required bool accept}) async {
    calls.add('settle:$accept');
    return 2;
  }

  @override
  Future<void> favoriteNote(String id, bool on) async => calls.add('star:$id:$on');
  @override
  Future<List<Map<String, Object?>>> textBoxes() async => [{'id': 'b1', 'page': 1, 'x': 10, 'y': 20, 'width': 260, 'text': 'Hello'}];
  @override
  Future<String> addTextBox(String text, {int? page, double? x, double? y, double? width}) async {
    calls.add('box:$text:$page:$x:$y:$width');
    return 'b2';
  }

  @override
  Future<void> moveTextBox(String id, {int? page, double? x, double? y, double? width}) async => calls.add('moveBox:$id:$page:$x:$y:$width');
  @override
  Future<void> deleteTextBox(String id) async => calls.add('deleteBox:$id');
  @override
  Future<List<Map<String, Object?>>> images() async => [{'id': 'i1', 'page': 2, 'x': 0, 'y': 0, 'width': 100, 'height': 50}];
  @override
  Future<void> moveImage(String id, {int? page, double? x, double? y, double? width}) async => calls.add('moveImage:$id:$page:$x:$y:$width');
  @override
  Future<void> deleteImage(String id) async => calls.add('deleteImage:$id');
  @override
  Future<int> drawStrokes(List<Map<String, Object?>> strokes, {int? page}) async {
    calls.add('draw:${strokes.length}:${(strokes.first['points'] as List).length}:$page:${strokes.first['fill']}');
    return strokes.length;
  }

  @override
  Future<String> setupPage(Map<String, Object?> options) async => 'set ${jsonEncode(options)}';
  @override
  Future<List<Map<String, Object?>>> listEvents(String from, String to) async => [{'title': 'Exam', 'start': '${from}T09:00', 'end': null, 'allDay': false, 'calendar': 'Work', 'to': to}];
  @override
  Future<void> addEvent(String title, String start, {String? end, bool allDay = false, String? calendar, String? description}) async =>
      calls.add('event:$title:$start:$end:$allDay:$calendar:$description');
  @override
  Future<String> addReminder(String text, String at, {String repeat = 'once', bool aboutNote = false}) async {
    calls.add('remind:$text:$at:$repeat:$aboutNote');
    return 'r1';
  }

  @override
  Future<List<Map<String, Object?>>> listReminders() async => [{'id': 'r1', 'text': 'Call', 'at': '2026-12-24T09:30', 'repeat': 'once'}];
  @override
  Future<void> removeReminder(String id) async => calls.add('unremind:$id');
  @override
  Future<int> addCards(List<Map<String, String>> cards) async {
    calls.add('cards:${cards.map((c) => '${c['front']}>${c['back']}').join(',')}');
    return cards.length;
  }

  @override
  Future<List<Map<String, Object?>>> listFolders() async => [{'name': 'School', 'parent': null, 'notes': 2}];
  @override
  Future<void> createFolder(String name, {String? parent}) async => calls.add('mkfolder:$name:$parent');
  @override
  Future<void> renameFolder(String name, String newName) async => calls.add('rename:$name:$newName');
  @override
  Future<List<Map<String, Object?>>> listNotes({String? folder, int limit = 20}) async => [{'id': 'n2', 'title': 'Biology', 'folder': folder, 'updated': '2026-10-31', 'limit': limit}];
  @override
  Future<void> moveNoteTo(String id, String? folder) async => calls.add('moveNote:$id:$folder');
  @override
  Future<void> tagNote(String id, List<String> tags) async => calls.add('tagNote:$id:${tags.join(',')}');
  @override
  Future<void> trashNote(String id) async => calls.add('trash:$id');
  @override
  Future<void> restoreNote(String id) async => calls.add('restore:$id');
  @override
  Future<void> addTask(String title, {String? due}) async => calls.add('task:$title:$due');
  @override
  Future<List<Map<String, Object?>>> pages() async => [{'page': 1, 'kind': 'notebook', 'strokes': 2, 'textBoxes': 0, 'images': 1}];
  @override
  Future<int> addPage({int? at}) async {
    calls.add('addPage:$at');
    return at ?? 4;
  }

  @override
  Future<void> deletePage(int page) async => calls.add('deletePage:$page');
  @override
  Future<void> movePage(int page, int to) async => calls.add('movePage:$page:$to');
  @override
  Future<List<Map<String, Object?>>> listTasks({bool? done}) async => [{'id': 't1', 'title': 'Buy milk', 'due': '2026-12-24', 'done': done ?? false}];
  @override
  Future<void> completeTask(String id, {bool done = true}) async => calls.add('complete:$id:$done');
  @override
  Future<void> updateTask(String id, {String? title, String? due, bool setDue = false}) async => calls.add('update:$id:$title:$due:$setDue');
  @override
  Future<void> removeTask(String id) async => calls.add('remove:$id');
  @override
  void message(String text) => messages.add(text);
  @override
  Future<void> copy(String text) async => calls.add('copy:$text');
}

class _Storage extends ExtensionStorage {
  Map<String, Object?> data = {};
  @override
  Future<Map<String, Object?>> read() async => Map.of(data);
  @override
  Future<void> write(Map<String, Object?> values) async => data = Map.of(values);
}

void main() {
  final available = QuickJsEngine.available;
  final skip = available ? null : 'the JavaScript engine is not here (run with LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib after a Linux build)';

  late _Api api;
  late _Storage storage;
  final fetched = <Uri>[];

  ExtensionRuntime runtime(String script, {Set<ExtensionPermission> permissions = const {}, Set<ExtensionPermission>? granted, List<String> hosts = const [], Duration? limit}) {
    return ExtensionRuntime(
      manifest: ExtensionManifest(id: 'test-ext', name: 'Test', version: '1', permissions: permissions, hosts: hosts),
      script: script,
      granted: granted ?? permissions,
      api: api,
      storage: storage,
      fetch: (url, {method = 'GET', headers = const {}, body}) async {
        fetched.add(url);
        return {'status': 200, 'headers': {}, 'body': 'hello from ${url.host}'};
      },
      limit: limit ?? const Duration(seconds: 5),
    );
  }

  setUp(() {
    api = _Api();
    storage = _Storage();
    fetched.clear();
  });

  group('running a tool', () {
    test('a script that computes does not hold up this isolate', () async {
      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 10), (_) => ticks++);
      final r = await runtime("notation.tool('busy', () => { const end = Date.now() + 800; while (Date.now() < end) {} return 'ok'; });").run('tool', 'busy', {});
      timer.cancel();
      expect(r.value, 'ok');
      expect(ticks, greaterThan(30));
    }, skip: skip);

    test('what the handler returns', () async {
      final r = await runtime("notation.tool('up', (ctx) => ctx.text.toUpperCase());").run('tool', 'up', {'text': 'abc'});
      expect(r.ok, isTrue);
      expect(r.value, 'ABC');
    }, skip: skip);

    test('an object, an async handler, and nothing', () async {
      final script = '''
        notation.tool('obj', (ctx) => ({ replace: 'x', message: 'done' }));
        notation.tool('later', async (ctx) => { await new Promise(r => setTimeout(r, 20)); return 'late'; });
        notation.tool('none', () => {});
      ''';
      expect((await runtime(script).run('tool', 'obj', {})).value, {'replace': 'x', 'message': 'done'});
      expect((await runtime(script).run('tool', 'later', {})).value, 'late');
      expect((await runtime(script).run('tool', 'none', {})).value, isNull);
    }, skip: skip);

    test('a tool that is not there, a script with a mistake, one that throws', () async {
      expect((await runtime("notation.tool('a', () => 1);").run('tool', 'b', {})).error, contains('no tool "b"'));
      expect((await runtime('this is not javascript').run('tool', 'a', {})).error, isNotNull);
      final thrown = await runtime("notation.tool('a', () => { throw new Error('nope'); });").run('tool', 'a', {});
      expect(thrown.error, 'nope');
      final rejected = await runtime("notation.tool('a', async () => { throw 'bad'; });").run('tool', 'a', {});
      expect(rejected.error, 'bad');
    }, skip: skip);

    test('console output is kept', () async {
      final r = await runtime("notation.tool('a', () => { console.log('hello', 3); });").run('tool', 'a', {});
      expect(r.log.single, contains('hello 3'));
    }, skip: skip);
  });

  group('the limits', () {
    test('a script that never ends is stopped', () async {
      final watch = Stopwatch()..start();
      final r = await runtime("notation.tool('a', () => { while (true) {} });").run('tool', 'a', {});
      expect(r.error, 'The script ran for too long.');
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
    }, skip: skip);

    test('one at the top level too', () async {
      final r = await runtime('while (true) {}').run('tool', 'a', {});
      expect(r.error, 'The script ran for too long.');
    }, skip: skip);

    test('a script that takes all the memory is stopped', () async {
      final r = await runtime("notation.tool('a', () => { const a = []; while (true) a.push(new Array(100000).fill(1)); });").run('tool', 'a', {});
      expect(r.error, 'The script used too much memory.');
    }, skip: skip);

    test('a script that waits for ever is given up on', () async {
      final r = await runtime("notation.tool('a', () => new Promise(() => {}));", limit: const Duration(milliseconds: 300)).run('tool', 'a', {});
      expect(r.error, contains('timed out'));
    }, skip: skip);

    test('too deep a recursion is an error, not a crash', () async {
      final r = await runtime("notation.tool('a', () => { const f = () => f() + 1; return f(); });").run('tool', 'a', {});
      expect(r.ok, isFalse);
    }, skip: skip);

    test('a script that is too big is not run', () async {
      final r = await runtime("notation.tool('a', () => 1);${' ' * 300000}").run('tool', 'a', {});
      expect(r.error, 'The script is too big.');
    });
  });

  group('what the script can reach', () {
    test('nothing but the language and notation', () async {
      final r = await runtime('''
        notation.tool('a', () => [typeof fetch, typeof require, typeof process, typeof XMLHttpRequest, typeof WebSocket, typeof std, typeof os,
          typeof __host, typeof notation].join(','));
      ''').run('tool', 'a', {});
      expect(r.value, 'undefined,undefined,undefined,undefined,undefined,undefined,undefined,function,object');
    }, skip: skip);

    test('notation cannot be replaced or changed', () async {
      final r = await runtime('''
        try { notation.note = null; } catch (e) {}
        try { globalThis.notation = null; } catch (e) {}
        notation.tool('a', () => typeof notation.note.get);
      ''').run('tool', 'a', {});
      expect(r.value, 'function');
    }, skip: skip);

    test('every run is on its own', () async {
      await runtime("globalThis.kept = 1; notation.tool('a', () => 1);").run('tool', 'a', {});
      final r = await runtime("notation.tool('a', () => typeof globalThis.kept);").run('tool', 'a', {});
      expect(r.value, 'undefined');
    }, skip: skip);

    test('what it asks for is checked in the app, even if the script calls the host by hand', () async {
      final r = await runtime("notation.tool('a', async () => await __host('note.get', 'null'));").run('tool', 'a', {});
      final reply = jsonDecode(r.value as String) as Map;
      expect(reply['error'], contains('did not ask'));
    }, skip: skip);
  });

  group('the permissions', () {
    test('without one, the call fails with a message the script can read', () async {
      final r = await runtime("notation.tool('a', async () => { try { await notation.note.get(); } catch (e) { return e.message; } return 'allowed'; });").run('tool', 'a', {});
      expect(r.value, contains('did not ask for the permission "note.read"'));
    }, skip: skip);

    test('asked for but not given', () async {
      final r = await runtime("notation.tool('a', async () => { try { await notation.note.get(); } catch (e) { return e.message; } });",
              permissions: {ExtensionPermission.noteRead}, granted: {})
          .run('tool', 'a', {});
      expect(r.value, contains('was not given'));
    }, skip: skip);

    test('given', () async {
      final r = await runtime("notation.tool('a', async () => (await notation.note.get()).title);", permissions: {ExtensionPermission.noteRead}).run('tool', 'a', {});
      expect(r.value, 'Physics');
    }, skip: skip);

    test('writing, tasks and the clipboard', () async {
      final script = '''
        notation.tool('a', async () => {
          await notation.selection.replace('R');
          await notation.note.insertText('I');
          await notation.note.setTitle('T');
          await notation.tasks.add('Buy milk', { due: '2026-12-24' });
          await notation.clipboard.write('C');
          await notation.ui.message('hi');
        });
      ''';
      final r = await runtime(script, permissions: {ExtensionPermission.noteWrite, ExtensionPermission.tasks, ExtensionPermission.clipboard}).run('tool', 'a', {});
      expect(r.ok, isTrue, reason: r.error);
      expect(api.calls, ['replace:R', 'insert:I', 'title:T', 'task:Buy milk:2026-12-24', 'copy:C']);
      expect(api.messages, ['hi']);
    }, skip: skip);

    test('where text goes, how it is formatted, replacing and formatting', () async {
      final script = '''
        notation.tool('a', async () => {
          await notation.note.insertText('A', { after: 'Intro' });
          await notation.note.insertText('B', { at: 'start' });
          const looks = await notation.note.inspect({ target: 'Intro' });
          const n = await notation.note.replaceText('a', 'b', { all: true });
          const f = await notation.note.format({ target: 'Intro', like: 'Title', bold: true });
          return [looks, n, f].join('|');
        });
      ''';
      final r = await runtime(script, permissions: {ExtensionPermission.noteWrite, ExtensionPermission.noteRead}).run('tool', 'a', {});
      expect(r.ok, isTrue, reason: r.error);
      expect(api.calls, ['insertAt:A:Intro:null:false', 'insertAt:B:null:null:true']);
      expect(r.value, 'looks of Intro|2|formatted {"target":"Intro","like":"Title","bold":true}');
      final both = await runtime("notation.tool('a', async () => { try { await notation.note.insertText('x', { after: 'a', before: 'b' }); } catch (e) { return e.message; } });", permissions: {ExtensionPermission.noteWrite}).run('tool', 'a', {});
      expect(both.value, contains('one of'));
    }, skip: skip);

    test('other notes and filing have their own permissions', () async {
      final script = '''
        notation.tool('a', async () => {
          const found = await notation.notes.search('cells', { limit: 3 });
          const note = await notation.notes.read(found[0].id);
          const made = await notation.notes.create('New', 'Body', { folder: 'School' });
          await notation.note.addTags(['bio', 'exam']);
          await notation.note.moveToFolder('School');
          await notation.note.moveToFolder(null);
          return [found[0].snippet, note.text, made.id].join('|');
        });
      ''';
      final r = await runtime(script, permissions: {ExtensionPermission.notesReadAll, ExtensionPermission.notesManage}).run('tool', 'a', {});
      expect(r.ok, isTrue, reason: r.error);
      expect(r.value, 'cells 3|cells|new1');
      expect(api.calls, ['create:New:Body:School', 'tags:bio,exam', 'move:School', 'move:null']);
      // (the note-wide permissions do not give these, nor the other way round)
      final denied = await runtime("notation.tool('a', async () => { try { await notation.notes.search('x'); } catch (e) { return e.message; } });",
              permissions: {ExtensionPermission.noteRead, ExtensionPermission.noteWrite, ExtensionPermission.notesManage})
          .run('tool', 'a', {});
      expect(denied.value, contains('notes.readAll'));
      final alsoDenied = await runtime("notation.tool('a', async () => { try { await notation.notes.create('x', 'y'); } catch (e) { return e.message; } });",
              permissions: {ExtensionPermission.notesReadAll, ExtensionPermission.noteWrite})
          .run('tool', 'a', {});
      expect(alsoDenied.value, contains('notes.manage'));
    }, skip: skip);

    test('folders, the library and the trash have their own permissions', () async {
      final script = '''
        notation.tool('a', async () => {
          const folders = await notation.folders.list();
          const notes = await notation.notes.list({ folder: 'School', limit: 500 });
          await notation.folders.create('Exams', { parent: 'School' });
          await notation.folders.rename('Exams', 'Finals');
          await notation.notes.move('n2', null);
          await notation.notes.tag('n2', ['bio']);
          await notation.notes.trash('n2');
          await notation.notes.restore('n2');
          return [folders[0].name, notes[0].folder, notes[0].limit].join('|');
        });
      ''';
      final r = await runtime(script, permissions: {ExtensionPermission.notesReadAll, ExtensionPermission.notesManage, ExtensionPermission.notesDelete}).run('tool', 'a', {});
      expect(r.ok, isTrue, reason: r.error);
      expect(r.value, 'School|School|50');
      expect(api.calls, ['mkfolder:Exams:School', 'rename:Exams:Finals', 'moveNote:n2:null', 'tagNote:n2:bio', 'trash:n2', 'restore:n2']);
      Future<String?> denied(String call, Set<ExtensionPermission> have) async =>
          (await runtime("notation.tool('a', async () => { try { await $call; } catch (e) { return e.message; } });", permissions: have).run('tool', 'a', {})).value as String?;
      // (managing notes is not deleting them)
      expect(await denied('notation.notes.trash("n2")', {ExtensionPermission.notesManage, ExtensionPermission.notesReadAll}), contains('notes.delete'));
      expect(await denied('notation.folders.list()', {ExtensionPermission.notesManage}), contains('notes.readAll'));
      expect(await denied('notation.folders.create("x")', {ExtensionPermission.notesReadAll}), contains('notes.manage'));
      expect(await denied('notation.notes.tag("n2", [])', {ExtensionPermission.notesManage}), contains('at most 20'));
    }, skip: skip);

    test('a PDF is read with the permission to read the note, another note\'s PDF needs the one for all notes', () async {
      final script = '''
        notation.tool('a', async () => {
          const mine = await notation.pdf.read({ from: 2, to: 3 });
          const found = await notation.pdf.search('cells');
          return [mine, found[0].page, found[0].snippet].join('|');
        });
      ''';
      final r = await runtime(script, permissions: {ExtensionPermission.noteRead}).run('tool', 'a', {});
      expect(r.ok, isTrue, reason: r.error);
      expect(r.value, 'pdf:null:2:3|2|cells:null');
      Future<String?> go(String call, Set<ExtensionPermission> have) async =>
          (await runtime("notation.tool('a', async () => { try { return String(await $call); } catch (e) { return e.message; } });", permissions: have).run('tool', 'a', {})).value as String?;
      expect(await go('notation.pdf.read({ id: "n9" })', {ExtensionPermission.noteRead}), contains('notes.readAll'));
      expect(await go('notation.pdf.read({ id: "n9", from: 4 })', {ExtensionPermission.notesReadAll}), 'pdf:n9:4:null');
      expect(await go('notation.pdf.search("x", { id: "n9" })', {ExtensionPermission.noteRead}), contains('notes.readAll'));
      expect(await go('notation.pdf.read()', {ExtensionPermission.notesReadAll}), contains('note.read'));
      expect(await go('notation.pdf.read({ from: 0 })', {ExtensionPermission.noteRead}), contains('page number'));
    }, skip: skip);

    test('tracked changes are settled and notes starred', () async {
      final r = await runtime('''
        notation.tool('a', async () => {
          const a = await notation.note.resolveChanges();
          const b = await notation.note.resolveChanges({ accept: false });
          await notation.notes.favorite('n2');
          await notation.notes.favorite('n3', false);
          return a.settled + b.settled;
        });
      ''', permissions: {ExtensionPermission.noteWrite, ExtensionPermission.notesManage}).run('tool', 'a', {});
      expect(r.ok, isTrue, reason: r.error);
      expect(r.value, 4);
      expect(api.calls, ['settle:true', 'settle:false', 'star:n2:true', 'star:n3:false']);
      final denied = await runtime("notation.tool('a', async () => { try { await notation.note.resolveChanges({ accept: 'yes' }); } catch (e) { return e.message; } });", permissions: {ExtensionPermission.noteWrite}).run('tool', 'a', {});
      expect(denied.value, contains('true (accept'));
    }, skip: skip);

    test('text boxes, pictures, drawing and the paper', () async {
      final script = '''
        notation.tool('a', async () => {
          const boxes = await notation.textBoxes.list();
          const made = await notation.textBoxes.add('Hi', { page: 2, x: 5, y: 6 });
          await notation.textBoxes.move('b1', { width: 300 });
          await notation.textBoxes.delete('b1');
          const images = await notation.images.list();
          await notation.images.move('i1', { x: 1, y: 2, width: 90 });
          await notation.images.delete('i1');
          const box = await notation.draw.shape({ type: 'rectangle', x: 10, y: 10, width: 100, height: 50, fill: '#ffeb3b' });
          const arrow = await notation.draw.shape({ type: 'arrow', x: 0, y: 0, x2: 100, y2: 0, page: 3 });
          const free = await notation.draw.strokes([{ points: [[0, 0], [5, 5], [9, 2]], color: '#ff0000' }]);
          const set = await notation.pages.setup({ paper: 'a5', orientation: 'landscape', margins: { left: 10 } });
          return [boxes[0].text, made.id, images[0].page, box.drawn, arrow.drawn, free.drawn, set].join('|');
        });
      ''';
      final r = await runtime(script, permissions: {ExtensionPermission.noteRead, ExtensionPermission.noteWrite, ExtensionPermission.drawPage, ExtensionPermission.pagesEdit}).run('tool', 'a', {});
      expect(r.ok, isTrue, reason: r.error);
      expect(r.value, 'Hello|b2|2|1|1|1|set {"paper":"a5","orientation":"landscape","margins":{"left":10}}');
      expect(api.calls, [
        'box:Hi:2:5.0:6.0:null',
        'moveBox:b1:null:null:null:300.0',
        'deleteBox:b1',
        'moveImage:i1:null:1.0:2.0:90.0',
        'deleteImage:i1',
        'draw:1:5:null:#ffeb3b',
        'draw:1:5:3:null',
        'draw:1:3:null:null',
      ]);
      Future<String?> denied(String call, Set<ExtensionPermission> have) async =>
          (await runtime("notation.tool('a', async () => { try { await $call; } catch (e) { return e.message; } });", permissions: have).run('tool', 'a', {})).value as String?;
      // (changing the text is not drawing, and drawing is not changing the text)
      expect(await denied('notation.draw.shape({type: "line", x: 0, y: 0, x2: 5, y2: 5})', {ExtensionPermission.noteWrite}), contains('draw.page'));
      expect(await denied('notation.textBoxes.add("x")', {ExtensionPermission.drawPage}), contains('note.write'));
      expect(await denied('notation.pages.setup({paper: "a4"})', {ExtensionPermission.noteWrite}), contains('pages.edit'));
      const all = {ExtensionPermission.noteRead, ExtensionPermission.noteWrite, ExtensionPermission.drawPage};
      expect(await denied('notation.draw.shape({type: "blob", x: 0, y: 0})', all), contains('rectangle'));
      expect(await denied('notation.draw.shape({type: "rectangle", x: 0, y: 0})', all), contains('"width"'));
      expect(await denied('notation.draw.shape({type: "line", x: 3, y: 3, x2: 3, y2: 3})', all), contains('no length'));
      expect(await denied('notation.draw.shape({type: "arrow", x: 0, y: 0, x2: 3, y2: 3, fill: "#fff"})', all), contains('cannot be filled'));
      expect(await denied('notation.draw.strokes([{points: [[0, 0]]}])', all), contains('two points'));
      expect(await denied('notation.textBoxes.add("x", { page: 0 })', all), contains('page number'));
      expect(await denied('notation.textBoxes.add("x", { width: -3 })', all), contains('positive'));
    }, skip: skip);

    test('the calendar has its own permission', () async {
      final script = '''
        notation.tool('a', async () => {
          const events = await notation.calendar.events('2026-12-24', '2026-12-31');
          await notation.calendar.addEvent('Lunch', '2026-12-25 12:00', { end: '2026-12-25T13:00', calendar: 'Work', description: 'with Sam' });
          await notation.calendar.addEvent('Holiday', '2026-12-26', { allDay: true });
          return events[0].title + events[0].start;
        });
      ''';
      final r = await runtime(script, permissions: {ExtensionPermission.calendarManage}).run('tool', 'a', {});
      expect(r.ok, isTrue, reason: r.error);
      expect(r.value, 'Exam2026-12-24T09:00');
      expect(api.calls, ['event:Lunch:2026-12-25T12:00:2026-12-25T13:00:false:Work:with Sam', 'event:Holiday:2026-12-26:null:true:null:null']);
      Future<String?> denied(String call, Set<ExtensionPermission> have) async =>
          (await runtime("notation.tool('a', async () => { try { await $call; } catch (e) { return e.message; } });", permissions: have).run('tool', 'a', {})).value as String?;
      expect(await denied('notation.calendar.events("2026-12-24", "2026-12-25")', {ExtensionPermission.tasks}), contains('calendar.manage'));
      const have = {ExtensionPermission.calendarManage};
      expect(await denied('notation.calendar.events("2026-12-24", "2027-12-25")', have), contains('62 days'));
      expect(await denied('notation.calendar.events("soon", "later")', have), contains('days like'));
      expect(await denied('notation.calendar.addEvent("x", "2026-12-26")', have), contains('times like'));
      expect(await denied('notation.calendar.addEvent("x", "2026-12-26T10:00", { allDay: true })', have), contains('days like'));
    }, skip: skip);

    test('reminders and flashcards have their own permissions', () async {
      final script = '''
        notation.tool('a', async () => {
          const made = await notation.reminders.add('Call', '2026-12-24 09:30', { repeat: 'weekly', aboutNote: true });
          const all = await notation.reminders.list();
          await notation.reminders.remove(all[0].id);
          const cards = await notation.cards.add([{ front: 'Q', back: 'A' }, { front: 'Q2', back: 'A2' }]);
          return [made.id, all[0].at, cards.added].join('|');
        });
      ''';
      final r = await runtime(script, permissions: {ExtensionPermission.remindersManage, ExtensionPermission.cardsAdd}).run('tool', 'a', {});
      expect(r.ok, isTrue, reason: r.error);
      expect(r.value, 'r1|2026-12-24T09:30|2');
      expect(api.calls, ['remind:Call:2026-12-24T09:30:weekly:true', 'unremind:r1', 'cards:Q>A,Q2>A2']);
      Future<String?> denied(String call, Set<ExtensionPermission> have) async =>
          (await runtime("notation.tool('a', async () => { try { await $call; } catch (e) { return e.message; } });", permissions: have).run('tool', 'a', {})).value as String?;
      expect(await denied('notation.cards.add([{front: "q", back: "a"}])', {ExtensionPermission.remindersManage}), contains('cards.add'));
      expect(await denied('notation.reminders.list()', {ExtensionPermission.cardsAdd}), contains('reminders.manage'));
      const both = {ExtensionPermission.remindersManage, ExtensionPermission.cardsAdd};
      expect(await denied('notation.reminders.add("x", "tomorrow")', both), contains('2026-12-24T09:30'));
      expect(await denied('notation.reminders.add("x", "2026-12-24T09:30", { repeat: "often" })', both), contains('weekly'));
      expect(await denied('notation.cards.add([{front: "q"}])', both), contains('"front" and a "back"'));
      expect(await denied('notation.cards.add([])', both), contains('1 to 30'));
    }, skip: skip);

    test('pages and tasks have their own permissions', () async {
      final script = '''
        notation.tool('a', async () => {
          const pages = await notation.pages.list();
          const added = await notation.pages.add({ at: 2 });
          const end = await notation.pages.add();
          await notation.pages.move(3, 1);
          await notation.pages.delete(2);
          const tasks = await notation.tasks.list({ done: true });
          await notation.tasks.complete('t1');
          await notation.tasks.complete('t1', false);
          await notation.tasks.update('t1', { title: 'Buy oat milk' });
          await notation.tasks.update('t1', { due: null });
          await notation.tasks.remove('t1');
          return [pages[0].strokes, added.page, end.page, tasks[0].title, tasks[0].done].join('|');
        });
      ''';
      final r = await runtime(script, permissions: {ExtensionPermission.noteRead, ExtensionPermission.pagesEdit, ExtensionPermission.tasksManage}).run('tool', 'a', {});
      expect(r.ok, isTrue, reason: r.error);
      expect(r.value, '2|2|4|Buy milk|true');
      expect(api.calls, [
        'addPage:2',
        'addPage:null',
        'movePage:3:1',
        'deletePage:2',
        'complete:t1:true',
        'complete:t1:false',
        'update:t1:Buy oat milk:null:false',
        'update:t1:null:null:true',
        'remove:t1',
      ]);
      Future<String?> denied(String call, Set<ExtensionPermission> have) async =>
          (await runtime("notation.tool('a', async () => { try { await $call; } catch (e) { return e.message; } });", permissions: have).run('tool', 'a', {})).value as String?;
      // (adding tasks is not managing them, and reading the note is not changing its pages)
      expect(await denied('notation.pages.delete(2)', {ExtensionPermission.noteRead, ExtensionPermission.noteWrite}), contains('pages.edit'));
      expect(await denied('notation.pages.list()', {ExtensionPermission.pagesEdit}), contains('note.read'));
      expect(await denied('notation.tasks.list()', {ExtensionPermission.tasks}), contains('tasks.manage'));
      expect(await denied('notation.tasks.remove("t1")', {ExtensionPermission.tasks}), contains('tasks.manage'));
      // (a wrong argument is an error the script can read)
      const all = {ExtensionPermission.noteRead, ExtensionPermission.pagesEdit, ExtensionPermission.tasksManage};
      expect(await denied('notation.pages.delete(0)', all), contains('page number'));
      expect(await denied('notation.pages.move(1, "x")', all), contains('page number'));
      expect(await denied('notation.pages.add({ at: 0 })', all), contains('from 1'));
      expect(await denied('notation.tasks.update("t1", {})', all), contains('"title" or a "due"'));
      expect(await denied('notation.tasks.update("t1", { due: "soon" })', all), contains('2026-12-24'));
      expect(await denied('notation.tasks.complete("t1", "yes")', all), contains('true or false'));
      expect(api.calls.length, 9);
    }, skip: skip);

    test('a task with a date that is not one', () async {
      final r = await runtime("notation.tool('a', async () => { try { await notation.tasks.add('x', { due: 'tomorrow' }); } catch (e) { return e.message; } });", permissions: {ExtensionPermission.tasks}).run('tool', 'a', {});
      expect(r.value, contains('2026-12-24'));
      expect(api.calls, isEmpty);
    }, skip: skip);

    test('what a place cannot do is an error the script can catch', () async {
      final bare = _BareApi();
      final rt = ExtensionRuntime(
        manifest: const ExtensionManifest(id: 'abc', name: 'x', version: '1', permissions: {ExtensionPermission.noteRead}),
        script: "notation.tool('a', async () => { try { await notation.note.get(); } catch (e) { return e.message; } });",
        granted: {ExtensionPermission.noteRead},
        api: bare,
        storage: storage,
        fetch: (u, {method = 'GET', headers = const {}, body}) async => {},
      );
      expect((await rt.run('tool', 'a', {})).value, 'There is no note here.');
    }, skip: skip);
  });

  group('the network', () {
    const perm = {ExtensionPermission.network};
    String script(String url) => "notation.tool('a', async () => { try { return (await notation.network.fetch('$url')).body; } catch (e) { return 'error: ' + e.message; } });";

    test('a website that was listed', () async {
      final r = await runtime(script('https://api.example.com/x'), permissions: perm, hosts: ['api.example.com']).run('tool', 'a', {});
      expect(r.value, 'hello from api.example.com');
      expect(fetched.single.path, '/x');
    }, skip: skip);

    test('one that was not, http, and the address of this computer', () async {
      for (final url in ['https://evil.example.org/x', 'http://api.example.com/x', 'https://localhost/x', 'file:///etc/passwd', 'https://api.example.com.evil.org/']) {
        final r = await runtime(script(url), permissions: perm, hosts: ['api.example.com']).run('tool', 'a', {});
        expect('${r.value}', startsWith('error: '), reason: url);
      }
      expect(fetched, isEmpty);
    }, skip: skip);
  });

  group('what an extension keeps', () {
    test('values stay from one run to the next', () async {
      const script = '''
        notation.tool('count', async () => { const n = ((await notation.storage.get('n')) || 0) + 1; await notation.storage.set('n', n); return n; });
      ''';
      expect((await runtime(script).run('tool', 'count', {})).value, 1);
      expect((await runtime(script).run('tool', 'count', {})).value, 2);
      expect(storage.data, {'n': 2});
    }, skip: skip);

    test('not more than 64 KB', () async {
      final r = await runtime("notation.tool('a', async () => { try { await notation.storage.set('big', 'x'.repeat(70000)); } catch (e) { return e.message; } });").run('tool', 'a', {});
      expect(r.value, contains('too much'));
      expect(storage.data, isEmpty);
    }, skip: skip);
  });
}

class _BareApi extends ExtensionApi {}
