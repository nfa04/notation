import 'dart:typed_data';

import '../data/note_repository.dart';
import '../llm/embedding_service.dart';
import '../l10n/language.dart';

/// How sure the sorter must be before it moves a note.
enum SortStrictness {
  careful('Careful: only when it is clearly the best fit', 0.45, 0.08),
  normal('Normal', 0.35, 0.05),
  eager('Eager: also when it is only a likely fit', 0.25, 0.02);

  final String label;

  /// The least similarity to a folder, and how far it must be ahead of the next folder.
  final double minScore, margin;

  const SortStrictness(this.label, this.minScore, this.margin);
}

/// The folder a note was found to belong in, or why none was.
class SortDecision {
  final String? folderId;
  final double score;
  final String reason;

  const SortDecision(this.folderId, this.score, this.reason);
}

/// A folder, as far as the choice is concerned.
class SortCandidate {
  final String id, name;

  /// The vectors of the notes in it, and of its name.
  final List<Float32List> notes;
  final Float32List nameVector;

  const SortCandidate(this.id, this.name, this.notes, this.nameVector);
}

/// How well a note with [vector] fits [folder]: how alike the most alike notes there are
/// (the mean of the best three), with a little of how alike the name of the folder is.
/// An empty folder is judged by its name alone.
double fitOf(Float32List vector, SortCandidate folder) {
  final byName = cosine(vector, folder.nameVector);
  if (folder.notes.isEmpty) return byName * 0.9;
  final sims = [for (final n in folder.notes) cosine(vector, n)]..sort((a, b) => b.compareTo(a));
  final top = sims.take(3).toList();
  final alike = top.reduce((a, b) => a + b) / top.length;
  return alike * 0.85 + byName * 0.15;
}

/// Picks the folder for a note with [vector] among [folders]: the best fit, if it is good
/// enough and clearly ahead of the next one. [current] is the folder the note is in.
SortDecision chooseFolder(Float32List vector, List<SortCandidate> folders, SortStrictness strictness, {String? current}) {
  if (folders.isEmpty) return SortDecision(null, 0, tr('There is no folder to choose from'));
  final scored = [for (final f in folders) (f, fitOf(vector, f))]..sort((a, b) => b.$2.compareTo(a.$2));
  final (best, score) = scored.first;
  final next = scored.length > 1 ? scored[1].$2 : -1.0;
  String pct(double v) => '${(v * 100).round()}%';
  if (score < strictness.minScore) {
    return SortDecision(null, score, tr('Not sure: the closest folder, "{name}", fits only {percent}', {'name': best.name, 'percent': pct(score)}));
  }
  if (score - next < strictness.margin) {
    return SortDecision(null, score, tr('Not sure: "{a}" ({pa}) and "{b}" ({pb}) fit about equally', {'a': best.name, 'pa': pct(score), 'b': scored[1].$1.name, 'pb': pct(next)}));
  }
  if (best.id == current) return SortDecision(null, score, tr('Already in the best folder, "{name}"', {'name': best.name}));
  final kin = best.notes.isEmpty ? tr('from its name') : trCount(best.notes.length, 'like 1 note there', 'like {n} notes there');
  return SortDecision(best.id, score, tr('Moved to "{name}" ({percent}, {kin})', {'name': best.name, 'percent': pct(score), 'kin': kin}));
}

/// Reads notes with a sentence model and files them under the folder whose notes they resemble.
class NoteSorter {
  final NoteRepository _notes;
  final TextEmbedder _embedder;

  /// Whether the model is there to read with.
  final bool Function() ready;

  /// Notes shorter than this (in characters) say too little to be filed.
  static const minText = 30;

  NoteSorter(this._notes, this._embedder, {required this.ready});

  /// A hash of [text] that is the same on every run.
  static int hashOf(String text) {
    // (BigInt because the 64-bit literals cannot be written as ints on the web; the values are the same as before on every
    // other platform, and on the web the result is rounded to what a number can hold, which is as stable as it needs to be)
    final mask = BigInt.parse('7fffffffffffffff', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    var h = BigInt.parse('cbf29ce484222325', radix: 16) & mask;
    for (final c in text.codeUnits) {
      h = ((h ^ BigInt.from(c)) * prime) & mask;
    }
    return h.toInt();
  }

  final Map<String, Float32List> _names = {};

  Future<Float32List> _nameVector(String name) async {
    final key = '${_embedder.modelId}|$name';
    return _names[key] ??= await _embedder.embed(name);
  }

  /// The vector of note [id]: kept from before when its text has not changed, else read now.
  /// [extra] is more text (from the PDF) that the database does not have; null when the note's text is too short.
  Future<Float32List?> vectorOf(String id, {String extra = ''}) async {
    final text = [await _notes.text.noteText(id), extra].where((t) => t.trim().isNotEmpty).join('\n');
    if (text.trim().length < minText) return null;
    final hash = hashOf(text);
    final kept = await _notes.knowledge.noteEmbedding(id, _embedder.modelId);
    if (kept != null && kept.textHash == hash) return kept.vector;
    // a note read without its PDF text must not replace the richer reading kept before
    if (kept != null && extra.isEmpty && (await _notes.noteInfo(id))?.pdfName != null) return kept.vector;
    final vector = await _embedder.embed(text);
    await _notes.knowledge.saveNoteEmbedding(id, _embedder.modelId, hash, vector);
    return vector;
  }

  /// Files note [noteId] and says what came of it. Only folders under [within] (a folder id; null = all)
  /// are considered. A note that is in a folder already is left alone with [unfiledOnly].
  Future<String> sort(
    String noteId, {
    String? within,
    bool unfiledOnly = true,
    SortStrictness strictness = SortStrictness.normal,
    String pdfText = '',
  }) async {
    if (!ready()) return tr('The sentence model is not installed (see Settings)');
    final info = await _notes.noteInfo(noteId);
    if (info == null) return tr('The note is gone');
    if (unfiledOnly && info.folderId != null) return tr('Left alone: it is in a folder already');
    final vector = await vectorOf(noteId, extra: pdfText.length > 3000 ? pdfText.substring(0, 3000) : pdfText);
    if (vector == null) return tr('Not enough text to tell where it belongs');

    final all = await _notes.listFolders();
    final inScope = <String>{};
    if (within == null || within.isEmpty) {
      inScope.addAll(all.map((f) => f.id));
    } else {
      void add(String id) {
        if (!inScope.add(id)) return;
        for (final f in all) {
          if (f.parentId == id) add(f.id);
        }
      }

      add(within);
      inScope.remove(within); // the folder itself is where notes are looked for, not a place to file into
      if (inScope.isEmpty) return tr('The chosen folder has no subfolders to file into');
    }
    final byFolder = <String, List<Float32List>>{};
    for (final n in await _notes.filedNotes()) {
      if (n.id == noteId || !inScope.contains(n.folderId)) continue;
      final v = await vectorOf(n.id);
      if (v != null) byFolder.putIfAbsent(n.folderId, () => []).add(v);
    }
    final candidates = [
      for (final f in all)
        if (inScope.contains(f.id)) SortCandidate(f.id, f.name, byFolder[f.id] ?? const [], await _nameVector(f.name)),
    ];
    final decision = chooseFolder(vector, candidates, strictness, current: info.folderId);
    final target = decision.folderId;
    if (target != null) await _notes.moveNote(noteId, target);
    return decision.reason;
  }
}
