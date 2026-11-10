import '../data/note_repository.dart';
import '../search/search_query.dart';
import 'extension_host.dart';

/// The calls of the extension API that read the person's other notes: searching, listing and reading them, and the text of their
/// PDFs. They belong to no open note, so the editor (for the assistant and the extensions) and the weekly review's assistant answer
/// them the same way. A locked note is not read.
mixin NotesReadApi on ExtensionApi {
  NoteRepository get notesRepository;

  @override
  Future<List<Map<String, Object?>>> searchNotes(String query, {int limit = 10}) async {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) throw ExtensionError('"query" is empty.');
    final repo = notesRepository;
    final titles = {for (final n in await repo.listNotes()) n.id: n.title};
    final seen = <String, List<SearchSource>>{};
    for (final s in await repo.text.searchSources()) {
      (seen[s.noteId] ??= []).add(s);
    }
    final found = <({String id, int score, String snippet})>[];
    for (final e in seen.entries) {
      if (!titles.containsKey(e.key)) continue;
      var score = 0;
      var every = true;
      String? snippet;
      for (final w in words) {
        var any = false;
        for (final s in e.value) {
          final low = s.text.toLowerCase();
          final at = low.indexOf(w);
          if (at < 0) continue;
          any = true;
          score += s.place == SearchPlace.title ? 5 : 1;
          snippet ??= s.text.substring((at - 50).clamp(0, s.text.length), (at + w.length + 70).clamp(0, s.text.length)).replaceAll(RegExp(r'\s+'), ' ').trim();
        }
        if (!any) every = false;
      }
      if (every) found.add((id: e.key, score: score, snippet: snippet ?? ''));
    }
    found.sort((a, b) => b.score.compareTo(a.score));
    return [for (final f in found.take(limit)) {'id': f.id, 'title': titles[f.id], 'snippet': f.snippet}];
  }

  @override
  Future<Map<String, Object?>> readNote(String id) async {
    final repo = notesRepository;
    final title = (await repo.listNotes()).where((n) => n.id == id).firstOrNull?.title;
    final text = title == null ? '' : await repo.text.noteText(id, limit: 20000);
    if (title == null || text.isEmpty) throw ExtensionError('There is no such note, or it is locked.');
    return {'id': id, 'title': title, 'text': text};
  }

  @override
  Future<List<Map<String, Object?>>> listNotes({String? folder, int limit = 20}) async {
    final repo = notesRepository;
    final all = await repo.listFolders();
    final folders = {for (final f in all) f.id: f.name};
    String? only;
    if (folder != null) {
      final found = all.where((f) => f.name.toLowerCase() == folder.trim().toLowerCase()).firstOrNull;
      only = (found ?? (throw ExtensionError('There is no folder "$folder". The folders are: ${all.map((f) => f.name).join(', ')}.'))).id;
    }
    String two(int n) => n.toString().padLeft(2, '0');
    return [
      for (final n in (await repo.listNotes()).where((n) => only == null || n.folderId == only).take(limit))
        {'id': n.id, 'title': n.locked ? 'Locked note' : n.title, 'folder': folders[n.folderId], 'updated': '${n.updatedAt.year.toString().padLeft(4, '0')}-${two(n.updatedAt.month)}-${two(n.updatedAt.day)}'},
    ];
  }
}
