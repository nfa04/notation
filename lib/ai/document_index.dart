import 'dart:math' as math;
import 'dart:typed_data';

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

/// What a question is about, which decides what of the document the assistant is given.
enum QuestionScope {
  /// Something in particular: the passages that fit it.
  passages,

  /// The pages it names (or the page the person is on): those pages whole.
  pages,

  /// The whole document (a summary, the key points): as much of it as fits, from all over it.
  whole,
}

/// What [focusOf] made of a question.
class QuestionFocus {
  final QuestionScope scope;

  /// For [QuestionScope.pages]: the pages (zero-based).
  final List<int> pages;
  const QuestionFocus(this.scope, [this.pages = const []]);

  static const passages = QuestionFocus(QuestionScope.passages);
}

final _pageWord = RegExp(r'\b(?:pages?|pp?\.|seiten?|s\.|pg\.?)\s*(\d{1,4})(?:\s*(?:-|–|to|bis|and|und|&)\s*(\d{1,4}))?', caseSensitive: false, unicode: true);
final _thisPage = RegExp(r'\b(?:this|current|that|the open|diese[rnms]?|aktuelle[rnms]?|cette)\s+(?:page|seite|sheet|blatt)\b', caseSensitive: false, unicode: true);
final _whole = RegExp(
    r'\b(?:summar\w*|sum up|overview|outline|key (?:points?|ideas?|takeaways?|terms?)|main (?:points?|ideas?|topics?)|tl;?dr|gist|'
    r'what (?:is|\x27s) (?:it|this|the (?:note|document|text)) about|zusammenfass\w*|fasse? .{0,40}zusammen|überblick|wichtigsten?|hauptpunkte|'
    r'worum geht|kernaussagen?|résum\w*|points? (?:clés?|principaux))\b',
    caseSensitive: false,
    unicode: true);

/// Whether [question] is about the whole document, about pages it names (or "this page", which is [currentPage]), or about
/// something in particular. Page numbers count from 1 in the question; pages past [pageCount] are left out.
QuestionFocus focusOf(String question, {int? currentPage, int? pageCount}) {
  final pages = <int>[];
  bool fits(int p) => p >= 0 && (pageCount == null || p < pageCount);
  for (final m in _pageWord.allMatches(question)) {
    final from = int.parse(m[1]!) - 1;
    final to = m[2] == null ? from : int.parse(m[2]!) - 1;
    for (var p = from; p <= to && p - from < 20; p++) {
      if (fits(p) && !pages.contains(p)) pages.add(p);
    }
  }
  if (currentPage != null && fits(currentPage) && _thisPage.hasMatch(question) && !pages.contains(currentPage)) pages.add(currentPage);
  if (pages.isNotEmpty) return QuestionFocus(QuestionScope.pages, pages);
  if (_whole.hasMatch(question)) return const QuestionFocus(QuestionScope.whole);
  return QuestionFocus.passages;
}

/// Cosine similarity of two vectors of the same length (0 when either is empty).
double cosineOf(Float32List a, Float32List b) {
  if (a.length != b.length || a.isEmpty) return 0;
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return na == 0 || nb == 0 ? 0 : dot / math.sqrt(na * nb);
}

/// The text of a whole document, in chunks, from which the ones that matter for
/// a question are picked: a model can only be given so much at once.
class DocumentIndex {
  final List<DocChunk> chunks;

  /// The vector of each chunk (by index) where a sentence model has read it; a chunk without one is found by its words alone.
  final List<Float32List?> vectors;

  DocumentIndex(this.chunks, {List<Float32List?>? vectors}) : vectors = vectors ?? List.filled(chunks.length, null);

  /// The same chunks with [vectors].
  DocumentIndex withVectors(List<Float32List?> vectors) => DocumentIndex(chunks, vectors: vectors);

  int get totalChars => chunks.fold(0, (sum, c) => sum + _cost(c));

  bool get isEmpty => chunks.isEmpty;

  /// How many pages the document has (as far as its chunks say).
  int get pageCount => chunks.fold(0, (n, c) => c.page != null && c.page! + 1 > n ? c.page! + 1 : n);

  static int _cost(DocChunk c) => c.text.length + c.where.length + 6;

