import '../search/search_query.dart' show SearchQuery;
import 'document_index.dart' show searchTerms;

/// What starts a line that was read out of handwriting (or a formula in it) by the app, in the text the model is given: that reading
/// can be wrong, and the model is told to say so when an answer rests on it.
const handwritingMark = '✎ ';

/// A passage the model was given, as it was marked: `[Biology 101 - Page 3]` (all notes) or `[Page 3]` (one note).
class KnownMark {
  /// The mark as written between the brackets, without the date a passage may be marked with.
  final String mark;

  /// The note's title ('' when the question is about one note, which the person has open).
  final String title;

  /// Zero-based; null for the title of a note.
  final int? page;

  /// The note it is in ('' for the open note).
  final String noteId;
  const KnownMark(this.mark, {this.title = '', this.page, this.noteId = ''});
}

/// A source the answer names, and whether the passage it names says what the answer says there.
class CitedSource {
  final KnownMark mark;

  /// The statements that cite it and that the passage does not seem to support (words or numbers it lacks).
  final List<String> unsupported;

  /// A mark that fits an unsupported statement better, when the model named the wrong page.
  final KnownMark? better;

  /// A few words of the passage that the statement rests on, as they are written in the note (to find and light up there); empty
  /// when there is nothing to find by (a formula, or no words in common).
  final String quote;

  /// Whether those words were read from handwriting by the app (and so may be misread).
  final bool handwriting;
  /// What the passage says where the statements rest on it (a sentence or two, as written in the note), for the person to check.
  final List<String> evidence;

  /// Why it does not seem to say what is said (see [ClaimCheck.doubt]); null when it does.
  final String? reason;
  const CitedSource(this.mark, this.unsupported, this.better, {this.quote = '', this.handwriting = false, this.evidence = const [], this.reason});

  bool get supported => unsupported.isEmpty;
}

/// One source a statement names: where, and the words to light up there.
class ClaimSource {
  final KnownMark mark;
  final String quote;
  final bool handwriting;
  const ClaimSource(this.mark, this.quote, this.handwriting);
}

/// One statement of an answer, the passages it names and whether they seem to say it.
class ClaimCheck {
  final String text;
  final List<ClaimSource> sources;

  /// Why the passages named do not seem to say it (null: they do, or there is nothing to check it against): 'words' (few of its
  /// words are there) or 'numbers:' and the numbers of it that are not.
  final String? doubt;

  /// A passage that fits it better, when the model named the wrong page.
  final KnownMark? better;
  const ClaimCheck(this.text, this.sources, {this.doubt, this.better});
}

/// What an answer says about where it comes from, checked against what the model was given.
class AnswerCheck {
  /// The passages the answer names, in the order it first names them.
  final List<CitedSource> sources;

  /// Citations that look like one but name nothing the model was given (made up, or from before).
  final List<String> unknown;

  /// The statements of the answer one by one (those with something to say), with the passages each names.
  final List<ClaimCheck> claims;

  /// The answer with each citation it makes written as the numbers of [sources] (`[1]`, `[2, 3]`): so that what stands on what is
  /// seen where it is said.
  final String display;
  const AnswerCheck(this.sources, this.unknown, {this.claims = const [], this.display = ''});

  /// Whether the answer names a passage it was given.
  bool get cited => sources.isNotEmpty;

  /// Whether an answer rests on something read from handwriting.
  bool get usesHandwriting => sources.any((s) => s.handwriting);

  bool get hasProblems => unknown.isNotEmpty || sources.any((s) => !s.supported);
}

String _norm(String s) {
  var t = s.toLowerCase().replaceAll(RegExp(r'\s*-\s*changed\s+\d{4}-\d\d-\d\d'), '');
  t = t.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();
  return t;
}

/// The text given for each mark, by its normalised mark: the lines of [given] that are a known mark (alone on a line, in brackets,
/// possibly with the date it changed) start its passage, which lasts to the next one.
Map<String, String> passagesOf(String given, Iterable<KnownMark> known) {
  final byNorm = {for (final k in known) _norm(k.mark): k};
  final out = <String, StringBuffer>{};
  StringBuffer? current;
  for (final line in given.split('\n')) {
    final t = line.trim();
    if (t.length > 2 && t.startsWith('[') && t.endsWith(']')) {
      final k = byNorm[_norm(t.substring(1, t.length - 1))];
      if (k != null) {
        current = out.putIfAbsent(_norm(k.mark), () => StringBuffer());
        current.write('\n');
        continue;
      }
    }
    current?.write('$line\n');
  }
  return {for (final e in out.entries) e.key: e.value.toString()};
}

