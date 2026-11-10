import 'dart:io';
import 'dart:typed_data';

import 'package:notes/automations/automation_service.dart' show NoteEditorHandle;
import 'package:notes/data/app_database.dart';
import 'package:notes/data/lock_repository.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/tag_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/history/note_history.dart';
import 'package:notes/mcp/mcp_notes.dart';
import 'package:notes/mcp/mcp_service.dart';
import 'package:notes/sync/caldav_service.dart' show SecretStore;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The token of the fixture (and of the dev server, see `dev_server_test.dart`): not a secret, the library it opens is made up.
const mcpDevToken = 'notation-dev-token-0000000000000000';

class _FixedSecret implements SecretStore {
  String? value;
  _FixedSecret(this.value);
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

/// A port nobody listens on.
Future<int> freeLoopbackPort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// The real MCP stack (the service, the HTTP server, the tools, the repositories, a note history that keeps real versions) over a made-up
/// library, for tests that talk to it the way an agent does, and for the dev server an agent in Claude Code can be pointed at.
class McpFixture {
  final Database db;
  final NoteRepository repository;
  final TaskRepository tasks;
  final TagRepository tags;
  final NoteHistory history;
  final McpService service;
  final Directory _dir;

  /// The ids of the notes and folders made, by what they are called here: `thermo`, `shopping`, `plan`, `diary` (locked), `draft`
  /// (in the trash), `school`, `maths`, `work`.
  final Map<String, String> ids;

  McpFixture._(this.db, this.repository, this.tasks, this.tags, this.history, this.service, this._dir, this.ids);

  String get url => service.url;
  String get token => service.token!;

  Future<void> close() async {
    await service.stop();
    service.dispose();
    if (_dir.existsSync()) await _dir.delete(recursive: true);
  }
}

/// Starts it on [port] (a free one if null) with [token]. [editorOf] says which notes are open in an editor.
Future<McpFixture> startMcpFixture({int? port, String token = mcpDevToken, bool canChange = true, NoteEditorHandle? Function(String id)? editorOf}) async {
  final db = await AppDatabase.open(path: inMemoryDatabasePath);
  // (an in-memory database is shared by what runs in one file)
  for (final t in ['notes', 'folders', 'tasks', 'note_tags', 'note_versions']) {
    await db.delete(t);
  }
  final repository = NoteRepository(db);
  final tasks = TaskRepository(db);
  final tags = TagRepository(db);
  final dir = await Directory.systemTemp.createTemp('notation_mcp_');
  final history = NoteHistory(db, repository, supportDirectory: () async => dir); // (not started: only the versions the agent asks for)
  final ids = await _seed(repository, tasks, tags);

  final stored = {'mcp_enabled': '1', 'mcp_port': '${port ?? await freeLoopbackPort()}', 'mcp_access': canChange ? 'write' : 'read'};
  final service = McpService(
    notes: McpNotes(repository: repository, tasks: tasks, tags: tags, history: history, editorOf: editorOf),
    read: (k) async => stored[k],
    write: (k, v) async => stored[k] = v,
    secret: _FixedSecret(token),
  );
  await service.load();
  if (!service.running) {
    final why = service.error;
    service.dispose();
    await dir.delete(recursive: true);
    throw StateError('The MCP server did not start: $why');
  }
  return McpFixture._(db, repository, tasks, tags, history, service, dir, ids);
}

Future<Map<String, String>> _seed(NoteRepository repo, TaskRepository tasks, TagRepository tags) async {
  Future<String> note(String title, String text, {String? folder, List<String> tag = const [], bool star = false}) async {
    final id = await repo.createNote(title: title, folderId: folder);
    final n = (await repo.loadNote(id))!;
    n.documentText = text;
    await repo.saveNote(n);
    if (tag.isNotEmpty) await tags.setTags(id, tag);
    if (star) await repo.setFavorite(id, true);
    return id;
  }

  final school = await repo.createFolder('School');
  final maths = await repo.createFolder('Maths', parentId: school);
  final work = await repo.createFolder('Work');
  final ids = {
    'school': school,
    'maths': maths,
    'work': work,
    'thermo': await note('Thermodynamics', '# Entropy\n\nEntropy never decreases in an isolated system.\n\nHeat flows from hot to cold.', folder: school, tag: ['physics', 'school/physics'], star: true),
    'shopping': await note('Shopping list', '- [ ] milk\n- [ ] bread\n- [ ] eggs'),
    'plan': await note('Project plan', '## Goals\n\nShip the beta.\n\n## Risks\n\nNone yet.', folder: work, tag: ['work']),
    'diary': await note('Locked diary', 'dear diary: the password is swordfish'),
    'draft': await note('Old draft', 'Nothing to see here.'),
  };
  await repo.locks.putLock(ids['diary']!, LockRow(mode: 1, salt: Uint8List(16), iterations: 1));
  await repo.trashNote(ids['draft']!);
  await tasks.createTask('Hand in essay', dueDate: DateTime(2026, 12, 24));
  await tasks.createTask('Buy milk');
  await tasks.setDone(await tasks.createTask('Water the plants'), true);
  return ids;
}
