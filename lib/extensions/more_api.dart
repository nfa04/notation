import '../ai/ai_prompt.dart';
import '../ai/ai_service.dart';
import '../citations/citation_repository.dart';
import '../citations/source.dart';
import '../data/card_repository.dart';
import '../data/link_repository.dart';
import '../data/note_repository.dart';
import '../data/tag_repository.dart';
import 'extension_host.dart';

/// The newer calls of the extension API that look at what is around the notes: their links, tags, flashcards and citations, the AI the
/// person chose, and the handwriting that was read. Each place says where its data is (null: not there, the call says so); the
/// permissions are checked before these are called.
mixin MoreApi on ExtensionApi {
  NoteRepository? get moreNotes => null;
  LinkRepository? get moreLinks => null;
  TagRepository? get moreTags => null;
  CardRepository? get moreCards => null;
  CitationRepository? get moreCitations => null;
  AiService? get moreAi => null;

  /// The id of the note that is open or the event is about; null: none.
  String? get moreNoteId => null;

  Future<String> _noteTitle(String id) async {
    final found = (await (moreNotes ?? (throw ExtensionError('Notes cannot be looked at here.'))).listNotes()).where((n) => n.id == id).firstOrNull;
    if (found == null) throw ExtensionError('There is no such note.');
    return found.locked ? 'Locked note' : found.title;
  }

  String _idOrOpen(String? id) => id ?? moreNoteId ?? (throw ExtensionError('There is no note here: say which one by its id.'));

  @override
  Future<List<Map<String, Object?>>> noteLinks(String? id) async {
    final repo = moreNotes ?? (throw ExtensionError('Links cannot be looked at here.'));
    final note = _idOrOpen(id);
    final titles = {for (final n in await repo.listNotes()) n.id: n.locked ? 'Locked note' : n.title};
    if (!titles.containsKey(note)) throw ExtensionError('There is no such note.');
    final text = await repo.text.noteText(note, limit: 200000);
    return [
      for (final target in linkedNoteIds(text))
        if (titles.containsKey(target) && target != note) {'id': target, 'title': titles[target]},
    ];
  }

  @override
  Future<List<Map<String, Object?>>> noteBacklinks(String? id) async {
    final links = moreLinks ?? (throw ExtensionError('Links cannot be looked at here.'));
    final note = _idOrOpen(id);
    await _noteTitle(note);
    return [
      for (final b in (await links.linksTo(note)).take(100)) {'id': b.noteId, 'title': b.title, 'page': b.page == null ? null : b.page! + 1, 'snippet': b.snippet},
    ];
  }

  @override
  Future<List<Map<String, Object?>>> notesWithTag(String tag) async {
    final tags = moreTags ?? (throw ExtensionError('Tags cannot be looked at here.'));
    final repo = moreNotes ?? (throw ExtensionError('Tags cannot be looked at here.'));
    final want = tag.trim().toLowerCase().replaceFirst(RegExp(r'^#'), '');
    if (want.isEmpty) throw ExtensionError('"tag" is empty.');
    final byNote = await tags.all();
    final titles = {for (final n in await repo.listNotes()) n.id: n.locked ? 'Locked note' : n.title};
    return [
      for (final e in byNote.entries)
        if (titles.containsKey(e.key) && e.value.any((t) => t == want || t.startsWith('$want/'))) {'id': e.key, 'title': titles[e.key], 'tags': e.value.toList()..sort()},
    ].take(100).toList();
  }

  @override
  Future<List<Map<String, Object?>>> listTags() async {
    final tags = moreTags ?? (throw ExtensionError('Tags cannot be looked at here.'));
    return [for (final e in (await tags.counts()).entries) {'tag': e.key, 'notes': e.value}];
  }

  @override
  Future<List<Map<String, Object?>>> listCards({bool due = false, int limit = 50}) async {
    final cards = moreCards ?? (throw ExtensionError('Flashcards cannot be looked at here.'));
    final list = due ? await cards.due(limit: limit) : (await cards.all()).take(limit).toList();
    String day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return [for (final c in list) {'id': c.id, 'front': c.card.front, 'back': c.card.back, 'source': c.source, 'due': day(c.schedule.due ?? DateTime.now())}];
  }

  @override
  Future<List<Map<String, Object?>>> searchCitations(String query) async {
    final repo = moreCitations ?? (throw ExtensionError('Citations cannot be looked at here.'));
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) throw ExtensionError('"query" is empty.');
    return [
      for (final s in await repo.all())
        if (words.every((w) => [s.id, s.title, s.container, s.doi, ...s.authors.map((a) => '${a.given} ${a.family}')].any((f) => f.toLowerCase().contains(w))))
          {'id': s.id, 'title': s.title, 'authors': [for (final a in s.authors) a.literal ? a.family : '${a.given} ${a.family}'.trim()], 'year': s.year},
    ].take(30).toList();
  }

  @override
  Future<String> addCitation(Map<String, Object?> source) async {
    final repo = moreCitations ?? (throw ExtensionError('Citations cannot be added here.'));
    final title = source['title'];
    if (title is! String || title.trim().isEmpty) throw ExtensionError('A source needs a "title".');
    final taken = {for (final s in await repo.all()) s.id};
    final draft = CitationSource.fromJson({...source}, id: 'draft');
    final key = CitationSource.makeKey(draft, taken);
    // the same work (same DOI, or same title and year) is not added twice
    for (final s in await repo.all()) {
      if ((draft.doi.isNotEmpty && s.doi.toLowerCase() == draft.doi.toLowerCase()) || (s.title.toLowerCase() == draft.title.toLowerCase() && s.year == draft.year)) return s.id;
    }
    await repo.save(CitationSource.fromJson({...source}, id: key));
    return key;
  }

  @override
  String? get aiPlace {
    final ai = moreAi;
    return ai?.provider == null ? null : (ai!.provider!.id == 'on-device' ? 'device' : 'service');
  }

  @override
  Future<String> aiComplete(String prompt, {int maxTokens = 400}) async {
    final ai = moreAi;
    if (ai == null || ai.provider == null) throw ExtensionError('No AI is set up: the person has to choose one in the settings.');
    return ai.generate(AiPrompt(system: 'You answer for a small program that was written for the person. Answer briefly and only with what was asked.', user: prompt), maxTokens: maxTokens);
  }

  @override
  Future<List<Map<String, Object?>>> inkReadings({int? page}) async {
    final repo = moreNotes ?? (throw ExtensionError('Handwriting cannot be looked at here.'));
    final id = _idOrOpen(null);
    final text = repo.text;
    final formulas = await text.inkFormulas(id);
    final reads = await text.inkReads(id);
    return [
      for (final f in formulas)
        if (page == null || f.page + 1 == page) {'page': f.page + 1, 'top': f.top, 'left': f.left, 'latex': f.latex},
      for (final r in reads)
        if (r.place != null && (r.text ?? '').isNotEmpty && (page == null || r.place!.page + 1 == page)) {'page': r.place!.page + 1, 'top': r.place!.top, 'left': r.place!.left, 'text': r.text},
    ];
  }
}