final _group = RegExp(r'\[([^\[\]\n]{1,100})\](?!\()|\(([^()\n]{1,100})\)');
final _pageWord = RegExp(r'^(?:pages?|pp?\.?|seiten?|s\.|pages?|pag(?:e|ina)s?)\s*(\d+(?:\s*(?:,|-|–|&|and|und)\s*\d+)*)$', caseSensitive: false);
final _number = RegExp(r'\d+(?:[.,]\d+)?');

/// The marks that citation [text] (what stands in the brackets) names, none when it names nothing known.
List<KnownMark> _resolve(String text, List<KnownMark> known) {
  final c = _norm(text);
  if (c.isEmpty) return const [];
  for (final k in known) {
    if (_norm(k.mark) == c) return [k];
  }
  // several in one: "Page 3; Page 5"
  final parts = text.split(RegExp(r'\s*;\s*'));
  if (parts.length > 1) {
    final all = [for (final p in parts) ..._resolve(p, known)];
    if (all.isNotEmpty) return all;
  }
  // the title and a page, written another way: "Biology 101, p. 3"
  final pages = {for (final m in RegExp(r'\d+').allMatches(text)) int.parse(m[0]!) - 1};
  final titled = known.where((k) => k.title.isNotEmpty && c.contains(_norm(k.title))).toList();
  if (titled.isNotEmpty) {
    final hit = titled.where((k) => k.page != null && pages.contains(k.page)).toList();
    if (hit.isNotEmpty) return hit;
    final title = titled.where((k) => k.page == null).toList();
    if (title.isNotEmpty && pages.isEmpty) return title;
    return const [];
  }
  // just the page ("p. 3", "Seiten 3-5"), where the note is the open one
  final m = _pageWord.firstMatch(text.trim());
  if (m != null) {
    final numbers = <int>{};
    final spec = m[1]!;
    final range = RegExp(r'^(\d+)\s*[-–]\s*(\d+)$').firstMatch(spec.trim());
    if (range != null) {
      final a = int.parse(range[1]!), b = int.parse(range[2]!);
      if (b >= a && b - a <= 40) numbers.addAll([for (var n = a; n <= b; n++) n]);
    } else {
      numbers.addAll(RegExp(r'\d+').allMatches(spec).map((x) => int.parse(x[0]!)));
    }
    final byPage = known.where((k) => k.title.isEmpty && k.page != null && numbers.contains(k.page! + 1)).toList();
    if (byPage.isNotEmpty) return byPage;
  }
  return const [];
}

/// Whether [text] looks like the name of a source, so that one that matches nothing given is told to the person ("[Page 40]").
bool _looksLikeCitation(String text, List<KnownMark> known) {
  final t = text.trim();
  if (_pageWord.hasMatch(t)) return true;
  final c = _norm(t);
  if (known.any((k) => k.title.isNotEmpty && c.contains(_norm(k.title)))) return true;
  return known.isNotEmpty && RegExp(r'^[^\d]{2,60}\s*[-,]\s*(?:page|p\.?|seite|s\.)\s*\d+$', caseSensitive: false).hasMatch(t);
}

