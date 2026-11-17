import 'search_query.dart' show MatchRange;

/// Matching with typos: the words of a query are looked for in a text allowing a few wrong, missing, extra or swapped letters
/// ("recieve" finds "receive", "Schmidt" finds "Schmitt"). Short words must be right; the longer a word, the more it may be off.

final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// How many letters of a word of [length] letters may be wrong: none up to three letters, one up to six, else two.
int typosAllowed(int length) => length <= 3 ? 0 : (length <= 6 ? 1 : 2);

/// The distance between [a] and [b] (a letter put in, left out, changed, or two next to each other swapped each count one), or more than
/// [limit] when it is more than that.
int editDistance(String a, String b, int limit) {
  if ((a.length - b.length).abs() > limit) return limit + 1;
  var twoBack = List<int>.filled(b.length + 1, 0);
  var back = [for (var j = 0; j <= b.length; j++) j];
  for (var i = 1; i <= a.length; i++) {
    final row = List<int>.filled(b.length + 1, 0)..[0] = i;
    var best = row[0];
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var v = back[j - 1] + cost;
      if (back[j] + 1 < v) v = back[j] + 1;
      if (row[j - 1] + 1 < v) v = row[j - 1] + 1;
      if (i > 1 && j > 1 && a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) && a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1) && twoBack[j - 2] + 1 < v) {
        v = twoBack[j - 2] + 1;
      }
      row[j] = v;
      if (v < best) best = v;
    }
    if (best > limit) return limit + 1; // (no way back below the limit from here)
    twoBack = back;
    back = row;
  }
  return back[b.length];
}

/// The places in [text] where the words of [query] are, as the same words in the same order next to each other, each allowed the
/// typos [typosAllowed] says. At most [limit]. A query with no words finds nothing.
List<MatchRange> fuzzyRanges(String text, String query, {bool caseSensitive = false, int limit = 1000}) {
  final wanted = [for (final m in _word.allMatches(caseSensitive ? query : query.toLowerCase())) m.group(0)!];
  if (wanted.isEmpty) return const [];
  final tokens = _word.allMatches(text).toList();
  final lower = [for (final t in tokens) caseSensitive ? t.group(0)! : t.group(0)!.toLowerCase()];
  final found = <MatchRange>[];
  bool same(int token, int w) {
    final allow = typosAllowed(wanted[w].length);
    return editDistance(lower[token], wanted[w], allow) <= allow;
  }

  for (var i = 0; i + wanted.length <= tokens.length; i++) {
    var all = true;
    for (var w = 0; w < wanted.length && all; w++) {
      all = same(i + w, w);
    }
    if (!all) continue;
    found.add(MatchRange(tokens[i].start, tokens[i + wanted.length - 1].end));
    if (found.length >= limit) break;
    i += wanted.length - 1; // (the next match starts after this one)
  }
  return found;
}
