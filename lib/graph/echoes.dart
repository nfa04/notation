import '../data/note_data.dart';

/// Another note that says something about what is being written: the terms that both have, and a page of that note where one of them is.
class Echo {
  final String noteId;
  final List<String> terms;
  final int? page;

  const Echo(this.noteId, this.terms, this.page);
}

/// The terms of the facts the graph holds (their keywords and titles), to tell which other notes a piece of writing echoes: "you wrote about
/// this before". No model is asked: it is a look-up of words in the facts that were made already.
class EchoIndex {
  /// A term that is in the facts of more than this share of the notes tells nothing (a word every note has).
  static const commonShare = 0.4;

  final Map<String, Set<String>> _notesOf = {};
  final Map<String, Map<String, int?>> _pageOf = {}; // note -> term -> page
  int _notes = 0;

  EchoIndex(Iterable<StoredFact> facts) {
    final notes = <String>{};
    for (final f in facts) {
      notes.add(f.noteId);
      for (final raw in [...f.keywords, f.title]) {
        final t = normalize(raw);
        if (!_usable(t)) continue;
        _notesOf.putIfAbsent(t, () => {}).add(f.noteId);
        (_pageOf.putIfAbsent(f.noteId, () => {})[t] ??= f.page);
      }
    }
    _notes = notes.length;
  }

  static String normalize(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

  /// A single word needs four letters; a phrase is fine.
  static bool _usable(String t) => t.contains(' ') ? t.length >= 5 : t.length >= 4;

  bool get isEmpty => _notesOf.isEmpty;

  bool _common(String term) => _notesOf[term]!.length > (_notes * commonShare < 3 ? 3 : _notes * commonShare);

  /// The notes (other than [exceptNote]) whose facts have terms that [text] has, the one with the most such terms first. A note counts when
  /// it shares two terms, or one that is a phrase of several words.
  List<Echo> find(String text, {required String exceptNote, int max = 3}) {
    final words = ' ${normalize(text)} ';
    if (words.trim().length < 8) return const [];
    final hits = <String, List<String>>{};
    for (final e in _notesOf.entries) {
      final term = e.key;
      if (!words.contains(' $term ') || _common(term)) continue;
      for (final note in e.value) {
        if (note != exceptNote) hits.putIfAbsent(note, () => []).add(term);
      }
    }
    final echoes = [
      for (final e in hits.entries)
        if (e.value.length >= 2 || e.value.any((t) => t.contains(' '))) Echo(e.key, e.value..sort(), _pageOf[e.key]![e.value.first]),
    ]..sort((a, b) {
        final c = b.terms.length.compareTo(a.terms.length);
        return c != 0 ? c : a.noteId.compareTo(b.noteId);
      });
    return echoes.take(max).toList();
  }
}