/// The stretch of [passage] a statement with [claimTerms] rests on: its sentence with most of the words, cut to six words around
/// the best of them, and whether that sentence was read from handwriting.
({String quote, bool handwriting, String sentence}) _quoteOf(String passage, Set<String> claimTerms) {
  var bestScore = 0;
  var bestWords = const <String>[];
  var bestSentence = '';
  var bestInk = false;
  for (final line in passage.split('\n')) {
    final ink = line.trimLeft().startsWith(handwritingMark.trim());
    for (final raw in line.split(RegExp(r'(?<=[.!?])\s+'))) {
      final sentence = raw.replaceFirst(handwritingMark.trim(), '').trim();
      final words = sentence.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
      final score = searchTerms(words.join(' ')).where(claimTerms.contains).length;
      if (score > bestScore) {
        bestScore = score;
        bestWords = words;
        bestSentence = sentence;
        bestInk = ink;
      }
    }
  }
  if (bestScore == 0) return (quote: '', handwriting: false, sentence: '');
  final sentence = bestSentence.length > 240 ? '${bestSentence.substring(0, 237)}...' : bestSentence;
  // the words to find it by: a run of plain words (no formula, no Markdown), as the note has them
  const size = 6;
  var quote = '';
  var best = 0;
  for (var i = 0; i < bestWords.length; i++) {
    final run = <String>[];
    for (var j = i; j < bestWords.length && run.length < size; j++) {
      final w = bestWords[j];
      if (w.contains(r'$') || w.contains('*') || w.contains(r'\')) break;
      run.add(w);
    }
    if (run.length < 2) continue;
    final n = searchTerms(run.join(' ')).where(claimTerms.contains).length;
    if (n > best) {
      best = n;
      quote = run.join(' ');
    }
  }
  return (quote: quote, handwriting: bestInk, sentence: sentence);
}

/// Which citations in [answer] name what the model was given ([known], with its text in [given]), and whether the passage named
/// says what the statement that names it says. A statement is doubted when many of its words are not in the passage, or a number
/// in it is not; that is a hint for the person, not a verdict, so the bar is low.
AnswerCheck checkAnswer(String answer, String given, List<KnownMark> known) {
  if (known.isEmpty || answer.trim().isEmpty) return const AnswerCheck([], []);
  final passages = passagesOf(given, known);
  final termsOf = <String, Set<String>>{};
  final numbersOf = <String, Set<String>>{};
  Set<String> terms(KnownMark k) => termsOf.putIfAbsent(_norm(k.mark), () => searchTerms(passages[_norm(k.mark)] ?? '').toSet());
  Set<String> numbers(KnownMark k) =>
      numbersOf.putIfAbsent(_norm(k.mark), () => {for (final m in _number.allMatches(passages[_norm(k.mark)] ?? '')) m[0]!.replaceAll(',', '.')});
  bool hasText(KnownMark k) => (passages[_norm(k.mark)] ?? '').trim().isNotEmpty;

  // statements and the citations in them (a citation on a line of its own belongs to the statement before)
  final claims = <({String text, List<KnownMark> cites})>[];
  final unknown = <String>[];
  // (the citations are lifted out first: "(p. 2)" must not end a sentence at its "p.")
  final groups = <String>[];
  final groupMarks = <List<KnownMark>>[];
  final lifted = answer.replaceAllMapped(_group, (g) {
    groups.add(g[0]!);
    groupMarks.add(const []);
    return '\u0001${groups.length - 1}\u0001';
  });
  final token = RegExp('\u0001(\\d+)\u0001');
  for (final segment in lifted.split(RegExp(r'(?<=[.!?:])\s+|\n+'))) {
    final cites = <KnownMark>[];
    for (final t in token.allMatches(segment)) {
      final g = _group.firstMatch(groups[int.parse(t[1]!)])!;
      final inner = (g[1] ?? g[2])!;
      final found = _resolve(inner, known);
      groupMarks[int.parse(t[1]!)] = found;
      if (found.isNotEmpty) {
        cites.addAll(found);
      } else if (g[1] != null && _looksLikeCitation(inner, known) && !unknown.contains(inner.trim())) {
        unknown.add(inner.trim());
      } else if (g[2] != null && _pageWord.hasMatch(inner.trim()) && !unknown.contains(inner.trim())) {
        unknown.add(inner.trim());
      }
    }
    final text = segment.replaceAll(token, '').replaceFirst(RegExp(r'^\s*(?:[-*]|\d+[.)])\s+'), '').trim();
    if (text.length < 3 && cites.isNotEmpty && claims.isNotEmpty) {
      claims.last.cites.addAll(cites);
    } else if (cites.isNotEmpty || text.isNotEmpty) {
      claims.add((text: text, cites: cites));
    }
  }

  final order = <String>[];
  final marks = <String, KnownMark>{};
  final doubts = <String, List<String>>{};
  final better = <String, KnownMark>{};
  final quotes = <String, ({String quote, bool handwriting, String sentence})>{};
  final evidence = <String, List<String>>{};
  final reasons = <String, String>{};
  final shown = <ClaimCheck>[];
  for (final claim in claims) {
    if (claim.cites.isEmpty) continue;
    // (a formula is written in so many ways that its symbols and digits say nothing about whether a passage has it)
    final checked = claim.text.replaceAll(RegExp(r'\$\$?[^$]+\$\$?'), ' ');
    final claimTerms = searchTerms(checked).toSet();
    final claimNumbers = {for (final m in _number.allMatches(checked)) m[0]!.replaceAll(',', '.')};
    for (final k in claim.cites.toSet()) {
      final key = _norm(k.mark);
      if (!marks.containsKey(key)) {
        marks[key] = k;
        order.add(key);
        doubts[key] = [];
      }
    }
    final withText = claim.cites.where(hasText).toList();
    final claimQuotes = {for (final k in claim.cites.toSet()) _norm(k.mark): hasText(k) ? _quoteOf(passages[_norm(k.mark)]!, claimTerms) : (quote: '', handwriting: false, sentence: '')};
    for (final e in claimQuotes.entries) {
      quotes.putIfAbsent(e.key, () => e.value);
      final list = evidence.putIfAbsent(e.key, () => []);
      if (e.value.sentence.isNotEmpty && !list.contains(e.value.sentence) && list.length < 2) list.add(e.value.sentence);
    }
    ClaimCheck made({String? doubt, KnownMark? better}) => ClaimCheck(
        claim.text, [for (final k in claim.cites.toSet()) ClaimSource(k, claimQuotes[_norm(k.mark)]!.quote, claimQuotes[_norm(k.mark)]!.handwriting)],
        doubt: doubt, better: better);
    if (withText.isEmpty) {
      shown.add(made()); // (read by a tool, or a title: nothing here to check it against)
      continue;
    }
    final have = {for (final k in withText) ...terms(k)};
    final haveNumbers = {for (final k in withText) ...numbers(k)};
    final overlap = claimTerms.isEmpty ? 1.0 : claimTerms.where(have.contains).length / claimTerms.length;
    final missing = claimNumbers.where((n) => !haveNumbers.contains(n) && !claim.cites.any((k) => k.page != null && '${k.page! + 1}' == n)).toList();
    // (a statement that is put in other words has few of the words of the passage: only little in common, or a number that is not there)
    final weak = (claimTerms.length >= 4 && overlap < 0.2) || missing.isNotEmpty && claimTerms.length >= 2;
    if (!weak) {
      shown.add(made());
      continue;
    }
    for (final k in withText) {
      doubts[_norm(k.mark)]!.add(claim.text);
      reasons.putIfAbsent(_norm(k.mark), () => missing.isNotEmpty ? 'numbers:${missing.join(', ')}' : 'words');
    }
    // another passage that has it
    KnownMark? best;
    var bestScore = overlap < 0.3 ? 0.5 : overlap + 0.2;
    for (final other in known) {
      if (!hasText(other) || withText.contains(other)) continue;
      final t = terms(other);
      if (claimTerms.isEmpty || missing.any((n) => !numbers(other).contains(n))) continue;
      final score = claimTerms.where(t.contains).length / claimTerms.length;
      if (score >= bestScore) {
        best = other;
        bestScore = score;
      }
    }
    if (best != null) better[_norm(withText.first.mark)] = best;
    shown.add(made(
        doubt: missing.isNotEmpty ? 'numbers:${missing.join(', ')}' : 'words', better: best));
  }
  // (statements with no source, of some substance, are shown too: the person sees what stands on nothing)
  final all = <ClaimCheck>[];
  for (final claim in claims) {
    final found = shown.where((c) => c.text == claim.text).firstOrNull;
    if (claim.text.isEmpty) continue;
    if (found != null) {
      all.add(found);
    } else if (claim.cites.isEmpty && searchTerms(claim.text.replaceAll(RegExp(r'\$\$?[^$]+\$\$?'), ' ')).length >= 4) {
      all.add(ClaimCheck(claim.text, const []));
    }
  }
  var at = 0;
  final display = answer.replaceAllMapped(_group, (g) {
    final found = groupMarks[at++];
    if (found.isEmpty) return g[0]!;
    final numbers = {for (final k in found) order.indexOf(_norm(k.mark)) + 1}.toList()..sort();
    return '[${numbers.join(', ')}]';
  });
  return AnswerCheck([
    for (final key in order)
      CitedSource(marks[key]!, doubts[key]!, better[key],
          quote: quotes[key]?.quote ?? '', handwriting: quotes[key]?.handwriting ?? false, evidence: evidence[key] ?? const [], reason: reasons[key])
  ], unknown, claims: all, display: display);
}

/// The search that finds [quote] (a few words of a passage) where it is written, whatever lies between its words.
SearchQuery quoteQuery(String quote) => SearchQuery(quote.trim().split(RegExp(r'\s+')).map(RegExp.escape).join(r'\s+'), regex: true);
