import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/automations/automation_service.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/extensions/extension_manifest.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/extensions/script_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const manifest = '''{
  "id": "daily", "name": "Daily", "version": "1",
  "permissions": ["tasks.add", "note.read"],
  "actions": [{ "id": "task", "title": "Make a task" }]
}''';
const script = '''
  notation.action('task', async (ctx) => {
    const note = await notation.note.get();
    await notation.tasks.add('Review ' + ctx.note.title + ' (' + ctx.event + ')', { due: '2026-03-08' });
    return 'made a task, the note has ' + note.text.length + ' letters';
  });
''';

void main() {
  setUpAll(AppDatabase.initFfi);
  final skip = QuickJsEngine.available ? null : 'the JavaScript engine is not here (LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib)';

  late Directory dir;
  late NoteRepository notes;
  late TaskRepository tasks;
  late ExtensionService extensions;
  late AutomationService service;
  late String noteId;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('extauto');
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('settings', where: "key = 'automations'");
    await db.delete('tasks');
    notes = NoteRepository(db);
    tasks = TaskRepository(db);
    extensions = ExtensionService((k) async => null, (k, v) async {}, directory: () async => Directory('${dir.path}/ext'), addTask: (title, due) async {
      await tasks.createTask(title, dueDate: due);
    });
    service = AutomationService(notes, tasks, extensions: extensions);
    await service.load();
    noteId = await notes.createNote();
  });
  tearDown(() async {
    service.dispose();
    await dir.delete(recursive: true);
  });

  const auto = Automation(id: 'x', event: AutomationEvent.noteClosed, action: AutomationAction.extensionAction, params: {'extension': 'daily/task'});

  test('an automation runs an action of an extension, with the permissions it was given', () async {
    await extensions.installSource(manifest, script);
    await extensions.setEnabled('daily', true);
    await extensions.setGranted('daily', ExtensionPermission.tasks, true);
    await extensions.setGranted('daily', ExtensionPermission.noteRead, true);
    await service.add(auto);
    final out = await service.run(AutomationEvent.noteClosed, noteId: noteId, title: 'Physics');
    expect(out.single, startsWith('made a task, the note has '));
    expect((await tasks.listTasks()).map((t) => t.title), ['Review Physics (noteClosed)']);
  }, skip: skip);

  test('without a permission it fails with the reason, and nothing is done', () async {
    await extensions.installSource(manifest, script);
    await extensions.setEnabled('daily', true);
    await extensions.setGranted('daily', ExtensionPermission.tasks, true); // (not note.read)
    await service.add(auto);
    final out = await service.run(AutomationEvent.noteClosed, noteId: noteId, title: 'Physics');
    expect(out.single, allOf(startsWith('Failed:'), contains('note.read')));
    expect(await tasks.listTasks(), isEmpty);
  }, skip: skip);

  test('an extension that is off, gone or not there says so', () async {
    await extensions.installSource(manifest, script);
    await service.add(auto);
    expect((await service.run(AutomationEvent.noteClosed, noteId: noteId, title: 'P')).single, contains('switched off'));
    await extensions.remove('daily');
    // (a note that was not changed since is not run again for the same automation: this is another)
    final again = AutomationService(notes, tasks);
    await again.load();
    await again.add(const Automation(id: 'y', event: AutomationEvent.noteClosed, action: AutomationAction.extensionAction, params: {'extension': 'daily/task'}));
    expect((await again.run(AutomationEvent.noteClosed, noteId: noteId, title: 'P')).single, contains('not available'));
    again.dispose();
  });
}
