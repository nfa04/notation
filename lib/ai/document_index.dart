import 'dart:math' as math;

/// A piece of the document, with where it is.
class DocChunk {
  /// For the assistant's text and the person: 'Page 3', or 'Title'.
  final String where;

  /// The page it is on (zero-based), or null when it belongs to no page.
  final int? page;
  final String text;

  const DocChunk(this.where, this.page, this.text);
}

/// What was picked from the document for a question.
class Excerpts {
  /// The passages, in document order, each marked with its place: what the
  /// assistant reads.
  final String text;

  /// Pages (zero-based) the best passages are on, most relevant first.
  final List<int> pages;

  /// Whether the whole document fits and was given.
  final bool complete;

  const Excerpts(this.text, this.pages, this.complete);
}

/// Splits [text] of one place into chunks of about [maxLength] characters,
/// at paragraph breaks where it can, at sentences or words where it must.
List<DocChunk> chunkText(String where, int? page, String text, {int maxLength = 700}) {
  final chunks = <DocChunk>[];
  var current = StringBuffer();

  void flush() {
    final t = current.toString().trim();
    if (t.isNotEmpty) chunks.add(DocChunk(where, page, t));
    current = StringBuffer();
  }

  void add(String piece) {
    if (current.length > 0 && current.length + piece.length + 1 > maxLength) flush();
    if (current.length > 0) current.write('\n');
    current.write(piece);
  }

  for (final paragraph in text.split(RegExp(r'\n\s*\n|\r\n\s*\r\n'))) {
    final p = paragraph.trim();
    if (p.isEmpty) continue;
    if (p.length <= maxLength) {
      add(p);
      continue;
    }
    // a long paragraph: by sentences, and by words when a sentence is still too long
    for (final sentence in p.split(RegExp(r'(?<=[.!?])\s+'))) {
      if (sentence.length <= maxLength) {
        add(sentence);
        continue;
      }
      flush();
      var start = 0;
      while (start < sentence.length) {
        var end = math.min(start + maxLength, sentence.length);
        if (end < sentence.length) {
          final space = sentence.lastIndexOf(' ', end);
          if (space > start + maxLength ~/ 2) end = space;
        }
        chunks.add(DocChunk(where, page, sentence.substring(start, end).trim()));
        start = end;
      }
    }
  }
  flush();
  return chunks;
}

const _stop = {
  'the', 'and', 'for', 'are', 'was', 'were', 'what', 'which', 'who', 'whom', 'how', 'why', 'when', 'where', 'does', 'did',
  'this', 'that', 'these', 'those', 'with', 'from', 'about', 'into', 'have', 'has', 'had', 'can', 'could', 'would',
  'should', 'will', 'not', 'but', 'you', 'your', 'there', 'their', 'they', 'them', 'its', 'any', 'all', 'some', 'tell',
  'der', 'die', 'das', 'und', 'ist', 'sind', 'war', 'wie', 'wer', 'wann', 'wo', 'warum', 'mit', 'von', 'zu',
  'den', 'dem', 'des', 'ein', 'eine', 'einen', 'einer', 'nicht', 'auch', 'auf', 'für', 'bei', 'als', 'oder', 'aber',
  'les', 'est', 'sont', 'une', 'pour', 'dans', 'que', 'qui', 'quoi', 'comment', 'pourquoi', 'avec', 'sur',
};

/// The words of [text] worth matching, cut to their first five letters so that
/// plurals and endings ("exams", "Prüfungen") still meet their stem.
List<String> searchTerms(String text) => [
      for (final m in RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches(text.toLowerCase()))
        if (m[0]!.length >= 3 && !_stop.contains(m[0]))
          m[0]!.length > 5 ? m[0]!.substring(0, 5) : m[0]!,
    ];

/// The text of a whole document, in chunks, from which the ones that matter for
/// a question are picked: a model can only be given so much at once.
class DocumentIndex {
  final List<DocChunk> chunks;

  DocumentIndex(this.chunks);

  int get totalChars => chunks.fold(0, (sum, c) => sum + _cost(c));

  bool get isEmpty => chunks.isEmpty;

  static int _cost(DocChunk c) => c.text.length + c.where.length + 6;

  /// The chunks that best answer [query], at most [budget] characters of them,
  /// back in document order. A document that fits is given whole.
  Excerpts select(String query, int budget) {
    if (chunks.isEmpty) return const Excerpts('', [], true);
    final terms = searchTerms(query).toSet();
    final scores = _scores(terms);

    // pages of the best matches, for pointing the person at them
    final ranked = [for (var i = 0; i < chunks.length; i++) if (scores[i] > 0) i]
      ..sort((a, b) => scores[b].compareTo(scores[a]));
    final pages = <int>[];
    for (final i in ranked) {
      final page = chunks[i].page;
      if (page != null && !pages.contains(page)) pages.add(page);
      if (pages.length >= 4) break;
    }

    if (totalChars <= budget) return Excerpts(_render(List.generate(chunks.length, (i) => i)), pages, true);

    final order = <int>[];
    if (ranked.isEmpty) {
      // nothing in particular was asked for ("summarize it"): the start, then an even spread
      order.add(0);
      final step = math.max(1, chunks.length ~/ 12);
      for (var i = step; i < chunks.length; i += step) {
        order.add(i);
      }
    } else {
      order.addAll(ranked);
    }
    final picked = <int>{};
    var used = 0;
    for (final i in order) {
      final cost = _cost(chunks[i]);
      if (used + cost > budget) {
        if (picked.isEmpty) {
          // even the best one is too long: a part of it
          picked.add(i);
          used = budget;
        }
        continue;
      }
      picked.add(i);
      used += cost;
    }
    final inOrder = picked.toList()..sort();
    return Excerpts(_render(inOrder, clip: budget), pages, false);
  }

  List<double> _scores(Set<String> terms) {
    if (terms.isEmpty) return List.filled(chunks.length, 0.0);
    final counts = [
      for (final c in chunks)
        () {
          final tf = <String, int>{};
          for (final t in searchTerms(c.text)) {
            tf[t] = (tf[t] ?? 0) + 1;
          }
          return tf;
        }()
    ];
    final n = chunks.length;
    final scores = List.filled(n, 0.0);
    for (final term in terms) {
      final df = counts.where((tf) => tf.containsKey(term)).length;
      if (df == 0) continue;
      final idf = math.log(1 + n / (1 + df));
      for (var i = 0; i < n; i++) {
        final tf = counts[i][term] ?? 0;
        if (tf > 0) scores[i] += idf * tf / (tf + 1.2);
      }
    }
    return scores;
  }

  /// Chunks marked with their place; neighbours on one page share a mark.
  String _render(List<int> indexes, {int? clip}) {
    final out = StringBuffer();
    String? last;
    for (final i in indexes) {
      final c = chunks[i];
      if (c.where != last) {
        if (out.isNotEmpty) out.write('\n\n');
        out.write('[${c.where}]\n');
        last = c.where;
      } else {
        out.write('\n');
      }
      out.write(c.text);
    }
    final text = out.toString();
    return clip != null && text.length > clip + 200 ? text.substring(0, clip + 200) : text;
  }
}
