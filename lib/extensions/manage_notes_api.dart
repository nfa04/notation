import '../data/note_data.dart';
import '../data/note_repository.dart';
import '../data/tag_repository.dart';
import 'extension_host.dart';

/// The calls of the extension API that file the person's notes (make notes and folders, move, tag, star, put in the trash and bring
/// back). They are done on the notes as the database holds them, so the editor (for the assistant and the extensions) and the
/// assistant of all notes answer them the same way.
mixin ManageNotesApi on ExtensionApi {
  NoteRepository get managedNotes;

  /// Null where tags cannot be set.
  TagRepository? get managedTags;

  /// Whether note [id] is open in an editor now: it cannot be put in the trash from here (its editor would write it back).
  bool isOpenNote(String id);

  /// The folder called [name] (case does not matter); a name that is not there says which folders there are.
  Future<FolderEntry> folderNamed(String name) async {
    final folders = await managedNotes.listFolders();
    final found = folders.where((f) => f.name.toLowerCase() == name.trim().toLowerCase()).firstOrNull;
    return found ?? (throw ExtensionError('There is no folder "$name". The folders are: ${folders.map((f) => f.name).join(', ')}.'));
  }

  /// Note [id], which must exist and not be locked.
  Future<NoteSummary> changeableNote(String id) async {
    final found = (await managedNotes.listNotes()).where((n) => n.id == id).firstOrNull;
    if (found == null) throw ExtensionError('There is no such note. notes.search and notes.list give the ids.');
    if (found.locked) throw ExtensionError('That note is locked: it cannot be changed from here.');
    return found;
  }

  @override
  Future<String> createNote(String title, String text, {String? folder}) async {
    final repo = managedNotes;
    final folderId = folder == null ? null : (await folderNamed(folder)).id;
    final id = await repo.createNote(title: title.trim().isEmpty ? 'Untitled Note' : title.trim(), folderId: folderId);
    if (text.trim().isNotEmpty) {
      final note = await repo.loadNote(id);
      if (note != null) await repo.saveNote(note..documentText = text);
    }
    return id;
  }

  @override
  Future<List<Map<String, Object?>>> listFolders() async {
    final folders = await managedNotes.listFolders();
    final names = {for (final f in folders) f.id: f.name};
    return [for (final f in folders) {'name': f.name, 'parent': names[f.parentId], 'notes': f.noteCount}];
  }

  @override
  Future<void> createFolder(String name, {String? parent}) async {
    final clean = name.trim();
    if (clean.isEmpty) throw ExtensionError('"name" is empty.');
    final repo = managedNotes;
    if ((await repo.listFolders()).any((f) => f.name.toLowerCase() == clean.toLowerCase())) throw ExtensionError('There is a folder "$clean" already.');
    await repo.createFolder(clean, parentId: parent == null ? null : (await folderNamed(parent)).id);
  }

  @override
  Future<void> renameFolder(String name, String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty) throw ExtensionError('"newName" is empty.');
    await managedNotes.renameFolder((await folderNamed(name)).id, clean);
  }

  @override
  Future<void> moveNoteTo(String id, String? folder) async {
    await changeableNote(id);
    await managedNotes.moveNote(id, folder == null ? null : (await folderNamed(folder)).id);
  }

  @override
  Future<void> tagNote(String id, List<String> tags) async {
    final repository = managedTags;
    if (repository == null) throw ExtensionError('Tags cannot be set here.');
    await changeableNote(id);
    await repository.setTags(id, {...await repository.tagsOf(id), ...tags});
  }

  @override
  Future<void> trashNote(String id) async {
    if (isOpenNote(id)) throw ExtensionError('That is the note that is open: close it first.');
    await changeableNote(id);
    await managedNotes.trashNote(id);
  }

  @override
  Future<void> restoreNote(String id) async {
    final repo = managedNotes;
    if (!(await repo.listTrash()).any((n) => n.id == id)) throw ExtensionError('There is no such note in the trash.');
    await repo.restoreNote(id);
  }

  @override
  Future<void> favoriteNote(String id, bool on) async {
    await changeableNote(id);
    await managedNotes.setFavorite(id, on);
  }
}
