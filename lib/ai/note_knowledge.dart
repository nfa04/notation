import 'dart:math' as math;
import 'dart:typed_data';

import '../automations/note_sorter.dart';
import '../citations/citation_service.dart';
import '../citations/source.dart';
import '../data/note_data.dart';
import '../data/note_repository.dart';
import '../graph/graph_builder.dart' show telltaleWords;
import '../l10n/language.dart';
import '../llm/embedding_service.dart';
import '../search/pdf_indexer.dart';
import '../search/search_query.dart';
import 'document_index.dart';

/// Stands in for the sentence model where there is none: the words alone decide then.
class NoEmbedder implements TextEmbedder {
  const NoEmbedder();
  @override
  String get modelId => '';
  @override
  Future<Float32List> embed(String text) => throw StateError('There is no sentence model.');
}

/// A passage of one of the notes that was found for a question.
class Passage {
  final String noteId;
  final String title;

  /// 'Page 3', 'Title'.
  final String label;

  /// Zero-based; null when the passage belongs to no page.
  final int? page;
  final String text;
  final double score;

  const Passage(this.noteId, this.title, this.label, this.page, this.text, this.score);
}

/// What was found in the notes for a question: the notes that are closest (best first) and, from them, the passages that answer it.
class Retrieval {
  final List<({String id, String title, double score})> notes;
  final List<Passage> passages;

  const Retrieval(this.notes, this.passages);

  /// The passages as the assistant reads them, each marked with its note and page, as much as fits in [budget] characters.
  String render(int budget) {
    final out = StringBuffer();
    String? last;
    for (final p in passages) {
      final mark = '[${p.title} - ${p.label}]';
      final piece = StringBuffer();
      if (mark != last) {
        if (out.isNotEmpty) piece.write('\n\n');
        piece.write('$mark\n');
        last = mark;
      } else {
        piece.write('\n');
      }
      piece.write(p.text);
      if (out.length + piece.length > budget && out.isNotEmpty) break;
      out.write(piece);
    }
    return out.toString();
  }
}

/// The text of note [id] cut into passages: the title, the written document, the text boxes and the text of the PDF, each
/// with its page. A locked note has none.
Future<List<DocChunk>> chunksOfNote(NoteRepository notes, String id) async {
  if (await notes.locks.lockModeOf(id) != 0) return const [];
  final chunks = <DocChunk>[];
  for (final s in await notes.text.searchSources(noteId: id)) {
    if (s.place == SearchPlace.pdfName || s.text.trim().isEmpty) continue;
    final page = s.page >= 0 ? s.page : null;
    final label = s.place == SearchPlace.title ? tr('Title') : tr('Page {n}', {'n': (page ?? 0) + 1});
    chunks.addAll(chunkText(label, page, s.text));
  }
  return chunks;
}

/// Finds what the notes say about a question. First the few notes that are closest to it (by the vectors that the sorting of
/// notes made, with the words as a second opinion), then, in those, the passages that are closest: every note is cut into
/// passages once, each with a vector of its own, and kept until the note changes. Without a sentence model the words alone decide.
class NoteKnowledge {
  final NoteRepository _notes;
  final TextEmbedder _embedder;
  final NoteSorter _sorter;

  /// Whether the sentence model is there to read with.
  final bool Function() ready;

  /// The library of sources: a question that names one (an author, a title, a key) is answered with the notes that cite it.
  final CitationService? citations;

  NoteKnowledge(this._notes, this._embedder, this._sorter, {required this.ready, this.citations});

  /// The notes that cite a source the question names, each with those sources. A source is named by its key, by the family name of
  /// one of its authors, or by two of the telling words of its title.
  Future<Map<String, List<CitationSource>>> _citingNotes(String question) async {
    final library = citations;
    if (library == null || !library.enabled() || library.sources.isEmpty) return const {};
    final asked = question.toLowerCase();
    final tokens = {for (final m in RegExp(r'[\p{L}\p{N}_:.\-/]+', unicode: true).allMatches(asked)) m[0]!.replaceFirst(RegExp(r'[.:\-/]+$'), '')};
    final words = {for (final m in RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches(asked)) m[0]!};
    final named = <CitationSource>[
      for (final s in library.sources)
        if (tokens.contains(s.id.toLowerCase()) ||
            [...s.authors, ...s.editors].any((p) => p.family.length >= 3 && p.family.toLowerCase().split(RegExp(r'\s+')).every(words.contains)) ||
            telltaleWords(s.title).where((w) => w.length >= 4 && words.contains(w)).toSet().length >= 2)
          s,
    ];
    if (named.isEmpty) return const {};
    final byKey = {for (final s in named) s.id: s};
    final out = <String, List<CitationSource>>{};
    for (final e in (await _notes.knowledge.noteCitations(isSource: library.has)).entries) {
      final hits = [for (final k in e.value) ?byKey[k]];
      if (hits.isNotEmpty) out[e.key] = hits;
    }
    return out;
  }