  /// The chunks that best answer [query], at most [budget] characters of them,
  /// back in document order. A document that fits is given whole. [focus] says
  /// what the question is about (see [focusOf]); [queryVector] is the question
  /// read by the sentence model, to find passages that say it in other words.
  Excerpts select(String query, int budget, {QuestionFocus focus = QuestionFocus.passages, Float32List? queryVector}) {
    if (chunks.isEmpty) return const Excerpts('', [], true);
    final terms = searchTerms(query).toSet();
    final scores = _scores(terms, queryVector);

    // pages of the best matches, for pointing the person at them
    final ranked = [for (var i = 0; i < chunks.length; i++) if (scores[i] > 0) i]
      ..sort((a, b) => scores[b].compareTo(scores[a]));
    final pages = <int>[if (focus.scope == QuestionScope.pages) ...focus.pages];
    if (focus.scope != QuestionScope.whole) {
      for (final i in ranked) {
        final page = chunks[i].page;
        if (page != null && !pages.contains(page)) pages.add(page);
        if (pages.length >= 4) break;
      }
    }

    if (totalChars <= budget) return Excerpts(_render(List.generate(chunks.length, (i) => i)), pages, true);

    final picked = <int>{};
    var used = 0;
    bool take(int i) {
      if (picked.contains(i)) return true;
      final cost = _cost(chunks[i]);
      if (used + cost > budget) return false;
      picked.add(i);
      used += cost;
      return true;
    }

    switch (focus.scope) {
      case QuestionScope.whole:
        // much too long to give in passages: the telling sentences of every page
        if (budget < totalChars * 0.6) return Excerpts(_skim(budget), pages, false);
        // the title and the start of every part: an even share of the room for each stretch of the document
        final ratio = budget / totalChars;
        var allowance = 0.0;
        for (var i = 0; i < chunks.length; i++) {
          final cost = _cost(chunks[i]);
          allowance += cost * ratio;
          if (i == 0 || cost <= allowance) {
            if (take(i)) allowance -= cost;
          }
        }
        // what is left of the room, for the passages that were not reached
        for (var i = 0; i < chunks.length; i++) {
          take(i);
        }
      case QuestionScope.pages:
        for (final p in focus.pages) {
          for (var i = 0; i < chunks.length; i++) {
            if (chunks[i].page == p) take(i);
          }
        }
        for (final i in ranked) {
          take(i);
        }
      case QuestionScope.passages:
        if (ranked.isEmpty) {
          // nothing in particular was found: the start, then an even spread
          return select(query, budget, focus: const QuestionFocus(QuestionScope.whole));
        }
        // the best passages, each of the first few with what comes just before and after it (a heading, the end of a thought)
        for (final (n, i) in ranked.indexed) {
          if (!take(i) && picked.isEmpty) {
            // even the best one is too long: a part of it
            picked.add(i);
            used = budget;
          }
          if (n < 3) {
            for (final j in [i - 1, i + 1]) {
              if (j >= 0 && j < chunks.length && chunks[j].page == chunks[i].page && _cost(chunks[j]) < budget ~/ 6) take(j);
            }
          }
        }
    }
    if (picked.isEmpty) picked.add(focus.scope == QuestionScope.pages ? chunks.indexWhere((c) => c.page == focus.pages.first) : 0);
    final inOrder = picked.toList()..sort();
    return Excerpts(_render(inOrder, clip: budget), pages, false);
  }

  /// How well each chunk fits: the words it shares with the question (BM25-like, scaled so the best is 1), and how close it is in
  /// meaning when there are vectors.
  List<double> _scores(Set<String> terms, Float32List? queryVector) {
    final n = chunks.length;
    final scores = List.filled(n, 0.0);
    if (terms.isNotEmpty) {
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
      for (final term in terms) {
        final df = counts.where((tf) => tf.containsKey(term)).length;
        if (df == 0) continue;
        final idf = math.log(1 + n / (1 + df));
        for (var i = 0; i < n; i++) {
          final tf = counts[i][term] ?? 0;
          if (tf > 0) scores[i] += idf * tf / (tf + 1.2);
        }
      }
      final best = scores.fold(0.0, math.max);
      if (best > 0) {
        for (var i = 0; i < n; i++) {
          scores[i] /= best;
        }
      }
    }
    if (queryVector != null) {
      // (a sentence model finds a passage that says it in other words; below 0.25 it is noise)
      for (var i = 0; i < n; i++) {
        final v = vectors[i];
        if (v == null) continue;
        final c = cosineOf(queryVector, v);
        if (c > 0.25) scores[i] += c;
      }
    }
    return scores;
  }

  /// The document skimmed into [budget] characters: every place (page) gets a share of the room that goes with its length, and
  /// fills it with its first line when that is short (a heading) and then with its sentences that say the most that is its own (the
  /// rarest words in the document), back in their order. Sentences every page has (a header, the same remarks) count for little.
  String _skim(int budget) {
    final places = <String, List<int>>{};
    for (var i = 0; i < chunks.length; i++) {
      places.putIfAbsent(chunks[i].where, () => []).add(i);
    }
    final sentences = <String, List<String>>{
      for (final e in places.entries)
        e.key: [
          for (final i in e.value)
            for (final line in chunks[i].text.split('\n'))
              for (final s in line.split(RegExp(r'(?<=[.!?;:])\s+'))) if (s.trim().isNotEmpty) s.trim(),
        ],
    };
    final df = <String, int>{};
    var count = 0;
    for (final list in sentences.values) {
      for (final s in list) {
        count++;
        for (final t in searchTerms(s).toSet()) {
          df[t] = (df[t] ?? 0) + 1;
        }
      }
    }
    double worth(String s) {
      final terms = searchTerms(s).toSet();
      if (terms.isEmpty) return 0;
      final sum = terms.fold(0.0, (a, t) => a + math.log(1 + count / (df[t] ?? 1)));
      return sum / math.sqrt(terms.length + 2);
    }

    final out = StringBuffer();
    final total = sentences.values.fold(0, (a, l) => a + l.fold(0, (b, s) => b + s.length + 1)) + 1;
    for (final e in sentences.entries) {
      final list = e.value;
      final room = math.max(80, ((budget - places.length * 12) * list.fold(0, (b, s) => b + s.length + 1) / total).floor());
      final chosen = <int>{};
      var used = 0;
      if (list.isNotEmpty && list.first.length <= 80) {
        chosen.add(0);
        used += list.first.length + 1;
      }
      final order = [for (var i = 0; i < list.length; i++) i]..sort((a, b) => worth(list[b]).compareTo(worth(list[a])));
      for (final i in order) {
        if (chosen.contains(i)) continue;
        if (used + list[i].length + 1 > room) continue;
        chosen.add(i);
        used += list[i].length + 1;
      }
      if (chosen.isEmpty) continue;
      final piece = '${out.isEmpty ? '' : '\n\n'}[${e.key}]\n${(chosen.toList()..sort()).map((i) => list[i]).join(' ')}';
      if (out.length + piece.length > budget + 200) break;
      out.write(piece);
    }
    return out.toString();
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