  /// The passages of note [id], made now if there are none or the note has changed since. Returns how many there are.
  Future<int> analyse(String id) async {
    final pieces = [for (final c in await chunksOfNote(_notes, id)) (page: c.page, label: c.where, text: c.text)];
    final model = ready() ? _embedder.modelId : '';
    final hash = NoteSorter.hashOf(pieces.map((p) => '${p.label}|${p.text}').join('\n'));
    final state = await _notes.knowledge.chunkState(id);
    if (state != null && state.textHash == hash && (state.model == model || model.isEmpty)) return pieces.length;

    final chunks = <StoredChunk>[];
    for (final p in pieces) {
      chunks.add(StoredChunk(p.page, p.label, p.text, model.isEmpty ? null : await _embedder.embed(p.text)));
    }
    await _notes.knowledge.saveChunks(id, model, hash, chunks);
    return chunks.length;
  }

  /// How many of the words of the question [text] has, 0 to 1.
  static double _overlap(Set<String> terms, String text) {
    if (terms.isEmpty) return 0;
    final has = searchTerms(text).toSet();
    return terms.where(has.contains).length / terms.length;
  }

  /// The [notes] closest notes to [question] and from them the best [passages] passages. [status] tells what is going on.
  Future<Retrieval> retrieve(String question, {int notes = 4, int passages = 8, void Function(String status)? status}) async {
    final terms = searchTerms(question).toSet();
    await PdfIndexer(_notes).run(); // the text of PDFs not read yet is part of what the notes say
    final useModel = ready();
    final qv = useModel ? await _embedder.embed(question) : null;

    status?.call(tr('Looking for the notes that fit...'));
    final citing = await _citingNotes(question);
    final scored = <({NoteSummary note, double score})>[];
    for (final n in await _notes.listNotes()) {
      if (n.locked) continue;
      var score = 0.0;
      if (qv != null) {
        final v = await _sorter.vectorOf(n.id);
        if (v != null) score += math.max(0, cosine(qv, v));
      }
      final text = await _notes.text.noteText(n.id, limit: 6000);
      score += (qv == null ? 1.0 : 0.5) * _overlap(terms, text) + 0.3 * _overlap(terms, n.title);
      if (citing.containsKey(n.id)) score += 1.0; // it cites what the question is about
      if (score > 0) scored.add((note: n, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    final chosen = scored.take(notes).toList();
    // the notes that cite what was asked about are all read, however many (up to a few more)
    for (final c in scored.skip(notes)) {
      if (citing.containsKey(c.note.id) && chosen.length < notes + 4) chosen.add(c);
    }

    status?.call(tr('Reading the closest notes...'));
    final found = <Passage>[];
    final style = citations?.style;
    for (final c in chosen) {
      final cites = citing[c.note.id];
      if (cites != null && style != null) {
        // what the note cites is not always in its words (a key, a list at the end): it is told to the assistant as a passage
        final entries = [for (final s in cites) style.entry(s).replaceAll('*', '')];
        found.add(Passage(c.note.id, c.note.title.isEmpty ? tr('Untitled') : c.note.title, tr('Citations'), null, '${tr('This note cites')}: ${entries.join(' | ')}', 3));
      }
      await analyse(c.note.id);
      final chunks = await _notes.knowledge.chunksOf(c.note.id);
      final perNote = <Passage>[];
      for (final k in chunks) {
        var s = _overlap(terms, k.text) * (qv == null ? 1.0 : 0.3);
        if (qv != null && k.vector != null) s += math.max(0, cosine(qv, k.vector!));
        if (s > 0) perNote.add(Passage(c.note.id, c.note.title.isEmpty ? tr('Untitled') : c.note.title, k.label, k.page, k.text, s));
      }
      perNote.sort((a, b) => b.score.compareTo(a.score));
      found.addAll(perNote.take(4));
    }
    found.sort((a, b) => b.score.compareTo(a.score));
    final best = found.take(passages).toList();
    // back in the order of the notes, then of the pages, so that what belongs together is read together
    final rank = {for (var i = 0; i < chosen.length; i++) chosen[i].note.id: i};
    best.sort((a, b) {
      final byNote = (rank[a.noteId] ?? chosen.length).compareTo(rank[b.noteId] ?? chosen.length);
      return byNote != 0 ? byNote : (a.page ?? -1).compareTo(b.page ?? -1);
    });
    return Retrieval([for (final c in chosen) (id: c.note.id, title: c.note.title, score: c.score)], best);
  }
}
